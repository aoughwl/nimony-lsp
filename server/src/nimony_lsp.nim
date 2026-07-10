## nimony-lsp — entry point.
##
## Blocking stdio loop: read a framed JSON-RPC message, dispatch, write the
## response. Feature handlers live in `features/` and the `driver/` layer; this
## module owns lifecycle + document synchronization and routes requests.

import std/[json, options, os, tables, sets, strutils, times]
from std/posix import poll, TPollfd, Tnfds, POLLIN
import lsp/[jsonrpc, protocol, uris]
import server/[state, documents]
import driver/[diagnostics, idetools, nifindex, nimonycli,
               signature, highlight, rename, workspacesym, semtokens, inlay,
               folding, selection, callhierarchy, extranav, daemon,
               doclink, codelens, paramhints, typehierarchy,
               nifcache, navindex, codeaction, format, pulldiag, linkededit]

const
  ServerName = "nimony-lsp"
  ServerVersion = "0.8.0"

var gState = newServerState()
var gOut = stdout

proc c_setvbuf(f: File; buf: pointer; mode: cint; size: csize_t): cint {.
  importc: "setvbuf", header: "<stdio.h>".}
const IONBF = cint(2)   ## _IONBF: no stdio read-ahead, so poll() on fd 0 sees
                        ## exactly what is pending — required for drainReady()
                        ## to detect a burst instead of it hiding in the buffer.

# --- as-you-type debounce ---------------------------------------------------
# Live diagnostics run the nimony checker: cold ~1.1s, warm ~10-30ms. Doing that
# synchronously on EVERY keystroke stalls hover/references behind a queue of
# compiles (the "Loading…" everyone hit). Instead a document edit just marks the
# doc dirty; the loop flushes ONE coalesced live-check only after input has been
# idle for `DebounceMs`. So fast typing runs a single check when you pause, and
# hover/definition/references are answered immediately, never waiting on a check.
const DebounceMs = 200
var pendingLive: HashSet[string]   ## uris with edits not yet checked
var pendingWarm: HashSet[string]   ## freshly opened uris whose MAIN nimcache
                                   ## must be warmed before nav is fast

var lastDiagnostics = initTable[string, seq[Diagnostic]]()
  ## Last diagnostics published per uri. The `textDocument/diagnostic` PULL is
  ## served from this instantly (no recompile) so focusing a tab never blanks the
  ## squiggles while a check runs — the push path below keeps it fresh.

proc publishDiagnostics(uri: string; diags: seq[Diagnostic]) =
  lastDiagnostics[uri] = diags
  let params = %*{"uri": uri, "diagnostics": toJsonArray(diags)}
  writeMessage(gOut, notification("textDocument/publishDiagnostics", params))

var gReqCounter = 0

proc serverRequest(meth: string; params: JsonNode) =
  ## Fire a server→client request with a fresh id. The client's reply arrives as
  ## a response message (no `method`), which the intake loop silently ignores —
  ## we don't need the result for refresh/create requests.
  inc gReqCounter
  writeMessage(gOut, %*{"jsonrpc": "2.0", "id": "srv-" & $gReqCounter,
                        "method": meth, "params": params})

var gProgressCounter = 0

proc beginAnalyzeProgress(): string =
  ## Create a work-done progress token and emit its `begin` so a cold compile
  ## reads as "working", not hung. Returns the token to pass to `endProgress`.
  inc gProgressCounter
  result = "nimony-analyze-" & $gProgressCounter
  serverRequest("window/workDoneProgress/create", %*{"token": result})
  writeMessage(gOut, notification("$/progress", %*{
    "token": result,
    "value": {"kind": "begin", "title": "Nimony: analyzing…",
              "cancellable": false}}))

proc reportProgress(token, message: string) =
  writeMessage(gOut, notification("$/progress", %*{
    "token": token, "value": {"kind": "report", "message": message}}))

proc endProgress(token: string) =
  writeMessage(gOut, notification("$/progress", %*{
    "token": token, "value": {"kind": "end"}}))

proc refreshDiagnostics(uri: string) =
  ## Run nimony check for the document and publish results for every file
  ## the checker reported on (plus an explicit clear for `uri`).
  let path = filePath(uri)
  if path.len == 0 or not path.fileExists: return
  let byFile = computeDiagnostics(gState.config, path)
  # Always clear the primary file first so stale diagnostics disappear.
  var reported = initTable[string, bool]()
  for absPath, diags in byFile:
    publishDiagnostics(pathToUri(absPath), diags)
    reported[pathToUri(absPath)] = true
  if not reported.hasKey(uri):
    publishDiagnostics(uri, @[])
  serverRequest("workspace/diagnostic/refresh", newJNull())  # pull clients re-fetch the fresh cache

proc liveTempPath(realPath: string): string =
  # Ephemeral sibling of the real file (deleted right after each check), so the
  # buffer's relative imports and project config still resolve during the check.
  # NOTE: the name must NOT start with a dot — nimony derives a module id from the
  # filename and a leading-dot name yields an empty id, crashing the checker
  # (`nifreader: r.thisModule.len > 0`). It is hidden from the explorer via the
  # extension's `files.exclude` contribution (`**/nimlsp_live_*`) instead.
  realPath.parentDir / ("nimlsp_live_" & extractFilename(realPath))

