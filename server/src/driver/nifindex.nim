## In-process reading of Nimony NIF artifacts (.idx.nif / .s.nif) for
## document symbols, hover, and completion.
##
## Reuses Nimony's reusable NIF libraries under /home/savant/nimony/src/lib
## (nifstreams / nifcursors / nifindexes / symparser / lineinfos).
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line is 1-based, col is 0-based.
##   - LSP wants: line 0-based, col 0-based.  So LSP line = nif.line - 1.
##
## Every public proc is defensively wrapped: any failure yields an empty /
## `none` result so the LSP process stays alive.

import std/[options, os, strutils, tables, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ./nimonycli
import ./idetools

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
import symparser
import nifindexes
from nifreader import processDirectives

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

proc relFileFor*(cfg: Config; file: string): string =
  ## Path as nimony sees it: relative to the project root, using '/'.
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    result = relativePath(file, cfg.projectRoot, '/')
  else:
    result = file
  result = result.replace('\\', '/')

proc nimcacheDir*(cfg: Config): string =
  let root = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
             else: getCurrentDir()
  result = root / "nimcache"

proc demangle*(sym: string): string =
  ## `add.0.` / `add.0.Mod9` / `x.0.` -> `add` / `x`.
  var isGlobal = false
  result = extractBasename(sym, isGlobal)
  if result.len == 0:
    let sn = splitSymName(sym)
    result = if sn.name.len > 0: sn.name else: sym

proc isSynthName*(nm: string): bool =
  ## True for compiler-synthesized decls that shouldn't appear in the outline or
  ## completion: lifecycle hooks (`=destroy`/`=copy`/`=sink`/… = `=` followed by
  ## a lowercase letter) and the auto `$`/`hash` hooks (which demangle to
  ## backtick/dotted junk like `` dollar`.Shape ``). Real operators (`==`, `<=`,
  ## `+=`, user-defined `+`) are kept — only `=<letter>` and backtick/dot junk go.
  if nm.len == 0: return true
  if '`' in nm or '.' in nm: return true
  result = nm[0] == '=' and nm.len >= 2 and nm[1] in {'a'..'z'}

proc classifyKind*(tagName: string): Option[SymbolKind] =
  case tagName
  of "proc", "func", "converter", "iterator", "macro", "template":
    some(skFunction)
  of "method":
    some(skMethod)
  of "type":
    some(skClass)
  of "const":
    some(skConstant)
  of "let", "glet", "tlet", "cursor", "var", "gvar", "tvar":
    some(skVariable)
  else:
    none(SymbolKind)

proc toCompletionKind(sk: SymbolKind): CompletionItemKind =
  case sk
  of skFunction: cikFunction
  of skMethod: cikMethod
  of skClass, skStruct: cikClass
  of skConstant: cikConstant
  of skField: cikField
  of skEnumMember: cikEnumMember
  else: cikVariable

# --------------------------------------------------------------------------
# Locating the .s.nif artifact for a source file
# --------------------------------------------------------------------------

proc pathsMatch*(stored, rel: string): bool =
  let a = stored.replace('\\', '/')
  let b = rel.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b) and (a.endsWith(b) or b.endsWith(a))

proc firstStmtsFile*(nifPath: string): string =
  ## Open a .s.nif, skip directives, read the first token (the module `stmts`)
  ## and return the source file recorded in its line info (as nimony stored it).
  result = ""
  var s = nifstreams.open(nifPath)
  try:
    discard processDirectives(s.r)
    let t = nifstreams.next(s)
    if t.kind == ParLe:
      let up = unpack(pool.man, t.info)
      if up.file.isValid:
        result = pool.files[up.file]
  finally:
    nifstreams.close s

proc findSNif*(cfg: Config; file: string): string =
  ## Return the absolute path to the `.s.nif` whose module body is `file`,
  ## or "" if none can be found.
  result = ""
  let dir = nimcacheDir(cfg)
  if not dirExists(dir): return ""
  let rel = relFileFor(cfg, file)
  for f in walkFiles(dir / "*.s.nif"):
    var stored = ""
    try:
      stored = firstStmtsFile(f)
    except CatchableError:
      continue
    if stored.len > 0 and pathsMatch(stored, rel):
      return f
  return ""

proc ensureArtifact*(cfg: Config; file: string): string =
  ## (Re)generate the nimcache artifacts for `file` and return its `.s.nif`.
  let rel = relFileFor(cfg, file)
  discard nimonycli.run(cfg, "check", rel)
  result = findSNif(cfg, file)

