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

proc query(cfg: Config; flag, file: string; pos: Position): seq[Location] =
  ## flag is "--def" or "--usages". Request col is 1-based.
  ## The track file path must match nimony's internal file id, which is stored
  ## relative to the working directory (project root) — absolute paths fail.
  var relFile = file
  if cfg.projectRoot.len > 0 and file.isAbsolute:
    relFile = relativePath(file, cfg.projectRoot)
  let track = flag & ":" & relFile & "," & $(pos.line + 1) & "," & $(pos.character + 1)
  let r = nimonycli.checkTrack(cfg, relFile, @[track])
  result = @[]
  var seen = initHashSet[string]()
  for line in r.output.splitLines:
    let rec = parseRecord(line)
    if rec.isSome:
      let loc = toLocation(cfg, rec.get)
      # idetools can emit duplicate records for the same span; dedup them.
      let key = loc.uri & "#" & $loc.`range`.start.line & ":" & $loc.`range`.start.character
      if not seen.containsOrIncl(key):
        result.add(loc)

proc definition*(cfg: Config; file: string; pos: Position): seq[Location] =
  query(cfg, "--def", file, pos)

proc references*(cfg: Config; file: string; pos: Position): seq[Location] =
  query(cfg, "--usages", file, pos)
