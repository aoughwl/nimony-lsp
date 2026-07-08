## textDocument/codeLens: emit a "N references" lens above each top-level
## declaration.
##
## We reuse nifindex.documentSymbols to enumerate top-level decls (with their
## ranges) and idetools.references to count uses of each. Reference counts are
## approximate: idetools is young and may miss some usages, which is acceptable.
##
## Every path is defensively wrapped so a failure yields `@[]` and never takes
## the LSP process down.

import std/[sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./nifindex
import ./idetools

const MaxSymbols = 200
  ## Cap: skip running idetools hundreds of times on a huge file.

proc referenceCount(cfg: Config; file: string; sym: DocumentSymbol): int =
  ## Number of distinct use-sites for `sym`, deduped by uri+line+char. The
  ## declaration site itself is excluded from the count.
  let locs = idetools.references(cfg, file, sym.selectionRange.start)
  var seen = initHashSet[string]()
  let declKey = pathToUri(file) & "#" &
    $sym.selectionRange.start.line & ":" & $sym.selectionRange.start.character
  for loc in locs:
    let key = loc.uri & "#" &
      $loc.`range`.start.line & ":" & $loc.`range`.start.character
    if key == declKey: continue          # exclude the declaration itself
    if not seen.containsOrIncl(key):
      inc result

proc codeLenses*(cfg: Config; doc: Document): seq[CodeLens] =
  result = @[]
  try:
    let file = uriToPath(doc.uri)
    let syms = nifindex.documentSymbols(cfg, file)
    if syms.len > MaxSymbols:
      return result           # too much work; bail rather than stall the LSP
    for sym in syms:
      if sym.name.len == 0: continue
      let count = referenceCount(cfg, file, sym)
      let title = if count == 1: "1 reference" else: $count & " references"
      result.add CodeLens(`range`: sym.selectionRange,
                          command: Command(title: title, command: ""))
  except CatchableError:
    return @[]
