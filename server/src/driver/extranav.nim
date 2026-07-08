## `textDocument/typeDefinition` and `textDocument/implementation`.
##
## Both walk the module's `.s.nif` artifact directly (like nifindex.nim). The
## private NIF helpers we need from nifindex.nim are not exported in this v0.1
## snapshot, so the small ones are copied locally.
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line is 1-based, col is 0-based.
##   - LSP wants: line 0-based, col 0-based.  So LSP line = nif.line - 1.
##
## Every public proc is defensively wrapped: any failure yields `@[]` so the LSP
## process stays alive.

import std/[options, os, strutils]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./nimonycli
import ./idetools

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
import symparser
from nifreader import processDirectives

# --------------------------------------------------------------------------
# Local copies of nifindex's private helpers
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

proc demangle(sym: string): string =
  ## `add.0.` / `add.0.Mod9` / `x.0.` -> `add` / `x`.
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
  ## Open a .s.nif, skip directives, read the first token (the module `stmts`)
  ## and return the source file recorded in its line info.
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

proc loadBuf(nifPath: string): TokenBuf =
  var s = nifstreams.open(nifPath)
  try:
    discard processDirectives(s.r)
    result = fromStream(s)
  finally:
    nifstreams.close s

# --------------------------------------------------------------------------
# NIF walking for type resolution
# --------------------------------------------------------------------------

## Decls that all share the `symdef, export, pragmas, TYPE, value` slot layout.
const DeclTags = ["let", "var", "glet", "gvar", "tlet", "tvar", "cursor",
                  "const", "param", "fld", "efld"]

proc firstSymbolName(c: Cursor): string =
  ## Demangled name of `c` if it is a `Symbol`, else of the first `Symbol`
  ## token found inside its subtree (handles `(ref X)`, `(ptr X)`, ...).
  if c.kind == Symbol: return demangle(pool.syms[c.symId])
  if c.kind != ParLe: return ""
  var x = c
  var depth = 0
  while true:
    case x.kind
    of ParLe: inc depth; inc x
    of ParRi:
      dec depth; inc x
      if depth <= 0: break
    of Symbol: return demangle(pool.syms[x.symId])
    of EofToken: break
    else: inc x
  return ""

proc declTypeName(start: Cursor): string =
  ## Given a cursor at a decl ParLe (var/param/field/...), return the demangled
  ## name of its declared TYPE (slot layout: symdef, export, pragmas, TYPE, ...).
  result = ""
  var t = start
  inc t                                    # symdef
  if t.kind != SymbolDef: return ""
  skip t                                   # past symdef
  if t.kind == ParRi: return ""
  skip t                                   # past export marker
  if t.kind == ParRi: return ""
  skip t                                   # past pragmas
  if t.kind == ParRi: return ""
  result = firstSymbolName(t)              # the TYPE slot

proc scanDeclType(buf: var TokenBuf; name: string): string =
  ## Find any var/let/param/field/const decl named `name`; return its type name.
  result = ""
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] in DeclTags:
        var t = n
        inc t
        if t.kind == SymbolDef and demangle(pool.syms[t.symId]) == name:
          let tn = declTypeName(n)
          if tn.len > 0: return tn
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n

proc locFromDef(cfg: Config; d: Cursor; nameLen: int): Option[Location] =
  ## Build an LSP Location from a `SymbolDef` cursor's line-info, widening the
  ## range to the name length.
  let up = unpack(pool.man, d.info)
  if not up.file.isValid or up.line <= 0: return none(Location)
  let l = int(up.line) - 1                 # 1-based -> 0-based line
  let c = max(0, int(up.col))              # already 0-based
  var f = pool.files[up.file]
  if f.len == 0: return none(Location)
  if not f.isAbsolute and cfg.projectRoot.len > 0:
    f = normalizedPath(cfg.projectRoot / f)
  let rng = mkRange(l, c, l, c + max(1, nameLen))
  some(Location(uri: pathToUri(f), `range`: rng))

proc findTypeDefIn(cfg: Config; buf: var TokenBuf; typeName: string): Option[Location] =
  ## Locate a `type` decl named `typeName` and return its definition Location.
  var n = beginRead(buf)
  var depth = 0
  while true:
    case n.kind
    of ParLe:
      if pool.tags[n.tagId] == "type":
        var t = n
        inc t
        if t.kind == SymbolDef and demangle(pool.syms[t.symId]) == typeName:
          return locFromDef(cfg, t, typeName.len)
      inc depth; inc n
    of ParRi:
      dec depth; inc n
      if depth <= 0: break
    of EofToken: break
    else: inc n
  none(Location)

# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

proc typeDefinition*(cfg: Config; doc: Document; pos: Position): seq[Location] =
  ## Jump to the definition of the TYPE of the symbol under the cursor.
  ## If the cursor is already on a type name, jump to that type's definition.
  ## Returns `@[]` when no type can be resolved (never the variable's own def).
  result = @[]
  try:
    let file = uriToPath(doc.uri)
    let word = doc.wordAt(pos)
    if word.len == 0: return @[]
    let nifPath = ensureArtifact(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return @[]
    var buf = loadBuf(nifPath)
    # The type of a var/param/field named `word`; if `word` is not a value decl
    # (e.g. the cursor is on a type name/use) fall back to the word itself.
    var typeName = scanDeclType(buf, word)
    if typeName.len == 0:
      typeName = word
    if typeName.len == 0: return @[]
    # Resolve the type decl in the current module first.
    let loc = findTypeDefIn(cfg, buf, typeName)
    if loc.isSome: return @[loc.get]
    # Otherwise search the other module artifacts (imported types).
    let dir = nimcacheDir(cfg)
    if dirExists(dir):
      for f in walkFiles(dir / "*.s.nif"):
        if f == nifPath: continue
        try:
          var b2 = loadBuf(f)
          let l2 = findTypeDefIn(cfg, b2, typeName)
          if l2.isSome: return @[l2.get]
        except CatchableError:
          continue
    return @[]
  except CatchableError:
    return @[]

proc implementation*(cfg: Config; doc: Document; pos: Position): seq[Location] =
  ## Nimony has no separate interface/implementation split, so the honest,
  ## correct behavior is: implementation == definition.
  try:
    return idetools.definition(cfg, uriToPath(doc.uri), pos)
  except CatchableError:
    return @[]