# --------------------------------------------------------------------------
# documentSymbols
# --------------------------------------------------------------------------

proc mkSymRange*(info: PackedLineInfo; nameLen: int): (Range, bool) =
  let up = unpack(pool.man, info)
  if not up.file.isValid or up.line <= 0:
    return (mkRange(0, 0, 0, 0), false)
  let l = int(up.line) - 1          # 1-based -> 0-based
  let c = max(0, int(up.col))
  (mkRange(l, c, l, c + max(1, nameLen)), true)

proc collectFields(typeCursor: Cursor): seq[DocumentSymbol] =
  ## Linear scan over a `type` subtree, gathering `fld` / `efld` members.
  result = @[]
  var c = typeCursor
  var depth = 0
  while true:
    case c.kind
    of ParLe:
      let tn = pool.tags[c.tagId]
      if tn == "fld" or tn == "efld":
        var d = c
        inc d
        if d.kind == SymbolDef:
          let nm = demangle(pool.syms[d.symId])
          let (rng, ok) = mkSymRange(d.info, nm.len)
          if ok:
            let sk = if tn == "efld": skEnumMember else: skField
            result.add DocumentSymbol(name: nm, kind: sk, `range`: rng,
                                      selectionRange: rng)
      inc depth
      inc c
    of ParRi:
      dec depth
      inc c
      if depth <= 0: break
    of EofToken:
      break
    else:
      inc c

