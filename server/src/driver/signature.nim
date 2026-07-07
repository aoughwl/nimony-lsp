## textDocument/signatureHelp.
##
## Given a cursor inside a call `callee(a, b, |c)`, resolve the callee via
## idetools goto-definition, read its declaration line, and present it as an
## LSP SignatureHelp with the parameter list broken out.
##
## Everything is wrapped in try/except returning none so the server process
## never dies on malformed input.

import std/[options, os, strutils]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./idetools

# --------------------------------------------------------------------------
# Lexical helpers (skip string/char literals and comments)
# --------------------------------------------------------------------------

const IdChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc skipLiteralOrComment(text: string; i0: int): int =
  ## If a string/char literal or comment starts at `i0`, return the index just
  ## past it; otherwise return `i0` unchanged.  Handles: "..." (with escapes),
  ## triple-quoted strings, '.' char literals, `#` line and `#[ ]#` block
  ## comments.  A `'` preceded by an identifier char is treated as a numeric
  ## suffix marker (e.g. 3'f32), not a char literal.
  let n = text.len
  var i = i0
  if i >= n: return i0
  let c = text[i]
  if c == '"':
    if i + 2 < n and text[i+1] == '"' and text[i+2] == '"':
      # triple-quoted string
      i += 3
      while i < n:
        if i + 2 < n and text[i] == '"' and text[i+1] == '"' and text[i+2] == '"':
          return i + 3
        inc i
      return n
    inc i
    while i < n:
      if text[i] == '\\': i += 2
      elif text[i] == '"': return i + 1
      else: inc i
    return n
  elif c == '\'' and (i == 0 or text[i-1] notin IdChars):
    inc i
    while i < n:
      if text[i] == '\\': i += 2
      elif text[i] == '\'': return i + 1
      else: inc i
    return n
  elif c == '#':
    if i + 1 < n and text[i+1] == '[':
      i += 2
      while i < n:
        if i + 1 < n and text[i] == ']' and text[i+1] == '#': return i + 2
        inc i
      return n
    # line comment
    inc i
    while i < n and text[i] != '\n': inc i
    return i
  return i0

# --------------------------------------------------------------------------
# Locate the enclosing call
# --------------------------------------------------------------------------

proc findOpenParen(text: string; cursor: int): int =
  ## Return the byte offset of the innermost unmatched '(' before `cursor`,
  ## or -1 if the cursor is not inside a parenthesised call.
  var stack: seq[tuple[ch: char, pos: int]] = @[]
  var i = 0
  while i < cursor:
    let j = skipLiteralOrComment(text, i)
    if j != i:
      i = j
      continue
    let c = text[i]
    case c
    of '(', '[', '{': stack.add((c, i))
    of ')', ']', '}':
      if stack.len > 0: discard stack.pop()
    else: discard
    inc i
  for k in countdown(stack.high, 0):
    if stack[k].ch == '(':
      return stack[k].pos
  return -1

proc countTopLevelCommas(text: string; openPos, cursor: int): int =
  ## Number of top-level commas between `openPos` (the '(') and `cursor`.
  result = 0
  var depth = 0
  var i = openPos + 1
  while i < cursor:
    let j = skipLiteralOrComment(text, i)
    if j != i:
      i = j
      continue
    let c = text[i]
    case c
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      if depth > 0: dec depth
    of ',':
      if depth == 0: inc result
    else: discard
    inc i

# --------------------------------------------------------------------------
# Parse a declaration line into label + parameters
# --------------------------------------------------------------------------

proc splitParams(inside: string): seq[ParameterInformation] =
  ## Split the text inside the outer parens on top-level ';' and ',' .
  result = @[]
  var depth = 0
  var start = 0
  var i = 0
  let n = inside.len
  var bounds: seq[(int, int)] = @[]
  while i < n:
    let j = skipLiteralOrComment(inside, i)
    if j != i:
      i = j
      continue
    let c = inside[i]
    case c
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      if depth > 0: dec depth
    of ';', ',':
      if depth == 0:
        bounds.add (start, i)
        start = i + 1
    else: discard
    inc i
  bounds.add (start, n)
  for (a, b) in bounds:
    let p = inside[a ..< b].strip()
    if p.len > 0: result.add ParameterInformation(label: p)

proc parseSignatureLine(line: string): SignatureInformation =
  ## Trim, drop a trailing `=`, and break out the parameter list.
  var sig = line.strip()
  if sig.endsWith("="):
    sig = sig[0 ..< sig.len-1].strip()
  result = SignatureInformation(label: sig, parameters: @[])
  # Locate the outer parens.
  let openIdx = sig.find('(')
  if openIdx < 0: return result
  var depth = 0
  var i = openIdx
  var closeIdx = -1
  let n = sig.len
  while i < n:
    let j = skipLiteralOrComment(sig, i)
    if j != i:
      i = j
      continue
    case sig[i]
    of '(': inc depth
    of ')':
      dec depth
      if depth == 0:
        closeIdx = i
        break
    else: discard
    inc i
  if closeIdx <= openIdx + 1: return result   # empty () or unbalanced
  result.parameters = splitParams(sig[openIdx+1 ..< closeIdx])

# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------

proc signatureHelp*(cfg: Config; doc: Document; pos: Position): Option[SignatureHelp] =
  try:
    let text = doc.text
    let cursor = clamp(doc.offsetAt(pos), 0, text.len)

    let openPos = findOpenParen(text, cursor)
    if openPos < 0: return none(SignatureHelp)

    # Callee identifier immediately before '(' (skipping any spaces).
    var e = openPos
    while e > 0 and text[e-1] in {' ', '\t'}: dec e
    var s = e
    while s > 0 and text[s-1] in IdChars: dec s
    if s == e: return none(SignatureHelp)   # e.g. a grouping paren, not a call
    let calleePos = doc.positionAt(s)

    let activeParam = countTopLevelCommas(text, openPos, cursor)

    # Resolve the callee to its declaration.
    let locs = idetools.definition(cfg, uriToPath(doc.uri), calleePos)
    if locs.len == 0: return none(SignatureHelp)
    let loc = locs[0]
    let defPath = uriToPath(loc.uri)
    if not fileExists(defPath): return none(SignatureHelp)
    let lineIdx = loc.`range`.start.line       # 0-based
    let lines = readFile(defPath).splitLines
    if lineIdx < 0 or lineIdx >= lines.len: return none(SignatureHelp)

    let si = parseSignatureLine(lines[lineIdx])
    if si.label.len == 0: return none(SignatureHelp)

    let active =
      if si.parameters.len > 0: min(activeParam, si.parameters.len - 1)
      else: 0
    return some(SignatureHelp(signatures: @[si],
                              activeSignature: 0,
                              activeParameter: active))
  except CatchableError:
    return none(SignatureHelp)
