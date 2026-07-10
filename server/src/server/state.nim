## Server configuration + open-document registry.

import std/[tables, os, strutils]
import ./documents
import ../lsp/uris

type
  Config* = object
    nimonyExe*: string        ## path to the `nimony` binary
    extraPaths*: seq[string]  ## extra --path entries
    projectRoot*: string      ## workspace root (filesystem path)
    daemonPath*: string       ## path to `nimsem serve` binary; "" = disabled
    cachePrune*: bool         ## bound the nimcache/lsp pool by size (LRU eviction)
    cacheBudgetBytes*: int    ## byte budget before pruning kicks in; <=0 = unbounded

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
  # Warm per-file nimcaches are NEVER deleted on tab close (a reopen would then
  # pay a full cold nimony compile, ~4s). Disk is bounded instead by a size
  # budget: once nimcache/lsp exceeds it, whole per-module caches are evicted
  # least-recently-used first (open documents are never evicted). Default ~1GB;
  # override via NIMONY_CACHE_BUDGET_MB or the cacheBudgetMB/cachePrune init opts.
  var budgetMB = 1000
  let envMB = getEnv("NIMONY_CACHE_BUDGET_MB")
  if envMB.len > 0:
    try: budgetMB = parseInt(envMB) except ValueError: discard
  Config(nimonyExe: exe, extraPaths: @[], projectRoot: getCurrentDir(),
         daemonPath: getEnv("NIMONY_DAEMON"),
         cachePrune: true, cacheBudgetBytes: budgetMB * 1_000_000)

proc newServerState*(): ServerState =
  ServerState(config: defaultConfig(), docs: initTable[string, Document]())

proc openDoc*(s: ServerState; uri, languageId: string; version: int; text: string) =
  s.docs[uri] = newDocument(uri, languageId, version, text)

proc closeDoc*(s: ServerState; uri: string) =
  s.docs.del(uri)

proc getDoc*(s: ServerState; uri: string): Document =
  s.docs.getOrDefault(uri)

proc filePath*(uri: string): string = uriToPath(uri)
