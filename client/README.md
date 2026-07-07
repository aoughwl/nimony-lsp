# Nimony for VSCode

The VSCode client for [`nimony-lsp`](../ARCHITECTURE.md), a Language Server
Protocol implementation for **Nimony** (the NIF-based Nim successor).

It provides diagnostics, go-to-definition, find-references, hover, document
symbols, and completion by driving the `nimony-lsp` server over stdio.

## Features

- Live diagnostics (errors / warnings / traces) as you type
- Go to Definition and Find All References
- Hover information
- Document symbols (outline / breadcrumbs)
- Completion (triggered on `.` and `(`)
- Syntax highlighting for `.nim`, `.nims`, and `.nimony` files
- Status bar item showing the server state (starting / running / stopped)
- `Nimony: Restart Language Server` command

## Requirements

1. **The language server binary.** Build it from the repo root:

   ```bash
   cd server && nimble build
   ```

   This produces `server/bin/nimony-lsp`. The extension auto-resolves this
   binary relative to its own location, so no configuration is needed for the
   default repo layout. If it lives elsewhere, set `nimony.serverPath`.

2. **The Nimony compiler.** The server shells out to the Nimony compiler,
   which defaults to `/home/savant/nimony/bin/nimony`. Override with
   `nimony.nimonyPath` if yours is elsewhere.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `nimony.serverPath` | `""` | Path to the `nimony-lsp` binary. Empty = auto-resolve. |
| `nimony.nimonyPath` | `/home/savant/nimony/bin/nimony` | Path to the Nimony compiler. |
| `nimony.extraPaths` | `[]` | Extra module search paths for the compiler. |
| `nimony.trace.server` | `off` | LSP trace verbosity (`off` / `messages` / `verbose`). |

## Build

```bash
cd client
npm install
npm run compile     # tsc -p ./  -> out/extension.js
npm run watch       # incremental rebuild on change
```

## Run / Debug (Extension Development Host)

1. Open the `client/` folder in VSCode.
2. `npm install` (once).
3. Press **F5** (uses `.vscode/launch.json`, which compiles first via the
   `npm: compile` task). This opens an Extension Development Host window with
   the Nimony extension loaded.
4. Open a `.nim` / `.nimony` file — the server starts automatically and the
   status bar shows `Nimony: running`.

## Package (.vsix)

```bash
cd client
npm install -g @vscode/vsce   # if not already installed
vsce package                  # runs vscode:prepublish (compile) -> nimony-0.1.0.vsix
```

Install the resulting `.vsix` via
`code --install-extension nimony-0.1.0.vsix` or the Extensions view
(`... > Install from VSIX...`).

## Troubleshooting

- **"Nimony language server not found"** — build the server
  (`cd server && nimble build`) or set `nimony.serverPath` to an absolute path.
- Inspect traffic: set `nimony.trace.server` to `verbose` and open the
  **Nimony Language Server** output channel.
- Use **Nimony: Restart Language Server** (also triggered by clicking the
  status bar item) after rebuilding the server binary.
