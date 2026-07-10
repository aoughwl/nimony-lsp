## textDocument/semanticTokens/full (+ /full/delta) for Nimony.
##
## Reads the module's `.s.nif` artifact (via `nifcache.getArtifact` — the
## shared parsed-buffer memo; NO nimony spawn here, no re-parsing on every
## request), walks the NIF tree and emits an LSP semantic-tokens payload: a
## flat `seq[int]`, 5 ints per token, sorted by (line, startChar) and
## delta-encoded per the LSP spec.
##
## Delta support: we keep the last full token-data array per uri (module-level
## `Table[string, ...]`) tagged with a monotonically increasing `resultId`
## (a plain counter — no wall-clock). `semanticTokensDelta` diffs the new full
## array against the stored one for `previousResultId` and returns a single
## `SemanticTokensEdit` run (common-prefix / common-suffix trim over the raw
## int array — this is exactly what LSP clients expect: they `splice` the edit
## directly into their cached array, so prefix+edit+suffix reconstructing the
## new array byte-for-byte is sufficient; no token-boundary alignment needed).
## If `previousResultId` is stale/unknown, we fall back to a full result.
##
## Coordinate conventions (see ARCHITECTURE.md):
##   - NIF PackedLineInfo: line is 1-based, col is 0-based.
##   - LSP wants line 0-based, col 0-based.  So LSP line = nif.line - 1.
##
## The emitted `tokenType` is an index into `protocol.SemanticTokenTypes`; the
## server advertises that same legend in its capabilities.  Everything is
## wrapped defensively: any failure yields an empty result.

import std/[os, strutils, tables, algorithm, sets]
import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./nifcache

# Nimony NIF libraries (paths added in config.nims).
import bitabs
import nifstreams
import nifcursors
import lineinfos
import symparser

# Named legend indices (computed once at compile time, into the shared legend).
const
  tyFunction  = SemanticTokenTypes.find("function")
  tyMethod    = SemanticTokenTypes.find("method")
  tyType      = SemanticTokenTypes.find("type")
  tyVariable  = SemanticTokenTypes.find("variable")
  tyProperty  = SemanticTokenTypes.find("property")
  tyEnumMember = SemanticTokenTypes.find("enumMember")
  tyParameter = SemanticTokenTypes.find("parameter")

  # Token-modifier bit masks (index into the shared modifier legend).
  modDeclaration = 1 shl SemanticTokenModifiers.find("declaration")
  modReadonly    = 1 shl SemanticTokenModifiers.find("readonly")

proc readonlyTag(tagName: string): bool =
  ## Immutable value declarations. `var`/`gvar`/`tvar` are mutable.
  tagName in ["const", "let", "glet", "tlet", "cursor"]

proc declType(tagName: string): int =
  ## Legend index a declaration tag maps its declared symbol to, or -1 if the
  ## tag is not a declaration we care about.
  case tagName
  of "proc", "func", "converter", "iterator", "macro", "template":
    tyFunction
  of "method":
    tyMethod
  of "type":
    tyType
  of "const", "let", "glet", "tlet", "cursor", "var", "gvar", "tvar":
    tyVariable
  of "fld":
    tyProperty
  of "efld":
    tyEnumMember
  of "param":
    tyParameter
  else:
    -1

# --------------------------------------------------------------------------
# Small helpers (self-contained copies of nifindex's private logic)
# --------------------------------------------------------------------------

proc demangle(sym: string): string =
  ## `add.0.` / `add.0.Mod9` / `x.0.` -> `add` / `x`.
  var isGlobal = false
  result = extractBasename(sym, isGlobal)
  if result.len == 0:
    let sn = splitSymName(sym)
    result = if sn.name.len > 0: sn.name else: sym

proc sameDoc(stored, file: string): bool =
  ## Does a token's recorded source file refer to `file` (this document)?
  let a = stored.replace('\\', '/')
  let b = file.replace('\\', '/')
  result = a == b or a.endsWith("/" & b) or b.endsWith("/" & a) or
           extractFilename(a) == extractFilename(b)

# --------------------------------------------------------------------------
# NIF walking
# --------------------------------------------------------------------------

type
  RawTok = object
    line, col, length, ttype, mods: int

proc buildSymTypes(buf: var TokenBuf; readonly: var HashSet[string]): Table[string, int] =
  ## PASS 1: map each declared symbol (mangled name) to its legend index, and
  ## record which symbols are read-only (declared const/let/...).
  result = initTable[string, int]()
  var n = beginRead(buf)
  var pending = -1               # legend index awaiting the next SymbolDef
  var pendingRo = false          # is the pending decl read-only?
  var left = buf.len             # bound: the cursor has no EofToken sentinel
  while left > 0 and n.kind != EofToken:
    case n.kind
    of ParLe:
      let tn = pool.tags[n.tagId]
      pending = declType(tn)
      pendingRo = readonlyTag(tn)
    of SymbolDef:
      if pending >= 0:
        result[pool.syms[n.symId]] = pending
        if pendingRo: readonly.incl pool.syms[n.symId]
      pending = -1
      pendingRo = false
    else:
      pending = -1
      pendingRo = false
    inc n
    dec left

