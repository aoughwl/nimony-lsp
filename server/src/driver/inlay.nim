## textDocument/inlayHint — inferred-type hints for `let`/`var`/`const`
## declarations that have no explicit type annotation.
##
## We read the semchecked `.s.nif` artifact (which has all inferred types
## filled in), walk its declaration nodes, and for each value declaration
## whose source text carries no `:` annotation we emit a `: <Type>` hint
## positioned right after the variable name.
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line 1-based, col 0-based.  LSP line = nif.line - 1.
##
## Everything is wrapped so that any failure yields `@[]` — the LSP process
## must stay alive.

import std/[os, strutils, sets]
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
# Locating the `.s.nif` artifact for a source file (mirrors nifindex helpers,
# kept local so this module is self-contained).
# --------------------------------------------------------------------------

proc relFileFor(cfg: Config; file: string): string =
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    result = relativePath(file, cfg.projectRoot, '/')
  else:
    result = file
  result = result.replace('\\', '/')

proc nimcacheDir(cfg: Config): string =
  let root = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
             else: getCurrentDir()
  result = root / "nimcache"

proc pathsMatch(stored, rel: string): bool =
  let a = stored.replace('\\', '/')
  let b = rel.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b) and (a.endsWith(b) or b.endsWith(a))

proc firstStmtsFile(nifPath: string): string =
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
  result = ""
  let dir = nimonycli.moduleCacheDir(cfg, file)
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
  let rel = relFileFor(cfg, file)
  discard nimonycli.run(cfg, "check", rel)
  result = findSNif(cfg, file)

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

proc demangle(sym: string): string =
  var isGlobal = false
  result = extractBasename(sym, isGlobal)
  if result.len == 0:
    let sn = splitSymName(sym)
    result = if sn.name.len > 0: sn.name else: sym

const valueDeclTags = ["let", "var", "const", "glet", "gvar", "gconst",
                       "tlet", "tvar", "tconst", "cursor"]

proc endPosFor(info: PackedLineInfo; nameLen: int): (Position, bool) =
  ## Position of the character right after the declared name.
  let up = unpack(pool.man, info)
  if not up.file.isValid or up.line <= 0:
    return (Position(line: 0, character: 0), false)
  let l = int(up.line) - 1          # 1-based -> 0-based
  let c = max(0, int(up.col)) + max(1, nameLen)
  (Position(line: l, character: c), true)

proc builtinTypeName(tag: string): string =
  ## Friendly name for a builtin type tag.  Empty => unknown / skip.
  case tag
  of "i": "int"
  of "u": "uint"
  of "f": "float"
  of "c": "char"
  of "bool": "bool"
  of "string": "string"
  of "cstring": "cstring"
  else: ""

proc renderType(c: Cursor): string =
  ## Produce a short, confident type name, or "" to skip.
  case c.kind
  of Symbol:
    result = demangle(pool.syms[c.symId])
  of ParLe:
    result = builtinTypeName(pool.tags[c.tagId])
  else:
    result = ""

# --------------------------------------------------------------------------
# inlayHints
# --------------------------------------------------------------------------

proc alreadyAnnotated(doc: Document; namePos: Position): bool =
  ## True when the source between the variable name and the `=` (or EOL for a
  ## typed decl without initializer) contains a `:` — i.e. the user annotated it.
  let line = doc.lineText(namePos.line)
  if namePos.character < 0 or namePos.character > line.len: return false
  let eq = line.find('=', namePos.character)
  let stop = if eq >= 0: eq else: line.len
  if stop <= namePos.character: return false
  result = line.find(':', namePos.character, stop - 1) >= 0

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc validTypeHintPos(doc: Document; pos: Position): bool =
  ## A `: Type` hint is trustworthy only when it sits immediately after the
  ## declared identifier on a real `let`/`var`/`const` line. The semchecked NIF
  ## also carries compiler-SYNTHESIZED decls (loop temps, `result`, lowered
  ## statements, module symbols) whose line-info points at arbitrary source
  ## tokens — a comment, the middle of an `import` word, an `inc`/call — which
  ## would otherwise scatter bogus (and mistyped) `: int` hints everywhere.
  let line = doc.lineText(pos.line)
  if pos.character <= 0 or pos.character > line.len: return false
  # Must land exactly at the end of an identifier: prev char ends a name, and
  # the char at pos does not continue one (kills mid-token / trailing-space).
  if not isIdentChar(line[pos.character - 1]): return false
  if pos.character < line.len and isIdentChar(line[pos.character]): return false
  let s = line.strip()
  if s.len == 0 or s[0] == '#': return false              # comment / blank
  # The line must actually introduce a binding with the keyword present, so a
  # bare `result = x` or a call is never decorated.
  result = s.startsWith("let ") or s.startsWith("var ") or s.startsWith("const ") or
           s.startsWith("let\t") or s.startsWith("var\t") or s.startsWith("const\t")

proc inlayHints*(cfg: Config; doc: Document; rng: Range): seq[InlayHint] =
  result = @[]
  var seen = initHashSet[(int, int)]()
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

    var n = beginRead(buf)
    if n.kind != ParLe: return result

    # Full depth-first walk of every node so nested declarations are covered.
    # Bounded by paren depth so we never read past the buffer.
    var depth = 0
    while true:
      case n.kind
      of ParLe:
        let tn = pool.tags[n.tagId]
        if tn in valueDeclTags:
          # (decl <SymbolDef> <export.> <pragmas.> <TYPE> <VALUE>)
          var d = n
          inc d                       # SymbolDef
          if d.kind == SymbolDef:
            let nm = demangle(pool.syms[d.symId])
            let symInfo = d.info
            if nm.len > 0:
              skip d                  # past name -> export
              skip d                  # past export -> pragmas
              skip d                  # past pragmas -> TYPE
              let typeName = renderType(d)
              if typeName.len > 0:
                let (pos, ok) = endPosFor(symInfo, nm.len)
                if ok and pos.line >= rng.start.line and pos.line <= rng.`end`.line and
                   validTypeHintPos(doc, pos):
                  if not alreadyAnnotated(doc, pos):
                    let key = (pos.line, pos.character)
                    if key notin seen:
                      seen.incl key
                      result.add InlayHint(
                        position: pos,
                        label: ": " & typeName,
                        kind: ihkType,
                        paddingLeft: false,
                        paddingRight: false)
        inc depth
        inc n                         # descend / recurse into every node
      of ParRi:
        dec depth
        inc n
        if depth <= 0: break
      of EofToken:
        break
      else:
        inc n
  except CatchableError:
    return @[]
