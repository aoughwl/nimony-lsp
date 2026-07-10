## Runs the `nimony` binary and captures its output.
##
## A generation-based cache coalesces the many redundant `nimony check`
## invocations a single editor request triggers (e.g. completion runs a check,
## then documentSymbols runs a check, then imported-index reads run a check).
## Within one generation the same (sub, file, track) invocation runs the
## compiler once; any document lifecycle change bumps the generation and clears
## the cache, so results never go stale relative to what the drivers can see.

import std/[osproc, os, strutils, streams, tables]
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

proc buildArgs(cfg: Config; sub: string; file: string; track: seq[string]): seq[string] =
  result = @[sub]
  for p in cfg.extraPaths:
    result.add("--path:" & p)
  for t in track:
    result.add(t)
  result.add(file)

proc runUncached(cfg: Config; sub: string; file: string; track: seq[string]): CheckResult =
  if cfg.nimonyExe.len == 0 or not fileExists(cfg.nimonyExe):
    return CheckResult(output: "", exitCode: 127)
  let args = buildArgs(cfg, sub, file, track)
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
  let cf = canonFile(cfg, file)
  let key = cacheKey(sub, cf, track)
  checkCache.withValue(key, cached):
    return cached[]
  result = runUncached(cfg, sub, cf, track)
  # Only cache a real compiler run (not the "binary missing" sentinel), so a
  # transient misconfiguration doesn't poison the whole generation.
  if result.exitCode != 127:
    checkCache[key] = result

proc checkTrack*(cfg: Config; file: string; track: seq[string]): CheckResult =
  run(cfg, "check", file, track)

proc runLiveCheck*(cfg: Config; file, nimcache: string): CheckResult =
  ## Check `file` into a DEDICATED nimcache (for live/as-you-type diagnostics on
  ## a temp buffer). Isolating the cache is what keeps this incremental & fast
  ## (~10ms) — sharing the main nimcache makes every temp check a cold rebuild.
  ## Uncached (never touches the generation cache) and never cross-contended.
  if cfg.nimonyExe.len == 0 or not fileExists(cfg.nimonyExe):
    return CheckResult(output: "", exitCode: 127)
  var args = @["check", "--nimcache:" & nimcache]
  for p in cfg.extraPaths: args.add("--path:" & p)
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
