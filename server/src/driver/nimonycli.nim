## Runs the `nimony` binary and captures its output.

import std/[osproc, os, strutils, streams]
import ../server/state

type
  CheckResult* = object
    output*: string    ## merged stdout+stderr
    exitCode*: int

proc buildArgs(cfg: Config; sub: string; file: string; track: seq[string]): seq[string] =
  result = @[sub]
  for p in cfg.extraPaths:
    result.add("--path:" & p)
  for t in track:
    result.add(t)
  result.add(file)

proc run*(cfg: Config; sub: string; file: string; track: seq[string] = @[]): CheckResult =
  ## Run `nimony <sub> [--path ...] [track...] <file>` from the project root.
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

proc checkTrack*(cfg: Config; file: string; track: seq[string]): CheckResult =
  run(cfg, "check", file, track)
