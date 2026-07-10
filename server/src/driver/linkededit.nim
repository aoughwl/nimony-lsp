## textDocument/linkedEditingRange — as the user edits one occurrence of an
## identifier, the client mirrors the edit into every other occurrence in the
## same document (e.g. renaming a `var` at its use-sites while typing).
##
## Built entirely on navindex.highlightsAt (in-process NIF walk, no nimony
## spawn): we take every in-file occurrence of the symbol under the cursor —
## both the declaration site and reads — and hand their ranges back verbatim.
## `none` when there's nothing to link (cursor not on an identifier, or the
## identifier is unique in the file — one range isn't worth linking).

import std/options
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./navindex

const IdentPattern = "[A-Za-z_][A-Za-z0-9_]*"
  ## Nim/Nimony identifier shape; handed to the client as `wordPattern` so it
  ## can validate typed text stays a legal identifier before mirroring edits.

proc linkedEditingRanges*(cfg: Config; doc: Document; pos: Position): Option[LinkedEditingRanges] =
  result = none(LinkedEditingRanges)
  try:
    if doc == nil: return
    let file = uriToPath(doc.uri)
    let highlights = navindex.highlightsAt(cfg, file, pos)
    if highlights.len < 2:
      return
    var ranges: seq[Range] = @[]
    for h in highlights:
      ranges.add h.`range`
    result = some(LinkedEditingRanges(ranges: ranges, wordPattern: IdentPattern))
  except CatchableError:
    result = none(LinkedEditingRanges)
