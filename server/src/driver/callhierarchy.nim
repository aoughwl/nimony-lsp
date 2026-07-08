## `callHierarchy/prepare`, `callHierarchy/incomingCalls`,
## `callHierarchy/outgoingCalls`.
##
## Built on top of `idetools.definition`/`idetools.references` (which return
## zero-width Locations) plus lightweight source-scan heuristics to locate the
## enclosing routine of a use and the call sites inside a routine body.
##
## All operations are best-effort and defensive: any failure yields `@[]`.

import std/[os, strutils, tables]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./idetools

const
  routineKeywords = ["proc", "func", "method", "template", "macro",
                     "converter", "iterator"]
  idStart = {'a'..'z', 'A'..'Z', '_'}
  idChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  ctrlKeywords = ["if", "elif", "while", "for", "case", "when", "return",
                  "and", "or", "not", "in", "is", "of", "yield", "discard",
                  "result", "cast"]

proc readLinesSafe(path: string): seq[string] =
  ## Read a file into lines, or @[] on any failure.
  try:
    if not fileExists(path): return @[]
    result = readFile(path).splitLines()
  except CatchableError:
    result = @[]

proc indentOf(line: string): int =
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  i

proc parseRoutine(line: string): tuple[ok: bool, name: string, nameCol, indent: int] =
  ## If `line` is a routine header, return its name / name column / indent.
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  let indent = i
  var j = i
  while j < line.len and line[j] in {'a'..'z'}: inc j
  let kw = line[i ..< j]
  if kw notin routineKeywords: return (false, "", 0, indent)
  var k = j
  while k < line.len and line[k] in {' ', '\t'}: inc k
  if k >= line.len or line[k] notin idStart: return (false, "", 0, indent)
  var m = k
  while m < line.len and line[m] in idChars: inc m
  (true, line[k ..< m], k, indent)

proc widen(start: Position; width: int): Range =
  mkRange(start.line, start.character, start.line, start.character + max(1, width))

proc mkItem(name: string; uri: string; nameRange: Range): CallHierarchyItem =
  CallHierarchyItem(name: name, kind: skFunction, detail: "", uri: uri,
                    `range`: nameRange, selectionRange: nameRange)

proc prepareCallHierarchy*(cfg: Config; doc: Document; pos: Position): seq[CallHierarchyItem] =
  result = @[]
  try:
    let word = doc.wordAt(pos)
    if word.len == 0: return @[]
    let defs = idetools.definition(cfg, uriToPath(doc.uri), pos)
    if defs.len == 0: return @[]
    let def = defs[0]
    let start = def.`range`.start
    let nameRange = widen(start, word.len)
    result.add(mkItem(word, def.uri, nameRange))
  except CatchableError:
    result = @[]

proc incomingCalls*(cfg: Config; item: CallHierarchyItem): seq[CallHierarchyIncomingCall] =
  result = @[]
  try:
    let path = uriToPath(item.uri)
    let pos = item.selectionRange.start
    let refs = idetools.references(cfg, path, pos)
    if refs.len == 0: return @[]

    # cache file lines per uri
    var fileLines = initTable[string, seq[string]]()
    # ordered grouping by caller
    type Caller = object
      name: string
      uri: string
      nameCol, headerLine: int
      ranges: seq[Range]
    var order: seq[string] = @[]
    var callers = initTable[string, Caller]()

    for loc in refs:
      let useLine = loc.`range`.start.line
      let useCol = loc.`range`.start.character
      # skip the definition site itself
      if loc.uri == item.uri and useLine == pos.line and useCol == pos.character:
        continue
      if not fileLines.hasKey(loc.uri):
        fileLines[loc.uri] = readLinesSafe(uriToPath(loc.uri))
      let lines = fileLines[loc.uri]
      if useLine < 0 or useLine >= lines.len: continue
      let useIndent = indentOf(lines[useLine])
      # scan upward for the nearest enclosing routine header
      var found = false
      var cName = ""
      var cCol = 0
      var cLine = 0
      var i = useLine
      while i >= 0:
        let (ok, nm, col, ind) = parseRoutine(lines[i])
        if ok and ind <= useIndent:
          # nearest routine header at indent <= the use's encloses the use
          found = true
          cName = nm; cCol = col; cLine = i
          break
        dec i
      if not found: continue
      let key = loc.uri & "#" & $cLine & "#" & cName
      if not callers.hasKey(key):
        order.add(key)
        callers[key] = Caller(name: cName, uri: loc.uri, nameCol: cCol,
                              headerLine: cLine, ranges: @[])
      callers[key].ranges.add(widen(loc.`range`.start, item.name.len))

    for key in order:
      let c = callers[key]
      let hdrRange = mkRange(c.headerLine, c.nameCol,
                             c.headerLine, c.nameCol + c.name.len)
      result.add(CallHierarchyIncomingCall(
        `from`: mkItem(c.name, c.uri, hdrRange),
        fromRanges: c.ranges))
  except CatchableError:
    result = @[]

