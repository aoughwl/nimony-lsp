## In-process, parsed-artifact memo for module `.s.nif` files.
##
## Every NIF reader (nifindex, navindex, semtokens, inlay, workspacesym, …)
## should obtain its `TokenBuf` through `getArtifact` instead of re-opening and
## re-parsing the `.s.nif` on every request. We:
##   1. ensure the artifact exists (via the memoized `nimonycli.run … "check"`),
##   2. locate the module `.s.nif` (same logic as `nifindex.findSNif`),
##   3. parse the `TokenBuf` ONCE, memoized keyed by the resolved `.s.nif` path,
##   4. re-parse only when the file's modification time changes.
##
## `TokenBuf` forbids copying (`=copy` is `{.error.}`), so the parsed buffer is
## MOVED into the `CachedArtifact` ref and callers read it in place:
##   let a = getArtifact(cfg, file)
##   if a == nil: return
##   var n = beginRead(a.buf)     # `a.buf` is a mutable lvalue through the ref
##
## Every public proc is defensive: any failure yields `nil` / a no-op so the LSP
## process never crashes and never spawns nimony outside the shared warm cache.

import std/[os, tables, options, times, strutils]

import bitabs
import nifstreams
import nifcursors
import lineinfos
from nifreader import processDirectives

import ../server/state
import ./nimonycli

type
  CachedArtifact* = ref object
    sNifPath*: string      ## abs path to the module `.s.nif`
    buf*: TokenBuf         ## parsed token buffer (moved in; read in place)

var
  cache = initTable[string, CachedArtifact]()
  mtimes = initTable[string, times.Time]()

# --------------------------------------------------------------------------
# Locating the `.s.nif` (mirrors nifindex.findSNif; duplicated here to avoid a
# nifcache <-> nifindex import cycle — nifindex imports nifcache, not vice versa)
# --------------------------------------------------------------------------

proc relFileFor(cfg: Config; file: string): string =
  ## Path as nimony sees it: relative to the project root, using '/'.
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    result = relativePath(file, cfg.projectRoot, '/')
  else:
    result = file
  result = result.replace('\\', '/')

proc pathsMatch(stored, rel: string): bool =
  let a = stored.replace('\\', '/')
  let b = rel.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b) and (a.endsWith(b) or b.endsWith(a))

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

# --------------------------------------------------------------------------
# Parse + memo
# --------------------------------------------------------------------------

proc parseBuf(nifPath: string; art: CachedArtifact): bool =
  ## Parse `nifPath` into `art.buf` (moved). Returns false on any failure.
  var s = nifstreams.open(nifPath)
  try:
    discard processDirectives(s.r)
    art.buf = fromStream(s)
  except CatchableError:
    nifstreams.close s
    return false
  nifstreams.close s
  return true

proc getArtifact*(cfg: Config; file: string): CachedArtifact =
  ## Ensure `file`'s `.s.nif` exists (memoized compile), locate it, and return a
  ## `CachedArtifact` holding the parsed `TokenBuf`. The buffer is parsed once
  ## and reused until the `.s.nif` modification time changes. Returns `nil` on
  ## any failure or when no artifact could be produced. Never raises.
  try:
    let rel = relFileFor(cfg, file)
    discard nimonycli.run(cfg, "check", rel)
    let nifPath = findSNif(cfg, file)
    if nifPath.len == 0 or not fileExists(nifPath): return nil
    var mt: times.Time
    try:
      mt = getLastModificationTime(nifPath)
    except CatchableError:
      return nil
    cache.withValue(nifPath, hit):
      let known = mtimes.getOrDefault(nifPath)
      if known == mt:
        return hit[]
    # Cold or stale: parse fresh and memoize.
    let art = CachedArtifact(sNifPath: nifPath)
    if not parseBuf(nifPath, art): return nil
    cache[nifPath] = art
    mtimes[nifPath] = mt
    return art
  except CatchableError:
    return nil

proc invalidate*(cfg: Config; file: string) =
  ## Drop the memo entry for `file`'s artifact (if any). Never raises.
  try:
    let nifPath = findSNif(cfg, file)
    if nifPath.len > 0:
      cache.del(nifPath)
      mtimes.del(nifPath)
  except CatchableError:
    discard

proc invalidateAll*() =
  ## Drop every memoized artifact (called on didChangeWatchedFiles). Never raises.
  try:
    cache.clear()
    mtimes.clear()
  except CatchableError:
    discard
