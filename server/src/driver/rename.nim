## `textDocument/prepareRename` and `textDocument/rename`.
##
## Built on top of `idetools.definition`/`idetools.references`: those give us
## zero-width Locations (one per def/use site, across files). Since the old
## identifier has a known length (the word under the cursor), we can turn each
## zero-width Location into a proper `[start, start+len)` TextEdit range.

import std/[options, tables, algorithm, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./idetools

proc identRange(doc: Document; pos: Position): Range =
  ## Range of the Nim identifier under `pos`, on `pos`'s line.
  const idChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  let line = doc.lineText(pos.line)
  var s = min(pos.character, line.len)
  while s > 0 and line[s-1] in idChars: dec s
  var e = min(pos.character, line.len)
  while e < line.len and line[e] in idChars: inc e
  mkRange(pos.line, s, pos.line, e)

proc prepareRename*(cfg: Config; doc: Document; pos: Position): Option[PrepareRenameResult] =
  try:
    let oldName = doc.wordAt(pos)
    if oldName.len == 0: return none(PrepareRenameResult)
    let defs = idetools.definition(cfg, uriToPath(doc.uri), pos)
    if defs.len == 0: return none(PrepareRenameResult)
    let r = identRange(doc, pos)
    some(PrepareRenameResult(`range`: r, placeholder: oldName))
  except CatchableError:
    none(PrepareRenameResult)

proc rename*(cfg: Config; doc: Document; pos: Position; newName: string): Option[WorkspaceEdit] =
  try:
    let oldName = doc.wordAt(pos)
    if oldName.len == 0 or newName.len == 0: return none(WorkspaceEdit)
    let L = oldName.len

    var locs = idetools.references(cfg, uriToPath(doc.uri), pos)
    locs.add(idetools.definition(cfg, uriToPath(doc.uri), pos))
    if locs.len == 0: return none(WorkspaceEdit)

    var seen = initHashSet[string]()
    var byUri = initOrderedTable[string, seq[TextEdit]]()
    for loc in locs:
      let key = loc.uri & "#" & $loc.`range`.start.line & ":" & $loc.`range`.start.character
      if seen.containsOrIncl(key): continue
      let startPos = loc.`range`.start
      let edit = TextEdit(`range`: mkRange(startPos.line, startPos.character,
                                            startPos.line, startPos.character + L),
                           newText: newName)
      byUri.mgetOrPut(loc.uri, @[]).add(edit)

    var changes: seq[(string, seq[TextEdit])] = @[]
    for uri, edits in byUri:
      var sorted = edits
      sorted.sort(proc(a, b: TextEdit): int =
        if a.`range`.start.line != b.`range`.start.line:
          b.`range`.start.line - a.`range`.start.line
        else:
          b.`range`.start.character - a.`range`.start.character)
      changes.add((uri, sorted))

    some(WorkspaceEdit(changes: changes))
  except CatchableError:
    none(WorkspaceEdit)
