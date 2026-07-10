## textDocument/codeAction: quick-fixes derived from nimony diagnostics, plus
## a `source.organizeImports` action.
##
## Two families of actions:
##
## - "undeclared identifier: X" (see ARCHITECTURE.md diagnostics format,
##   `path(line, col) Error: undeclared identifier: X`) -> search for a module
##   that exports a top-level symbol named X: first the workspace's already
##   -compiled `.s.nif` artifacts (via `nimonycli.allSNif`, matching the
##   embedded export index's demangled name), then nimony's std lib SOURCE
##   tree (plain text scan for `proc X*` / `type X*` / ... — this never
##   spawns the compiler, it only greps files already on disk). Each distinct
##   matching module becomes a CodeAction whose WorkspaceEdit inserts
##   `import <module>` after the file's existing import block (or near the
##   top, if there is none).
## - `source.organizeImports`: sorts + dedupes the contiguous block of
##   top-level `import <...>` lines starting at the first such line.
##
## `codeActions*` is the only public entry point and is defensively wrapped
## end-to-end so any failure yields `@[]` rather than taking the LSP down.

import std/[options, os, strutils, algorithm, sets, tables]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./nimonycli
import ./diagnostics
import ./nifindex

# Nimony NIF libraries (paths added in config.nims) — same pattern as
# nifindex.nim / workspacesym.nim.
import bitabs
import nifstreams
import nifindexes
from nifreader import processDirectives

const
  MaxImportCandidates = 5
    ## Cap on how many "import X" quick-fix alternatives we offer.
  IdChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  DeclKeywords = ["proc", "func", "template", "macro", "type", "const",
                  "iterator", "converter"]

# --------------------------------------------------------------------------
# Range helper
# --------------------------------------------------------------------------

proc overlaps(a, b: Range): bool =
  ## True unless `a` ends strictly before `b` starts or vice versa.
  not (a.`end`.line < b.start.line or
       (a.`end`.line == b.start.line and a.`end`.character < b.start.character) or
       b.`end`.line < a.start.line or
       (b.`end`.line == a.start.line and b.`end`.character < a.start.character))

# --------------------------------------------------------------------------
# "undeclared identifier: X" -> X
# --------------------------------------------------------------------------

proc firstIdentFrom(s: string; start: int): string =
  ## Skip leading quote/backtick/space noise, then read one identifier.
  var i = start
  while i < s.len and s[i] in {'\'', '`', ' ', '\t'}: inc i
  var e = i
  while e < s.len and s[e] in IdChars: inc e
  if e > i: s[i ..< e] else: ""

proc extractUndeclaredName(msg: string): string =
  ## Pulls the missing identifier out of a diagnostic message. Handles the
  ## verified `undeclared identifier: X` form, and best-effort-falls back to
  ## any `declare 'X'`-shaped phrasing other diagnostics might use.
  result = ""
  let lower = msg.toLowerAscii
  let uIdx = lower.find("undeclared identifier")
  if uIdx >= 0:
    let colon = msg.find(':', uIdx)
    if colon >= 0:
      result = firstIdentFrom(msg, colon + 1)
    if result.len > 0: return result
  let dIdx = lower.find("declare")
  if dIdx >= 0:
    let q = msg.find('\'', dIdx)
    if q >= 0:
      result = firstIdentFrom(msg, q)

# --------------------------------------------------------------------------
# Candidate modules that export `name`
# --------------------------------------------------------------------------

proc humanModuleName(storedFile: string): string =
  ## Human module name = the source file's basename without extension
  ## (mirrors workspacesym.moduleContainerName).
  if storedFile.len == 0: return ""
  result = splitFile(storedFile).name
  if result.endsWith(".s"): result = result[0 ..< result.len - 2]

proc collectWorkspaceExporters(cfg: Config; name: string;
                               seen: var HashSet[string]; acc: var seq[string]) =
  try:
    for f in nimonycli.allSNif(cfg):
      if acc.len >= MaxImportCandidates: return
      try:
        let storedFile = nifindex.firstStmtsFile(f)
        if storedFile.len == 0: continue
        var s = nifstreams.open(f)
        var tbl: Table[string, NifIndexEntry]
        try:
          discard processDirectives(s.r)
          tbl = readEmbeddedIndex(s)
        finally:
          nifstreams.close s
        for sym, entry in tbl:
          if entry.vis != Exported: continue
          if nifindex.demangle(sym) != name: continue
          let modName = humanModuleName(storedFile)
          if modName.len == 0 or modName in seen: continue
          seen.incl modName
          acc.add modName
          break
      except CatchableError:
        continue
  except CatchableError:
    discard

proc stdLibDir(cfg: Config): string =
  ## `<nimony-root>/lib/std`, derived from the configured nimony binary
  ## (`.../bin/nimony` -> `.../lib/std`). "" if it can't be found — the
  ## caller then just skips the std-lib scan.
  result = ""
  if cfg.nimonyExe.len == 0: return ""
  let root = parentDir(parentDir(cfg.nimonyExe.absolutePath))
  let cand = root / "lib" / "std"
  if dirExists(cand): result = cand

proc lineDeclaresExported(line: string; name: string): bool =
  let s = line.strip()
  var kw = ""
  for k in DeclKeywords:
    if s.startsWith(k & " ") or s.startsWith(k & "*"):
      kw = k
      break
  if kw.len == 0: return false
  let needle = name & "*"
  let p = s.find(needle, kw.len)
  if p < 0: return false
  if p > 0 and s[p-1] in IdChars: return false
  true

