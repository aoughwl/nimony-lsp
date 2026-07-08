## textDocument/documentLink: clickable links from `import` / `from ... import`
## / `include` module references to the resolved source file.

import std/[os, strutils]
import ../server/documents
import ../server/state
import ../lsp/protocol
import ../lsp/uris

const
  IdentChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  RefChars = IdentChars + {'/', '.'}

proc skipWs(line: string; i: int): int =
  result = i
  while result < line.len and line[result] in {' ', '\t'}: inc result

proc scanWord(line: string; i: int): tuple[tok: string, s, e: int] =
  ## Plain identifier word (used to detect leading keywords).
  let s = skipWs(line, i)
  var e = s
  while e < line.len and line[e] in IdentChars: inc e
  result = (line[s ..< e], s, e)

proc scanRef(line: string; i: int): tuple[tok: string, s, e: int] =
  ## A module reference token: either a quoted string or a bare path-ish
  ## token of identifier chars plus '/' and '.'. Returns the range covering
  ## just the reference text (quotes excluded).
  let start = skipWs(line, i)
  if start >= line.len:
    return ("", start, start)
  if line[start] == '"':
    var e = start + 1
    while e < line.len and line[e] != '"': inc e
    result = (line[start + 1 ..< e], start + 1, e)
  else:
    var e = start
    while e < line.len and line[e] in RefChars: inc e
    result = (line[start ..< e], start, e)

proc resolveModule(cfg: Config; curDir: string; modRef: string): string =
  ## Returns an absolute file path if the module resolves to an existing
  ## file, else "".
  if modRef.len == 0:
    return ""
  if modRef.startsWith("std/"):
    return ""  # Nimony stdlib modules: skip (not reliably locatable here).
  let relPath = if modRef.endsWith(".nim"): modRef else: modRef & ".nim"

  var candidates: seq[string] = @[]
  candidates.add(curDir / relPath)
  if cfg.projectRoot.len > 0:
    candidates.add(cfg.projectRoot / relPath)
  for p in cfg.extraPaths:
    candidates.add(p / relPath)

  for c in candidates:
    let ac = try: absolutePath(c) except ValueError: c
    if fileExists(ac):
      return ac
  return ""

proc addLinksForEntries(result: var seq[DocumentLink]; cfg: Config; curDir: string;
                         line: string; lineNo: int; startIdx: int) =
  ## Parses a comma-separated list of module refs starting at `startIdx`
  ## (used for `import a, b, c` and `include a, b`), stopping at a comment
  ## or end of line.
  var i = startIdx
  while i < line.len:
    i = skipWs(line, i)
    if i >= line.len or line[i] == '#':
      break
    let (tok, s, e) = scanRef(line, i)
    if tok.len == 0:
      break
    let resolved = resolveModule(cfg, curDir, tok)
    if resolved.len > 0:
      result.add DocumentLink(
        `range`: mkRange(lineNo, s, lineNo, e),
        target: pathToUri(resolved),
        tooltip: resolved)
    # advance past the token, then skip an optional "as <name>" / "except ..."
    # qualifier up to the next top-level comma.
    i = e
    while i < line.len and line[i] notin {',', '#'}:
      inc i
    if i < line.len and line[i] == ',':
      inc i
    else:
      break

proc documentLinks*(cfg: Config; doc: Document): seq[DocumentLink] =
  result = @[]
  try:
    let curDir = parentDir(uriToPath(doc.uri))
    for lineNo in 0 ..< doc.lineCount():
      let line = doc.lineText(lineNo)
      let (word, wS, wE) = scanWord(line, 0)
      if word == "import":
        addLinksForEntries(result, cfg, curDir, line, lineNo, wE)
      elif word == "include":
        addLinksForEntries(result, cfg, curDir, line, lineNo, wE)
      elif word == "from":
        let (modTok, modS, modE) = scanRef(line, wE)
        if modTok.len == 0: continue
        # confirm an `import` keyword follows (allow anything up to it).
        let afterMod = skipWs(line, modE)
        let (kw, _, kwE) = scanWord(line, afterMod)
        if kw != "import": continue
        let resolved = resolveModule(cfg, curDir, modTok)
        if resolved.len > 0:
          result.add DocumentLink(
            `range`: mkRange(lineNo, modS, lineNo, modE),
            target: pathToUri(resolved),
            tooltip: resolved)
        # `from a import x, y` — x/y are symbols, not modules; nothing more
        # to link on this line.
  except CatchableError:
    result = @[]
