## LSP wire types (0-based lines, 0-based UTF-16 columns) and JSON helpers.
##
## Outgoing types provide a `%` (to-JSON) proc. Incoming params are read from
## JsonNode with the small accessor helpers at the bottom.

import std/[json, options]

type
  Position* = object
    line*: int        ## 0-based
    character*: int   ## 0-based, UTF-16 code units

  Range* = object
    start*: Position
    `end`*: Position

  Location* = object
    uri*: string
    `range`*: Range

  DiagnosticSeverity* = enum
    dsError = 1, dsWarning = 2, dsInformation = 3, dsHint = 4

  DiagnosticRelatedInformation* = object
    location*: Location
    message*: string

  Diagnostic* = object
    `range`*: Range
    severity*: DiagnosticSeverity
    source*: string
    message*: string
    relatedInformation*: seq[DiagnosticRelatedInformation]

  MarkupContent* = object
    kind*: string     ## "plaintext" | "markdown"
    value*: string

  Hover* = object
    contents*: MarkupContent
    `range`*: Option[Range]

  SymbolKind* = enum
    skFile = 1, skModule = 2, skNamespace = 3, skPackage = 4, skClass = 5,
    skMethod = 6, skProperty = 7, skField = 8, skConstructor = 9, skEnum = 10,
    skInterface = 11, skFunction = 12, skVariable = 13, skConstant = 14,
    skString = 15, skNumber = 16, skBoolean = 17, skArray = 18, skObject = 19,
    skKey = 20, skNull = 21, skEnumMember = 22, skStruct = 23, skEvent = 24,
    skOperator = 25, skTypeParameter = 26

  DocumentSymbol* = object
    name*: string
    detail*: string
    kind*: SymbolKind
    `range`*: Range
    selectionRange*: Range
    children*: seq[DocumentSymbol]

  CompletionItemKind* = enum
    cikText = 1, cikMethod = 2, cikFunction = 3, cikConstructor = 4,
    cikField = 5, cikVariable = 6, cikClass = 7, cikInterface = 8,
    cikModule = 9, cikProperty = 10, cikUnit = 11, cikValue = 12,
    cikEnum = 13, cikKeyword = 14, cikSnippet = 15, cikColor = 16,
    cikFile = 17, cikReference = 18, cikFolder = 19, cikEnumMember = 20,
    cikConstant = 21, cikStruct = 22, cikEvent = 23, cikOperator = 24,
    cikTypeParameter = 25

  CompletionItem* = object
    label*: string
    kind*: CompletionItemKind
    detail*: string
    documentation*: string
    insertText*: string

  # ---- signatureHelp ----
  ParameterInformation* = object
    label*: string              ## substring of the signature label

  SignatureInformation* = object
    label*: string
    documentation*: string      ## markdown; omitted when empty
    parameters*: seq[ParameterInformation]

  SignatureHelp* = object
    signatures*: seq[SignatureInformation]
    activeSignature*: int
    activeParameter*: int

  # ---- documentHighlight ----
  DocumentHighlightKind* = enum
    dhkText = 1, dhkRead = 2, dhkWrite = 3

  DocumentHighlight* = object
    `range`*: Range
    kind*: DocumentHighlightKind

  # ---- rename / workspace edits ----
  TextEdit* = object
    `range`*: Range
    newText*: string

  WorkspaceEdit* = object
    changes*: seq[(string, seq[TextEdit])]   ## (uri, edits) pairs

  PrepareRenameResult* = object
    `range`*: Range
    placeholder*: string

  # ---- workspace/symbol ----
  SymbolInformation* = object
    name*: string
    kind*: SymbolKind
    location*: Location
    containerName*: string

  # ---- semantic tokens ----
  SemanticTokens* = object
    data*: seq[int]             ## 5-int LSP delta encoding, flattened

  # ---- inlay hints ----
  InlayHintKind* = enum
    ihkType = 1, ihkParameter = 2

  InlayHint* = object
    position*: Position
    label*: string
    kind*: InlayHintKind
    paddingLeft*: bool
    paddingRight*: bool

const
  ## Fixed legend shared by the semanticTokens capability and semtokens.nim.
  ## Producers MUST emit indices into these two arrays.
  SemanticTokenTypes* = [
    "namespace", "type", "class", "enum", "interface", "struct",
    "typeParameter", "parameter", "variable", "property", "enumMember",
    "event", "function", "method", "macro", "keyword", "modifier",
    "comment", "string", "number", "regexp", "operator", "decorator"]
  SemanticTokenModifiers* = [
    "declaration", "definition", "readonly", "static", "deprecated",
    "abstract", "async", "modification", "documentation", "defaultLibrary"]

# --------------------------------------------------------------------------
# to-JSON
# --------------------------------------------------------------------------

proc `%`*(p: Position): JsonNode =
  %*{"line": p.line, "character": p.character}

proc `%`*(r: Range): JsonNode =
  %*{"start": %r.start, "end": %r.`end`}

