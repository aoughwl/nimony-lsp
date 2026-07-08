## Parameter-name inlay hints.
##
## For each call site `callee(arg0, arg1, ...)` whose line falls inside the
## requested range, we resolve the callee's parameter names (via idetools
## goto-definition + a lightweight parse of the signature line) and emit an
## `ihkParameter` hint before every *positional* argument, e.g. `area(3, 4)`
## renders as `area(w: 3, h: 4)`.
##
## The approach is deliberately source-based and conservative: anything we are
## unsure about is skipped, and the whole thing is wrapped in try/except so a
## parse hiccup can never take the request down.

import std/[strutils]
import ../lsp/protocol
import ../server/documents
import ../server/state
import ../lsp/uris
import ./idetools

const
  IdentStart = {'a'..'z', 'A'..'Z', '_'}
  IdentChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  DefKeywords = ["proc", "func", "method", "template", "macro",
                 "iterator", "converter"]

proc skipAtomic(t: string; i: var int): bool =
  ## If `t[i]` begins a string / char literal or a comment, advance `i` past it
  ## and return true. Otherwise leave `i` untouched and return false.
  if i >= t.len: return false
  let c = t[i]
  case c
  of '#':
    if i + 1 < t.len and t[i+1] == '[':
      # block comment #[ ... ]#
      i += 2
      while i + 1 < t.len and not (t[i] == ']' and t[i+1] == '#'): inc i
      i = min(t.len, i + 2)
    else:
      while i < t.len and t[i] != '\n': inc i
    return true
  of '"':
    if i + 2 < t.len and t[i+1] == '"' and t[i+2] == '"':
      # triple-quoted string
      i += 3
      while i + 2 < t.len and
            not (t[i] == '"' and t[i+1] == '"' and t[i+2] == '"'): inc i
      i = min(t.len, i + 3)
    else:
      inc i
      while i < t.len and t[i] != '"' and t[i] != '\n':
        if t[i] == '\\': inc i
        inc i
      if i < t.len and t[i] == '"': inc i
    return true
  of '\'':
    # Only a char literal when not a numeric-literal suffix (e.g. `1'u8`).
    if i > 0 and t[i-1] in IdentChars:
      return false
    inc i
    while i < t.len and t[i] != '\'' and t[i] != '\n':
      if t[i] == '\\': inc i
      inc i
    if i < t.len and t[i] == '\'': inc i
    return true
  else:
    return false

proc precededByDefKeyword(t: string; s: int): bool =
  ## Is the identifier starting at `s` immediately preceded (modulo blanks) by a
  ## definition keyword? Guards against hinting a `proc foo(...)` *declaration*.
  var j = s - 1
  while j >= 0 and t[j] in {' ', '\t'}: dec j
  if j < 0 or t[j] notin IdentChars: return false
  let e = j
  while j >= 0 and t[j] in IdentChars: dec j
  let w = t[j+1 .. e]
  return w in DefKeywords

proc isNamedArg(span: string): bool =
  ## True when `span` looks like `name: value` or `name = value` at top level.
  var i = 0
  while i < span.len and span[i] in {' ', '\t'}: inc i
  if i >= span.len or span[i] notin IdentStart: return false
  while i < span.len and span[i] in IdentChars: inc i
  while i < span.len and span[i] in {' ', '\t'}: inc i
  if i >= span.len: return false
  if span[i] == ':': return true
  if span[i] == '=':
    # avoid ==, <=, >=, != (those are not named-arg separators)
    return i + 1 >= span.len or span[i+1] != '='
  return false

