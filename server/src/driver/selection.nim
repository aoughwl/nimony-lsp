## textDocument/selectionRange — expanding "smart select" ranges around each
## requested cursor position.
##
## Purely source-based (no compiler round-trip needed): for a position we
## build a nested chain, innermost first, each range strictly containing the
## one before it:
##   1. the identifier under the cursor
##   2. enclosing bracket pairs `()`/`[]`/`{}`, content then including the
##      brackets, from smallest to largest
##   3. the current line, trimmed to its non-blank content
##   4. successive enclosing indentation blocks (each header line less
##      indented than the block it introduces), out to the top level
##   5. the whole document
## Levels that don't strictly grow the previous range are skipped so the
## chain never contains duplicate ranges.

import std/[algorithm, strutils]
import ../lsp/protocol
import ../server/state
import ../server/documents

const idChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
const wsChars = {' ', '\t'}

proc rng(doc: Document; so, eo: int): Range =
  Range(start: doc.positionAt(so), `end`: doc.positionAt(eo))

proc findBracketPairs(text: string): seq[tuple[a, b: int]] =
  ## All matched bracket pairs in `text`, skipping over string/char literals
  ## and `#` line comments. Not type-checked (a `(` may "match" a `]`) — this
  ## is a best-effort heuristic, not a parser.
  result = @[]
  var stack: seq[int] = @[]
  let n = text.len
  var i = 0
  while i < n:
    let c = text[i]
    case c
    of '"':
      if i + 2 < n and text[i+1] == '"' and text[i+2] == '"':
        i += 3
        while i + 2 < n and not (text[i] == '"' and text[i+1] == '"' and text[i+2] == '"'):
          inc i
        i = min(i + 3, n)
      else:
        inc i
        while i < n and text[i] != '"':
          if text[i] == '\\' and i + 1 < n: inc i
          inc i
        if i < n: inc i
    of '\'':
      inc i
      while i < n and text[i] != '\'':
        if text[i] == '\\' and i + 1 < n: inc i
        inc i
      if i < n: inc i
    of '#':
      while i < n and text[i] != '\n': inc i
    of '(', '[', '{':
      stack.add(i)
      inc i
    of ')', ']', '}':
      if stack.len > 0:
        let a = stack.pop()
        result.add((a, i))
      inc i
    else:
      inc i

proc isBlankLine(doc: Document; line: int): bool =
  doc.lineText(line).strip().len == 0

proc lineIndentOf(doc: Document; line: int): int =
  let t = doc.lineText(line)
  var i = 0
  while i < t.len and t[i] in wsChars: inc i
  result = i

proc findEnclosingBlock(doc: Document; curLine: int): tuple[found: bool, s, e: int] =
  ## The nearest ancestor indentation block of `curLine`: a header line with
  ## strictly less indentation, plus the contiguous run of more-indented (or
  ## blank) lines that follow it.
  if curLine < 0 or curLine >= doc.lineCount():
    return (false, 0, 0)
  let childIndent = lineIndentOf(doc, curLine)
  var header = curLine - 1
  while header >= 0:
    if isBlankLine(doc, header):
      dec header
      continue
    if lineIndentOf(doc, header) < childIndent:
      break
    dec header
  if header < 0:
    return (false, 0, 0)
  let headerIndent = lineIndentOf(doc, header)
  var endLine = header
  var i = header + 1
  while i < doc.lineCount():
    if isBlankLine(doc, i):
      inc i
      continue
    if lineIndentOf(doc, i) > headerIndent:
      endLine = i
      inc i
    else:
      break
  result = (true, header, endLine)

proc widthCmp(x, y: tuple[a, b: int]): int = (x.b - x.a) - (y.b - y.a)

proc buildCandidates(doc: Document; pos: Position): seq[tuple[so, eo: int]] =
  result = @[]
  let off = doc.offsetAt(pos)

  # 1. identifier under the cursor
  var s = off
  while s > 0 and doc.text[s-1] in idChars: dec s
  var e = off
  while e < doc.text.len and doc.text[e] in idChars: inc e
  if e > s:
    result.add((s, e))

  let pStart = if e > s: s else: off
  let pEnd = if e > s: e else: off

  # 2. enclosing bracket pairs, smallest to largest
  var containing: seq[tuple[a, b: int]] = @[]
  for p in findBracketPairs(doc.text):
    if p.a < pStart and p.b + 1 >= pEnd:
      containing.add(p)
  containing.sort(widthCmp)
  for p in containing:
    result.add((p.a + 1, p.b))   # content only
    result.add((p.a, p.b + 1))   # including the brackets

  # 3. current line, trimmed
  let lt = doc.lineText(pos.line)
  var ls = 0
  while ls < lt.len and lt[ls] in wsChars: inc ls
  var le = lt.len
  while le > ls and lt[le-1] in wsChars: dec le
  if le > ls:
    let sp = doc.offsetAt(Position(line: pos.line, character: ls))
    let ep = doc.offsetAt(Position(line: pos.line, character: le))
    result.add((sp, ep))

  # 4. enclosing indentation blocks
  var curLine = pos.line
  while true:
    let blk = findEnclosingBlock(doc, curLine)
    if not blk.found: break
    let sp = doc.offsetAt(Position(line: blk.s, character: 0))
    var ep: int
    if blk.e + 1 < doc.lineCount():
      ep = doc.offsetAt(Position(line: blk.e + 1, character: 0))
    else:
      ep = doc.text.len
    while ep > sp and doc.text[ep-1] in {'\n', '\r'}: dec ep
    result.add((sp, ep))
    curLine = blk.s

  # 5. whole document
  result.add((0, doc.text.len))

proc dedupeGrowing(candidates: seq[tuple[so, eo: int]]): seq[tuple[so, eo: int]] =
  ## Keep only candidates that strictly grow (and contain) the previous one,
  ## in order — drops duplicate/non-monotonic levels.
  result = @[]
  for c in candidates:
    if result.len == 0:
      result.add(c)
    else:
      let last = result[result.len-1]
      if c.so <= last.so and c.eo >= last.eo and (c.so < last.so or c.eo > last.eo):
        result.add(c)

proc chainFromOffsets(doc: Document; offs: seq[tuple[so, eo: int]]): SelectionRange =
  var parent: SelectionRange = nil
  for idx in countdown(offs.high, 0):
    parent = SelectionRange(range: doc.rng(offs[idx].so, offs[idx].eo), parent: parent)
  result = parent

proc fallback(doc: Document; pos: Position): SelectionRange =
  try:
    let lt = doc.lineText(pos.line)
    SelectionRange(range: rng(doc, doc.offsetAt(Position(line: pos.line, character: 0)),
                               doc.offsetAt(Position(line: pos.line, character: lt.len))),
                    parent: nil)
  except CatchableError:
    SelectionRange(range: Range(start: Position(line: 0, character: 0),
                                 `end`: doc.positionAt(doc.text.len)),
                    parent: nil)

proc selectionRanges*(cfg: Config; doc: Document; positions: seq[Position]): seq[SelectionRange] =
  result = @[]
  for pos in positions:
    try:
      let candidates = buildCandidates(doc, pos)
      let final = dedupeGrowing(candidates)
      if final.len == 0:
        result.add(fallback(doc, pos))
      else:
        result.add(chainFromOffsets(doc, final))
    except CatchableError:
      result.add(fallback(doc, pos))