proc collectTokens(buf: var TokenBuf; file: string;
                   symType: Table[string, int];
                   readonly: HashSet[string]): seq[RawTok] =
  ## PASS 2: emit a raw token for every Symbol / SymbolDef in `file`.
  result = @[]
  var n = beginRead(buf)
  var left = buf.len
  while left > 0 and n.kind != EofToken:
    if n.kind == Symbol or n.kind == SymbolDef:
      let up = unpack(pool.man, n.info)
      if up.file.isValid and up.line > 0:
        let stored = pool.files[up.file]
        if sameDoc(stored, file):
          let sym = pool.syms[n.symId]
          let nm = demangle(sym)
          if nm.len > 0:
            let t = symType.getOrDefault(sym, tyVariable)
            var mods = 0
            if n.kind == SymbolDef: mods = mods or modDeclaration
            if sym in readonly: mods = mods or modReadonly
            result.add RawTok(line: int(up.line) - 1,
                              col: max(0, int(up.col)),
                              length: nm.len, ttype: t, mods: mods)
    inc n
    dec left

proc encode(raws: seq[RawTok]): seq[int] =
  ## Sort by (line, col), dedup identical positions, delta-encode.
  var toks = raws
  toks.sort(proc (a, b: RawTok): int =
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.col, b.col))
  result = @[]
  var prevLine = 0
  var prevCol = 0
  var haveLine = -1
  var haveCol = -1
  for r in toks:
    if r.line == haveLine and r.col == haveCol:
      continue                   # dedup exact (line,col) collisions
    let dl = r.line - prevLine
    let dc = if dl == 0: r.col - prevCol else: r.col
    result.add dl
    result.add dc
    result.add r.length
    result.add r.ttype
    result.add r.mods            # tokenModifiers bitset
    prevLine = r.line
    prevCol = r.col
    haveLine = r.line
    haveCol = r.col

# --------------------------------------------------------------------------
# Per-uri last-full-result memo (for delta requests)
# --------------------------------------------------------------------------

type
  LastResult = object
    resultId: string
    data: seq[int]

  SemTokResult* = object
    ## Sum type returned by `semanticTokensDelta`: either an actual delta
    ## against a known previous result, or a full re-send when the previous
    ## `resultId` is unknown/stale. Both branch types have `%` (to-JSON)
    ## procs in protocol.nim, so the dispatcher just picks one.
    isDelta*: bool
    delta*: SemanticTokensDelta   ## valid when isDelta
    full*: SemanticTokens         ## valid when not isDelta

var
  lastByUri = initTable[string, LastResult]()
  resultCounter = 0

proc nextResultId(): string =
  inc resultCounter
  result = $resultCounter

proc computeFullData(cfg: Config; doc: Document): seq[int] =
  ## The raw (flat, delta-encoded) token array for `doc`, or `@[]` on failure.
  result = @[]
  let file = uriToPath(doc.uri)
  if file.len == 0: return result
  let art = nifcache.getArtifact(cfg, file)
  if art == nil: return result
  var readonly = initHashSet[string]()
  let symType = buildSymTypes(art.buf, readonly)
  let raws = collectTokens(art.buf, file, symType, readonly)
  result = encode(raws)

proc computeEdit(oldData, newData: seq[int]): SemanticTokensEdit =
  ## Single common-prefix/common-suffix edit that reconstructs `newData` when
  ## spliced into `oldData`: `oldData[0..<start] & data & oldData[start+deleteCount..^1] == newData`.
  var p = 0
  let minLen = min(oldData.len, newData.len)
  while p < minLen and oldData[p] == newData[p]: inc p
  var s = 0
  while s < minLen - p and oldData[oldData.len - 1 - s] == newData[newData.len - 1 - s]:
    inc s
  result = SemanticTokensEdit(
    start: p,
    deleteCount: oldData.len - p - s,
    data: newData[p ..< newData.len - s])

# --------------------------------------------------------------------------
# Entry points
# --------------------------------------------------------------------------

proc semanticTokensFull*(cfg: Config; doc: Document): SemanticTokens =
  result = SemanticTokens(resultId: "", data: @[])
  try:
    let data = computeFullData(cfg, doc)
    let rid = nextResultId()
    lastByUri[doc.uri] = LastResult(resultId: rid, data: data)
    result = SemanticTokens(resultId: rid, data: data)
  except CatchableError:
    return SemanticTokens(resultId: "", data: @[])

proc semanticTokensDelta*(cfg: Config; doc: Document;
                          previousResultId: string): SemTokResult =
  ## Delta vs the stored full result for `previousResultId`, or a fresh full
  ## result (wrapped as `isDelta: false`) when that id is unknown/stale.
  try:
    let data = computeFullData(cfg, doc)
    let rid = nextResultId()
    let prev = lastByUri.getOrDefault(doc.uri, LastResult(resultId: "", data: @[]))
    lastByUri[doc.uri] = LastResult(resultId: rid, data: data)
    if previousResultId.len == 0 or prev.resultId.len == 0 or
       prev.resultId != previousResultId:
      return SemTokResult(isDelta: false,
                          full: SemanticTokens(resultId: rid, data: data))
    let edit = computeEdit(prev.data, data)
    var edits: seq[SemanticTokensEdit] = @[]
    if edit.deleteCount != 0 or edit.data.len != 0:
      edits.add edit
    return SemTokResult(isDelta: true,
                        delta: SemanticTokensDelta(resultId: rid, edits: edits))
  except CatchableError:
    return SemTokResult(isDelta: false, full: SemanticTokens(resultId: "", data: @[]))
