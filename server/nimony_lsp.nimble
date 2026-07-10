version       = "0.7.1"
author        = "nimony-lsp"
description    = "Language Server Protocol implementation for Nimony"
license       = "MIT"
srcDir        = "src"
bin           = @["nimony_lsp"]
binDir        = "bin"

requires "nim >= 2.0.0"

import std/os

after build:
  # The VS Code extension (client/src/extension.ts) launches `bin/nimony-lsp`
  # (dash), but Nim/nimble derives the binary name from the source module
  # `nimony_lsp.nim` (underscore). Keep the dash-named binary the extension
  # expects in sync with every build so a rebuilt server is actually the one
  # that runs — otherwise VS Code silently keeps launching a stale binary.
  let src = binDir / "nimony_lsp"
  let dst = binDir / "nimony-lsp"
  if fileExists(src):
    # Rebuild while VS Code is running: the dst binary is being executed, so a
    # plain cpFile (open+write) fails with ETXTBSY ("Text file busy"). Write a
    # temp and atomically rename over it — rename replaces the directory entry
    # while the running server keeps its old inode, so this always succeeds.
    let tmp = dst & ".new"
    cpFile(src, tmp)
    when defined(posix): exec "chmod +x " & tmp   # cpFile drops the +x bit
    mvFile(tmp, dst)
