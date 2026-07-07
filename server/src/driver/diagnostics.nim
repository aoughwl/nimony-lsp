## Parse `nimony check` output into LSP diagnostics.
##
## Line format (line/col both 1-based, col points at a UTF-8 byte/codepoint):
##   path(line, col) Error: message
##   path(line, col) Trace: message        <- related info for the preceding Error
##   path(line, col) Warning: message
## The trailing `FAILURE: ...` build-summary line is ignored.

import std/[tables, strutils, os, options]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ./nimonycli

type ParsedLine = object
  path: string
  line, col: int
  kind: string
  message: string

proc parseLine(s: string): Option[ParsedLine] =
  # find "(l, c)" — the first '(' after a path, matched with its ')'
  let lp = s.find('(')
  if lp <= 0: return none(ParsedLine)
  let rp = s.find(')', lp)
  if rp < 0: return none(ParsedLine)
  let inside = s[lp+1 ..< rp]
  let comma = inside.find(',')
  if comma < 0: return none(ParsedLine)
  var line, col: int
  try:
    line = parseInt(inside[0 ..< comma].strip)
    col = parseInt(inside[comma+1 .. ^1].strip)
  except ValueError:
    return none(ParsedLine)
  # after ')': " Kind: message"
  var rest = s[rp+1 .. ^1].strip
  let colon = rest.find(':')
  if colon < 0: return none(ParsedLine)
  let kind = rest[0 ..< colon].strip
  if kind notin ["Error", "Warning", "Trace", "Hint", "Info"]:
    return none(ParsedLine)
  let message = rest[colon+1 .. ^1].strip
  some(ParsedLine(path: s[0 ..< lp].strip, line: line, col: col,
                  kind: kind, message: message))

proc severityOf(kind: string): DiagnosticSeverity =
  case kind
  of "Error": dsError
  of "Warning": dsWarning
  of "Hint": dsHint
  else: dsInformation

proc absPath(cfg: Config; p: string): string =
  if isAbsolute(p): return p
  let root = if cfg.projectRoot.len > 0: cfg.projectRoot else: getCurrentDir()
  result = normalizedPath(root / p)

proc toRange(line, col: int): Range =
  # nimony is 1-based line & col; LSP is 0-based. Highlight one char.
  let l = max(0, line - 1)
  let c = max(0, col - 1)
  mkRange(l, c, l, c + 1)

proc parseOutput*(cfg: Config; raw: string): Table[string, seq[Diagnostic]] =
  ## Returns diagnostics keyed by absolute file path.
  result = initTable[string, seq[Diagnostic]]()
  var lastKey = ""
  var lastIdx = -1
  for rawLine in raw.splitLines:
    let line = rawLine.strip(leading = false)
    if line.len == 0: continue
    if line.startsWith("FAILURE:") or line.startsWith("SUCCESS:"): continue
    let pl = parseLine(line)
    if pl.isNone: continue
    let p = pl.get
    let key = absPath(cfg, p.path)
    if p.kind == "Trace" and lastKey.len > 0 and lastIdx >= 0:
      # attach as related information to the previous diagnostic
      result[lastKey][lastIdx].relatedInformation.add(
        DiagnosticRelatedInformation(
          location: Location(uri: pathToUri(key), `range`: toRange(p.line, p.col)),
          message: p.message))
      continue
    var d = Diagnostic(`range`: toRange(p.line, p.col),
                       severity: severityOf(p.kind),
                       source: "nimony",
                       message: p.message)
    if not result.hasKey(key): result[key] = @[]
    result[key].add(d)
    lastKey = key
    lastIdx = result[key].len - 1

proc computeDiagnostics*(cfg: Config; file: string): Table[string, seq[Diagnostic]] =
  ## Run the checker and parse. `file` is an absolute path.
  let r = nimonycli.run(cfg, "check", file)
  parseOutput(cfg, r.output)
