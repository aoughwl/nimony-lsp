## Server configuration + open-document registry.

import std/[tables, os]
import ./documents
import ../lsp/uris

type
  Config* = object
    nimonyExe*: string        ## path to the `nimony` binary
    extraPaths*: seq[string]  ## extra --path entries
    projectRoot*: string      ## workspace root (filesystem path)
    daemonPath*: string       ## path to `nimsem serve` binary; "" = disabled

  ServerState* = ref object
    config*: Config
    docs*: Table[string, Document]   ## keyed by URI
    rootUri*: string
    initialized*: bool
    shutdownRequested*: bool

proc defaultConfig*(): Config =
  # Sensible defaults; overridden by client initializationOptions / CLI flags.
  var exe = getEnv("NIMONY_EXE")
  if exe.len == 0:
    exe = "/home/savant/nimony/bin/nimony"
  # Opt-in warm-daemon backend for navigation (exact cross-module overload
  # resolution, no per-query `nimony check`). OFF by default — the proven
  # idetools path stays the default — and enabled only when `NIMONY_DAEMON`
  # (or the `daemonPath` init option / client setting) points at a
  # `nimsem serve` binary. Navigation falls back to idetools on any miss.
  Config(nimonyExe: exe, extraPaths: @[], projectRoot: getCurrentDir(),
         daemonPath: getEnv("NIMONY_DAEMON"))

proc newServerState*(): ServerState =
  ServerState(config: defaultConfig(), docs: initTable[string, Document]())

proc openDoc*(s: ServerState; uri, languageId: string; version: int; text: string) =
  s.docs[uri] = newDocument(uri, languageId, version, text)

proc closeDoc*(s: ServerState; uri: string) =
  s.docs.del(uri)

proc getDoc*(s: ServerState; uri: string): Document =
  s.docs.getOrDefault(uri)

proc filePath*(uri: string): string = uriToPath(uri)
