## Runs the `nimony` binary and captures its output.
##
## A generation-based cache coalesces the many redundant `nimony check`
## invocations a single editor request triggers (e.g. completion runs a check,
## then documentSymbols runs a check, then imported-index reads run a check).
## Within one generation the same (sub, file, track) invocation runs the
## compiler once; any document lifecycle change bumps the generation and clears
## the cache, so results never go stale relative to what the drivers can see.

import std/[osproc, os, strutils, streams, tables, sets, algorithm, times]
import ../server/state

type
  CheckResult* = object
    output*: string    ## merged stdout+stderr
    exitCode*: int

const
  CheckTimeoutMs = 20_000   ## hard cap on any nimony subprocess. Normal checks
                            ## are ~1s; this only ever fires on a genuine hang,
                            ## turning "Loading forever" into a bounded failure.

proc waitBounded(p: Process; timeoutMs: int): int =
  ## Exit code, or -1 if the process overran `timeoutMs` (then it is killed).
  ## A live process reports peekExitCode == -1, so -1 is a safe "timed out"
  ## sentinel (a real exit code is always >= 0).
  var waited = 0
  const step = 15
  while true:
    let c = p.peekExitCode()
    if c != -1: return c
    if waited >= timeoutMs:
      try: p.terminate() except CatchableError: discard
      try:
        if p.peekExitCode() == -1: p.kill()
      except CatchableError: discard
      try: discard p.waitForExit() except CatchableError: discard
      return -1
    sleep(step)
    waited += step

var
  checkGeneration = 0
  checkCache = initTable[string, CheckResult]()

proc bumpCheckGeneration*() =
  ## Invalidate the check cache. Called on every document lifecycle event.
  inc checkGeneration
  checkCache.clear()

proc canonFile*(cfg: Config; file: string): string =
  ## Canonical path form handed to nimony: RELATIVE to projectRoot when the file
  ## lives under it. nimony keys its incremental compile cache by the path string
  ## AS GIVEN, so an absolute-path warm (diagnostics) and a relative-path query
  ## (--def / --usages for hover, definition, references) would otherwise land on
  ## SEPARATE cache entries — navigation would recompile the whole project on
  ## every request, forever, no matter how many times diagnostics warmed. Funnel
  ## every invocation through the SAME form so they all share one warm entry.
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    let rel = relativePath(file, cfg.projectRoot, '/')
    if rel.len == 0 or rel.startsWith(".."): file   # outside the root: keep abs
    else: rel
  else:
    file

proc cacheKey(sub, file: string; track: seq[string]): string =
  $checkGeneration & "\x1f" & sub & "\x1f" & file & "\x1f" & track.join("\x1f")

proc lspCacheDir(cfg: Config; canonName: string): string =
  ## A dedicated nimcache PER main module. The LSP checks every open file as its
  ## own main module; nimony writes different artifacts for a module compiled as
  ## `--isMain` vs. as a dependency, so several main modules sharing ONE nimcache
  ## overwrite each other's artifacts and NONE of them ever warm again (every
  ## check stays a full ~1.3s recompile — the "Loading forever / typing does
  ## nothing" disease). Isolating each file's cache lets each stay warm (~0.00s
  ## after one cold compile). Lives under `nimcache/lsp/` so it never collides
  ## with the user's own `nimony c` build cache.
  let root = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
             else: parentDir(canonName)
  var key = canonName
  for ch in ["/", "\\", ":", " "]: key = key.replace(ch, "_")
  if key.len == 0: key = "main"
  root / "nimcache" / "lsp" / key

proc moduleCacheDir*(cfg: Config; file: string): string =
  ## The per-module nimcache for `file` — where its LSP check writes its .s.nif
  ## AND where the artifact readers (completion/inlay/symbols/semtokens/…) must
  ## look. Both sides call this with the same file, so they always agree on the
  ## location despite the per-file isolation.
  lspCacheDir(cfg, canonFile(cfg, file))

proc lspCacheRoot(cfg: Config): string =
  (if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
   else: getCurrentDir()) / "nimcache" / "lsp"

iterator allSNif*(cfg: Config): string =
  ## Every module `.s.nif` across ALL per-file LSP caches — for cross-module
  ## searches (imported-type definitions, type-hierarchy super/subtypes,
  ## workspace symbols). A shared module appears once per cache that compiled it;
  ## callers dedupe by match.
  let base = lspCacheRoot(cfg)
  if dirExists(base):
    for sub in walkDirs(base / "*"):
      for f in walkFiles(sub / "*.s.nif"):
        yield f

# --- warm-cache retention: never delete on close; bound the pool by size ------
var
  cacheUseTick = 0
  cacheUse = initTable[string, int]()   ## per-module cache dir -> last-use tick

proc recordCacheUse*(cfg: Config; file: string) =
  ## Mark `file`'s per-module cache most-recently-used, so the LRU prune keeps
  ## the files you actually touch and evicts the ones you don't. Called on every
  ## check/artifact access.
  try:
    inc cacheUseTick
    cacheUse[moduleCacheDir(cfg, file)] = cacheUseTick
  except CatchableError: discard

proc dirSizeBytes(dir: string): int =
  try:
    for f in walkDirRec(dir):
      try: result += int(getFileSize(f))
      except CatchableError: discard
  except CatchableError: discard

