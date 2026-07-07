## Server configuration + open-document registry.

import std/[tables, os]
import ./documents
import ../lsp/uris

type
  Config* = object
    nimonyExe*: string        ## path to the `nimony` binary
    extraPaths*: seq[string]  ## extra --path entries
    projectRoot*: string      ## workspace root (filesystem path)

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
  Config(nimonyExe: exe, extraPaths: @[], projectRoot: getCurrentDir())

proc newServerState*(): ServerState =
  ServerState(config: defaultConfig(), docs: initTable[string, Document]())

proc openDoc*(s: ServerState; uri, languageId: string; version: int; text: string) =
  s.docs[uri] = newDocument(uri, languageId, version, text)

proc closeDoc*(s: ServerState; uri: string) =
  s.docs.del(uri)

proc getDoc*(s: ServerState; uri: string): Document =
  s.docs.getOrDefault(uri)

proc filePath*(uri: string): string = uriToPath(uri)
