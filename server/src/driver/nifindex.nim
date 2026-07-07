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

proc classifyKind(tagName: string): Option[SymbolKind] =
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

proc pathsMatch(stored, rel: string): bool =
  let a = stored.replace('\\', '/')
  let b = rel.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b) and (a.endsWith(b) or b.endsWith(a))

proc firstStmtsFile(nifPath: string): string =
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

proc findSNif(cfg: Config; file: string): string =
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

proc ensureArtifact(cfg: Config; file: string): string =
  ## (Re)generate the nimcache artifacts for `file` and return its `.s.nif`.
  let rel = relFileFor(cfg, file)
  discard nimonycli.run(cfg, "check", rel)
  result = findSNif(cfg, file)

# --------------------------------------------------------------------------
# documentSymbols
# --------------------------------------------------------------------------

proc mkSymRange(info: PackedLineInfo; nameLen: int): (Range, bool) =
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
            if ok and nm.len > 0:
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
    var sig = lines[lineIdx].strip()
    # Trim a trailing `=` (proc/body separator) for a cleaner signature line.
    if sig.endsWith("="):
      sig = sig[0 ..< sig.len-1].strip()
    if sig.len == 0: return none(Hover)
    let md = "```nim\n" & sig & "\n```"
    return some(Hover(contents: MarkupContent(kind: "markdown", value: md),
                      `range`: none(Range)))
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
        if nm.len == 0 or nm in seen: continue
        seen.incl nm
        items.add CompletionItem(label: nm, kind: cikFunction)
    except CatchableError:
      continue

proc completions*(cfg: Config; file: string; pos: Position): seq[CompletionItem] =
  result = @[]
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