proc pruneCaches*(cfg: Config; keep: HashSet[string] = initHashSet[string]()) =
  ## If the whole nimcache/lsp pool exceeds cfg.cacheBudgetBytes, evict entire
  ## per-module cache dirs — least-recently-used first (in-session use ticks,
  ## falling back to on-disk mtime across sessions) — until back under budget.
  ## Never evicts a dir in `keep` (the currently-open documents). No-op when
  ## pruning is disabled or the budget is non-positive. Fully defensive.
  if not cfg.cachePrune or cfg.cacheBudgetBytes <= 0: return
  let base = lspCacheRoot(cfg)
  if not dirExists(base): return
  try:
    var entries: seq[tuple[dir: string, size, recency: int]] = @[]
    var total = 0
    for sub in walkDirs(base / "*"):
      let sz = dirSizeBytes(sub)
      total += sz
      var rec = cacheUse.getOrDefault(sub, 0)
      if rec == 0:
        try: rec = int(getLastModificationTime(sub).toUnix)
        except CatchableError: discard
      entries.add((sub, sz, rec))
    if total <= cfg.cacheBudgetBytes: return
    entries.sort(proc (a, b: tuple[dir: string, size, recency: int]): int =
      cmp(a.recency, b.recency))          # oldest / least-recently-used first
    for e in entries:
      if total <= cfg.cacheBudgetBytes: break
      if e.dir in keep: continue
      if "/nimcache/lsp/" notin e.dir.replace("\\", "/"): continue   # safety guard
      try:
        removeDir(e.dir)
        cacheUse.del(e.dir)
        total -= e.size
      except CatchableError: discard
  except CatchableError: discard

proc buildArgs(cfg: Config; sub, file, nimcache: string; track: seq[string]): seq[string] =
  result = @[sub]
  if nimcache.len > 0:
    result.add("--nimcache:" & nimcache)
  for p in cfg.extraPaths:
    result.add("--path:" & p)
  for t in track:
    result.add(t)
  result.add(file)

proc runUncached(cfg: Config; sub: string; file: string; track: seq[string]): CheckResult =
  if cfg.nimonyExe.len == 0 or not fileExists(cfg.nimonyExe):
    return CheckResult(output: "", exitCode: 127)
  # `file` is already canonicalized by run(); give it its own per-module cache.
  let args = buildArgs(cfg, sub, file, lspCacheDir(cfg, file), track)
  let workdir = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
                else: parentDir(file)
  var p: Process
  try:
    p = startProcess(cfg.nimonyExe, workingDir = workdir, args = args,
                     options = {poStdErrToStdOut})
  except OSError:
    return CheckResult(output: "", exitCode: 127)
  let code = waitBounded(p, CheckTimeoutMs)
  let buf = try: p.outputStream.readAll() except CatchableError: ""
  p.close()
  if code < 0: return CheckResult(output: "", exitCode: 124)   # hung → killed
  CheckResult(output: buf, exitCode: code)

proc run*(cfg: Config; sub: string; file: string; track: seq[string] = @[]): CheckResult =
  ## Run `nimony <sub> [--path ...] [track...] <file>` from the project root,
  ## memoized for the current generation. The file path is canonicalized so every
  ## caller (diagnostics, hover, definition, references) shares one warm cache.
  recordCacheUse(cfg, file)           # LRU: this module was just touched
  let cf = canonFile(cfg, file)
  let key = cacheKey(sub, cf, track)
  checkCache.withValue(key, cached):
    return cached[]
  let t0 = epochTime()
  result = runUncached(cfg, sub, cf, track)
  let ms = (epochTime() - t0) * 1000
  if ms > 250:   # surface cold/slow compiles in the VS Code "Nimony" output channel
    try: stderr.writeLine("[nimony-lsp] " & sub & " " & cf &
                          (if track.len > 0: " " & track.join(" ") else: "") &
                          " took " & $int(ms) & "ms")
    except CatchableError: discard
  # Only cache a real compiler run (not the "binary missing" sentinel), so a
  # transient misconfiguration doesn't poison the whole generation.
  if result.exitCode != 127:
    checkCache[key] = result

proc checkTrack*(cfg: Config; file: string; track: seq[string]): CheckResult =
  run(cfg, "check", file, track)

proc runLiveCheck*(cfg: Config; file, nimcache: string;
                   track: seq[string] = @[]): CheckResult =
  ## Check `file` into a DEDICATED nimcache (for live/as-you-type diagnostics on
  ## a temp buffer). Isolating the cache is what keeps this incremental & fast
  ## (~10ms) — sharing the main nimcache makes every temp check a cold rebuild.
  ## Uncached (never touches the generation cache) and never cross-contended.
  ## With a `track` (--def/--usages), answers hover/definition/references against
  ## the UNSAVED buffer's temp file into the SAME isolated live cache — so nav
  ## reflects what you're typing, never contends the main warm cache, and is
  ## never funnelled through canonFile's generation memo.
  if cfg.nimonyExe.len == 0 or not fileExists(cfg.nimonyExe):
    return CheckResult(output: "", exitCode: 127)
  var args = @["check", "--nimcache:" & nimcache]
  for p in cfg.extraPaths: args.add("--path:" & p)
  for t in track: args.add t
  args.add file
  let workdir = if cfg.projectRoot.len > 0 and dirExists(cfg.projectRoot): cfg.projectRoot
                else: parentDir(file)
  var p: Process
  try:
    p = startProcess(cfg.nimonyExe, workingDir = workdir, args = args,
                     options = {poStdErrToStdOut})
  except OSError:
    return CheckResult(output: "", exitCode: 127)
  let code = waitBounded(p, CheckTimeoutMs)
  let buf = try: p.outputStream.readAll() except CatchableError: ""
  p.close()
  if code < 0: return CheckResult(output: "", exitCode: 124)   # hung → killed
  CheckResult(output: buf, exitCode: code)