proc documentSymbols*(cfg: Config; file: string): seq[DocumentSymbol] =
  result = @[]
  try:
    let nifPath = ensureArtifact(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return result
    var s = nifstreams.open(nifPath)
    var buf: TokenBuf
    try:
      discard processDirectives(s.r)
      buf = fromStream(s)
    finally:
      nifstreams.close s
    var n = beginRead(buf)
    if n.kind != ParLe: return result
    inc n                     # descend past the `stmts` tag
    while n.kind != ParRi and n.kind != EofToken:
      if n.kind == ParLe:
        let tn = pool.tags[n.tagId]
        let sk = classifyKind(tn)
        if sk.isSome:
          var d = n
          inc d                # SymbolDef
          if d.kind == SymbolDef:
            let nm = demangle(pool.syms[d.symId])
            let (rng, ok) = mkSymRange(d.info, nm.len)
            if ok and not isSynthName(nm):
              var ds = DocumentSymbol(name: nm, kind: sk.get,
                                      `range`: rng, selectionRange: rng)
              if tn == "type":
                ds.children = collectFields(n)
              result.add ds
        skip n
      else:
        skip n
  except CatchableError:
    return result

# --------------------------------------------------------------------------
# hoverAt
# --------------------------------------------------------------------------

const IdChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc leadingWs(s: string): int =
  result = 0
  while result < s.len and s[result] in {' ', '\t'}: inc result

proc identPrefix(s: string): string =
  ## Leading identifier token of a (stripped) line, e.g. "proc" / "type".
  var i = 0
  while i < s.len and s[i] in IdChars: inc i
  result = s[0 ..< i]

proc parenBalance(s: string): int =
  for ch in s:
    if ch == '(': inc result
    elif ch == ')': dec result

proc collectSignature(lines: seq[string]; idx: int): (string, int) =
  ## Assemble a (possibly multi-line) declaration signature starting at `idx`.
  ## For procs with wrapping params: continue while parens are unbalanced.
  ## For object/enum/tuple types: include the indented body block.
  ## Returns (dedented signature text, index of last consumed line).
  let first = lines[idx]
  let base = leadingWs(first)
  let head = first.strip()
  let kw = identPrefix(head)
  let procLike = kw in ["proc", "func", "method", "iterator",
                        "converter", "template", "macro"]
  let isType = kw == "type" or head.contains("= object") or
               head.contains("= enum") or head.contains("= ref object") or
               head.contains("= tuple") or head.contains("= object)") or
               head.endsWith("= object") or head.endsWith("= enum")
  var outLines = @[first]
  var last = idx
  if procLike:
    var depth = parenBalance(first)
    var guard = 0
    while depth > 0 and last + 1 < lines.len and guard < 16:
      inc last; inc guard
      outLines.add lines[last]
      depth += parenBalance(lines[last])
  elif isType:
    var guard = 0
    while last + 1 < lines.len and guard < 24:
      let nxt = lines[last + 1]
      if nxt.strip().len == 0: break
      if leadingWs(nxt) <= base: break
      inc last; inc guard
      outLines.add nxt
  # Dedent by the declaration's own indentation.
  var res: seq[string] = @[]
  for ln in outLines:
    if base > 0 and ln.len >= base and ln[0 ..< base].strip().len == 0:
      res.add ln[base .. ^1].strip(leading = false)
    else:
      res.add ln.strip(leading = false)
  var sig = res.join("\n").strip(leading = false)
  if sig.endsWith("="):
    sig = sig[0 ..< sig.len - 1].strip(leading = false)
  result = (sig, last)

proc stripDocMarker(s: string): string =
  var t = s.strip()
  if t.startsWith("##"):
    t = t[2 .. ^1]
    if t.startsWith(" "): t = t[1 .. ^1]
  result = t

proc collectDoc(lines: seq[string]; declIdx, sigEnd: int): string =
  ## Doc comments are contiguous `##` lines immediately AFTER the signature
  ## block (indented body) or immediately BEFORE the declaration.
  var after: seq[string] = @[]
  var i = sigEnd + 1
  while i < lines.len and lines[i].strip().startsWith("##"):
    after.add stripDocMarker(lines[i]); inc i
  if after.len > 0:
    return after.join("\n").strip()
  var before: seq[string] = @[]
  var j = declIdx - 1
  while j >= 0 and lines[j].strip().startsWith("##"):
    before.insert(stripDocMarker(lines[j]), 0); dec j
  result = before.join("\n").strip()

proc hoverSingleLine(lines: seq[string]; lineIdx: int): Option[Hover] =
  ## Original behavior: a single fenced source line. Used as the safety net.
  if lineIdx < 0 or lineIdx >= lines.len: return none(Hover)
  var sig = lines[lineIdx].strip()
  if sig.endsWith("="):
    sig = sig[0 ..< sig.len - 1].strip()
  if sig.len == 0: return none(Hover)
  let md = "```nim\n" & sig & "\n```"
  return some(Hover(contents: MarkupContent(kind: "markdown", value: md),
                    `range`: none(Range)))

proc hoverAt*(cfg: Config; file: string; pos: Position): Option[Hover] =
  try:
    let locs = idetools.definition(cfg, file, pos)
    if locs.len == 0: return none(Hover)
    let loc = locs[0]
    let defPath = uriToPath(loc.uri)
    if not fileExists(defPath): return none(Hover)
    let lineIdx = loc.`range`.start.line     # 0-based
    let content = readFile(defPath)
    let lines = content.splitLines
    if lineIdx < 0 or lineIdx >= lines.len: return none(Hover)
    # Enriched path: multi-line signature + doc comment. Any failure falls
    # back to the original single-line behavior.
    try:
      let (sig, sigEnd) = collectSignature(lines, lineIdx)
      if sig.len == 0: return hoverSingleLine(lines, lineIdx)
      let doc = collectDoc(lines, lineIdx, sigEnd)
      var md = "```nim\n" & sig & "\n```"
      if doc.len > 0:
        md.add "\n\n" & doc
      return some(Hover(contents: MarkupContent(kind: "markdown", value: md),
                        `range`: none(Range)))
    except CatchableError:
      return hoverSingleLine(lines, lineIdx)
  except CatchableError:
    return none(Hover)

# --------------------------------------------------------------------------
# completions
# --------------------------------------------------------------------------

proc addImportedExports(cfg: Config; buf: var TokenBuf;
                        items: var seq[CompletionItem]; seen: var HashSet[string]) =
  ## Walk top-level `import` nodes, resolve each imported module's `.s.nif`
  ## in nimcache, and add its exported symbols as completions.
  let dir = nimcacheDir(cfg)
  var modIds: seq[string] = @[]
  block scan:
    var n = beginRead(buf)
    if n.kind != ParLe: break scan
    inc n
    while n.kind != ParRi and n.kind != EofToken:
      if n.kind == ParLe:
        let tn = pool.tags[n.tagId]
        if tn == "import" or tn == "from" or tn == "include":
          # linear scan of this subtree for (kv <modid> "path")
          var c = n
          var depth = 0
          while true:
            case c.kind
            of ParLe:
              if pool.tags[c.tagId] == "kv":
                var k = c
                inc k
                if k.kind == Ident:
                  modIds.add pool.strings[k.litId]
                elif k.kind == Symbol:
                  modIds.add pool.syms[k.symId]
              inc depth; inc c
            of ParRi:
              dec depth; inc c
              if depth <= 0: break
            of EofToken: break
            else: inc c
        skip n
      else:
        skip n
  for mid in modIds:
    let path = dir / (mid & ".s.nif")
    if not fileExists(path): continue
    try:
      var s = nifstreams.open(path)
      var tbl: Table[string, NifIndexEntry]
      try:
        discard processDirectives(s.r)
        tbl = readEmbeddedIndex(s)
      finally:
        nifstreams.close s
      for sym, entry in tbl:
        if entry.vis != Exported: continue
        let nm = demangle(sym)
        if nm.len == 0 or nm in seen or isSynthName(nm): continue
        seen.incl nm
        items.add CompletionItem(label: nm, kind: cikFunction)
    except CatchableError:
      continue

# --------------------------------------------------------------------------
# Dot-context member completion
# --------------------------------------------------------------------------

const VarTags = ["let", "var", "glet", "gvar", "tlet", "tvar", "cursor", "const"]
const RoutineTags = ["proc", "func", "method", "template", "macro",
                     "converter", "iterator"]

proc typeSlotName(start: Cursor): string =
  ## Given a cursor at a var/param ParLe, return the demangled name of its
  ## declared TYPE (slot layout: symdef, export, pragmas, TYPE, value).
  result = ""
  var t = start
  inc t                                    # symdef
  if t.kind != SymbolDef: return ""
  skip t                                   # past symdef
  if t.kind == ParRi: return ""
  skip t                                   # past export marker
  if t.kind == ParRi: return ""
  skip t                                   # past pragmas
  if t.kind == Symbol:
    result = demangle(pool.syms[t.symId])

proc typeSlotSym(start: Cursor): string =
  ## Like `typeSlotName`, but returns the RAW (mangled) type symbol, e.g.
  ## `Circle.0.shakc8bms` — which carries the defining-module suffix so we can
  ## find where the type (and its methods) actually live.
  result = ""
  var t = start
  inc t
  if t.kind != SymbolDef: return ""
  skip t
  if t.kind == ParRi: return ""
  skip t
  if t.kind == ParRi: return ""
  skip t
  if t.kind == Symbol:
    result = pool.syms[t.symId]

proc scanVarType(buf: var TokenBuf; name: string): string =
  ## Find any var/let/const declaration named `name` and return its type name.
  result = ""
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] in VarTags:
        var t = n
        inc t
        if t.kind == SymbolDef and demangle(pool.syms[t.symId]) == name:
          let tn = typeSlotName(n)
          if tn.len > 0: return tn
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc scanVarTypeSym(buf: var TokenBuf; name: string): string =
  ## Like `scanVarType` but returns the RAW type symbol (with module suffix).
  result = ""
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] in VarTags:
        var t = n
        inc t
        if t.kind == SymbolDef and demangle(pool.syms[t.symId]) == name:
          let ts = typeSlotSym(n)
          if ts.len > 0: return ts
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc collectTypeFields(buf: var TokenBuf; typeName: string): seq[DocumentSymbol] =
  ## Fields (`fld`/`efld`) of the `type` declaration named `typeName`.
  result = @[]
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] == "type":
        var t = n
        inc t
        if t.kind == SymbolDef and demangle(pool.syms[t.symId]) == typeName:
          return collectFields(n)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc objectBaseSym(typeCursor: Cursor): string =
  ## Raw base symbol of a `type … = object of Base` decl (the `of Base` Symbol),
  ## or "" for a base-less object / non-object type.
  result = ""
  var c = typeCursor
  var depth = 0
  while true:
    case c.kind
    of ParLe:
      if pool.tags[c.tagId] == "object":
        var o = c
        inc o
        if o.kind == Symbol: return pool.syms[o.symId]
        return ""
      inc depth; inc c
    of ParRi:
      dec depth; inc c
      if depth <= 0: break
    of EofToken: break
    else: inc c

