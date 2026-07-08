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

proc toLocation(cfg: Config; r: Record): Location =
  let l = max(0, r.line - 1)   # 1-based -> 0-based line
  let c = max(0, r.col)        # already 0-based
  Location(uri: pathToUri(absPath(cfg, r.file)),
           `range`: mkRange(l, c, l, c))

proc relOf(cfg: Config; file: string): string =
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    relativePath(file, cfg.projectRoot)
  else:
    file

proc collectRecords(cfg: Config; output: string; want: string;
                    seen: var HashSet[string]; acc: var seq[Location]) =
  ## Parse idetools output; `want` = "" (any) / "def" / "use".
  for line in output.splitLines:
    let rec = parseRecord(line)
    if rec.isSome:
      let r = rec.get
      if want.len > 0 and r.kind != want: continue
      let loc = toLocation(cfg, r)
      let key = loc.uri & "#" & $loc.`range`.start.line & ":" & $loc.`range`.start.character
      if not seen.containsOrIncl(key):
        acc.add(loc)

proc query(cfg: Config; flag, file: string; pos: Position): seq[Location] =
  ## flag is "--def" or "--usages". Request col is 1-based.
  ## The track file path must match nimony's internal file id, which is stored
  ## relative to the working directory (project root) — absolute paths fail.
  let relFile = relOf(cfg, file)
  let track = flag & ":" & relFile & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  let r = nimonycli.checkTrack(cfg, relFile, @[track])
  result = @[]
  var seen = initHashSet[string]()
  collectRecords(cfg, r.output, "", seen, result)

proc definition*(cfg: Config; file: string; pos: Position): seq[Location] =
  query(cfg, "--def", file, pos)

proc references*(cfg: Config; file: string; pos: Position;
                extraRoots: seq[string] = @[]): seq[Location] =
  ## Find usages of the symbol under `pos`. idetools only reports occurrences
  ## inside the translation unit rooted at the *checked* file, so a usage that
  ## lives in another module is invisible unless that module is compiled. We
  ## therefore run the same `--usages` query against every candidate root
  ## (`file` itself plus `extraRoots` — typically the open documents) and union
  ## the results, so cross-file references are found. The declaration site is
  ## included via a `--def` pass.
  let relTarget = relOf(cfg, file)
  let track = "--usages:" & relTarget & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  result = @[]
  var seen = initHashSet[string]()

  var roots: seq[string] = @[relTarget]
  for e in extraRoots:
    let r = relOf(cfg, e)
    if r notin roots: roots.add(r)

  for root in roots:
    let res = nimonycli.checkTrack(cfg, root, @[track])
    collectRecords(cfg, res.output, "use", seen, result)

  # Include the declaration itself (idetools --usages omits it).
  let defTrack = "--def:" & relTarget & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  let dres = nimonycli.checkTrack(cfg, relTarget, @[defTrack])
  collectRecords(cfg, dres.output, "def", seen, result)
