## Type hierarchy (LSP `textDocument/prepareTypeHierarchy`,
## `typeHierarchy/supertypes`, `typeHierarchy/subtypes`) for Nimony object types.
##
## For an object type under the cursor:
##   - supertypes = the base type(s) it inherits from
##       (`type T = object of Base` -> Base)
##   - subtypes   = every type across all modules that inherits from it
##       (scan all nimcache `.s.nif` for `object of T`).
##
## Reads Nimony NIF artifacts (`.s.nif`) directly, reusing the walking patterns
## from nifindex.nim. All small nimcache/NIF helpers are copied locally so this
## file only depends on the NIF libraries + protocol/uris/state/nimonycli.
##
## Coordinates (see ARCHITECTURE.md): NIF PackedLineInfo line is 1-based, col
## 0-based -> LSP line = nif.line - 1, LSP col = nif.col.
##
## Every public proc is defensively wrapped: any failure yields @[] so the LSP
## process stays alive.

import std/[os, strutils]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./nimonycli

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
import symparser
from nifreader import processDirectives

# --------------------------------------------------------------------------
# Small helpers (copied from nifindex.nim so this file is self-contained)
# --------------------------------------------------------------------------

proc relFileFor(cfg: Config; file: string): string =
  ## Path as nimony sees it: relative to the project root, using '/'.
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    result = relativePath(file, cfg.projectRoot, '/')
  else:
    result = file
  result = result.replace('\\', '/')

proc nimcacheDir(cfg: Config): string =
  let root = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
             else: getCurrentDir()
  result = root / "nimcache"

proc absPathFor(cfg: Config; p: string): string =
  if p.isAbsolute: p
  else: normalizedPath((if cfg.projectRoot.len > 0: cfg.projectRoot
                        else: getCurrentDir()) / p)

proc demangle(sym: string): string =
  ## `Animal.0.` / `RootObj.0.sysvq0asl` -> `Animal` / `RootObj`.
  var isGlobal = false
  result = extractBasename(sym, isGlobal)
  if result.len == 0:
    let sn = splitSymName(sym)
    result = if sn.name.len > 0: sn.name else: sym

proc pathsMatch(stored, rel: string): bool =
  let a = stored.replace('\\', '/')
  let b = rel.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b) and (a.endsWith(b) or b.endsWith(a))

proc firstStmtsFile(nifPath: string): string =
  ## Open a .s.nif, skip directives, read the module `stmts` token and return
  ## the source file recorded in its line info (as nimony stored it).
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

proc findSNif(cfg: Config; file: string): string =
  ## Absolute path to the `.s.nif` whose module body is `file`, or "".
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

proc ensureArtifact(cfg: Config; file: string): string =
  ## (Re)generate the nimcache artifacts for `file` and return its `.s.nif`.
  let rel = relFileFor(cfg, file)
  discard nimonycli.run(cfg, "check", rel)
  result = findSNif(cfg, file)

proc mkSymRange(info: PackedLineInfo; nameLen: int): (Range, bool) =
  let up = unpack(pool.man, info)
  if not up.file.isValid or up.line <= 0:
    return (mkRange(0, 0, 0, 0), false)
  let l = int(up.line) - 1          # 1-based -> 0-based
  let c = max(0, int(up.col))
  (mkRange(l, c, l, c + max(1, nameLen)), true)

proc loadBuf(nifPath: string): TokenBuf =
  var s = nifstreams.open(nifPath)
  try:
    discard processDirectives(s.r)
    result = fromStream(s)
  finally:
    nifstreams.close s

# --------------------------------------------------------------------------
# Type-decl scanning
# --------------------------------------------------------------------------

type TypeRec = object
  name: string
  rng: Range
  base: string        ## demangled base type name; "" if none / RootObj-less