proc `%`*(l: Location): JsonNode =
  %*{"uri": l.uri, "range": %l.`range`}

proc `%`*(ri: DiagnosticRelatedInformation): JsonNode =
  %*{"location": %ri.location, "message": ri.message}

proc `%`*(d: Diagnostic): JsonNode =
  result = %*{
    "range": %d.`range`,
    "severity": ord(d.severity),
    "message": d.message
  }
  if d.source.len > 0: result["source"] = %d.source
  if d.relatedInformation.len > 0:
    var arr = newJArray()
    for ri in d.relatedInformation: arr.add(%ri)
    result["relatedInformation"] = arr

proc `%`*(m: MarkupContent): JsonNode =
  %*{"kind": m.kind, "value": m.value}

proc `%`*(h: Hover): JsonNode =
  result = %*{"contents": %h.contents}
  if h.`range`.isSome: result["range"] = %h.`range`.get

proc `%`*(s: DocumentSymbol): JsonNode =
  result = %*{
    "name": s.name,
    "kind": ord(s.kind),
    "range": %s.`range`,
    "selectionRange": %s.selectionRange
  }
  if s.detail.len > 0: result["detail"] = %s.detail
  if s.children.len > 0:
    var arr = newJArray()
    for c in s.children: arr.add(%c)
    result["children"] = arr

proc `%`*(c: CompletionItem): JsonNode =
  result = %*{"label": c.label, "kind": ord(c.kind)}
  if c.detail.len > 0: result["detail"] = %c.detail
  if c.documentation.len > 0: result["documentation"] = %c.documentation
  if c.insertText.len > 0: result["insertText"] = %c.insertText

proc `%`*(p: ParameterInformation): JsonNode =
  %*{"label": p.label}

proc `%`*(s: SignatureInformation): JsonNode =
  result = %*{"label": s.label}
  if s.documentation.len > 0:
    result["documentation"] = %*{"kind": "markdown", "value": s.documentation}
  if s.parameters.len > 0:
    var arr = newJArray()
    for p in s.parameters: arr.add(%p)
    result["parameters"] = arr

proc `%`*(h: SignatureHelp): JsonNode =
  result = newJObject()
  var arr = newJArray()
  for s in h.signatures: arr.add(%s)
  result["signatures"] = arr
  result["activeSignature"] = %h.activeSignature
  result["activeParameter"] = %h.activeParameter

proc `%`*(d: DocumentHighlight): JsonNode =
  %*{"range": %d.`range`, "kind": ord(d.kind)}

proc `%`*(e: TextEdit): JsonNode =
  %*{"range": %e.`range`, "newText": e.newText}

proc `%`*(w: WorkspaceEdit): JsonNode =
  var changes = newJObject()
  for (uri, edits) in w.changes:
    var arr = newJArray()
    for e in edits: arr.add(%e)
    changes[uri] = arr
  result = %*{"changes": changes}

proc `%`*(r: PrepareRenameResult): JsonNode =
  %*{"range": %r.`range`, "placeholder": r.placeholder}

proc `%`*(s: SymbolInformation): JsonNode =
  result = %*{"name": s.name, "kind": ord(s.kind), "location": %s.location}
  if s.containerName.len > 0: result["containerName"] = %s.containerName

proc `%`*(t: SemanticTokens): JsonNode =
  var arr = newJArray()
  for x in t.data: arr.add(%x)
  %*{"data": arr}

proc `%`*(h: InlayHint): JsonNode =
  result = %*{"position": %h.position, "label": h.label, "kind": ord(h.kind)}
  if h.paddingLeft: result["paddingLeft"] = %true
  if h.paddingRight: result["paddingRight"] = %true

proc toJsonArray*[T](xs: seq[T]): JsonNode =
  result = newJArray()
  for x in xs: result.add(%x)

# --------------------------------------------------------------------------
# from-JSON param accessors (tolerant of missing keys)
# --------------------------------------------------------------------------

proc getPosition*(n: JsonNode): Position =
  if n == nil: return
  result.line = n{"line"}.getInt(0)
  result.character = n{"character"}.getInt(0)

proc getRange*(n: JsonNode): Range =
  if n == nil: return
  result.start = getPosition(n{"start"})
  result.`end` = getPosition(n{"end"})

proc textDocumentUri*(params: JsonNode): string =
  ## params.textDocument.uri
  if params == nil: return ""
  params{"textDocument", "uri"}.getStr("")

proc positionParam*(params: JsonNode): Position =
  getPosition(params{"position"})

proc mkRange*(sl, sc, el, ec: int): Range =
  Range(start: Position(line: sl, character: sc),
        `end`: Position(line: el, character: ec))

proc renameNewName*(params: JsonNode): string =
  if params == nil: return ""
  params{"newName"}.getStr("")

proc queryParam*(params: JsonNode): string =
  if params == nil: return ""
  params{"query"}.getStr("")

proc rangeParam*(params: JsonNode): Range =
  ## params.range (for inlay hints / range requests)
  getRange(params{"range"})
