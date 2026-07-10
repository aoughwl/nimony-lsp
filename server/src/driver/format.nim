## textDocument/formatting, textDocument/rangeFormatting,
## textDocument/onTypeFormatting.
##
## Nimony has no formatter subcommand, so this is a small, deliberately
## CONSERVATIVE in-house formatter: it only normalizes whitespace that is
## unambiguously safe to touch. It never reflows code semantically (no
## reordering, no re-wrapping, no re-parenthesizing) and it never touches a
## line whose bytes might be semantic content rather than layout:
##
##   - trailing whitespace is stripped from every line, UNLESS that line is
##     (part of) a triple-quoted string literal, where trailing spaces are
##     part of the string's value.
##   - runs of 2+ blank separator lines collapse to 1 (blank lines that are
##     literally inside a triple-quoted string are never touched/collapsed).
##   - the document ends with exactly one trailing newline.
##   - leading indentation is renormalized to 2-space multiples, but ONLY for
##     a "structural" code line: not inside a triple-quoted string, not a
##     continuation line inside an unclosed `(`/`[`/`{` (paren/bracket
##     continuations keep their original alignment — that's often
##     intentional hand-alignment, and reindenting it would be a reflow),
##     not comment-only, not blank, and using pure-space indentation (a line
##     whose leading whitespace contains a tab is left alone entirely — tab
##     width is ambiguous, so we can't safely compute its nesting level).
##
## Indentation levels are derived from a single top-to-bottom stack walk
## mirroring how Nim itself compares indentation: strictly-deeper is a new
## nested level (this line's original column becomes worth prevLevel+2),
## equal-to-an-enclosing-level's original column reuses that level's
## normalized column, and dedents pop the stack. This never changes *which*
## lines are considered same-level / nested vs. their neighbors — it only
## renormalizes the pixel-perfect column used to express that structure — so
## it cannot flip which block a line belongs to.
##
## Anywhere the analysis is unsure (mixed tabs, unterminated construct, empty
## document, no-op result, ...) the affected line — or, for formatDocument,
## the whole document — is left untouched. Every public proc is wrapped so a
## bug here degrades to "did nothing" rather than corrupting the buffer or
## crashing the server.

import std/strutils
import ../lsp/protocol
import ../server/state
import ../server/documents

type
  LineInfo = object
    raw: string          ## original line text (no line-ending)
    startDepth: int       ## bracket depth (paren/square/curly) at line start
    protected: bool        ## line touches a triple-quoted string -> never edit
    hasTabIndent: bool      ## leading whitespace contains a tab
    isBlank: bool            ## whitespace-only line
    isCommentOnly: bool       ## nothing but a `#` comment on this line
    commentIdx: int            ## index of an unquoted `#`, or -1
    rawIndent: int              ## count of leading space/tab chars
    normIndent: int              ## renormalized (or contextual) indent width

proc leadingInfo(s: string): tuple[rawIndent: int, hasTab: bool] =
  var i = 0
  var hasTab = false
  while i < s.len and (s[i] == ' ' or s[i] == '\t'):
    if s[i] == '\t': hasTab = true
    inc i
  (i, hasTab)

proc scanLine(line: string; depth0: int; inTriple0: bool):
    tuple[depth1: int, inTriple1: bool, touched: bool, commentIdx: int] =
  ## Best-effort lexical scan of one line: tracks bracket depth and
  ## triple-quoted-string state across lines, skipping over string/char
  ## literals and `#` comments. Not a real parser — a heuristic, same spirit
  ## as selection.nim's `findBracketPairs`.
  var i = 0
  var depth = depth0
  var inTriple = inTriple0
  var touched = inTriple0
  var commentIdx = -1
  let n = line.len
  while i < n:
    if inTriple:
      touched = true
      if i + 2 < n and line[i] == '"' and line[i+1] == '"' and line[i+2] == '"':
        inTriple = false
        i += 3
      else:
        inc i
      continue
    case line[i]
    of '"':
      if i + 2 < n and line[i+1] == '"' and line[i+2] == '"':
        inTriple = true
        touched = true
        i += 3
      else:
        inc i
        while i < n and line[i] != '"':
          if line[i] == '\\' and i + 1 < n: inc i
          inc i
        if i < n: inc i
    of '\'':
      inc i
      while i < n and line[i] != '\'':
        if line[i] == '\\' and i + 1 < n: inc i
        inc i
      if i < n: inc i
    of '#':
      if commentIdx < 0: commentIdx = i
      i = n
    of '(', '[', '{':
      inc depth
      inc i
    of ')', ']', '}':
      if depth > 0: dec depth
      inc i
    else:
      inc i
  result = (depth, inTriple, touched, commentIdx)

