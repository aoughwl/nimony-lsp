## In-process implementation of `workspace/symbol`.
##
## Scans every `.s.nif` artifact in the nimcache directory (built by
## `nimony check`) and returns the top-level symbols whose (demangled) name
## contains `query` (case-insensitively). If `query` is empty, returns a
## bounded prefix of all top-level symbols instead of failing/erroring.
##
## Reuses the exported helpers from `nifindex` (nimcacheDir, firstStmtsFile,
## demangle, classifyKind, mkSymRange) rather than re-implementing the NIF
## walking logic.
##
## Every failure is swallowed and yields `@[]` (or whatever was already
## collected) so the LSP process stays alive.

import std/[options, os, strutils, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ./nifindex
import ./nimonycli

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
import symparser
import nifindexes
from nifreader import processDirectives

const MaxResults = 500

proc moduleContainerName(storedFile: string): string =
  ## Human module name = the source file's basename without extension
  ## (e.g. `sample.nim` -> `sample`), rather than nimony's mangled artifact id.
  if storedFile.len == 0: return ""
  result = splitFile(storedFile).name
  # A generated/derived module records a `<hash>.s.nif` path; drop the `.s`.
  if result.endsWith(".s"): result = result[0 ..< result.len - 2]

proc resolveSourceUri(cfg: Config; storedFile: string): string =
  ## Turn the (possibly relative) source path recorded in the artifact's
  ## line info into an absolute file:// URI.
  if storedFile.len == 0:
    return ""
  var abs = storedFile
  if not abs.isAbsolute:
    let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()
    abs = root / storedFile
  abs = abs.normalizedPath
  result = pathToUri(abs)

proc collectFromArtifact(cfg: Config; nifPath: string; query: string;
                         seen: var HashSet[string];
                         result: var seq[SymbolInformation]) =
  let storedFile = nifindex.firstStmtsFile(nifPath)
  let uri = resolveSourceUri(cfg, storedFile)
  if uri.len == 0: return
  let containerName = moduleContainerName(storedFile)
  let needle = query.toLowerAscii

  var s = nifstreams.open(nifPath)
  var buf: TokenBuf
  try:
    discard processDirectives(s.r)
    buf = fromStream(s)
  finally:
    nifstreams.close s

  var n = beginRead(buf)
  if n.kind != ParLe: return
  inc n                     # descend past the `stmts` tag
  while n.kind != ParRi and n.kind != EofToken:
    if result.len >= MaxResults: return
    if n.kind == ParLe:
      let tn = pool.tags[n.tagId]
      let sk = nifindex.classifyKind(tn)
      if sk.isSome:
        var d = n
        inc d                # SymbolDef
        if d.kind == SymbolDef:
          let nm = nifindex.demangle(pool.syms[d.symId])
          if nm.len > 0 and (needle.len == 0 or nm.toLowerAscii.contains(needle)):
            let (rng, ok) = nifindex.mkSymRange(d.info, nm.len)
            if ok:
              let key = uri & "\x00" & nm & "\x00" & $rng.start.line
              if key notin seen:
                seen.incl key
                result.add SymbolInformation(
                  name: nm, kind: sk.get,
                  location: Location(uri: uri, `range`: rng),
                  containerName: containerName)
      skip n
    else:
      skip n

proc workspaceSymbols*(cfg: Config; query: string): seq[SymbolInformation] =
  result = @[]
  try:
    var seen = initHashSet[string]()
    for f in nimonycli.allSNif(cfg):
      if result.len >= MaxResults: break
      try:
        collectFromArtifact(cfg, f, query, seen, result)
      except CatchableError:
        continue
  except CatchableError:
    return result