proc pruneCachesNow() =
  ## Bound the nimcache/lsp pool by size, never evicting a currently-open doc.
  var keep = initHashSet[string]()
  for u in gState.docs.keys:
    let p = filePath(u)
    if p.len > 0: keep.incl nimonycli.moduleCacheDir(gState.config, p)
  nimonycli.pruneCaches(gState.config, keep)

proc cleanupLiveTemp(uri: string) =
  let path = filePath(uri)
  if path.len == 0: return
  try:
    let tmp = liveTempPath(path)
    if fileExists(tmp): removeFile(tmp)
  except CatchableError: discard

proc buildLiveCtx(uri: string; doc: Document): (idetools.LiveCtx, bool) =
  ## (ctx, wroteTemp). ctx.active only when the buffer differs from disk — so
  ## hover/definition/references reflect UNSAVED edits (they otherwise read the
  ## last-saved file). Caller MUST cleanupLiveTemp(uri) when wroteTemp. Mirrors
  ## refreshDiagnosticsLive's temp materialization (sibling dotfile, relative
  ## path, isolated .nimlsp_livecache), so nav and live diagnostics share warmth.
  result = (idetools.LiveCtx(), false)
  let path = filePath(uri)
  if path.len == 0: return
  var onDisk = ""
  var haveDisk = false
  try:
    onDisk = readFile(path); haveDisk = true
  except CatchableError: discard
  if haveDisk and onDisk == doc.text: return        # clean → disk path (warm cache)
  let tmp = liveTempPath(path)
  try: writeFile(tmp, doc.text)
  except CatchableError: return                      # write failed → fall back to disk
  let root = if gState.config.projectRoot.len > 0: gState.config.projectRoot
             else: getCurrentDir()
  let relTmp = if tmp.isAbsolute and gState.config.projectRoot.len > 0:
                 relativePath(tmp, gState.config.projectRoot)
               else: tmp
  result = (idetools.LiveCtx(active: true,
                             realAbs: normalizedPath(path),
                             tempAbs: normalizedPath(tmp),
                             tempRel: relTmp,
                             nimcache: root / ".nimlsp_livecache"), true)

proc bufferClean(uri: string; doc: Document): bool =
  ## True when the doc buffer matches what is on disk — i.e. the warm on-disk
  ## .s.nif that navindex reads reflects the buffer, so the in-process nav
  ## (definition/references/highlight) is valid. Cheap: no temp materialized.
  let path = filePath(uri)
  if path.len == 0: return false
  try: return readFile(path) == doc.text
  except CatchableError: return false

proc refreshDiagnosticsLive(uri, text: string) =
  ## As-you-type diagnostics on the UNSAVED buffer: materialize it to a stable
  ## sibling temp file, run the checker into an ISOLATED nimcache (so it stays
  ## incremental, ~10ms), and remap the temp's diagnostics onto `uri`.
  ## Synchronous: the isolated-cache check is fast enough not to lag typing.
  let path = filePath(uri)
  if path.len == 0: return
  let tmp = liveTempPath(path)
  try:
    writeFile(tmp, text)
  except CatchableError:
    return
  # The temp exists only for the duration of this check; drop it however we exit
  # (isolated .nimlsp_livecache keeps the deps warm, so re-creating it is cheap).
  defer:
    try: removeFile(tmp)
    except CatchableError: discard
  let root = if gState.config.projectRoot.len > 0: gState.config.projectRoot
             else: getCurrentDir()
  let livecache = root / ".nimlsp_livecache"
  let relTmp = if tmp.isAbsolute and gState.config.projectRoot.len > 0:
                 relativePath(tmp, gState.config.projectRoot)
               else: tmp
  let r = nimonycli.runLiveCheck(gState.config, relTmp, livecache)
  let byFile = parseOutput(gState.config, r.output)
  let tmpUri = pathToUri(normalizedPath(tmp))
  var publishedPrimary = false
  for absPath, diags in byFile:
    if pathToUri(normalizedPath(absPath)) == tmpUri:
      publishDiagnostics(uri, diags)      # remap temp → real document uri
      publishedPrimary = true
    else:
      publishDiagnostics(pathToUri(absPath), diags)
  if not publishedPrimary:
    publishDiagnostics(uri, @[])          # buffer is clean → clear
  serverRequest("workspace/diagnostic/refresh", newJNull())  # pull clients re-fetch fresh cache

# --------------------------------------------------------------------------
# request handlers
# --------------------------------------------------------------------------

