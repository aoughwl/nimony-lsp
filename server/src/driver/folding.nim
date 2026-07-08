## textDocument/foldingRange support.
##
## Source-based (no compiler involvement): derives folding ranges from plain
## text structure — indentation blocks, contiguous comment runs, and
## contiguous import/from/include groups. Works line-by-line over the
## Document's text, so it's robust even against code that doesn't currently
## compile.

import std/strutils
import ../lsp/protocol
import ../server/documents
import ../server/state

proc isBlank(s: string): bool =
  s.strip().len == 0

proc indentOf(s: string): int =
  ## Leading-whitespace width; tabs count as 1 column (per spec).
  result = 0
  for ch in s:
    if ch == ' ' or ch == '\t':
      inc result
    else:
      break

proc isCommentLine(s: string): bool =
  let t = s.strip()
  t.startsWith("#")

proc startsWithWord(t, word: string): bool =
  if not t.startsWith(word): return false
  if t.len == word.len: return true
  let c = t[word.len]
  result = c == ' ' or c == '\t'

proc isImportLine(s: string): bool =
  let t = s.strip()
  startsWithWord(t, "import") or startsWithWord(t, "from") or startsWithWord(t, "include")

proc collectIndentBlocks(lines: seq[string]; res: var seq[FoldingRange]) =
  let n = lines.len
  for L in 0 ..< n:
    if isBlank(lines[L]): continue
    let ind = indentOf(lines[L])
    # find next non-blank line
    var j = L + 1
    while j < n and isBlank(lines[j]): inc j
    if j >= n: continue
    if indentOf(lines[j]) <= ind: continue
    # scan forward collecting the last non-blank line that stays more indented
    var last = j
    var k = j
    while k < n:
      if isBlank(lines[k]):
        inc k
        continue
      if indentOf(lines[k]) > ind:
        last = k
        inc k
      else:
        break
    if last > L:
      res.add FoldingRange(startLine: L, endLine: last, kind: "")

proc collectRuns(lines: seq[string]; pred: proc(s: string): bool {.noSideEffect.};
                  kind: string; res: var seq[FoldingRange]) =
  let n = lines.len
  var i = 0
  while i < n:
    if pred(lines[i]):
      var j = i
      while j < n and pred(lines[j]): inc j
      if j - i >= 2:
        res.add FoldingRange(startLine: i, endLine: j - 1, kind: kind)
      i = j
    else:
      inc i

proc foldingRanges*(cfg: Config; doc: Document): seq[FoldingRange] =
  result = @[]
  try:
    var lines = newSeq[string](doc.lineCount)
    for i in 0 ..< doc.lineCount:
      lines[i] = doc.lineText(i)

    var raw: seq[FoldingRange] = @[]
    collectIndentBlocks(lines, raw)
    collectRuns(lines, isCommentLine, "comment", raw)
    collectRuns(lines, isImportLine, "imports", raw)

    var seen: seq[(int, int)] = @[]
    for fr in raw:
      let key = (fr.startLine, fr.endLine)
      if key notin seen:
        seen.add key
        result.add fr
  except CatchableError:
    result = @[]
