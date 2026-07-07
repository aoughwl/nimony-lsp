# nimony-lsp — Architecture & module contracts

A Language Server Protocol implementation for **Nimony** (the NIF-based Nim
successor), plus a full VSCode extension.

```
nimony-lsp/
  server/                  # the LSP server (Nim 2.3.1, static binary `nimony-lsp`)
    nimony_lsp.nimble
    config.nims
    src/
      nimony_lsp.nim       # entry point: stdio loop + dispatch
      lsp/
        jsonrpc.nim        # Content-Length framed JSON-RPC over stdin/stdout
        protocol.nim       # LSP wire types + (de)serialization helpers
        uris.nim           # file:// <-> path
      server/
        state.nim          # ServerState: config, open documents, workspace roots
        documents.nim      # Document: text, version, line index, LSP<->offset mapping
      driver/
        nimonycli.nim      # run `nimony check [--def/--usages]`, capture output
        diagnostics.nim    # parse `path(line,col) Error: msg` -> Diagnostic[]
        idetools.nim       # parse def/use tab records -> Location[]
        nifindex.nim       # in-process .idx.nif/.s.nif reading (symbols/hover/completion)
      features/
        definition.nim references.nim hover.nim completion.nim
        documentsymbol.nim workspacesymbol.nim diagnosticspush.nim
  client/                  # VSCode extension (TypeScript)
    package.json tsconfig.json
    src/extension.ts
    language-configuration.json
    syntaxes/nimony.tmLanguage.json
```

## Data-format ground truth (verified against bin/nimony 0.4.0)

Diagnostics — from `nimony check <file>` on stdout (exit code is 0 even on error,
so DO NOT rely on exit code; parse stdout):
```
../../tmp/errsample.nim(2, 14) Error: type mismatch: got: string but wanted: int64
../../tmp/errsample.nim(3, 1) Trace: instantiation from here
../../tmp/errsample.nim(3, 6) Error: undeclared identifier: y
FAILURE: /home/.../nifmake ... nimcache/....build.nif      <- summary line, skip
```
- `path(line, col) Kind: message` — **line 1-based, col 1-based**.
- Kinds seen: `Error`, `Trace` (= related-info of the preceding Error), `Warning`.
- Paths may be relative to nimony's cwd; resolve to absolute against the cwd we run in.

idetools — from `nimony check --def:FILE,LINE,COL FILE` (or `--usages:`):
```
def\t\tadd.0.tgokb0h9q\t\t\ttests/.../tgotodecl.nim\t1\t5
use\t\tadd.0.tgokb0h9q\t\t\ttests/.../tgotodecl.nim\t3\t8
```
Tab-separated: `kind` (`def`/`use`), symkind(empty), **mangled symbol**, sig(empty),
container(empty), **file**, **line (1-based)**, **col (0-based)**.
- Input `--def/--usages` **col is 1-based** (editor convention; nimony converts internally).
- So: LSP request Position(line0, char0) -> nimony `line0+1, char0+1`.
- idetools output Position -> LSP `Position(line-1, col)` (col already 0-based).

Mangled symbol names (`add.0.tgokb0h9q`): use `src/lib/symparser.nim`
(`extractBasename`, `extractModule`) to get a human name.

## Coordinate conventions (single source of truth)

| Surface | line base | col base | col unit |
|---|---|---|---|
| LSP wire | 0 | 0 | UTF-16 code units |
| nimony diagnostics | 1 | 1 | bytes/codepoints |
| idetools input | 1 | 1 | codepoints |
| idetools output | 1 | 0 | codepoints |

`documents.nim` owns all conversion between LSP UTF-16 columns and byte offsets.
Driver modules convert only the 0/1-based line/col shift and hand codepoint columns
to `documents.nim` for UTF-16 reconciliation where needed. For v1, assume ASCII
alignment (codepoint==UTF-16) and centralize the conversion so we can harden later.

## Module contracts (types live in protocol.nim unless noted)

- `jsonrpc.nim`
  - `type Message = object` (id: Option, `method`: Option[string], params/result/error: JsonNode)
  - `proc readMessage(inp: File): Option[Message]` — nil/none on EOF.
  - `proc writeMessage(outp: File; msg: JsonNode)` — frames + flushes.
  - `proc response(id: JsonNode; res: JsonNode): JsonNode`
  - `proc errorResponse(id: JsonNode; code: int; msg: string): JsonNode`
  - `proc notification(meth: string; params: JsonNode): JsonNode`

- `protocol.nim` — LSP structs (Position, Range, Location, Diagnostic,
  TextDocumentIdentifier, CompletionItem, Hover, DocumentSymbol, ...) with
  `%*`/`toJson` and `fromJson`/accessor helpers. Positions are 0-based UTF-16.

- `server/documents.nim`
  - `type Document = ref object` (uri, languageId, version: int, text: string, lineStarts: seq[int])
  - `proc newDocument(uri, languageId: string; version: int; text: string): Document`
  - `proc update(d: Document; version: int; text: string)` (full sync for v1)
  - `proc offsetAt(d: Document; pos: Position): int` and
    `proc positionAt(d: Document; offset: int): Position` (UTF-16 aware).

- `server/state.nim`
  - `type Config = object` (nimonyExe, extraPaths: seq[string], projectRoot: string)
  - `type ServerState = ref object` (config, docs: Table[string, Document], rootUri: string, initialized: bool)
  - helpers: `openDoc`, `closeDoc`, `getDoc`, `filePath(uri)`.

- `driver/nimonycli.nim`
  - `type CheckResult = object` (stdout, stderr: string; exitCode: int)
  - `proc runCheck(cfg: Config; file: string; track: seq[string] = @[]): CheckResult`
    (track e.g. `@["--def:" & file & "," & $line & "," & $col]`). Writes unsaved
    buffer to a temp overlay dir when the on-disk file differs, and points nimony there.

- `driver/diagnostics.nim`
  - `proc parseDiagnostics(cfg: Config; forFileAbs: string; raw: string): Table[string, seq[Diagnostic]]`
    keyed by absolute path (multi-file). Maps Trace lines to relatedInformation of the
    preceding Error. Skips `FAILURE:`/build-noise lines.

- `driver/idetools.nim`
  - `proc definition(cfg: Config; file: string; pos: Position): seq[Location]`
  - `proc references(cfg: Config; file: string; pos: Position): seq[Location]`
  - parses tab records; converts line-1, col stays 0-based for output.

- `driver/nifindex.nim` (reuses /home/savant/nimony/src/lib)
  - `proc documentSymbols(cfg: Config; file: string): seq[DocumentSymbol]`
  - `proc hoverAt(cfg: Config; file: string; pos: Position): Option[Hover]`
  - `proc completions(cfg: Config; file: string; pos: Position): seq[CompletionItem]`
  - Backed by reading `nimcache/*.idx.nif` + `.s.nif` for the module.

## Build

Server: `cd server && nimble build` -> `server/bin/nimony-lsp`.
The nimony toolchain lives at `/home/savant/nimony/bin` (configurable via the
`nimony.nimonyPath` client setting / `--nimony` server flag).
