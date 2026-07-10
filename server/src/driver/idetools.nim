## Goto-definition / find-references via `nimony check --def/--usages`.
##
## Output record (tab-separated):
##   def|use \t <symkind> \t <mangled-sym> \t <sig> \t <container> \t <file> \t <line> \t <col>
## line is 1-based, col is 0-based.  The `--def:/--usages:` request col is 1-based.

import std/[strutils, os, options, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ./nimonycli

type Record = object
  kind: string    ## "def" or "use"
  sym: string
  file: string
  line, col: int

type LiveCtx* = object
  ## When active, navigation runs against the UNSAVED buffer materialized to a
  ## sibling temp file (the same one live diagnostics use). The temp is a
  ## byte-for-byte copy of the buffer, so cursor coordinates need no remapping —
  ## only the file path is swapped temp→real on the way out.
  active*: bool
  realAbs*: string     ## absolute real source file (normalized)
  tempAbs*: string     ## absolute temp buffer file (normalized)
  tempRel*: string     ## temp path as nimony sees it (relative to projectRoot)
  nimcache*: string    ## isolated live nimcache dir (.nimlsp_livecache)

proc parseRecord(line: string): Option[Record] =
  if not (line.startsWith("def\t") or line.startsWith("use\t")):
    return none(Record)
  let parts = line.split('\t')
  # kind, symkind, sym, sig, container, file, line, col  (>= 8 fields)
  if parts.len < 8: return none(Record)
  var r: Record
  r.kind = parts[0]
  r.sym = parts[2]
  r.file = parts[^3]
  try:
    r.line = parseInt(parts[^2].strip)
    r.col = parseInt(parts[^1].strip)
  except ValueError:
    return none(Record)
  some(r)

proc absPath(cfg: Config; p: string): string =
  if isAbsolute(p): p
  else: normalizedPath((if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()) / p)

proc toLocation(cfg: Config; r: Record; live: LiveCtx): Location =
  let l = max(0, r.line - 1)   # 1-based -> 0-based line
  let c = max(0, r.col)        # already 0-based
  var abs = normalizedPath(absPath(cfg, r.file))
  if live.active and abs == live.tempAbs:
    abs = live.realAbs         # path-only swap; line/col are buffer-correct
  Location(uri: pathToUri(abs), `range`: mkRange(l, c, l, c))

proc relOf(cfg: Config; file: string): string =
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    relativePath(file, cfg.projectRoot)
  else:
    file

proc collectRecords(cfg: Config; output: string; want: string;
                    seen: var HashSet[string]; acc: var seq[Location];
                    live: LiveCtx = LiveCtx(); dropAbs = "") =
  ## Parse idetools output; `want` = "" (any) / "def" / "use". `dropAbs`, when
  ## set, suppresses records landing in that absolute file (used so a disk
  ## cross-file pass doesn't double-report in-file usages the live pass owns).
  for line in output.splitLines:
    let rec = parseRecord(line)
    if rec.isSome:
      let r = rec.get
      if want.len > 0 and r.kind != want: continue
      let loc = toLocation(cfg, r, live)
      if dropAbs.len > 0 and normalizedPath(uriToPath(loc.uri)) == dropAbs: continue
      let key = loc.uri & "#" & $loc.`range`.start.line & ":" & $loc.`range`.start.character
      if not seen.containsOrIncl(key):
        acc.add(loc)

proc query(cfg: Config; flag, file: string; pos: Position;
           live: LiveCtx = LiveCtx()): seq[Location] =
  ## flag is "--def" or "--usages". Request col is 1-based.
  ## The track file path must match nimony's internal file id, which is stored
  ## relative to the working directory (project root) — absolute paths fail.
  ## When `live.active`, run against the unsaved-buffer temp file into the
  ## isolated live cache instead of the on-disk file.
  let reqFile = if live.active: live.tempRel else: relOf(cfg, file)
  let track = flag & ":" & reqFile & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  let r = if live.active: nimonycli.runLiveCheck(cfg, reqFile, live.nimcache, @[track])
          else: nimonycli.checkTrack(cfg, reqFile, @[track])
  result = @[]
  var seen = initHashSet[string]()
  collectRecords(cfg, r.output, "", seen, result, live)

proc definition*(cfg: Config; file: string; pos: Position;
                 live: LiveCtx = LiveCtx()): seq[Location] =
  query(cfg, "--def", file, pos, live)

proc references*(cfg: Config; file: string; pos: Position;
                extraRoots: seq[string] = @[]; live: LiveCtx = LiveCtx()): seq[Location] =
  ## Find usages of the symbol under `pos`. idetools only reports occurrences
  ## inside the translation unit rooted at the *checked* file, so a usage that
  ## lives in another module is invisible unless that module is compiled. We
  ## therefore run the same `--usages` query against every candidate root
  ## (`file` itself plus `extraRoots` — typically the open documents) and union
  ## the results, so cross-file references are found. The declaration site is
  ## included via a `--def` pass.
  let diskTarget = relOf(cfg, file)
  let liveTarget = if live.active: live.tempRel else: diskTarget
  result = @[]
  var seen = initHashSet[string]()

  # (1) Usages inside the target module — LIVE when dirty, else disk.
  block:
    let track = "--usages:" & liveTarget & "," & $(pos.line + 1) & "," & $(pos.character + 1)
    let res = if live.active: nimonycli.runLiveCheck(cfg, liveTarget, live.nimcache, @[track])
              else: nimonycli.checkTrack(cfg, liveTarget, @[track])
    collectRecords(cfg, res.output, "use", seen, result, live)

  # (2) Cross-file usages — always disk-based (the extra roots import the REAL
  #     module, not the temp, so the temp coordinate can't resolve there). Drop
  #     any record in the target file: pass (1) owns those authoritatively.
  let diskTrack = "--usages:" & diskTarget & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  for e in extraRoots:
    let root = relOf(cfg, e)
    if root == diskTarget: continue
    let res = nimonycli.checkTrack(cfg, root, @[diskTrack])
    collectRecords(cfg, res.output, "use", seen, result, live,
                   dropAbs = (if live.active: live.realAbs else: ""))

  # (3) Declaration site — LIVE when dirty (idetools --usages omits it).
  let defTrack = "--def:" & liveTarget & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  let dres = if live.active: nimonycli.runLiveCheck(cfg, liveTarget, live.nimcache, @[defTrack])
             else: nimonycli.checkTrack(cfg, liveTarget, @[defTrack])
  collectRecords(cfg, dres.output, "def", seen, result, live)
