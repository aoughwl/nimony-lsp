## nimony-lsp — entry point.
##
## Blocking stdio loop: read a framed JSON-RPC message, dispatch, write the
## response. Feature handlers live in `features/` and the `driver/` layer; this
## module owns lifecycle + document synchronization and routes requests.

import std/[json, options, os, tables, sets]
from std/posix import poll, TPollfd, Tnfds, POLLIN
import lsp/[jsonrpc, protocol, uris]
import server/[state, documents]
import driver/[diagnostics, idetools, nifindex, nimonycli,
               signature, highlight, rename, workspacesym, semtokens, inlay,
               folding, selection, callhierarchy, extranav, daemon,
               doclink, codelens, paramhints, typehierarchy]

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

proc publishDiagnostics(uri: string; diags: seq[Diagnostic]) =
  let params = %*{"uri": uri, "diagnostics": toJsonArray(diags)}
  writeMessage(gOut, notification("textDocument/publishDiagnostics", params))

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

proc liveTempPath(realPath: string): string =
  # Hidden + ephemeral: a dotfile (never shows in the explorer) that is deleted
  # right after each check (see refreshDiagnosticsLive), so it can't linger or
  # flicker in the file tree. Kept a SIBLING of the real file (not /tmp) so the
  # buffer's relative imports and project config still resolve during the check.
  realPath.parentDir / (".nimlsp_live_" & extractFilename(realPath))

proc cleanupLiveTemp(uri: string) =
  let path = filePath(uri)
  if path.len == 0: return
  try:
    let tmp = liveTempPath(path)
    if fileExists(tmp): removeFile(tmp)
  except CatchableError: discard

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
      "completionProvider": {"triggerCharacters": [".", "("]},
      "signatureHelpProvider": {"triggerCharacters": ["(", ","], "retriggerCharacters": [","]},
      "renameProvider": {"prepareProvider": true},
      "workspaceSymbolProvider": true,
      "inlayHintProvider": true,
      "foldingRangeProvider": true,
      "selectionRangeProvider": true,
      "callHierarchyProvider": true,
      "typeDefinitionProvider": true,
      "implementationProvider": true,
      "declarationProvider": true,
      "typeHierarchyProvider": true,
      "documentLinkProvider": {"resolveProvider": false},
      "codeLensProvider": {"resolveProvider": false},
      "semanticTokensProvider": {
        "legend": {"tokenTypes": tokenTypes, "tokenModifiers": tokenMods},
        "full": true,
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
  # Warm-daemon path (exact overload resolution) first; idetools fallback.
  var locs: seq[Location]
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
  if locs.len == 0: newJNull() else: toJsonArray(locs)

proc handleReferences(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let pos = positionParam(params)
  var locs: seq[Location]
  let d = daemon.references(gState.config, filePath(uri), pos)
  if d.isSome and d.get.len > 0: locs = d.get
  else:
    # Pass every open document as an extra compilation root so usages in other
    # modules (which idetools only sees when their unit is compiled) are found.
    var roots: seq[string]
    for docUri in gState.docs.keys:
      if docUri != uri: roots.add(filePath(docUri))
    locs = idetools.references(gState.config, filePath(uri), pos, roots)
  toJsonArray(locs)

proc handleHover(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJNull()
  let h = nifindex.hoverAt(gState.config, filePath(uri), positionParam(params))
  if h.isSome: %h.get else: newJNull()

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
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(highlight.documentHighlights(gState.config, doc, positionParam(params)))

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
  # Defer the first check to the next idle gap (it also warms the live-cache):
  # opening a file no longer blocks the loop on a cold ~1.1s compile.
  pendingLive.incl uri

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
  refreshDiagnostics(uri)

proc handleDidClose(params: JsonNode) =
  bumpCheckGeneration()
  let uri = textDocumentUri(params)
  pendingLive.excl uri
  cleanupLiveTemp(uri)
  gState.closeDoc(uri)

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
  of "textDocument/semanticTokens/range": response(m.id, handleSemanticTokensFull(m.params))
  of "textDocument/documentLink": response(m.id, handleDocumentLink(m.params))
  of "textDocument/codeLens": response(m.id, handleCodeLens(m.params))
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

proc dispatchNotification(m: Message) =
  case m.meth
  of "initialized": discard
  of "exit":
    for uri in gState.docs.keys: cleanupLiveTemp(uri)
    daemon.shutdown()
    quit(if gState.shutdownRequested: 0 else: 1)
  of "textDocument/didOpen": handleDidOpen(m.params)
  of "textDocument/didChange": handleDidChange(m.params)
  of "textDocument/didSave": handleDidSave(m.params)
  of "textDocument/didClose": handleDidClose(m.params)
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
  if m.isNotification:
    dispatchNotification(m)
  elif m.isRequest:
    if not gState.initialized and m.meth != "initialize":
      writeMessage(gOut, errorResponse(m.id, ServerNotInitialized, "server not initialized"))
    else:
      writeMessage(gOut, dispatchRequest(m))

var bgQueue: seq[Message]   ## background requests awaiting service, FIFO

const ContentModified = -32801   ## LSP: "result is stale, discard" (silenced by clients)

proc bgKey(m: Message): string =
  let u = if m.params != nil: textDocumentUri(m.params) else: ""
  m.meth & "\x1f" & u

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

proc intake(batch: seq[Message]) =
  ## Serve notifications (in order) and interactive requests immediately;
  ## enqueue background requests for later.
  for m in batch:
    if m.isNotification: serve(m)
    elif m.isInteractive: serve(m)
    elif m.isRequest: enqueueBackground(m)

proc main() =
  discard c_setvbuf(stdin, nil, IONBF, 0)   # unbuffered: see note on IONBF
  while true:
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
    # never stuck behind the whole semantic-tokens/inlay/codeLens tail.
    if bgQueue.len > 0:
      let m = bgQueue[0]
      bgQueue.delete(0)
      serve(m)

when isMainModule:
  main()
