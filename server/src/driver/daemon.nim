## Client for the persistent `nimsem serve` warm worker (JSONL over stdio).
##
## Routes navigation (definition / references / workspace symbols) to the warm
## daemon, which resolves against the whole-program interned graph — exact,
## per-overload, and without re-running a whole `nimony check` per query.
##
## Every entry point returns an `Option`: `none` means "daemon unavailable or
## the request failed" and the caller MUST fall back to the idetools path.
## `some(@[])` means "the daemon answered, with no results".

import std/[osproc, os, streams, json, options, strutils, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state

const ProtocolVersion = 0

type Daemon = ref object
  p: Process
  inp, outp: Stream

var gDaemon: Daemon = nil
var gReqId = 0

proc stop() =
  if gDaemon != nil:
    try: gDaemon.p.terminate() except CatchableError: discard
    try: gDaemon.p.close() except CatchableError: discard
    gDaemon = nil

proc ensureUp(cfg: Config): Daemon =
  if cfg.daemonPath.len == 0 or not fileExists(cfg.daemonPath): return nil
  if gDaemon != nil: return gDaemon
  try:
    let p = startProcess(cfg.daemonPath, args = @["serve"], options = {})
    gDaemon = Daemon(p: p, inp: p.inputStream, outp: p.outputStream)
    return gDaemon
  except CatchableError:
    return nil

proc roundtrip(cfg: Config; req: JsonNode): JsonNode =
  ## Send one request, read one reply line. Restart once on a dead worker.
  for attempt in 0 .. 1:
    let d = ensureUp(cfg)
    if d == nil: return nil
    try:
      d.inp.writeLine($req)
      d.inp.flush()
      let line = d.outp.readLine()
      if line.len == 0:
        stop()
        continue                 # worker died mid-flight; retry once
      return parseJson(line)
    except CatchableError:
      stop()
      continue
  return nil

# --------------------------------------------------------------------------
# request/param helpers
# --------------------------------------------------------------------------

proc relFileFor(cfg: Config; file: string): string =
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    result = relativePath(file, cfg.projectRoot, '/')
  else:
    result = file

proc nimcacheDir(cfg: Config): string =
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()
  result = root / "nimcache"

proc absOf(cfg: Config; file: string): string =
  if file.isAbsolute: normalizedPath(file)
  elif cfg.projectRoot.len > 0: normalizedPath(cfg.projectRoot / file)
  else: file

proc posQuery(cfg: Config; verb, file: string; pos: Position): JsonNode =
  ## Build a position-based query envelope (defs / usages). idetools convention:
  ## request line & col are 1-based; the LSP Position is 0-based.
  inc gReqId
  result = %*{
    "v": ProtocolVersion, "id": gReqId, "verb": verb,
    "file": relFileFor(cfg, file),
    "line": pos.line + 1, "col": pos.character + 1,
    "nimcache": nimcacheDir(cfg),
    "paths": %[if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()]
  }

proc locationsFromReply(cfg: Config; reply: JsonNode; wantRole: string): seq[Location] =
  ## Parse the symbol-keyed reply into LSP Locations. Daemon line is 1-based,
  ## col is 0-based (idetools convention) → LSP line = line-1, char = col.
  result = @[]
  if reply == nil or not reply{"ok"}.getBool(false): return
  let syms = reply{"symbols"}
  if syms == nil or syms.kind != JObject: return
  var seen = initHashSet[string]()
  for _, entry in syms:
    let locs = entry{"locations"}
    if locs == nil or locs.kind != JArray: continue
    for loc in locs:
      if wantRole.len > 0 and loc{"role"}.getStr("") != wantRole and
         not (wantRole == "any"): continue
      let f = loc{"file"}.getStr("")
      if f.len == 0: continue
      let l = max(0, loc{"line"}.getInt(1) - 1)
      let c = max(0, loc{"col"}.getInt(0))
      let uri = pathToUri(absOf(cfg, f))
      let key = uri & "#" & $l & ":" & $c
      if seen.containsOrIncl(key): continue
      result.add Location(uri: uri, `range`: mkRange(l, c, l, c))

# --------------------------------------------------------------------------
# public API (Option: none => fall back to idetools)
# --------------------------------------------------------------------------

proc available*(cfg: Config): bool =
  cfg.daemonPath.len > 0 and fileExists(cfg.daemonPath)

proc definition*(cfg: Config; file: string; pos: Position): Option[seq[Location]] =
  if not available(cfg): return none(seq[Location])
  let reply = roundtrip(cfg, posQuery(cfg, "defs", file, pos))
  if reply == nil or not reply{"ok"}.getBool(false): return none(seq[Location])
  some(locationsFromReply(cfg, reply, "def"))

proc references*(cfg: Config; file: string; pos: Position): Option[seq[Location]] =
  if not available(cfg): return none(seq[Location])
  let reply = roundtrip(cfg, posQuery(cfg, "usages", file, pos))
  if reply == nil or not reply{"ok"}.getBool(false): return none(seq[Location])
  # references want every occurrence (def + uses)
  some(locationsFromReply(cfg, reply, "any"))

proc workspaceSymbols*(cfg: Config; query: string): Option[seq[SymbolInformation]] =
  if not available(cfg): return none(seq[SymbolInformation])
  inc gReqId
  let req = %*{"v": ProtocolVersion, "id": gReqId, "verb": "symbols",
               "query": query, "nimcache": nimcacheDir(cfg),
               "paths": %[if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()]}
  let reply = roundtrip(cfg, req)
  if reply == nil or not reply{"ok"}.getBool(false): return none(seq[SymbolInformation])
  var items: seq[SymbolInformation] = @[]
  let syms = reply{"symbols"}
  if syms != nil and syms.kind == JObject:
    for symId, entry in syms:
      var name = symId
      let dot = name.find('.')
      if dot > 0: name = name[0 ..< dot]     # demangle: strip the .N.module suffix
      let locs = entry{"locations"}
      if locs == nil or locs.kind != JArray or locs.len == 0: continue
      let loc = locs[0]
      let f = loc{"file"}.getStr("")
      if f.len == 0: continue
      let l = max(0, loc{"line"}.getInt(1) - 1)
      let c = max(0, loc{"col"}.getInt(0))
      items.add SymbolInformation(name: name, kind: skFunction,
        location: Location(uri: pathToUri(absOf(cfg, f)),
                           `range`: mkRange(l, c, l, c + name.len)),
        containerName: "")
  some(items)

proc shutdown*() =
  ## Best-effort clean stop (called at server exit).
  if gDaemon != nil:
    try:
      inc gReqId
      gDaemon.inp.writeLine($(%*{"v": ProtocolVersion, "id": gReqId, "verb": "shutdown"}))
      gDaemon.inp.flush()
    except CatchableError: discard
    stop()
