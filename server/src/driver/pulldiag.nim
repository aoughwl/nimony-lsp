## textDocument/diagnostic (LSP 3.17 "pull diagnostics").
##
## The push model (`publishDiagnostics`, driven by `diagnostics.computeDiagnostics`
## in nimony_lsp.nim) already runs `nimony check` and parses its output into
## per-file `Diagnostic`s. This driver just lets a client PULL that same result
## for one document on demand instead of waiting for the server to push it —
## same underlying `computeDiagnostics` call (which itself goes through the
## generation-memoized `nimonycli.run`, so a pull right after/around a push
## costs nothing extra within one generation).
##
## Response shape (full document diagnostic report):
##   {"kind": "full", "items": [<Diagnostic>...]}

import std/[json, os, tables]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./diagnostics

proc normPath(p: string): string =
  try: normalizedPath(p)
  except CatchableError: p

proc diagnosticReport*(cfg: Config; doc: Document): JsonNode =
  ## Full diagnostic report for `doc`, in the shape the
  ## `textDocument/diagnostic` response expects. Never raises: any failure
  ## (missing binary, unreadable file, parse hiccup) yields an empty report
  ## rather than an error, so a pull request can never crash the server.
  result = %*{"kind": "full", "items": newJArray()}
  try:
    if doc == nil: return
    let path = uriToPath(doc.uri)
    if path.len == 0: return
    let docNorm = normPath(path)
    let byFile = computeDiagnostics(cfg, path)
    var items: seq[Diagnostic] = @[]
    for absPath, diags in byFile:
      if normPath(absPath) == docNorm:
        items = diags
        break
    result["items"] = toJsonArray(items)
  except CatchableError:
    result = %*{"kind": "full", "items": newJArray()}