proc parseParamNames(line: string): seq[string] =
  ## Parse `proc callee(a: T; b, c: U): R` into `@["a", "b", "c"]`.
  result = @[]
  let op = line.find('(')
  if op < 0: return
  var depth = 0
  var cp = -1
  block findClose:
    var i = op
    while i < line.len:
      if skipAtomic(line, i): continue
      case line[i]
      of '(', '[', '{': inc depth
      of ')', ']', '}':
        dec depth
        if depth == 0:
          cp = i
          break findClose
      else: discard
      inc i
  if cp < 0 or cp <= op + 1: return
  let paramsRegion = line[op+1 ..< cp]

  # Split the region into groups on top-level ';'.
  var groups: seq[string] = @[]
  var d = 0
  var start = 0
  var k = 0
  while k < paramsRegion.len:
    if skipAtomic(paramsRegion, k): continue
    case paramsRegion[k]
    of '(', '[', '{': inc d
    of ')', ']', '}': dec d
    of ';':
      if d == 0:
        groups.add(paramsRegion[start ..< k])
        start = k + 1
    else: discard
    inc k
  groups.add(paramsRegion[start .. ^1])

  for g in groups:
    # Names are the comma-separated identifiers before the top-level ':'.
    var colon = -1
    var gd = 0
    var m = 0
    while m < g.len:
      if skipAtomic(g, m): continue
      case g[m]
      of '(', '[', '{': inc gd
      of ')', ']', '}': dec gd
      of ':':
        if gd == 0:
          colon = m
          break
      else: discard
      inc m
    if colon < 0: continue
    let namePart = g[0 ..< colon]
    for raw in namePart.split(','):
      var nm = raw.strip
      # Drop any pragma / annotation trailing the name.
      var p = 0
      while p < nm.len and nm[p] in IdentChars: inc p
      nm = nm[0 ..< p]
      if nm.len > 0 and nm[0] in IdentStart:
        result.add(nm)

proc argSpans(t: string; op: int): seq[tuple[startOff: int; named: bool]] =
  ## Given the offset of the opening '(', return one entry per top-level
  ## argument: the offset of its first non-blank char and whether it is named.
  result = @[]
  var i = op + 1
  var depth = 1
  var spanStart = i
  proc flush(t: string; a, b: int; acc: var seq[tuple[startOff: int; named: bool]]) =
    var s = a
    while s < b and t[s] in {' ', '\t', '\r', '\n'}: inc s
    if s >= b: return   # empty span (e.g. trailing comma) -> ignore
    acc.add((s, isNamedArg(t[a ..< b])))
  while i < t.len and depth > 0:
    if skipAtomic(t, i): continue
    case t[i]
    of '(', '[', '{':
      inc depth; inc i
    of ')', ']', '}':
      dec depth
      if depth == 0:
        flush(t, spanStart, i, result)
        inc i
        break
      inc i
    of ',':
      if depth == 1:
        flush(t, spanStart, i, result)
        inc i
        spanStart = i
      else:
        inc i
    else:
      inc i

proc parameterHints*(cfg: Config; doc: Document; rng: Range): seq[InlayHint] =
  result = @[]
  try:
    let t = doc.text
    let path = uriToPath(doc.uri)

    var i = 0
    while i < t.len:
      if skipAtomic(t, i): continue
      let c = t[i]
      if c in IdentStart:
        let s = i
        while i < t.len and t[i] in IdentChars: inc i
        # A call site: identifier immediately followed by '('.
        if i < t.len and t[i] == '(':
          let calleePos = doc.positionAt(s)
          if calleePos.line >= rng.start.line and calleePos.line <= rng.`end`.line and
             not precededByDefKeyword(t, s):
            let spans = argSpans(t, i)
            if spans.len > 0:
              # Resolve THIS call site's overload (idetools resolves the exact
              # symbol at the position) — do NOT cache by callee name, or
              # overloaded calls would reuse the first overload's params.
              var params: seq[string] = @[]
              let defs = idetools.definition(cfg, path, calleePos)
              if defs.len > 0:
                let loc = defs[0]
                let defPath = uriToPath(loc.uri)
                try:
                  let lines = readFile(defPath).splitLines
                  let li = loc.`range`.start.line
                  if li >= 0 and li < lines.len:
                    let defLine = lines[li]
                    if defLine.find('(') >= 0:
                      params = parseParamNames(defLine)
                except CatchableError:
                  params = @[]
              if params.len > 0:
                for k, a in spans:
                  if k >= params.len: break
                  if a.named: continue
                  let pos = doc.positionAt(a.startOff)
                  result.add(InlayHint(
                    position: pos,
                    label: params[k] & ":",
                    kind: ihkParameter,
                    paddingLeft: false,
                    paddingRight: true))
        continue
      inc i
  except CatchableError:
    return @[]