proc handleInitialize(params: JsonNode): JsonNode =
  gState.rootUri = params{"rootUri"}.getStr("")
  if gState.rootUri.len > 0:
    gState.config.projectRoot = filePath(gState.rootUri)
  # initializationOptions overrides
  let opts = params{"initializationOptions"}
  if opts != nil:
    let np = opts{"nimonyPath"}.getStr("")
    if np.len > 0: gState.config.nimonyExe = np
    let ep = opts{"extraPaths"}
    if ep != nil and ep.kind == JArray:
      for x in ep: gState.config.extraPaths.add(x.getStr)
    let dp = opts{"daemonPath"}.getStr("")
    if dp.len > 0: gState.config.daemonPath = dp
    let cb = opts{"cacheBudgetMB"}
    if cb != nil and cb.kind == JInt: gState.config.cacheBudgetBytes = cb.getInt * 1_000_000
    let cp = opts{"cachePrune"}
    if cp != nil and cp.kind == JBool: gState.config.cachePrune = cp.getBool
  gState.initialized = true
  var tokenTypes = newJArray()
  for t in SemanticTokenTypes: tokenTypes.add(%t)
  var tokenMods = newJArray()
  for m in SemanticTokenModifiers: tokenMods.add(%m)
  result = %*{
    "capabilities": {
      "textDocumentSync": {"openClose": true, "change": 2, "save": {"includeText": false}},
      "definitionProvider": true,
      "referencesProvider": true,
      "hoverProvider": true,
      "documentSymbolProvider": true,
      "documentHighlightProvider": true,
      "completionProvider": {"triggerCharacters": [".", "("], "resolveProvider": true},
      "signatureHelpProvider": {"triggerCharacters": ["(", ","], "retriggerCharacters": [","]},
      "renameProvider": {"prepareProvider": true},
      "workspaceSymbolProvider": true,
      "inlayHintProvider": {"resolveProvider": true},
      "foldingRangeProvider": true,
      "selectionRangeProvider": true,
      "callHierarchyProvider": true,
      "typeDefinitionProvider": true,
      "implementationProvider": true,
      "declarationProvider": true,
      "typeHierarchyProvider": true,
      "documentLinkProvider": {"resolveProvider": false},
      "codeLensProvider": {"resolveProvider": true},
      "codeActionProvider": {"codeActionKinds": ["quickfix", "source.organizeImports"]},
      "documentFormattingProvider": true,
      "documentRangeFormattingProvider": true,
      "documentOnTypeFormattingProvider": {"firstTriggerCharacter": "\n"},
      "linkedEditingRangeProvider": true,
      "diagnosticProvider": {"interFileDependencies": true, "workspaceDiagnostics": false},
      "semanticTokensProvider": {
        "legend": {"tokenTypes": tokenTypes, "tokenModifiers": tokenMods},
        "full": {"delta": true},
        "range": true
      }
    },
    "serverInfo": {"name": ServerName, "version": ServerVersion}
  }

