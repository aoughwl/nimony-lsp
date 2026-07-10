## In-process navigation index — definition / references / highlights /
## reference-counts by walking the semchecked `.s.nif` artifacts directly,
## with ZERO `nimony` spawns beyond the one memoized warm compile that
## `nifcache.getArtifact` performs for the current file.
##
## Symbols are matched ACROSS modules by their MANGLED STRING
## (`pool.syms[symId]`): the numeric `symId` is pool-local and unstable, but
## the interned string (`add.0.tgokb0h9q`) is stable everywhere the symbol is
## used, so a plain string compare unifies a declaration in one module with
## its uses in another.
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line 1-based, col 0-based.  LSP line = nif.line - 1.
##
## Every public proc is defensively wrapped so any failure yields an empty
## result — the LSP process must never crash.

import std/[options, os, strutils, tables, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ./nimonycli
import ./nifindex
import ./nifcache

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
from nifreader import processDirectives

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

type Occ = tuple[info: PackedLineInfo, isDef: bool]
  ## One occurrence of a symbol: its source line-info and whether the token was
  ## a `SymbolDef` (the declaration site) rather than a plain `Symbol` (a use).

proc loadBuf(p: string): TokenBuf =
  ## Parse a `.s.nif` artifact into a TokenBuf (directives skipped). Raises on
  ## a malformed file; callers guard.
  var s = nifstreams.open(p)
  try:
    discard processDirectives(s.r)
    result = fromStream(s)
  finally:
    nifstreams.close s

proc resolveSourceUri(cfg: Config; stored: string): string =
  ## Turn the (possibly relative) source path recorded in a token's line-info
  ## into an absolute `file://` URI. Mirrors workspacesym.resolveSourceUri.
  if stored.len == 0: return ""
  var abs = stored
  if not abs.isAbsolute:
    let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()
    abs = root / stored
  abs = abs.normalizedPath
  result = pathToUri(abs)

proc locFromInfo(cfg: Config; info: PackedLineInfo; nameLen: int): Option[Location] =
  ## Build a `Location` covering an identifier of `nameLen` chars at `info`.
  let up = unpack(pool.man, info)
  if not up.file.isValid or up.line <= 0: return none(Location)
  let uri = resolveSourceUri(cfg, pool.files[up.file])
  if uri.len == 0: return none(Location)
  let l = int(up.line) - 1                 # 1-based -> 0-based
  let c = max(0, int(up.col))
  some(Location(uri: uri, `range`: mkRange(l, c, l, c + max(1, nameLen))))

proc findOccs(buf: var TokenBuf; target: string; res: var seq[Occ]) =
  ## Append every `Symbol`/`SymbolDef` token whose mangled string equals
  ## `target`. A single depth-bounded walk over the whole artifact.
  var n = beginRead(buf)
  if n.kind != ParLe: return
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of Symbol:
      if pool.syms[n.symId] == target: res.add (n.info, false)
      inc n
    of SymbolDef:
      if pool.syms[n.symId] == target: res.add (n.info, true)
      inc n
    of EofToken:
      break
    else:
      inc n

proc symbolAt(cfg: Config; buf: var TokenBuf; file: string; pos: Position): string =
  ## The mangled symbol whose `Symbol`/`SymbolDef` token in THIS artifact spans
  ## `pos` (line-info line == pos.line+1, col <= pos.character <= col+len), and
  ## whose recorded source file is `file`. "" when the cursor is on no symbol.
  result = ""
  let rel = nifindex.relFileFor(cfg, file)
  var n = beginRead(buf)
  if n.kind != ParLe: return ""
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of Symbol, SymbolDef:
      let up = unpack(pool.man, n.info)
      if up.file.isValid and up.line > 0 and int(up.line) - 1 == pos.line:
        let sym = pool.syms[n.symId]
        let nm = nifindex.demangle(sym)
        let c = max(0, int(up.col))
        if nm.len > 0 and pos.character >= c and
           pos.character <= c + max(1, nm.len) and
           nifindex.pathsMatch(pool.files[up.file], rel):
          return sym
      inc n
    of EofToken:
      break
    else:
      inc n

# --------------------------------------------------------------------------
# Imported-symbol fallback (name-based) — used when `symbolAt` finds nothing
# because the clicked identifier is a reference to an IMPORTED type/proc: in the
# semchecked `.s.nif` that token carries the DEFINITION's line-info (pointing
# into the defining module, not the use site) and sem may have erased the alias
# (`Store` -> `Store.Obj`, `AtomId` -> `string`), so there is no use-site token
# at the cursor to match. We recover by:
#   1. reading the source NAME at the cursor from the nifler `.p.nif` parse
#      artifact (sibling of the `.s.nif`), which preserves every source
#      identifier at its true source line/col with no sem substitution; then
#   2. resolving that NAME to a real declaration's SymbolDef across every
#      module's `.s.nif`.
# --------------------------------------------------------------------------

proc siblingArtifact(sNifPath, newSuffix: string): string =
  ## `.../<stem>.s.nif` -> `.../<stem><newSuffix>` (e.g. ".p.nif", ".p.deps.nif").
  if not sNifPath.endsWith(".s.nif"): return ""
  result = sNifPath[0 ..< sNifPath.len - ".s.nif".len] & newSuffix

proc nameAtParse(cfg: Config; sNifPath, file: string; pos: Position): string =
  ## Source identifier spanning `pos` in the `.p.nif` parse artifact for `file`.
  ## Idents keep their text verbatim (`pool.strings`); the occasional Symbol /
  ## SymbolDef is demangled. "" when the cursor is on no identifier.
  result = ""
  let pPath = siblingArtifact(sNifPath, ".p.nif")
  if pPath.len == 0 or not fileExists(pPath): return ""
  var buf: TokenBuf
  try: buf = loadBuf(pPath)
  except CatchableError: return ""
  let rel = nifindex.relFileFor(cfg, file)
  var n = beginRead(buf)
  if n.kind != ParLe: return ""
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of Ident, Symbol, SymbolDef:
      let up = unpack(pool.man, n.info)
      if up.file.isValid and up.line > 0 and int(up.line) - 1 == pos.line:
        let nm = if n.kind == Ident: pool.strings[n.litId]
                 else: nifindex.demangle(pool.syms[n.symId])
        let c = max(0, int(up.col))
        if nm.len > 0 and pos.character >= c and pos.character < c + nm.len and
           nifindex.pathsMatch(pool.files[up.file], rel):
          return nm
      inc n
    of EofToken:
      break
    else:
      inc n

proc nameAtSource(file: string; pos: Position): string =
  ## The identifier spanning `pos` read straight from the source file on disk.
  ## Backstop for `nameAtParse`: nifler records some tokens (notably a proc's
  ## RETURN type) with an inaccurate column, so the `.p.nif` may have no token at
  ## the real cursor position — the source text always does. "" on any failure or
  ## when the cursor is not on an identifier char.
  const IdChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  result = ""
  var content = ""
  try:
    if not fileExists(file): return ""
    content = readFile(file)
  except CatchableError:
    return ""
  let lines = content.splitLines
  if pos.line < 0 or pos.line >= lines.len: return ""
  let line = lines[pos.line]
  var i = pos.character
  if i < 0: return ""
  # Cursor may sit just past the identifier's last char.
  if i >= line.len or line[i] notin IdChars:
    if i > 0 and i - 1 < line.len and line[i - 1] in IdChars: dec i
    else: return ""
  var a = i
  while a > 0 and line[a - 1] in IdChars: dec a
  var b = i
  while b < line.len and line[b] in IdChars: inc b
  result = line[a ..< b]

proc importSetFor(sNifPath: string): HashSet[string] =
  ## Module names this file directly imports, from the `.p.deps.nif` sibling
  ## (nifler `nim-deps` dialect: `(import <name>)` nodes). Used to disambiguate
  ## a name that several modules declare.
  result = initHashSet[string]()
  let dPath = siblingArtifact(sNifPath, ".p.deps.nif")
  if dPath.len == 0 or not fileExists(dPath): return result
  var buf: TokenBuf
  try: buf = loadBuf(dPath)
  except CatchableError: return result
  var n = beginRead(buf)
  if n.kind != ParLe: return result
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of Ident:
      result.incl pool.strings[n.litId]
      inc n
    of Symbol:
      result.incl nifindex.demangle(pool.syms[n.symId])
      inc n
    of EofToken:
      break
    else:
      inc n

proc moduleNameOf(buf: var TokenBuf): string =
  ## The module a `.s.nif` belongs to — the filename stem of the source file
  ## recorded on its leading `stmts` token (e.g. `nifcas/nifcas.nim` -> "nifcas").
  result = ""
  var m = beginRead(buf)
  if m.kind == ParLe:
    let up = unpack(pool.man, m.info)
    if up.file.isValid:
      result = splitFile(pool.files[up.file]).name

proc realDeclSyms(buf: var TokenBuf; name: string; modl: string;
                  res: var seq[tuple[sym, modl: string]]) =
  ## Every SymbolDef in `buf` that demangles to `name` AND names a real
  ## declaration (its enclosing node's tag classifies via `nifindex.classifyKind`
  ## — a type/proc/const/var/…, not an arbitrary token). Paired with `modl`.
  var n = beginRead(buf)
  if n.kind != ParLe: return
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      let tag = pool.tags[n.tagId]
      if nifindex.classifyKind(tag).isSome:
        var d = n
        inc d
        if d.kind == SymbolDef:
          let sym = pool.syms[d.symId]
          if nifindex.demangle(sym) == name:
            res.add (sym, modl)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken:
      break
    else:
      inc n

proc resolveNameToSym(cfg: Config; name: string; imports: HashSet[string]): string =
  ## Resolve a source NAME to the MANGLED symbol of a real declaration by
  ## scanning every module `.s.nif`. Prefer a decl in a directly-imported module;
  ## otherwise the first type/decl match. "" when nothing matches.
  result = ""
  var firstMatch = ""
  for f in nimonycli.allSNif(cfg):
    var buf: TokenBuf
    try: buf = loadBuf(f)
    except CatchableError: continue
    let modl = moduleNameOf(buf)
    var cands: seq[tuple[sym, modl: string]] = @[]
    realDeclSyms(buf, name, modl, cands)
    for c in cands:
      if firstMatch.len == 0: firstMatch = c.sym
      if c.modl.len > 0 and c.modl in imports:
        return c.sym
  return firstMatch

proc crossModuleDef(cfg: Config; target: string): seq[Location] =
  ## The declaration site of the mangled `target`, searched across every module
  ## `.s.nif`. A single-element seq, or `@[]`.
  result = @[]
  let nameLen = nifindex.demangle(target).len
  for f in nimonycli.allSNif(cfg):
    var buf: TokenBuf
    try: buf = loadBuf(f)
    except CatchableError: continue
    var occs: seq[Occ] = @[]
    findOccs(buf, target, occs)
    for oc in occs:
      if oc.isDef:
        let loc = locFromInfo(cfg, oc.info, nameLen)
        if loc.isSome: return @[loc.get]

proc nameOccsInParse(cfg: Config; sNifPath, file, name: string;
                     seen: var HashSet[string]; acc: var seq[Location]) =
  ## Append every use of source identifier `name` in `file`'s `.p.nif` parse
  ## artifact (true use-site positions that survive sem's alias erasure), deduped
  ## against `seen`. Lets `referencesAt` report an imported symbol's uses.
  let pPath = siblingArtifact(sNifPath, ".p.nif")
  if pPath.len == 0 or not fileExists(pPath): return
  var buf: TokenBuf
  try: buf = loadBuf(pPath)
  except CatchableError: return
  let rel = nifindex.relFileFor(cfg, file)
  var n = beginRead(buf)
  if n.kind != ParLe: return
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of Ident, Symbol, SymbolDef:
      let up = unpack(pool.man, n.info)
      if up.file.isValid and up.line > 0:
        let nm = if n.kind == Ident: pool.strings[n.litId]
                 else: nifindex.demangle(pool.syms[n.symId])
        if nm == name and nifindex.pathsMatch(pool.files[up.file], rel):
          let loc = locFromInfo(cfg, n.info, name.len)
          if loc.isSome:
            let l = loc.get
            let key = l.uri & "#" & $l.`range`.start.line & ":" &
                      $l.`range`.start.character
            if not seen.containsOrIncl(key): acc.add l
      inc n
    of EofToken:
      break
    else:
      inc n

# --------------------------------------------------------------------------
# definitionAt
# --------------------------------------------------------------------------

proc definitionAt*(cfg: Config; file: string; pos: Position): seq[Location] =
  ## The declaration site of the symbol under the cursor. Looks in the current
  ## artifact first, then across every module's `.s.nif` (the def usually lives
  ## in the imported module). Returns a single-element seq, or `@[]`.
  result = @[]
  try:
    let a = nifcache.getArtifact(cfg, file)
    if a == nil: return result
    let target = symbolAt(cfg, a.buf, file, pos)
    if target.len == 0:
      # Fallback: the cursor is on a reference to an IMPORTED symbol whose
      # `.s.nif` token carries the definition's line-info (so `symbolAt` matched
      # nothing here). Recover the source NAME from the `.p.nif`, then resolve it
      # to a real decl across modules.
      var name = nameAtParse(cfg, a.sNifPath, file, pos)
      if name.len == 0: name = nameAtSource(file, pos)
      if name.len == 0: return result
      let sym = resolveNameToSym(cfg, name, importSetFor(a.sNifPath))
      if sym.len == 0: return result
      return crossModuleDef(cfg, sym)
    let nameLen = nifindex.demangle(target).len

    # 1. Declaration in the current artifact.
    var occs: seq[Occ] = @[]
    findOccs(a.buf, target, occs)
    for oc in occs:
      if oc.isDef:
        let loc = locFromInfo(cfg, oc.info, nameLen)
        if loc.isSome: return @[loc.get]

    # 2. Declaration in another module.
    for f in nimonycli.allSNif(cfg):
      var buf: TokenBuf
      try: buf = loadBuf(f)
      except CatchableError: continue
      var xocc: seq[Occ] = @[]
      findOccs(buf, target, xocc)
      for oc in xocc:
        if oc.isDef:
          let loc = locFromInfo(cfg, oc.info, nameLen)
          if loc.isSome: return @[loc.get]
    return result
  except CatchableError:
    return @[]

# --------------------------------------------------------------------------
# referencesAt
# --------------------------------------------------------------------------

proc referencesAt*(cfg: Config; file: string; pos: Position;
                   includeDecl = true): seq[Location] =
  ## Every occurrence of the symbol under the cursor: in-file (this artifact)
  ## plus cross-file (every module's `.s.nif`). Deduped by uri+line+col.
  result = @[]
  try:
    let a = nifcache.getArtifact(cfg, file)
    if a == nil: return result
    var target = symbolAt(cfg, a.buf, file, pos)
    var fallbackName = ""
    if target.len == 0:
      # Imported-symbol fallback: recover the NAME from the `.p.nif`, resolve it
      # to a real decl's mangled symbol, and additionally gather the true
      # use-site occurrences from this file's parse artifact (sem erased the
      # aliases at those uses, so the mangled walk alone cannot see them).
      fallbackName = nameAtParse(cfg, a.sNifPath, file, pos)
      if fallbackName.len == 0: fallbackName = nameAtSource(file, pos)
      if fallbackName.len == 0: return result
      target = resolveNameToSym(cfg, fallbackName, importSetFor(a.sNifPath))
      if target.len == 0: return result
    let nameLen = nifindex.demangle(target).len
    var seen = initHashSet[string]()
    var acc: seq[Location] = @[]   # NOT `result`: `result` is lent and cannot be
                                   # captured by the nested `addFrom` closure.

    proc addFrom(buf: var TokenBuf) =
      var occs: seq[Occ] = @[]
      findOccs(buf, target, occs)
      for oc in occs:
        if oc.isDef and not includeDecl: continue
        let loc = locFromInfo(cfg, oc.info, nameLen)
        if loc.isNone: continue
        let l = loc.get
        let key = l.uri & "#" & $l.`range`.start.line & ":" &
                  $l.`range`.start.character
        if seen.containsOrIncl(key): continue
        acc.add l

    addFrom(a.buf)
    for f in nimonycli.allSNif(cfg):
      var buf: TokenBuf
      try: buf = loadBuf(f)
      except CatchableError: continue
      addFrom(buf)
    if fallbackName.len > 0:
      # True use-site positions for the imported symbol, from THIS file's parse
      # artifact (deduped against the mangled-walk results above).
      nameOccsInParse(cfg, a.sNifPath, file, fallbackName, seen, acc)
    return acc
  except CatchableError:
    return @[]

# --------------------------------------------------------------------------
# highlightsAt
# --------------------------------------------------------------------------

proc highlightsAt*(cfg: Config; file: string; pos: Position): seq[DocumentHighlight] =
  ## Occurrences of the symbol under the cursor WITHIN the current file only.
  ## The declaration site is a write; every use is a read.
  result = @[]
  try:
    let a = nifcache.getArtifact(cfg, file)
    if a == nil: return result
    let target = symbolAt(cfg, a.buf, file, pos)
    if target.len == 0: return result
    let nameLen = nifindex.demangle(target).len
    let rel = nifindex.relFileFor(cfg, file)

    var occs: seq[Occ] = @[]
    findOccs(a.buf, target, occs)
    var seen = initHashSet[string]()
    for oc in occs:
      let up = unpack(pool.man, oc.info)
      if not up.file.isValid: continue
      if not nifindex.pathsMatch(pool.files[up.file], rel): continue
      let loc = locFromInfo(cfg, oc.info, nameLen)
      if loc.isNone: continue
      let r = loc.get.`range`
      let key = $r.start.line & ":" & $r.start.character
      if seen.containsOrIncl(key): continue
      let k = if oc.isDef: dhkWrite else: dhkRead
      result.add DocumentHighlight(`range`: r, kind: k)
    return result
  except CatchableError:
    return @[]

# --------------------------------------------------------------------------
# referenceCounts
# --------------------------------------------------------------------------

proc referenceCounts*(cfg: Config;
                      file: string): seq[tuple[rng: Range, name: string, count: int]] =
  ## For every top-level declaration in `file`: its selection range, demangled
  ## name, and in-file use-count (occurrences minus the declaration). ONE walk
  ## of the artifact — no per-symbol spawns. Powers codeLens.
  result = @[]
  try:
    let a = nifcache.getArtifact(cfg, file)
    if a == nil: return result
    var decls: seq[tuple[sym: string, rng: Range, name: string]] = @[]
    var occ = initCountTable[string]()

    var n = beginRead(a.buf)
    if n.kind != ParLe: return result
    var depth = 0
    while true:
      case n.kind
      of ParLe:
        let tag = pool.tags[n.tagId]
        # Direct children of the module `stmts` (depth == 1) that are decls.
        if depth == 1 and nifindex.classifyKind(tag).isSome:
          var d = n
          inc d
          if d.kind == SymbolDef:
            let sym = pool.syms[d.symId]
            let nm = nifindex.demangle(sym)
            if nm.len > 0 and not nifindex.isSynthName(nm):
              let (rng, ok) = nifindex.mkSymRange(d.info, nm.len)
              if ok: decls.add (sym, rng, nm)
        inc depth; inc n
      of ParRi:
        dec depth; inc n
        if depth <= 0: break
      of Symbol, SymbolDef:
        occ.inc(pool.syms[n.symId])
        inc n
      of EofToken:
        break
      else:
        inc n

    for d in decls:
      let uses = max(0, occ.getOrDefault(d.sym) - 1)   # minus the decl itself
      result.add (rng: d.rng, name: d.name, count: uses)
    return result
  except CatchableError:
    return @[]