proc collectTypeFieldsBySym(buf: var TokenBuf; typeSym: string;
                            baseSym: var string): seq[DocumentSymbol] =
  ## Fields of the `type` decl whose full symbol is `typeSym`. Also reports its
  ## `object of Base` base symbol via `baseSym` (for inherited-member walks).
  result = @[]
  baseSym = ""
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] == "type":
        var t = n
        inc t
        if t.kind == SymbolDef and pool.syms[t.symId] == typeSym:
          baseSym = objectBaseSym(n)
          return collectFields(n)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc firstParamType(procCursor: Cursor): string =
  ## Type name of a routine's first parameter (UFCS receiver), or "".
  result = ""
  var c = procCursor
  var depth = 0
  while true:
    case c.kind
    of ParLe:
      if pool.tags[c.tagId] == "param":
        return typeSlotName(c)
      inc depth; inc c
    of ParRi:
      dec depth; inc c
      if depth <= 0: break
    of EofToken: break
    else: inc c

proc firstParamTypeSym(procCursor: Cursor): string =
  ## Raw (suffix-qualified) type symbol of a routine's first parameter, or "".
  result = ""
  var c = procCursor
  var depth = 0
  while true:
    case c.kind
    of ParLe:
      if pool.tags[c.tagId] == "param":
        return typeSlotSym(c)
      inc depth; inc c
    of ParRi:
      dec depth; inc c
      if depth <= 0: break
    of EofToken: break
    else: inc c