proc handleDefinition(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJNull()
  let pos = positionParam(params)
  let (live, wrote) = buildLiveCtx(uri, doc)
  try:
    var locs: seq[Location]
    if live.active:
      # Dirty buffer: the warm daemon compiled the last-saved file and can't see
      # unsaved edits, so go straight to the live temp. If the buffer is mid-edit
      # (unparseable) and yields nothing, fall back to the last-good answer.
      locs = idetools.definition(gState.config, filePath(uri), pos, live)
      if locs.len == 0:
        let d = daemon.definition(gState.config, filePath(uri), pos)
        if d.isSome and d.get.len > 0: locs = d.get
        else: locs = idetools.definition(gState.config, filePath(uri), pos)
    else:
      # Clean buffer: answer in-process from the warm .s.nif (no spawn, cross-module)
      # FIRST; fall through to the warm daemon then idetools only if it comes up empty.
      locs = navindex.definitionAt(gState.config, filePath(uri), pos)
      if locs.len == 0:
        let d = daemon.definition(gState.config, filePath(uri), pos)
        if d.isSome and d.get.len > 0: locs = d.get
        else: locs = idetools.definition(gState.config, filePath(uri), pos)
    if locs.len == 0:
      # No value symbol under the cursor — maybe it's a MODULE name in an import
      # line (`import std/syncio`). Resolve it to the module's source file so F12
      # on the module name opens it (stdlib source lives under <nimony>/lib).
      let modPath = doclink.moduleRefAt(gState.config, doc, pos.line, pos.character)
      if modPath.len > 0:
        return toJsonArray(@[Location(uri: pathToUri(modPath), `range`: mkRange(0, 0, 0, 0))])
    result = if locs.len == 0: newJNull() else: toJsonArray(locs)
  finally:
    if wrote: cleanupLiveTemp(uri)

proc handleReferences(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let pos = positionParam(params)
  # Pass every open document as an extra compilation root so usages in other
  # modules (which idetools only sees when their unit is compiled) are found.
  var roots: seq[string]
  for docUri in gState.docs.keys:
    if docUri != uri: roots.add(filePath(docUri))
  let (live, wrote) = buildLiveCtx(uri, doc)
  try:
    var locs: seq[Location]
    if live.active:
      locs = idetools.references(gState.config, filePath(uri), pos, roots, live)
      if locs.len == 0:                                   # mid-edit fallback
        locs = idetools.references(gState.config, filePath(uri), pos, roots)
    else:
      # Clean buffer: in-process cross-module references from the warm .s.nif FIRST.
      locs = navindex.referencesAt(gState.config, filePath(uri), pos, includeDecl = true)
      if locs.len == 0:
        let d = daemon.references(gState.config, filePath(uri), pos)
        if d.isSome and d.get.len > 0: locs = d.get
        else: locs = idetools.references(gState.config, filePath(uri), pos, roots)
    result = toJsonArray(locs)
  finally:
    if wrote: cleanupLiveTemp(uri)

proc handleHover(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJNull()
  let (live, wrote) = buildLiveCtx(uri, doc)
  try:
    var h = nifindex.hoverAt(gState.config, filePath(uri),
                             positionParam(params), live, doc.text)
    if h.isNone and live.active:                          # mid-edit fallback
      h = nifindex.hoverAt(gState.config, filePath(uri), positionParam(params))
    result = if h.isSome: %h.get else: newJNull()
  finally:
    if wrote: cleanupLiveTemp(uri)

proc handleDocumentSymbol(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  toJsonArray(nifindex.documentSymbols(gState.config, filePath(uri)))

proc handleCompletion(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let items = nifindex.completions(gState.config, filePath(uri), positionParam(params), doc.text)
  toJsonArray(items)

proc handleSignatureHelp(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let sh = signature.signatureHelp(gState.config, doc, positionParam(params))
  if sh.isSome: %sh.get else: newJNull()

proc handleDocumentHighlight(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let pos = positionParam(params)
  # Clean buffer: in-process highlight from the warm .s.nif (no spawn) FIRST;
  # fall back to the idetools path when it is empty or the buffer is dirty.
  if bufferClean(uri, doc):
    let hs = navindex.highlightsAt(gState.config, filePath(uri), pos)
    if hs.len > 0: return toJsonArray(hs)
  toJsonArray(highlight.documentHighlights(gState.config, doc, pos))

proc handlePrepareRename(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let r = rename.prepareRename(gState.config, doc, positionParam(params))
  if r.isSome: %r.get else: newJNull()

proc handleRename(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJNull()
  # Pass the other open documents so a rename updates cross-file usages too.
  var roots: seq[string]
  for docUri in gState.docs.keys:
    if docUri != uri: roots.add(filePath(docUri))
  let we = rename.rename(gState.config, doc, positionParam(params), renameNewName(params), roots)
  if we.isSome: %we.get else: newJNull()

proc handleWorkspaceSymbol(params: JsonNode): JsonNode =
  let q = queryParam(params)
  let d = daemon.workspaceSymbols(gState.config, q)
  if d.isSome and d.get.len > 0: toJsonArray(d.get)
  else: toJsonArray(workspacesym.workspaceSymbols(gState.config, q))

proc handleInlayHint(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  let rng = rangeParam(params)
  var hints = inlay.inlayHints(gState.config, doc, rng)          # inferred types
  hints.add paramhints.parameterHints(gState.config, doc, rng)   # parameter names
  toJsonArray(hints)

proc handleSemanticTokensFull(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return %*{"data": newJArray()}
  %semtokens.semanticTokensFull(gState.config, doc)

proc handleDocumentLink(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(doclink.documentLinks(gState.config, doc))

proc handleCodeLens(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(codelens.codeLenses(gState.config, doc))

proc handleDeclaration(params: JsonNode): JsonNode =
  # Nimony has no separate declaration/definition split; alias definition.
  handleDefinition(params)

proc handlePrepareTypeHierarchy(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let items = typehierarchy.prepareTypeHierarchy(gState.config, doc, positionParam(params))
  if items.len == 0: newJNull() else: toJsonArray(items)

proc handleSupertypes(params: JsonNode): JsonNode =
  toJsonArray(typehierarchy.supertypes(gState.config, typeHierarchyItemParam(params)))

proc handleSubtypes(params: JsonNode): JsonNode =
  toJsonArray(typehierarchy.subtypes(gState.config, typeHierarchyItemParam(params)))

proc handleFoldingRange(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(folding.foldingRanges(gState.config, doc))

proc handleSelectionRange(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(selection.selectionRanges(gState.config, doc, selectionPositions(params)))

proc handlePrepareCallHierarchy(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let items = callhierarchy.prepareCallHierarchy(gState.config, doc, positionParam(params))
  if items.len == 0: newJNull() else: toJsonArray(items)

proc handleIncomingCalls(params: JsonNode): JsonNode =
  toJsonArray(callhierarchy.incomingCalls(gState.config, callHierarchyItemParam(params)))

proc handleOutgoingCalls(params: JsonNode): JsonNode =
  toJsonArray(callhierarchy.outgoingCalls(gState.config, callHierarchyItemParam(params)))

proc handleTypeDefinition(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let locs = extranav.typeDefinition(gState.config, doc, positionParam(params))
  if locs.len == 0: newJNull() else: toJsonArray(locs)

proc handleImplementation(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let locs = extranav.implementation(gState.config, doc, positionParam(params))
  if locs.len == 0: newJNull() else: toJsonArray(locs)

proc handleCompletionResolve(params: JsonNode): JsonNode =
  ## completionItem/resolve: the client sends back a single CompletionItem to be
  ## enriched with detail/documentation. Parse it, resolve, re-serialize. Any
  ## malformed input echoes the original params unchanged.
  if params == nil or params.kind != JObject:
    return params
  var item = CompletionItem(
    label: params{"label"}.getStr(""),
    detail: params{"detail"}.getStr(""),
    documentation: (block:
      let d = params{"documentation"}
      if d != nil and d.kind == JObject: d{"value"}.getStr("")
      elif d != nil and d.kind == JString: d.getStr("")
      else: ""),
    insertText: params{"insertText"}.getStr(""))
  let k = params{"kind"}.getInt(0)
  if k >= ord(low(CompletionItemKind)) and k <= ord(high(CompletionItemKind)):
    item.kind = CompletionItemKind(k)
  result = %nifindex.resolveCompletion(gState.config, item)

proc handleCodeLensResolve(params: JsonNode): JsonNode =
  ## codeLens/resolve. Titles are computed eagerly by codelens.codeLenses, so
  ## this reconstructs the lens from the client's payload and routes it through
  ## the (identity) resolver. Defensive: any failure reflects params unchanged.
  try:
    var lens = CodeLens(`range`: getRange(params["range"]))
    let cmd = params{"command"}
    if cmd != nil and cmd.kind == JObject:
      lens.command = Command(title: cmd{"title"}.getStr(""),
                             command: cmd{"command"}.getStr(""))
    %codelens.resolveCodeLens(gState.config, lens)
  except CatchableError:
    params

proc handleInlayHintResolve(params: JsonNode): JsonNode =
  ## `inlayHint/resolve`: unlike textDocument/* requests, params here IS the
  ## InlayHint object itself (no `textDocument` wrapper) — exactly what
  ## `handleInlayHint` returned, echoed back by the client, including our
  ## `data` payload. The uri to resolve against travels in `data.uri` since
  ## LSP gives us no other way to recover it.
  try:
    if params == nil: return params
    var hint: InlayHint
    hint.position = positionParam(params)          # params.position
    hint.label = params{"label"}.getStr("")
    hint.kind = InlayHintKind(params{"kind"}.getInt(ord(ihkType)))
    hint.paddingLeft = params{"paddingLeft"}.getBool(false)
    hint.paddingRight = params{"paddingRight"}.getBool(false)
    let dataNode = params{"data"}
    var uri = ""
    if dataNode != nil and dataNode.kind == JObject:
      hint.data = dataNode
      uri = dataNode{"uri"}.getStr("")
    if uri.len == 0: return params
    let doc = gState.getDoc(uri)
    if doc == nil: return params
    %inlay.resolveInlay(gState.config, doc, hint)
  except CatchableError:
    params

proc handleSemanticTokensDelta(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return %*{"data": newJArray()}
  let previousResultId = params{"previousResultId"}.getStr("")
  let r = semtokens.semanticTokensDelta(gState.config, doc, previousResultId)
  if r.isDelta: %r.delta else: %r.full

proc handleCodeAction(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let rng = rangeParam(params)
  var diags: seq[Diagnostic] = @[]
  let ctx = params{"context"}
  if ctx != nil:
    let da = ctx{"diagnostics"}
    if da != nil and da.kind == JArray:
      for dj in da:
        var sev = dsError
        let sevOrd = dj{"severity"}.getInt(ord(dsError))
        if sevOrd >= ord(low(DiagnosticSeverity)) and sevOrd <= ord(high(DiagnosticSeverity)):
          sev = DiagnosticSeverity(sevOrd)
        diags.add Diagnostic(
          `range`: getRange(dj{"range"}),
          severity: sev,
          source: dj{"source"}.getStr(""),
          message: dj{"message"}.getStr(""))
  toJsonArray(codeaction.codeActions(gState.config, doc, rng, diags))

proc handleFormatting(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(format.formatDocument(gState.config, doc))

proc handleRangeFormatting(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(format.formatRange(gState.config, doc, rangeParam(params)))

proc handleOnTypeFormatting(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  let pos = positionParam(params)
  let ch = params{"ch"}.getStr("")
  toJsonArray(format.onTypeFormat(gState.config, doc, pos, ch))

proc handleLinkedEditingRange(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let r = linkededit.linkedEditingRanges(gState.config, doc, positionParam(params))
  if r.isSome: %r.get else: newJNull()

proc handleDiagnosticPull(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  # Serve the LAST PUSHED diagnostics instantly — never recompile on a pull. The
  # push path (didOpen warm / didChange live / didSave) keeps `lastDiagnostics`
  # fresh, so focusing a tab returns immediately instead of blanking the squiggles
  # for the duration of a `nimony check`. Only compute if we have nothing cached
  # yet (a pull that races ahead of the first push).
  if lastDiagnostics.hasKey(uri):
    return %*{"kind": "full", "items": toJsonArray(lastDiagnostics[uri])}
  let doc = gState.getDoc(uri)
  pulldiag.diagnosticReport(gState.config, doc)

# --------------------------------------------------------------------------
# notification handlers (document sync)
# --------------------------------------------------------------------------

proc handleDidOpen(params: JsonNode) =
  bumpCheckGeneration()
  let td = params{"textDocument"}
  if td == nil: return
  let uri = td{"uri"}.getStr
  gState.openDoc(uri, td{"languageId"}.getStr("nim"),
                 td{"version"}.getInt(0), td{"text"}.getStr(""))
  # Warm the MAIN nimcache for this doc right away (highest priority in the loop).
  # hover / definition / references all read that cache; if it is cold, EACH pays
  # a ~1.5s compile and — with VS Code's feature burst and multiple servers all
  # thrashing one cold nimcache — the whole IDE "hangs on everything for ages"
  # until something finally compiles the project. Warming eagerly means the burst
  # that follows didOpen hits a WARM cache and resolves instantly.
  pendingWarm.incl uri
  # NB: pruning runs on didClose, NOT here — a full-pool size walk on the open
  # path would delay the very diagnostics/underlines this open is meant to show.

proc handleDidChange(params: JsonNode) =
  bumpCheckGeneration()
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return
  let changes = params{"contentChanges"}
  if changes != nil and changes.kind == JArray and changes.len > 0:
    let ver = params{"textDocument", "version"}.getInt(doc.version + 1)
    # Apply each change in order. A change with a `range` is incremental; one
    # without is a whole-document replacement (client's choice per change).
    for ch in changes:
      let rng = ch{"range"}
      if rng != nil:
        doc.applyChange(ver, getRange(rng), ch{"text"}.getStr(""))
      else:
        doc.update(ver, ch{"text"}.getStr(""))
    pendingLive.incl uri   # coalesced; flushed once input goes idle (see main)

proc handleDidSave(params: JsonNode) =
  bumpCheckGeneration()
  let uri = textDocumentUri(params)
  pendingLive.excl uri                      # the on-save real check supersedes
  cleanupLiveTemp(uri)                      # disk is current; drop the temp
  nifcache.invalidate(gState.config, filePath(uri))  # new .s.nif after this recheck
  refreshDiagnostics(uri)

proc handleDidClose(params: JsonNode) =
  bumpCheckGeneration()
  let uri = textDocumentUri(params)
  pendingLive.excl uri
  pendingWarm.excl uri
  cleanupLiveTemp(uri)
  nifcache.invalidate(gState.config, filePath(uri))
  gState.closeDoc(uri)
  # Do NOT delete this file's warm nimcache on close: a reopen would then pay a
  # full cold nimony compile (~4s) — the "lost my underlines, now it hangs again"
  # churn when VS Code recycles a preview tab. Keep every cache warm and bound
  # total disk with a size-budgeted LRU prune of the whole nimcache/lsp pool
  # instead, never evicting a still-open document's cache.
  pruneCachesNow()

# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------

proc dispatchRequest(m: Message): JsonNode =
  case m.meth
  of "initialize": response(m.id, handleInitialize(m.params))
  of "shutdown":
    gState.shutdownRequested = true
    response(m.id, newJNull())
  of "textDocument/definition": response(m.id, handleDefinition(m.params))
  of "textDocument/references": response(m.id, handleReferences(m.params))
  of "textDocument/hover": response(m.id, handleHover(m.params))
  of "textDocument/documentSymbol": response(m.id, handleDocumentSymbol(m.params))
  of "textDocument/completion": response(m.id, handleCompletion(m.params))
  of "textDocument/signatureHelp": response(m.id, handleSignatureHelp(m.params))
  of "textDocument/documentHighlight": response(m.id, handleDocumentHighlight(m.params))
  of "textDocument/prepareRename": response(m.id, handlePrepareRename(m.params))
  of "textDocument/rename": response(m.id, handleRename(m.params))
  of "textDocument/inlayHint": response(m.id, handleInlayHint(m.params))
  of "textDocument/semanticTokens/full": response(m.id, handleSemanticTokensFull(m.params))
  of "textDocument/semanticTokens/full/delta": response(m.id, handleSemanticTokensDelta(m.params))
  of "textDocument/semanticTokens/range": response(m.id, handleSemanticTokensFull(m.params))
  of "textDocument/documentLink": response(m.id, handleDocumentLink(m.params))
  of "textDocument/codeLens": response(m.id, handleCodeLens(m.params))
  of "codeLens/resolve": response(m.id, handleCodeLensResolve(m.params))
  of "completionItem/resolve": response(m.id, handleCompletionResolve(m.params))
  of "inlayHint/resolve": response(m.id, handleInlayHintResolve(m.params))
  of "textDocument/codeAction": response(m.id, handleCodeAction(m.params))
  of "textDocument/formatting": response(m.id, handleFormatting(m.params))
  of "textDocument/rangeFormatting": response(m.id, handleRangeFormatting(m.params))
  of "textDocument/onTypeFormatting": response(m.id, handleOnTypeFormatting(m.params))
  of "textDocument/linkedEditingRange": response(m.id, handleLinkedEditingRange(m.params))
  of "textDocument/diagnostic": response(m.id, handleDiagnosticPull(m.params))
  of "textDocument/declaration": response(m.id, handleDeclaration(m.params))
  of "textDocument/prepareTypeHierarchy": response(m.id, handlePrepareTypeHierarchy(m.params))
  of "typeHierarchy/supertypes": response(m.id, handleSupertypes(m.params))
  of "typeHierarchy/subtypes": response(m.id, handleSubtypes(m.params))
  of "workspace/symbol": response(m.id, handleWorkspaceSymbol(m.params))
  of "textDocument/foldingRange": response(m.id, handleFoldingRange(m.params))
  of "textDocument/selectionRange": response(m.id, handleSelectionRange(m.params))
  of "textDocument/prepareCallHierarchy": response(m.id, handlePrepareCallHierarchy(m.params))
  of "callHierarchy/incomingCalls": response(m.id, handleIncomingCalls(m.params))
  of "callHierarchy/outgoingCalls": response(m.id, handleOutgoingCalls(m.params))
  of "textDocument/typeDefinition": response(m.id, handleTypeDefinition(m.params))
  of "textDocument/implementation": response(m.id, handleImplementation(m.params))
  else: errorResponse(m.id, MethodNotFound, "unhandled method: " & m.meth)

proc handleDidChangeWatchedFiles(params: JsonNode) =
  ## A file changed on disk outside our edit stream (git checkout, another
  ## editor, a build). Bump the check generation so the next request recompiles,
  ## and drop every parsed .s.nif buffer nifcache has memoized so it re-reads the
  ## fresh artifacts. (nifcache's mtime check self-heals too; this is belt-and-braces.)
  bumpCheckGeneration()
  nifcache.invalidateAll()

proc registerWatchedFiles() =
  ## Ask the client to watch Nim(ony) sources so it sends didChangeWatchedFiles.
  ## Dynamic registration (there is no static server capability for this); the
  ## client's response id is ignored by our loop, which is harmless.
  let params = %*{
    "registrations": [{
      "id": "nimony-watched-files",
      "method": "workspace/didChangeWatchedFiles",
      "registerOptions": {
        "watchers": [
          {"globPattern": "**/*.nim"},
          {"globPattern": "**/*.nimble"}
        ]
      }
    }]
  }
  writeMessage(gOut, %*{"jsonrpc": "2.0", "id": "reg-watched-files",
                        "method": "client/registerCapability", "params": params})

proc dispatchNotification(m: Message) =
  case m.meth
  of "initialized": registerWatchedFiles()
  of "exit":
    for uri in gState.docs.keys: cleanupLiveTemp(uri)
    daemon.shutdown()
    quit(if gState.shutdownRequested: 0 else: 1)
  of "textDocument/didOpen": handleDidOpen(m.params)
  of "textDocument/didChange": handleDidChange(m.params)
  of "textDocument/didSave": handleDidSave(m.params)
  of "textDocument/didClose": handleDidClose(m.params)
  of "workspace/didChangeWatchedFiles": handleDidChangeWatchedFiles(m.params)
  else: discard

proc flushPending() =
  ## Run one coalesced check per dirty document, then clear the set.
  if pendingLive.len == 0: return
  let due = pendingLive     # snapshot; edits arriving during a check re-mark it
  pendingLive.clear()
  for uri in due:
    let doc = gState.getDoc(uri)
    if doc == nil: continue
    let path = filePath(uri)
    var onDisk = ""
    var haveDisk = false
    try:
      onDisk = readFile(path); haveDisk = true
    except CatchableError: discard
    if haveDisk and onDisk == doc.text:
      # Buffer == disk (just opened, or saved): check the REAL file into the main
      # cache. This both publishes diagnostics AND warms the cache that hover /
      # definition / references read — so the first navigation is fast, not a
      # cold compile. (The isolated live-cache below wouldn't help those.)
      refreshDiagnostics(uri)
    else:
      # Unsaved edits: isolated live-cache check on the temp buffer.
      refreshDiagnosticsLive(uri, doc.text)

proc stdinReadyWithin(ms: int): bool =
  ## True if stdin has input ready within `ms`; false on idle timeout. Lets the
  ## blocking loop wake up after a typing pause to flush pending diagnostics.
  var fds: TPollfd
  fds.fd = cint(0)                     # stdin
  fds.events = POLLIN
  fds.revents = 0
  let r = poll(addr fds, Tnfds(1), cint(ms))
  result = r > 0 and (fds.revents.int and POLLIN.int) != 0

# Requests the user is actively waiting on. VS Code fires a BURST of feature
# requests on every edit/cursor-move (semanticTokens, inlayHint, codeLens,
# folding, documentSymbol, documentHighlight …), each costing a compile. Served
# strictly in arrival order, an interactive hover queues behind all of them
# (~9s → "Loading forever"). We drain the burst and serve these FIRST; LSP lets
# responses return out of order (the client matches by request id).
const InteractiveMethods = [
  "textDocument/hover", "textDocument/completion", "textDocument/signatureHelp",
  "textDocument/definition", "textDocument/declaration",
  "textDocument/typeDefinition", "textDocument/implementation",
  "textDocument/references", "shutdown"]

proc isInteractive(m: Message): bool =
  m.isRequest and m.meth in InteractiveMethods

proc drainReady(): seq[Message] =
  ## Every message already waiting on stdin, without blocking. Excess (buffered
  ## in stdio, invisible to poll) is simply picked up on the next loop turn.
  result = @[]
  while stdinReadyWithin(0):
    let mo = readMessage(stdin)
    if mo.isNone: break
    result.add mo.get

proc serve(m: Message) =
  # A handler must NEVER take the server down. Any exception becomes an error
  # response (so the client isn't left waiting) and the loop keeps serving.
  try:
    if m.isNotification:
      let t0 = epochTime()
      dispatchNotification(m)
      let ms = (epochTime() - t0) * 1000
      if ms > 250:
        try: stderr.writeLine("[nimony-lsp] notif " & m.meth & " took " & $int(ms) & "ms")
        except CatchableError: discard
    elif m.isRequest:
      if not gState.initialized and m.meth != "initialize":
        writeMessage(gOut, errorResponse(m.id, ServerNotInitialized, "server not initialized"))
      else:
        let t0 = epochTime()
        let resp = dispatchRequest(m)
        let ms = (epochTime() - t0) * 1000
        if ms > 250:   # shown in the VS Code "Nimony Language Server" output channel
          try: stderr.writeLine("[nimony-lsp] " & m.meth & " took " & $int(ms) & "ms")
          except CatchableError: discard
        writeMessage(gOut, resp)
  except CatchableError as e:
    if m.isRequest:
      try: writeMessage(gOut, errorResponse(m.id, InternalError, "handler error: " & e.msg))
      except CatchableError: discard

var bgQueue: seq[Message]   ## background requests awaiting service, FIFO

const ContentModified = -32801   ## LSP: "result is stale, discard" (silenced by clients)

proc bgKey(m: Message): string =
  let u = if m.params != nil: textDocumentUri(m.params) else: ""
  m.meth & "\x1f" & u

proc rank(m: Message): int =
  ## Lower rank = served first. A single edit/cursor-move fires a BURST of
  ## background requests; serve the cheap in-process NIF-walk features
  ## (inlayHint, semanticTokens*, documentSymbol, foldingRange, documentLink)
  ## BEFORE the expensive ones (codeLens does a cross-file reference walk), so
  ## the fast, visible results paint first. Ties keep arrival order.
  case m.meth
  of "textDocument/inlayHint", "inlayHint/resolve",
     "textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta",
     "textDocument/semanticTokens/range", "textDocument/documentSymbol",
     "textDocument/foldingRange", "textDocument/documentLink": 0
  of "textDocument/codeLens", "codeLens/resolve": 2
  else: 1

proc enqueueBackground(m: Message) =
  ## Queue a background request, superseding any earlier queued one of the SAME
  ## kind for the SAME document — while you keep typing, VS Code re-fires
  ## semanticTokens/inlay/codeLens every keystroke; without this the queue floods
  ## and takes a minute to drain. The superseded request is answered
  ## ContentModified (stale), so the client never leaks a pending request.
  let k = bgKey(m)
  var kept: seq[Message]
  for q in bgQueue:
    if bgKey(q) == k:
      writeMessage(gOut, errorResponse(q.id, ContentModified, "superseded"))
    else:
      kept.add q
  kept.add m
  bgQueue = kept

const RequestCancelled = -32800   ## LSP: request cancelled by the client

proc cancelPending(m: Message) =
  ## Handle `$/cancelRequest`: drop a still-queued background request the client
  ## abandoned (e.g. cursor moved on), answering it Cancelled so no pending
  ## request leaks. Interactive requests are served immediately and never sit in
  ## the queue, so a cancel for one simply finds nothing — a harmless no-op.
  let id = if m.params != nil: m.params{"id"} else: nil
  if id == nil or id.kind == JNull: return
  var kept: seq[Message]
  for q in bgQueue:
    if q.id == id:
      writeMessage(gOut, errorResponse(q.id, RequestCancelled, "cancelled"))
    else:
      kept.add q
  bgQueue = kept

proc intake(batch: seq[Message]) =
  ## Serve notifications (in order) and interactive requests immediately;
  ## enqueue background requests for later.
  for m in batch:
    if m.isNotification:
      if m.meth == "$/cancelRequest": cancelPending(m)
      else: serve(m)
    elif m.isInteractive: serve(m)
    elif m.isRequest: enqueueBackground(m)

proc popAny(s: var HashSet[string]): string =
  ## Remove and return one arbitrary element (set has no ordering).
  result = ""
  for x in s:
    result = x
    break
  if result.len > 0: s.excl result

proc main() =
  discard c_setvbuf(stdin, nil, IONBF, 0)   # unbuffered: see note on IONBF
  while true:
    # HIGHEST PRIORITY: warm the MAIN nimcache for a freshly opened doc before
    # anything else. Ungated by idle/queue state on purpose — under a feature
    # burst the idle flush below can be starved indefinitely, and until the cache
    # is warm every hover/definition sits on a cold compile. One cold compile per
    # open; every check afterward hits the warm cache and is ~instant.
    if pendingWarm.len > 0:
      let uri = popAny(pendingWarm)
      if uri.len > 0 and gState.getDoc(uri) != nil:
        pendingLive.excl uri            # this warm publishes fresh diagnostics too
        # Surface the cold compile as work-done progress so the ~3s reads as
        # working, not hung.
        let tok = beginAnalyzeProgress()
        reportProgress(tok, extractFilename(filePath(uri)))
        refreshDiagnostics(uri)
        endProgress(tok)
        # The MAIN nimcache (and its .s.nif) is now warm. Nudge the client to
        # re-request the cheap NIF-walk features so type hints / tokens land
        # WITH the diagnostics instead of ~1.5s later against a cold cache.
        serverRequest("workspace/semanticTokens/refresh", newJNull())
        serverRequest("workspace/inlayHint/refresh", newJNull())
      continue

    # Idle housekeeping: with edits pending and no background work queued, wait
    # briefly; if input stays idle, flush ONE coalesced live-check (diagnostics).
    if bgQueue.len == 0 and pendingLive.len > 0 and not stdinReadyWithin(DebounceMs):
      flushPending()
      continue

    # Fetch work. Block for it ONLY when there's no background item to grind —
    # otherwise just drain what's ready (non-blocking) so background work keeps
    # moving while we stay responsive to new input.
    if bgQueue.len == 0:
      let mo = readMessage(stdin)
      if mo.isNone: break                    # EOF
      intake(@[mo.get] & drainReady())
    else:
      intake(drainReady())

    # Serve ONE background request, then loop back — so a hover/completion that
    # arrives mid-burst is drained and served BEFORE the next background item,
    # never stuck behind the whole semantic-tokens/inlay/codeLens tail. Pick the
    # lowest-rank queued item (cheap NIF-walk features before expensive codeLens).
    if bgQueue.len > 0:
      var best = 0
      for i in 1 ..< bgQueue.len:
        if rank(bgQueue[i]) < rank(bgQueue[best]): best = i
      let m = bgQueue[best]
      bgQueue.delete(best)
      serve(m)

when isMainModule:
  main()