proc collectStdLibExporters(cfg: Config; name: string;
                            seen: var HashSet[string]; acc: var seq[string]) =
  try:
    let dir = stdLibDir(cfg)
    if dir.len == 0: return
    for f in walkFiles(dir / "*.nim"):
      if acc.len >= MaxImportCandidates: return
      let modName = "std/" & splitFile(f).name
      if modName in seen: continue
      var content: string
      try: content = readFile(f)
      except CatchableError: continue
      for line in content.splitLines:
        if lineDeclaresExported(line, name):
          seen.incl modName
          acc.add modName
          break
  except CatchableError:
    discard

proc findExportingModules(cfg: Config; name: string): seq[string] =
  ## Distinct importable module names (e.g. "mymodule", "std/algorithm")
  ## that export a top-level symbol named `name`. Workspace modules first
  ## (exact compiled export), then nimony's std lib source (text scan).
  result = @[]
  var seen = initHashSet[string]()
  collectWorkspaceExporters(cfg, name, seen, result)
  if result.len < MaxImportCandidates:
    collectStdLibExporters(cfg, name, seen, result)

# --------------------------------------------------------------------------
# WorkspaceEdit builders
# --------------------------------------------------------------------------

proc importInsertionEdit(doc: Document; moduleName: string): TextEdit =
  ## Insert `import <moduleName>` right after the last top-level
  ## `import`/`from`/`include` line, or — if there is none — after any
  ## leading blank/`#`-comment lines at the top of the file.
  var lastImportLine = -1
  for i in 0 ..< doc.lineCount:
    let s = doc.lineText(i).strip()
    if s.startsWith("import ") or s == "import" or
       s.startsWith("from ") or s.startsWith("include "):
      lastImportLine = i
  if lastImportLine >= 0:
    return TextEdit(`range`: mkRange(lastImportLine + 1, 0, lastImportLine + 1, 0),
                    newText: "import " & moduleName & "\n")
  var insertAt = 0
  for i in 0 ..< doc.lineCount:
    let s = doc.lineText(i).strip()
    if s.len == 0 or s.startsWith("#"):
      insertAt = i + 1
    else:
      break
  TextEdit(`range`: mkRange(insertAt, 0, insertAt, 0),
          newText: "import " & moduleName & "\n\n")

proc importFixActions(cfg: Config; doc: Document; d: Diagnostic): seq[CodeAction] =
  result = @[]
  let name = extractUndeclaredName(d.message)
  if name.len == 0: return result
  let mods = findExportingModules(cfg, name)
  for m in mods:
    let edit = importInsertionEdit(doc, m)
    result.add CodeAction(
      title: "Import '" & m & "' (declares '" & name & "')",
      kind: "quickfix",
      diagnostics: @[d],
      edit: WorkspaceEdit(changes: @[(doc.uri, @[edit])]),
      isPreferred: result.len == 0)

# --------------------------------------------------------------------------
# source.organizeImports
# --------------------------------------------------------------------------

proc organizeImportsAction(doc: Document): Option[CodeAction] =
  ## Sorts (case-insensitively) and dedupes the contiguous run of top-level
  ## (non-indented) `import ...` lines starting at the first one found. Lines
  ## are treated as opaque units (not split on `,`) so `from X import Y` /
  ## `import a except b` style lines are reordered safely without altering
  ## their meaning.
  try:
    var startLine = -1
    var endLine = -1
    for i in 0 ..< doc.lineCount:
      let raw = doc.lineText(i)
      let s = raw.strip()
      let indented = raw.len > 0 and raw[0] in {' ', '\t'}
      if not indented and (s.startsWith("import ") or s == "import"):
        if startLine < 0: startLine = i
        endLine = i
      elif startLine >= 0:
        break
    if startLine < 0: return none(CodeAction)
    var lines: seq[string] = @[]
    for i in startLine .. endLine: lines.add doc.lineText(i)
    var uniq: seq[string] = @[]
    var seen = initHashSet[string]()
    for ln in lines:
      let key = ln.strip()
      if key notin seen:
        seen.incl key
        uniq.add ln
    uniq.sort(proc(a, b: string): int = cmpIgnoreCase(a.strip(), b.strip()))
    let newText = uniq.join("\n") & "\n"
    let edit = TextEdit(`range`: mkRange(startLine, 0, endLine + 1, 0), newText: newText)
    some CodeAction(title: "Organize imports", kind: "source.organizeImports",
                    diagnostics: @[],
                    edit: WorkspaceEdit(changes: @[(doc.uri, @[edit])]),
                    isPreferred: false)
  except CatchableError:
    none(CodeAction)

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

proc codeActions*(cfg: Config; doc: Document; rng: Range;
                  diags: seq[Diagnostic]): seq[CodeAction] =
  result = @[]
  try:
    let file = uriToPath(doc.uri)
    var relevant = diags
    if relevant.len == 0:
      try:
        let byFile = diagnostics.computeDiagnostics(cfg, file)
        let norm = normalizedPath(file)
        for path, ds in byFile:
          if normalizedPath(path) == norm:
            relevant = ds
            break
      except CatchableError:
        relevant = @[]
    for d in relevant:
      if not overlaps(d.`range`, rng): continue
      try:
        result.add importFixActions(cfg, doc, d)
      except CatchableError:
        discard
    try:
      let oi = organizeImportsAction(doc)
      if oi.isSome: result.add oi.get
    except CatchableError:
      discard
  except CatchableError:
    return @[]
