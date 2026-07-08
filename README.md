# nimony-lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
implementation for **[Nimony](https://github.com/nim-lang/nimony)** — the
NIF-based reimplementation of the Nim compiler — together with a full VSCode
extension.

The server is built directly on Nimony's own infrastructure. Navigation is
served by the compiler's `idetools` backend (`--def` / `--usages`), diagnostics
by parsing `nimony check`, and document symbols, hover, and completion by reading
the NIF artifacts (`nimcache/*.s.nif` / `*.s.idx.nif`) **in-process** through
Nimony's own reusable NIF libraries — no re-parsing of the on-disk S-expressions,
no shelling out to a second tool. One statically linked Nim binary speaks
JSON-RPC over stdio; the VSCode extension is a thin `vscode-languageclient`
wrapper around it.

## Contents

- [Motivation](#motivation)
- [Capabilities](#capabilities)
- [Layout](#layout)
- [Build](#build)
- [Editor setup](#editor-setup)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Data-format ground truth](#data-format-ground-truth)
- [Coordinate conventions](#coordinate-conventions)
- [Design notes](#design-notes)
- [Limitations](#limitations)
- [Requirements](#requirements)
- [License](#license)

## Motivation

Nimony ships a real IDE backend — `idetools` — and a lowered, fully typed
representation of every module in `nimcache/`. Nothing consumed either from an
editor. `nimony-lsp` closes that gap by turning the compiler's existing outputs
into the standard protocol every modern editor already speaks, rather than
building a parallel analysis engine:

| Editor need | What Nimony already emits | How the server uses it |
|-------------|---------------------------|------------------------|
| Errors while you type | `nimony check` diagnostics on stdout | Parsed into `Diagnostic[]`; `Trace` lines fold into `relatedInformation`. |
| Go to definition / find references | `idetools` `--def` / `--usages` records | Parsed into `Location[]` and deduplicated. |
| Outline, hover, completion | typed `.s.nif` / `.s.idx.nif` in `nimcache/` | Read in-process via Nimony's `nifstreams`/`nifcursors`/`nifindexes`/`symparser` libraries. |
| Syntax highlighting | — | A TextMate grammar (`source.nimony`) shipped with the extension. |

Because the typed NIF is read directly, symbols and completion reflect what the
compiler actually resolved — not a regex approximation of the source.

## Capabilities

Every capability below has been driven end-to-end against the compiled server
binary through an LSP client harness and verified against `nimony` 0.4.0.

| LSP capability | Backing mechanism | Status |
|----------------|-------------------|--------|
| Diagnostics (errors / warnings, with related info) | `nimony check` stdout parsing | ✅ |
| Go to definition | `nimony check --def` (idetools) | ✅ |
| Find references | `nimony check --usages` (idetools), deduplicated | ✅ |
| Hover | in-process NIF resolution → multi-line signature + doc comment | ✅ |
| Document symbols | in-process `.s.nif` top-level walk (types carry field children) | ✅ |
| Completion | module + imported `.s.idx.nif` exports; **dot-context member completion** (fields + UFCS methods) on the live buffer | ✅ |
| Signature help | enclosing-call parse → all callee overloads, resolved one active | ✅ |
| Document highlight | idetools occurrences in the file, read/write classified | ✅ |
| Rename (+ prepareRename) | idetools references → cross-file `WorkspaceEdit` | ✅ |
| Workspace symbol | name search across every `.s.nif` in `nimcache` | ✅ |
| Semantic tokens (full + range) | NIF walk → typed legend + `declaration`/`readonly` modifiers | ✅ |
| Inlay hints | inferred-type hints for un-annotated `let`/`var`/`const` | ✅ |
| Folding ranges | indentation blocks, comment runs, import groups | ✅ |
| Selection ranges | expand-selection: ident → brackets → line → blocks → file | ✅ |
| Call hierarchy | prepare + incoming/outgoing (idetools + call-site scan) | ✅ |
| Go to type definition | type of the symbol under the cursor (NIF type-slot) | ✅ |
| Go to implementation | aliases definition (Nimony has no interface/impl split) | ✅ |
| Document link | `import`/`from`/`include` → resolved module file | ✅ |
| Code lens | "N references" above each top-level declaration | ✅ |
| Inlay hints (parameters) | `paramName:` before positional call arguments (overload-aware) | ✅ |
| Type hierarchy | super/subtypes of an object type (NIF inheritance walk) | ✅ |
| Go to declaration | aliases definition | ✅ |
| Syntax highlighting | TextMate grammar (`source.nimony`) | ✅ |

Text document sync is **incremental** (`textDocumentSync: 2`); completion triggers
on `.` and `(`, signature help on `(` and `,`. A **generation-based cache**
coalesces the many `nimony check` invocations a single editor request would
otherwise trigger into one, invalidated on any document change.

### Optional warm-daemon backend

> **Status: experimental / frozen.** Araq's one-shot `nim track` direction
> (goto-def/find-uses via the CLI, made fast by incremental compilation, with no
> server process) is the blessed path for navigation — and it's exactly what the
> **default** idetools backend already does. The warm daemon below is a marginal
> latency optimization kept as an opt-in hedge; it is not developed further, and
> navigation should be expected to ride the one-shot path.

Definition, references, and workspace-symbol can be routed to a persistent
`nimsem serve` worker instead of spawning `nimony check --def/--usages` per
query. The daemon holds the whole-program interned symbol graph warm, so it
resolves the **exact overload** at a call site (across module boundaries) and
answers without re-checking. It is **opt-in and fails safe**: set
`nimony.daemonPath` (or the `NIMONY_DAEMON` env / `daemonPath` init option) to a
`nimsem serve` binary; every query falls back to the built-in idetools path when
the daemon is unset, unavailable, or returns nothing. The daemon reads the
`.s.nif` artifacts the server already maintains, so no extra build step is
needed. Verbs implemented: `defs`, `usages`/`references`, `symbols`
(`typeDefinition`/`callHierarchy` still use the in-process heuristics).

## Layout

```
nimony-lsp/
├── server/                     Nim 2.x LSP server → single binary `nimony-lsp`
│   ├── nimony_lsp.nimble
│   ├── config.nims             adds Nimony's src/lib to the module path
│   └── src/
│       ├── nimony_lsp.nim      entry point: stdio loop + request/notification dispatch
│       ├── lsp/
│       │   ├── jsonrpc.nim     Content-Length framed JSON-RPC 2.0 over stdio
│       │   ├── protocol.nim    LSP wire types + (de)serialization
│       │   └── uris.nim        file:// ↔ path
│       ├── server/
│       │   ├── state.nim       Config + ServerState (open docs, roots)
│       │   └── documents.nim   Document: text, versions, UTF-16 ↔ offset mapping
│       └── driver/
│           ├── nimonycli.nim   run `nimony check [--def/--usages]` + generation cache
│           ├── diagnostics.nim parse `path(line,col) Kind: msg` → Diagnostic[]
│           ├── idetools.nim    parse def/use tab records → Location[]
│           ├── nifindex.nim    in-process .s.nif/.s.idx.nif → symbols / hover / completion
│           ├── signature.nim   signatureHelp: enclosing-call parse + idetools
│           ├── highlight.nim   documentHighlight: in-file occurrences, read/write
│           ├── rename.nim      prepareRename + rename → WorkspaceEdit
│           ├── workspacesym.nim workspace/symbol: name search over nimcache
│           ├── semtokens.nim   semanticTokens/full: NIF walk → token legend + modifiers
│           ├── inlay.nim       inlayHint: inferred-type hints
│           ├── folding.nim     foldingRange: indentation / comments / imports
│           ├── selection.nim   selectionRange: expand-selection hierarchy
│           ├── callhierarchy.nim  prepare + incoming/outgoing calls
│           ├── extranav.nim    typeDefinition + implementation
│           └── daemon.nim      optional `nimsem serve` client (defs/usages/symbols)
│           ├── doclink.nim     documentLink: imports → module files
│           ├── codelens.nim    codeLens: reference counts
│           └── paramhints.nim  inlayHint: parameter names at call sites
├── client/                     VSCode extension (TypeScript, vscode-languageclient)
│   ├── package.json
│   ├── src/extension.ts        spawns the server over stdio; status bar; restart command
│   ├── language-configuration.json
│   └── syntaxes/nimony.tmLanguage.json
├── ARCHITECTURE.md             design, module contracts, data-format ground truth
├── README.md
└── LICENSE
```

## Build

### Server

```bash
cd server
nimble build            # → server/bin/nimony-lsp
```

`config.nims` adds Nimony's `src/lib` to the compile path so the server links the
compiler's own NIF libraries. The server needs a Nimony toolchain at run time; it
defaults to `/home/savant/nimony/bin/nimony` and can be pointed elsewhere (see
[Configuration](#configuration)).

### VSCode extension

```bash
cd client
npm install
npm run compile         # → client/out/extension.js
```

Press **F5** with the `client/` folder open to launch an Extension Development
Host, or run `vsce package` to produce an installable `.vsix`.

## Editor setup

The extension registers the server for `.nim`, `.nims`, and `.nimony` files. In
any LSP-capable editor the wiring is the same three facts: launch
`server/bin/nimony-lsp`, talk JSON-RPC over stdio, and pass the compiler path in
`initializationOptions.nimonyPath`.

Note that Nim and Nimony share the `.nim` extension. A workspace is one language
or the other; run this server for Nimony projects and a Nim language server for
Nim projects, not both over the same files. The companion
[`nim-code`](https://github.com/aoughwl/nim-code) plugin documents the
per-project opt-in for wiring this server into Claude Code alongside its Nim
counterpart.

## Configuration

| Setting | Default | Meaning |
|---------|---------|---------|
| `nimony.serverPath` | auto | Path to the `nimony-lsp` binary. Empty → the bundled binary, then a built-in fallback. |
| `nimony.nimonyPath` | `/home/savant/nimony/bin/nimony` | The Nimony compiler the server drives. |
| `nimony.extraPaths` | `[]` | Extra `--path` entries handed to the compiler. |
| `nimony.trace.server` | `off` | LSP JSON-RPC tracing (`off` / `messages` / `verbose`). |

The compiler path may also be supplied out-of-band via the `NIMONY_EXE`
environment variable or `initializationOptions.nimonyPath`; the client setting
takes precedence when present.

## How it works

The server is layered so that each concern is independently testable:

- **Transport** (`lsp/jsonrpc.nim`) reads and writes Content-Length framed
  JSON-RPC 2.0 messages on stdio.
- **Protocol** (`lsp/protocol.nim`) holds the LSP wire types and their
  JSON (de)serialization; positions are 0-based UTF-16 throughout.
- **Document store** (`server/documents.nim`) keeps the authoritative text for
  each open buffer, maintains a line index, and owns every conversion between LSP
  UTF-16 columns and byte offsets.
- **Drivers** (`driver/*`) are the only code that touches Nimony. `nimonycli`
  runs the compiler; `diagnostics` and `idetools` parse its textual output;
  `nifindex` reads the binary NIF artifacts in-process.
- **Dispatch** (`nimony_lsp.nim`) is the stdio loop that routes each request to a
  driver and publishes diagnostics on document changes.

`nifindex.nim` is the part that goes beyond shelling out: it opens the module's
`.s.nif` with Nimony's `nifstreams`/`nifcursors`, walks the top-level
declarations to build the document outline (descending into `type` nodes to
collect field children), demangles symbols with `symparser`, and reads imported
modules' embedded `.s.idx.nif` indexes for completion. Every public entry point
is defensively wrapped so a malformed or missing artifact yields an empty result
rather than taking the server down.

## Data-format ground truth

These facts were verified against `nimony` 0.4.0 and are what the parsers depend
on. They are easy to get wrong and are documented in full in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

- `nimony check` reports diagnostics as `path(line, col) Kind: message` with
  **1-based line and column**, and **exits 0 even on error** — so success is
  determined by parsing stdout for an `Error:` line, never by the exit code. The
  trailing `FAILURE:` / `SUCCESS:` build-summary line is skipped.
- `idetools` tracking (`--def` / `--usages`) requires the file path to be
  **relative to the compiler's working directory**; an absolute path reports
  "symbol not found".
- `idetools` output columns are **0-based** while request columns are
  **1-based**, and the backend emits **duplicate records** for a span — the
  server deduplicates them.
- Nimony packs `(file, line, col)` into every NIF token and marks declarations
  (`SymbolDef`) distinctly from uses (`Symbol`), which is what makes navigation
  and outlines fall out of the artifacts cheaply.

## Coordinate conventions

A single source of truth for the off-by-one and base differences the drivers
reconcile:

| Surface | Line base | Col base | Col unit |
|---------|-----------|----------|----------|
| LSP wire | 0 | 0 | UTF-16 code units |
| nimony diagnostics | 1 | 1 | codepoints |
| idetools input | 1 | 1 | codepoints |
| idetools output | 1 | 0 | codepoints |

All UTF-16 ↔ byte reconciliation is centralized in `documents.nim`; the drivers
only apply the 0/1-based line/col shift.

## Design notes

- **Built on the compiler, not beside it.** Navigation, diagnostics, and typed
  symbols all come from Nimony's own outputs, so results track exactly what the
  compiler resolved.
- **In-process NIF reading.** The document-symbol / hover / completion path links
  Nimony's `src/lib` NIF libraries directly instead of spawning or re-parsing,
  keeping those features fast and faithful to the typed representation.
- **Fail open.** Every artifact-reading path is wrapped to degrade to an empty or
  `none` result; a bad or absent `.s.nif` never crashes the server.
- **Single binary, thin client.** All analysis lives in one Nim executable; the
  VSCode extension only launches it, surfaces status, and offers a restart
  command, so the same server drops into any LSP-capable editor.

## Limitations

Current, honest edges — none block day-to-day use:

- Diagnostics run on open/save (not per keystroke). This is **not** a compiler
  limitation: Nimony's `check` is incrementally fast (~20ms per edit), and live
  diagnostics on the *unsaved* buffer is proven to work (materialize the buffer
  to a temp file, check, remap). What remains is doing it **off the stdio loop**
  — a background worker with coalescing — so a ~1s cold check never blocks
  typing. A first threaded worker proved unstable at teardown, so it is deferred
  pending careful async work; it is the clear next step, not a blocker.
  Navigation/hover/symbols/tokens read the **saved** file; member completion and
  the document buffer (incremental sync) use the live text.
- Call hierarchy and go-to-type-definition use source-scan / single-module NIF
  heuristics, so cross-module overloads and deeply generic types can be missed.
- The generation cache coalesces redundant checks within a request but is not yet
  a persistent index, so large modules still re-check after an edit.
- Some type-usage references are missed because `idetools` type-use resolution is
  young upstream — the server deduplicates what it returns but cannot recover uses
  the backend never emits (this also bounds rename/highlight completeness).
- Semantic-token modifiers are always `0` (types only); symbol `range` equals
  `selectionRange` (the declaration name span).

## Requirements

- **Nim** 2.0+ to build the server (developed against 2.3.1).
- **Nimony** — a built toolchain providing `nimony` (e.g. `~/nimony/bin`), and
  its `src/lib` sources on disk for the in-process NIF libraries the server links
  against. Required at both build and run time.
- **Node.js / npm** and **VSCode** 1.75+ for the extension; `vsce` only if you
  package a `.vsix`.

## License

MIT — see [LICENSE](LICENSE).
