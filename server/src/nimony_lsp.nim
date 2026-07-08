## nimony-lsp — entry point.
##
## Blocking stdio loop: read a framed JSON-RPC message, dispatch, write the
## response. Feature handlers live in `features/` and the `driver/` layer; this
## module owns lifecycle + document synchronization and routes requests.

import std/[json, options, os, tables]
import lsp/[jsonrpc, protocol, uris]
import server/[state, documents]
import driver/[diagnostics, idetools, nifindex, nimonycli,
               signature, highlight, rename, workspacesym, semtokens, inlay,
               folding, selection, callhierarchy, extranav]

const
  ServerName = "nimony-lsp"
  ServerVersion = "0.3.0"

var gState = newServerState()
var gOut = stdout

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
      "semanticTokensProvider": {
        "legend": {"tokenTypes": tokenTypes, "tokenModifiers": tokenMods},
        "full": true
      }
    },
    "serverInfo": {"name": ServerName, "version": ServerVersion}
  }

proc handleDefinition(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJNull()
  let locs = idetools.definition(gState.config, filePath(uri), positionParam(params))
  if locs.len == 0: newJNull() else: toJsonArray(locs)

proc handleReferences(params: JsonNode): JsonNode =
  let uri = textDocumentUri(params)
  let doc = gState.getDoc(uri)
  if doc == nil: return newJArray()
  let locs = idetools.references(gState.config, filePath(uri), positionParam(params))
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
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJNull()
  let we = rename.rename(gState.config, doc, positionParam(params), renameNewName(params))
  if we.isSome: %we.get else: newJNull()

proc handleWorkspaceSymbol(params: JsonNode): JsonNode =
  toJsonArray(workspacesym.workspaceSymbols(gState.config, queryParam(params)))

proc handleInlayHint(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return newJArray()
  toJsonArray(inlay.inlayHints(gState.config, doc, rangeParam(params)))

proc handleSemanticTokensFull(params: JsonNode): JsonNode =
  let doc = gState.getDoc(textDocumentUri(params))
  if doc == nil: return %*{"data": newJArray()}
  %semtokens.semanticTokensFull(gState.config, doc)

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
  refreshDiagnostics(uri)

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

proc handleDidSave(params: JsonNode) =
  bumpCheckGeneration()
  refreshDiagnostics(textDocumentUri(params))

proc handleDidClose(params: JsonNode) =
  bumpCheckGeneration()
  gState.closeDoc(textDocumentUri(params))

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
  of "exit": quit(if gState.shutdownRequested: 0 else: 1)
  of "textDocument/didOpen": handleDidOpen(m.params)
  of "textDocument/didChange": handleDidChange(m.params)
  of "textDocument/didSave": handleDidSave(m.params)
  of "textDocument/didClose": handleDidClose(m.params)
  else: discard

proc main() =
  while true:
    let mo = readMessage(stdin)
    if mo.isNone: break        # EOF
    let m = mo.get
    if m.isNotification:
      dispatchNotification(m)
    elif m.isRequest:
      if not gState.initialized and m.meth != "initialize":
        writeMessage(gOut, errorResponse(m.id, ServerNotInitialized, "server not initialized"))
        continue
      writeMessage(gOut, dispatchRequest(m))
    # responses from client (to our requests) are ignored for now

when isMainModule:
  main()
