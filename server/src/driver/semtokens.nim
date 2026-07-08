## textDocument/semanticTokens/full for Nimony.
##
## Reads the module's `.s.nif` artifact (via nimcache), walks the NIF tree and
## emits an LSP semantic-tokens payload: a flat `seq[int]`, 5 ints per token,
## sorted by (line, startChar) and delta-encoded per the LSP spec.
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line is 1-based, col is 0-based.
##   - LSP wants line 0-based, col 0-based.  So LSP line = nif.line - 1.
##
## The emitted `tokenType` is an index into `protocol.SemanticTokenTypes`; the
## server advertises that same legend in its capabilities.  Everything is
## wrapped defensively: any failure yields an empty result.

import std/[os, strutils, tables, algorithm, sets]
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

# Named legend indices (computed once at compile time, into the shared legend).
const
  tyFunction  = SemanticTokenTypes.find("function")
  tyMethod    = SemanticTokenTypes.find("method")
  tyType      = SemanticTokenTypes.find("type")
  tyVariable  = SemanticTokenTypes.find("variable")
  tyProperty  = SemanticTokenTypes.find("property")
  tyEnumMember = SemanticTokenTypes.find("enumMember")
  tyParameter = SemanticTokenTypes.find("parameter")

  # Token-modifier bit masks (index into the shared modifier legend).
  modDeclaration = 1 shl SemanticTokenModifiers.find("declaration")
  modReadonly    = 1 shl SemanticTokenModifiers.find("readonly")

proc readonlyTag(tagName: string): bool =
  ## Immutable value declarations. `var`/`gvar`/`tvar` are mutable.
  tagName in ["const", "let", "glet", "tlet", "cursor"]

proc declType(tagName: string): int =
  ## Legend index a declaration tag maps its declared symbol to, or -1 if the
  ## tag is not a declaration we care about.
  case tagName
  of "proc", "func", "converter", "iterator", "macro", "template":
    tyFunction
  of "method":
    tyMethod
  of "type":
    tyType
  of "const", "let", "glet", "tlet", "cursor", "var", "gvar", "tvar":
    tyVariable
  of "fld":
    tyProperty
  of "efld":
    tyEnumMember
  of "param":
    tyParameter
  else:
    -1

# --------------------------------------------------------------------------
# Small helpers (self-contained copies of nifindex's private logic)
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

proc sameDoc(stored, file: string): bool =
  ## Does a token's recorded source file refer to `file` (this document)?
  let a = stored.replace('\\', '/')
  let b = file.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b)

proc firstStmtsFile(nifPath: string): string =
  ## Open a `.s.nif`, skip directives, read the first token (the module `stmts`)
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

# --------------------------------------------------------------------------
# NIF walking
# --------------------------------------------------------------------------

type
  RawTok = object
    line, col, length, ttype, mods: int

proc buildSymTypes(buf: var TokenBuf; readonly: var HashSet[string]): Table[string, int] =
  ## PASS 1: map each declared symbol (mangled name) to its legend index, and
  ## record which symbols are read-only (declared const/let/...).
  result = initTable[string, int]()
  var n = beginRead(buf)
  var pending = -1               # legend index awaiting the next SymbolDef
  var pendingRo = false          # is the pending decl read-only?
  var left = buf.len             # bound: the cursor has no EofToken sentinel
  while left > 0 and n.kind != EofToken:
    case n.kind
    of ParLe:
      let tn = pool.tags[n.tagId]
      pending = declType(tn)
      pendingRo = readonlyTag(tn)
    of SymbolDef:
      if pending >= 0:
        result[pool.syms[n.symId]] = pending
        if pendingRo: readonly.incl pool.syms[n.symId]
      pending = -1
      pendingRo = false
    else:
      pending = -1
      pendingRo = false
    inc n
    dec left

proc collectTokens(buf: var TokenBuf; file: string;
                   symType: Table[string, int];
                   readonly: HashSet[string]): seq[RawTok] =
  ## PASS 2: emit a raw token for every Symbol / SymbolDef in `file`.
  result = @[]
  var n = beginRead(buf)
  var left = buf.len
  while left > 0 and n.kind != EofToken:
    if n.kind == Symbol or n.kind == SymbolDef:
      let up = unpack(pool.man, n.info)
      if up.file.isValid and up.line > 0:
        let stored = pool.files[up.file]
        if sameDoc(stored, file):
          let sym = pool.syms[n.symId]
          let nm = demangle(sym)
          if nm.len > 0:
            let t = symType.getOrDefault(sym, tyVariable)
            var mods = 0
            if n.kind == SymbolDef: mods = mods or modDeclaration
            if sym in readonly: mods = mods or modReadonly
            result.add RawTok(line: int(up.line) - 1,
                              col: max(0, int(up.col)),
                              length: nm.len, ttype: t, mods: mods)
    inc n
    dec left

proc encode(raws: seq[RawTok]): seq[int] =
  ## Sort by (line, col), dedup identical positions, delta-encode.
  var toks = raws
  toks.sort(proc (a, b: RawTok): int =
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col))
  result = @[]
  var prevLine = 0
  var prevCol = 0
  var haveLine = -1
  var haveCol = -1
  for r in toks:
    if r.line == haveLine and r.col == haveCol:
      continue                   # dedup exact (line,col) collisions
    let dl = r.line - prevLine
    let dc = if dl == 0: r.col - prevCol else: r.col
    result.add dl
    result.add dc
    result.add r.length
    result.add r.ttype
    result.add r.mods            # tokenModifiers bitset
    prevLine = r.line
    prevCol = r.col
    haveLine = r.line
    haveCol = r.col

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

proc semanticTokensFull*(cfg: Config; doc: Document): SemanticTokens =
  result = SemanticTokens(data: @[])
  try:
    let file = uriToPath(doc.uri)
    if file.len == 0: return result
    let nifPath = ensureArtifact(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return result
    var s = nifstreams.open(nifPath)
    var buf: TokenBuf
    try:
      discard processDirectives(s.r)
      buf = fromStream(s)
    finally:
      nifstreams.close s
    var readonly = initHashSet[string]()
    let symType = buildSymTypes(buf, readonly)
    let raws = collectTokens(buf, file, symType, readonly)
    result = SemanticTokens(data: encode(raws))
  except CatchableError:
    return SemanticTokens(data: @[])