proc collectUfcsMethods(buf: var TokenBuf; typeName: string): seq[CompletionItem] =
  ## Top-level routines whose FIRST parameter type is `typeName` (UFCS methods).
  result = @[]
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] in RoutineTags:
        var t = n
        inc t
        if t.kind == SymbolDef:
          let pname = demangle(pool.syms[t.symId])
          if pname.len > 0 and firstParamType(n) == typeName:
            result.add CompletionItem(label: pname, kind: cikMethod)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc collectUfcsMethodsBySym(buf: var TokenBuf; typeSym: string): seq[CompletionItem] =
  ## Routines whose FIRST parameter's full type symbol is `typeSym` — the UFCS
  ## methods callable as `receiver.method(...)`, wherever they are defined.
  result = @[]
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] in RoutineTags:
        var t = n
        inc t
        if t.kind == SymbolDef:
          let pname = demangle(pool.syms[t.symId])
          if pname.len > 0 and not isSynthName(pname) and
             firstParamTypeSym(n) == typeSym:
            result.add CompletionItem(label: pname, kind: cikMethod)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc dotMemberCompletions(cfg: Config; file: string; pos: Position;
                          bufText: string): Option[seq[CompletionItem]] =
  ## If `pos` is in `<ident>.` member-access context AND we can resolve the
  ## base identifier's object type, return its fields + UFCS methods. Otherwise
  ## `none`, so the caller falls back to the full completion list.
  ##
  ## `bufText` is the live (possibly unsaved) editor buffer; when non-empty it
  ## is used instead of the on-disk file so member completion works while typing.
  var raw = bufText
  if raw.len == 0:
    try: raw = readFile(file)
    except CatchableError: return none(seq[CompletionItem])
  let lines = raw.splitLines
  if pos.line < 0 or pos.line >= lines.len: return none(seq[CompletionItem])
  let line = lines[pos.line]
  let ci = pos.character
  if ci <= 0 or ci > line.len: return none(seq[CompletionItem])
  # Cursor may sit after a partial member name (`c.ra|`), not only right after
  # the dot (`c.|`). Scan the partial back to the dot.
  var ps = ci
  while ps > 0 and line[ps - 1] in IdChars: dec ps
  if ps == 0 or line[ps - 1] != '.': return none(seq[CompletionItem])
  let dotPos = ps - 1
  # Base identifier immediately before the dot.
  var b = dotPos
  while b > 0 and line[b - 1] in IdChars: dec b
  let base = line[b ..< dotPos]
  if base.len == 0: return none(seq[CompletionItem])
  # Repair the in-progress line so the buffer semchecks (a failed semcheck emits
  # no `.s.nif`, which would silently drop us to the global fallback). Drop the
  # trailing `.<partial>`; if that leaves the base as a bare expression statement
  # (which nimony rejects as "must be used/discarded"), wrap it in `discard` so
  # the base is still typed. Keep any leading assignment/call context intact.
  var repaired = lines
  let prefix = line[0 ..< b]
  if prefix.strip.len == 0:
    repaired[pos.line] = prefix & "discard " & base
  else:
    repaired[pos.line] = line[0 ..< dotPos]
  let dir = if file.isAbsolute: parentDir(file) else: getCurrentDir()
  let tmp = dir / ("nimlsp_dot_" & $getCurrentProcessId() & ".nim")
  # Snapshot nimcache so we can delete exactly the artifacts this temp compile
  # produces — otherwise every dot-completion permanently grows nimcache and
  # pollutes workspace-symbol results.
  let ncdir = nimcacheDir(cfg)
  var ncBefore = initHashSet[string]()
  if dirExists(ncdir):
    for f in walkFiles(ncdir / "*"): ncBefore.incl f
  var nifPath = ""
  try:
    writeFile(tmp, repaired.join("\n"))
    nifPath = ensureArtifact(cfg, tmp)
  except CatchableError:
    discard
  proc cleanup() =
    try: removeFile(tmp) except CatchableError: discard
    if dirExists(ncdir):
      for f in walkFiles(ncdir / "*"):
        if f notin ncBefore:
          try: removeFile(f) except CatchableError: discard
  if nifPath.len == 0 or not fileExists(nifPath):
    cleanup()
    return none(seq[CompletionItem])
  var items: seq[CompletionItem] = @[]
  var seen = initHashSet[string]()
  proc loadBuf(p: string): TokenBuf =
    var s = nifstreams.open(p)
    try:
      discard processDirectives(s.r)
      result = fromStream(s)
    finally:
      nifstreams.close s
  try:
    var buf = loadBuf(nifPath)
    # Resolve the receiver's fully-qualified type symbol (carries the defining
    # module suffix). The type declaration and its UFCS methods usually live in
    # a *different* module (the imported one), so we scan every module artifact
    # for members matching this symbol — not just the current buffer.
    let typeSym = scanVarTypeSym(buf, base)
    if typeSym.len > 0:
      # Walk the inheritance chain (Circle -> Shape -> RootObj): members of every
      # supertype are also accessible on the receiver. `chain` is the set of type
      # symbols to gather fields + UFCS methods for.
      var chain: seq[string] = @[typeSym]
      var chainSet = initHashSet[string]()
      chainSet.incl typeSym
      var files: seq[string] = @[]
      for f in walkFiles(ncdir / "*.s.nif"): files.add f
      var i = 0
      while i < chain.len and chain.len < 32:
        let cur = chain[i]; inc i
        for f in files:
          var mbuf: TokenBuf
          try: mbuf = loadBuf(f)
          except CatchableError: continue
          var baseSym = ""
          for ds in collectTypeFieldsBySym(mbuf, cur, baseSym):
            if ds.name.len > 0 and not isSynthName(ds.name) and ds.name notin seen:
              seen.incl ds.name
              items.add CompletionItem(label: ds.name, kind: toCompletionKind(ds.kind))
          if baseSym.len > 0 and baseSym notin chainSet and
             demangle(baseSym) != "RootObj":
            chainSet.incl baseSym
            chain.add baseSym
      # UFCS methods whose first parameter is any type in the chain.
      for f in files:
        var mbuf: TokenBuf
        try: mbuf = loadBuf(f)
        except CatchableError: continue
        for sym in chain:
          for it in collectUfcsMethodsBySym(mbuf, sym):
            if it.label.len > 0 and it.label notin seen:
              seen.incl it.label
              items.add it
    else:
      # Fallback: type couldn't be resolved to a qualified symbol (e.g. a local
      # or generic) — try same-buffer, name-based resolution.
      let typeName = scanVarType(buf, base)
      if typeName.len > 0:
        for ds in collectTypeFields(buf, typeName):
          if ds.name.len > 0 and ds.name notin seen:
            seen.incl ds.name
            items.add CompletionItem(label: ds.name, kind: toCompletionKind(ds.kind))
        for it in collectUfcsMethods(buf, typeName):
          if it.label.len > 0 and it.label notin seen:
            seen.incl it.label
            items.add it
  except CatchableError:
    discard
  cleanup()
  if items.len == 0: return none(seq[CompletionItem])
  return some(items)

proc completions*(cfg: Config; file: string; pos: Position;
                  bufText: string = ""): seq[CompletionItem] =
  result = @[]
  # Dot-context member completion (best-effort; falls back on failure).
  try:
    let mem = dotMemberCompletions(cfg, file, pos, bufText)
    if mem.isSome and mem.get.len > 0:
      return mem.get
  except CatchableError:
    discard
  var seen = initHashSet[string]()
  try:
    let nifPath = ensureArtifact(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return result
    # Current module top-level symbols.
    for ds in documentSymbols(cfg, file):
      if ds.name.len > 0 and ds.name notin seen:
        seen.incl ds.name
        result.add CompletionItem(label: ds.name, kind: toCompletionKind(ds.kind))
    # Exported symbols of imported modules.
    var s = nifstreams.open(nifPath)
    var buf: TokenBuf
    try:
      discard processDirectives(s.r)
      buf = fromStream(s)
    finally:
      nifstreams.close s
    addImportedExports(cfg, buf, result, seen)
  except CatchableError:
    return result