proc analyzeLines(doc: Document): seq[LineInfo] =
  result = @[]
  let n = doc.lineCount()
  var depth = 0
  var inTriple = false
  for i in 0 ..< n:
    let raw = doc.lineText(i)
    let (rawIndent, hasTab) = leadingInfo(raw)
    let isBlank = rawIndent >= raw.len
    let (depth1, inTriple1, touched, commentIdx) = scanLine(raw, depth, inTriple)
    let isCommentOnly = (not isBlank) and commentIdx == rawIndent
    result.add LineInfo(raw: raw, startDepth: depth, protected: touched,
                         hasTabIndent: hasTab, isBlank: isBlank,
                         isCommentOnly: isCommentOnly, commentIdx: commentIdx,
                         rawIndent: rawIndent, normIndent: 0)
    depth = depth1
    inTriple = inTriple1

  # Second pass: derive normalized indentation via a level stack. Only
  # "structural" lines (see module doc) push/pop the stack; every other line
  # just reads the current top-of-stack as contextual indentation (used by
  # onTypeFormat), without mutating it.
  var stack = @[(raw: 0, norm: 0)]
  for i in 0 ..< result.len:
    let eligible = (not result[i].protected) and result[i].startDepth == 0 and
                   not result[i].hasTabIndent and not result[i].isBlank and
                   not result[i].isCommentOnly
    if eligible:
      let ri = result[i].rawIndent
      while stack.len > 1 and stack[^1].raw > ri:
        stack.setLen(stack.len - 1)
      if stack[^1].raw == ri:
        result[i].normIndent = stack[^1].norm
      elif stack[^1].raw < ri:
        result[i].normIndent = stack[^1].norm + 2
        stack.add (raw: ri, norm: result[i].normIndent)
      else:
        result[i].normIndent = 0   # unreachable in practice (base is raw 0)
    else:
      result[i].normIndent = stack[^1].norm

proc computeNewLine(li: LineInfo): string =
  if li.protected:
    return li.raw
  var s = li.raw.strip(leading = false, trailing = true, chars = {' ', '\t'})
  if not li.hasTabIndent and li.startDepth == 0 and not li.isBlank and not li.isCommentOnly:
    let content = if s.len >= li.rawIndent: s[li.rawIndent ..< s.len] else: ""
    s = repeat(' ', li.normIndent) & content
  result = s

proc formatDocument*(cfg: Config; doc: Document): seq[TextEdit] =
  ## Whole-document conservative reformat, returned as a single replace edit
  ## (or `@[]` if nothing would change / input is empty / anything looked
  ## unsafe).
  result = @[]
  try:
    if doc == nil or doc.text.len == 0:
      return
    let infos = analyzeLines(doc)
    var outLines: seq[string] = @[]
    var outProtected: seq[bool] = @[]
    var lastBlank = false
    for li in infos:
      let newLine = computeNewLine(li)
      let isBlankOut = (not li.protected) and newLine.len == 0
      if isBlankOut and lastBlank:
        continue
      outLines.add newLine
      outProtected.add li.protected
      lastBlank = isBlankOut
    # No dangling blank separator lines right before EOF.
    while outLines.len > 0 and outLines[^1].len == 0 and not outProtected[^1]:
      outLines.setLen(outLines.len - 1)
      outProtected.setLen(outProtected.len - 1)
    let eol = if doc.text.contains("\r\n"): "\r\n" else: "\n"
    let newText = if outLines.len == 0: "" else: outLines.join(eol) & eol
    if newText == doc.text:
      return
    let endPos = doc.positionAt(doc.text.len)
    result.add TextEdit(`range`: Range(start: Position(line: 0, character: 0), `end`: endPos),
                         newText: newText)
  except CatchableError:
    result = @[]

proc formatRange*(cfg: Config; doc: Document; rng: Range): seq[TextEdit] =
  ## Per-line conservative reformat restricted to `rng`'s line span. Does not
  ## collapse blank lines or touch EOF (those are whole-document concerns);
  ## only trailing-whitespace strip + indentation renormalization, one edit
  ## per changed line.
  result = @[]
  try:
    if doc == nil:
      return
    let infos = analyzeLines(doc)
    if infos.len == 0:
      return
    let lo = clamp(min(rng.start.line, rng.`end`.line), 0, infos.len - 1)
    let hi = clamp(max(rng.start.line, rng.`end`.line), 0, infos.len - 1)
    for i in lo .. hi:
      let li = infos[i]
      if li.protected:
        continue
      let newLine = computeNewLine(li)
      if newLine == li.raw:
        continue
      result.add TextEdit(`range`: mkRange(i, 0, i, li.raw.len), newText: newLine)
  except CatchableError:
    result = @[]

proc onTypeFormat*(cfg: Config; doc: Document; pos: Position; ch: string): seq[TextEdit] =
  ## Fires after the client sends a just-typed `ch` (server advertises only
  ## `"\n"` as a trigger). Handles exactly one safe, common case: the client
  ## inserted a newline and the freshly created line (at `pos.line`) is still
  ## blank — set its indentation to match the enclosing block (+2 more if the
  ## previous line opens a block, i.e. ends with `:`). Anything else (mid-line
  ## edits, continuation lines, protected/tab-indented context) is left alone.
  result = @[]
  try:
    if doc == nil or ch != "\n":
      return
    let infos = analyzeLines(doc)
    if pos.line <= 0 or pos.line >= infos.len:
      return
    let cur = infos[pos.line]
    let prev = infos[pos.line - 1]
    if cur.protected or prev.protected:
      return
    if cur.startDepth != 0 or not cur.isBlank:
      return
    var target = prev.normIndent
    if not prev.hasTabIndent and prev.startDepth == 0 and not prev.isBlank:
      let codePart = if prev.commentIdx >= 0: prev.raw[0 ..< prev.commentIdx] else: prev.raw
      if codePart.strip(leading = false, trailing = true).endsWith(":"):
        target = prev.normIndent + 2
    let newIndent = repeat(' ', target)
    let curRaw = doc.lineText(pos.line)
    if curRaw == newIndent:
      return
    result.add TextEdit(`range`: mkRange(pos.line, 0, pos.line, curRaw.len), newText: newIndent)
  except CatchableError:
    result = @[]
