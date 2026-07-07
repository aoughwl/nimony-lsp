## textDocument/documentHighlight — highlight all occurrences of the symbol
## under the cursor within the current document.
##
## Built on top of `idetools.definition`/`idetools.references`, which shell
## out to `nimony check --def:/--usages:` and return Locations with
## zero-width ranges (start == end). We widen each range to cover the
## identifier (same length as the word under the cursor, since it's the same
## symbol at every occurrence) and classify the definition site as a write,
## everything else as a read.

import std/[os, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./idetools

proc normOf(uri: string): string =
  try:
    normalizedPath(uriToPath(uri))
  except CatchableError:
    uriToPath(uri)

proc documentHighlights*(cfg: Config; doc: Document; pos: Position): seq[DocumentHighlight] =
  result = @[]
  try:
    let word = doc.wordAt(pos)
    if word.len == 0:
      return @[]

    let absPath = uriToPath(doc.uri)
    let docNorm = normalizedPath(absPath)
    let L = word.len

    let defs = idetools.definition(cfg, absPath, pos)
    let refs = idetools.references(cfg, absPath, pos)

    var defKeys = initHashSet[string]()
    for d in defs:
      if normOf(d.uri) == docNorm:
        defKeys.incl($d.`range`.start.line & ":" & $d.`range`.start.character)

    var seen = initHashSet[string]()
    for loc in refs & defs:
      if normOf(loc.uri) != docNorm:
        continue
      let l = loc.`range`.start.line
      let c = loc.`range`.start.character
      let key = $l & ":" & $c
      if seen.containsOrIncl(key):
        continue
      let kind = if key in defKeys: dhkWrite else: dhkRead
      result.add(DocumentHighlight(`range`: mkRange(l, c, l, c + L), kind: kind))
  except CatchableError:
    result = @[]