proc objectBase(typeCursor: Cursor): string =
  ## Given a cursor at a `type` ParLe, find its `object` body and return the
  ## demangled name of the base type (the `of Base` Symbol), or "".
  result = ""
  var c = typeCursor
  var depth = 0
  while true:
    case c.kind
    of ParLe:
      if pool.tags[c.tagId] == "object":
        var o = c
        inc o                       # first child of `object`
        if o.kind == Symbol:
          return demangle(pool.syms[o.symId])
        return ""
      inc depth; inc c
    of ParRi:
      dec depth; inc c
      if depth <= 0: break
    of EofToken:
      break
    else:
      inc c

proc collectTypeDecls(buf: var TokenBuf): seq[TypeRec] =
  ## All top-level `type` declarations in `buf`, with their name range and base.
  result = @[]
  var n = beginRead(buf)
  if n.kind != ParLe: return result
  inc n                             # descend past the `stmts` tag
  while n.kind != ParRi and n.kind != EofToken:
    if n.kind == ParLe:
      if pool.tags[n.tagId] == "type":
        var d = n
        inc d                       # SymbolDef (type name)
        if d.kind == SymbolDef:
          let nm = demangle(pool.syms[d.symId])
          let (rng, ok) = mkSymRange(d.info, nm.len)
          if ok and nm.len > 0:
            result.add TypeRec(name: nm, rng: rng, base: objectBase(n))
      skip n
    else:
      skip n

proc moduleUri(cfg: Config; nifPath: string): string =
  ## file:// URI of the source module a `.s.nif` was compiled from.
  let src = firstStmtsFile(nifPath)
  if src.len == 0: return ""
  result = pathToUri(absPathFor(cfg, src))

proc mkItem(name: string; rng: Range; uri: string): TypeHierarchyItem =
  TypeHierarchyItem(name: name, kind: skClass, detail: "", uri: uri,
                    `range`: rng, selectionRange: rng)

# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

proc prepareTypeHierarchy*(cfg: Config; doc: Document; pos: Position): seq[TypeHierarchyItem] =
  result = @[]
  try:
    let word = doc.wordAt(pos)
    if word.len == 0: return result
    let file = uriToPath(doc.uri)
    let nifPath = ensureArtifact(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return result
    var buf = loadBuf(nifPath)
    for tr in collectTypeDecls(buf):
      if tr.name == word:
        result.add mkItem(tr.name, tr.rng, doc.uri)
        return result
  except CatchableError:
    return @[]

proc supertypes*(cfg: Config; item: TypeHierarchyItem): seq[TypeHierarchyItem] =
  result = @[]
  try:
    let file = uriToPath(item.uri)
    let nifPath = findSNif(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return result
    var buf = loadBuf(nifPath)
    let decls = collectTypeDecls(buf)
    var base = ""
    for tr in decls:
      if tr.name == item.name:
        base = tr.base
        break
    if base.len == 0 or base == "RootObj": return result
    # Base declared in the same module?
    for tr in decls:
      if tr.name == base:
        result.add mkItem(tr.name, tr.rng, item.uri)
        return result
    # Otherwise search every module's `.s.nif` for the base type's own decl.
    let dir = nimcacheDir(cfg)
    if not dirExists(dir): return result
    for f in walkFiles(dir / "*.s.nif"):
      try:
        var b2 = loadBuf(f)
        for tr in collectTypeDecls(b2):
          if tr.name == base:
            let uri = moduleUri(cfg, f)
            if uri.len > 0:
              result.add mkItem(tr.name, tr.rng, uri)
              return result
      except CatchableError:
        continue
  except CatchableError:
    return @[]

proc subtypes*(cfg: Config; item: TypeHierarchyItem): seq[TypeHierarchyItem] =
  result = @[]
  try:
    let dir = nimcacheDir(cfg)
    if not dirExists(dir): return result
    const Cap = 200
    for f in walkFiles(dir / "*.s.nif"):
      if result.len >= Cap: break
      var uri = ""
      try:
        var buf = loadBuf(f)
        for tr in collectTypeDecls(buf):
          if tr.base == item.name:
            if uri.len == 0: uri = moduleUri(cfg, f)
            if uri.len > 0:
              result.add mkItem(tr.name, tr.rng, uri)
              if result.len >= Cap: break
      except CatchableError:
        continue
  except CatchableError:
    return @[]
