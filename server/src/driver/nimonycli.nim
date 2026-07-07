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

var
  checkGeneration = 0
  checkCache = initTable[string, CheckResult]()

proc bumpCheckGeneration*() =
  ## Invalidate the check cache. Called on every document lifecycle event.
  inc checkGeneration
  checkCache.clear()

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
  let outp = p.outputStream
  var buf = ""
  buf = outp.readAll()
  let code = p.waitForExit()
  p.close()
  CheckResult(output: buf, exitCode: code)

proc run*(cfg: Config; sub: string; file: string; track: seq[string] = @[]): CheckResult =
  ## Run `nimony <sub> [--path ...] [track...] <file>` from the project root,
  ## memoized for the current generation.
  let key = cacheKey(sub, file, track)
  checkCache.withValue(key, cached):
    return cached[]
  result = runUncached(cfg, sub, file, track)
  # Only cache a real compiler run (not the "binary missing" sentinel), so a
  # transient misconfiguration doesn't poison the whole generation.
  if result.exitCode != 127:
    checkCache[key] = result

proc checkTrack*(cfg: Config; file: string; track: seq[string]): CheckResult =
  run(cfg, "check", file, track)