proc outgoingCalls*(cfg: Config; item: CallHierarchyItem): seq[CallHierarchyOutgoingCall] =
  result = @[]
  try:
    let bodyFile = uriToPath(item.uri)
    let lines = readLinesSafe(bodyFile)
    if lines.len == 0: return @[]
    let headerLine = item.`range`.start.line
    if headerLine < 0 or headerLine >= lines.len: return @[]
    let headerIndent = indentOf(lines[headerLine])

    # body spans from the header line to the next line at indent <= header's
    var endLine = lines.len
    for i in (headerLine + 1) ..< lines.len:
      if lines[i].strip.len == 0: continue
      if indentOf(lines[i]) <= headerIndent:
        endLine = i
        break

    # ordered grouping by callee identifier
    type Callee = object
      pos: Position           ## first call-site position (for resolution)
      ranges: seq[Range]
    var order: seq[string] = @[]
    var callees = initTable[string, Callee]()

    for li in headerLine ..< endLine:
      let line = lines[li]
      var i = 0
      var inStr = false
      var strDelim = ' '
      while i < line.len:
        let ch = line[i]
        if inStr:
          if ch == '\\':
            inc i, 2
            continue
          if ch == strDelim: inStr = false
          inc i
          continue
        if ch == '#':
          break  # rest of line is a comment
        if ch == '"' or ch == '\'':
          inStr = true; strDelim = ch; inc i
          continue
        if ch in idStart:
          let s = i
          var e = i
          while e < line.len and line[e] in idChars: inc e
          let name = line[s ..< e]
          # is it a call?  identifier immediately followed by '('
          if e < line.len and line[e] == '(':
            # preceding non-space char, to detect routine-decl / member access
            var p = s - 1
            while p >= 0 and line[p] in {' ', '\t'}: dec p
            var precededByKw = false
            if p >= 0:
              # word before us
              var q = p
              while q >= 0 and line[q] in idChars: dec q
              let prevWord = line[(q + 1) .. p]
              if prevWord in routineKeywords: precededByKw = true
            let skip = name in ctrlKeywords or name in routineKeywords or
                       precededByKw
            if not skip:
              if not callees.hasKey(name):
                order.add(name)
                callees[name] = Callee(pos: Position(line: li, character: s),
                                       ranges: @[])
              callees[name].ranges.add(widen(Position(line: li, character: s), name.len))
          i = e
          continue
        inc i

    for name in order:
      let c = callees[name]
      let defs = idetools.definition(cfg, bodyFile, c.pos)
      if defs.len == 0: continue
      let def = defs[0]
      let nameRange = widen(def.`range`.start, name.len)
      result.add(CallHierarchyOutgoingCall(
        to: mkItem(name, def.uri, nameRange),
        fromRanges: c.ranges))
  except CatchableError:
    result = @[]
