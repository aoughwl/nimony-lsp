import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
  State,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;
let statusBarItem: vscode.StatusBarItem;

// Serialize server lifecycle transitions. VS Code delivers restart and
// config-change events as independent async callbacks; without serialization a
// second event can call startClient() while the first stopClient() is still
// awaiting the old server's shutdown, spawning a NEW server before the old one
// exits — several overlapping servers then compile into one shared nimcache and
// thrash it. Chaining every stop→start through one promise caps concurrent
// servers at one.
let lifecycleChain: Promise<void> = Promise.resolve();
function serializeLifecycle(op: () => Promise<void>): Promise<void> {
  lifecycleChain = lifecycleChain.then(op, op);
  return lifecycleChain;
}

/**
 * Absolute fallback path to the server binary, matching the checked-in repo
 * layout described in ARCHITECTURE.md (`server/bin/nimony-lsp`).
 */
const ABSOLUTE_FALLBACK_SERVER =
  "/home/savant/nimony-lsp/server/bin/nimony-lsp";

/** Read the extension's configuration namespace. */
function getConfig(): vscode.WorkspaceConfiguration {
  return vscode.workspace.getConfiguration("nimony");
}

/**
 * Resolve the path to the nimony-lsp server binary.
 *
 * Precedence:
 *   1. `nimony.serverPath` setting, if non-empty.
 *   2. A binary bundled alongside the extension (../server/bin/nimony-lsp,
 *      i.e. the sibling `server` directory of this `client` extension).
 *   3. The absolute fallback path from the repo layout.
 */
function resolveServerPath(context: vscode.ExtensionContext): string {
  const configured = getConfig().get<string>("serverPath", "").trim();
  if (configured.length > 0) {
    return configured;
  }

  // The extension lives at `client/`; the built binary at `server/bin/nimony-lsp`.
  // context.extensionPath points at the `client` directory, so go up one level.
  const sibling = path.join(
    context.extensionPath,
    "..",
    "server",
    "bin",
    "nimony-lsp"
  );
  if (fs.existsSync(sibling)) {
    return sibling;
  }

  return ABSOLUTE_FALLBACK_SERVER;
}

/** Build initializationOptions from the current configuration. */
function buildInitializationOptions(): Record<string, unknown> {
  const config = getConfig();
  return {
    nimonyPath: config.get<string>(
      "nimonyPath",
      "/home/savant/nimony/bin/nimony"
    ),
    extraPaths: config.get<string[]>("extraPaths", []),
    daemonPath: config.get<string>("daemonPath", ""),
  };
}

/** Update the status bar item to reflect the current server state. */
function setStatus(text: string, tooltip: string): void {
  statusBarItem.text = `$(server-process) Nimony: ${text}`;
  statusBarItem.tooltip = tooltip;
  statusBarItem.show();
}

/**
 * Create (but do not start) a LanguageClient wired to the resolved server
 * binary. Returns undefined and shows an error if the binary is missing.
 */
function createClient(
  context: vscode.ExtensionContext
): LanguageClient | undefined {
  const serverPath = resolveServerPath(context);

  if (!fs.existsSync(serverPath)) {
    vscode.window.showErrorMessage(
      `Nimony language server not found at "${serverPath}". ` +
        `Build it with: cd server && nimble build ` +
        `(or set "nimony.serverPath" in your settings).`
    );
    setStatus("stopped", `Server binary not found at ${serverPath}`);
    return undefined;
  }

  const serverOptions: ServerOptions = {
    run: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
    debug: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "nimony" },
      { scheme: "file", language: "nim" },
    ],
    initializationOptions: buildInitializationOptions(),
    synchronize: {
      configurationSection: "nimony",
    },
    outputChannelName: "Nimony Language Server",
  };

  const newClient = new LanguageClient(
    "nimony",
    "Nimony Language Server",
    serverOptions,
    clientOptions
  );

  // Reflect lifecycle transitions in the status bar.
  newClient.onDidChangeState((event) => {
    switch (event.newState) {
      case State.Starting:
        setStatus("starting", "Nimony language server is starting…");
        break;
      case State.Running:
        setStatus("running", `Nimony language server running (${serverPath})`);
        break;
      case State.Stopped:
        setStatus("stopped", "Nimony language server stopped");
        break;
    }
  });

  return newClient;
}

/** Start the language client, creating it if needed. */
async function startClient(context: vscode.ExtensionContext): Promise<void> {
  if (!client) {
    client = createClient(context);
  }
  if (!client) {
    return;
  }
  setStatus("starting", "Nimony language server is starting…");
  try {
    await client.start();
  } catch (err) {
    setStatus("stopped", "Nimony language server failed to start");
    vscode.window.showErrorMessage(
      `Failed to start Nimony language server: ${String(err)}`
    );
  }
}

/** Stop and dispose the current language client, if any. */
async function stopClient(): Promise<void> {
  if (!client) {
    return;
  }
  const stopping = client;
  client = undefined;
  try {
    await stopping.stop();
  } catch {
    // Ignore; the process may already be gone.
  }
  await stopping.dispose().catch(() => undefined);
}

export async function activate(
  context: vscode.ExtensionContext
): Promise<void> {
  statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100
  );
  statusBarItem.command = "nimony.restartServer";
  context.subscriptions.push(statusBarItem);
  setStatus("stopped", "Nimony language server not started");

  // Restart command: full stop + start with a freshly resolved config.
  context.subscriptions.push(
    vscode.commands.registerCommand("nimony.restartServer", async () => {
      await serializeLifecycle(async () => {
        await stopClient();
        await startClient(context);
      });
      vscode.window.setStatusBarMessage("Nimony: language server restarted", 3000);
    })
  );

  // Run the current file: `nimony c -r <file>` in a reused terminal (F6).
  context.subscriptions.push(
    vscode.commands.registerCommand("nimony.run.file", async () => {
      const ed = vscode.window.activeTextEditor;
      if (!ed) {
        vscode.window.showWarningMessage("Nimony: no active file to run.");
        return;
      }
      await ed.document.save();
      const file = ed.document.uri.fsPath;
      const cfg = getConfig();
      const nimony = cfg.get<string>("nimonyPath", "/home/savant/nimony/bin/nimony");
      const extra = cfg.get<string[]>("extraPaths", []);
      const q = (s: string) => (/[\s"']/.test(s) ? `'${s.replace(/'/g, "'\\''")}'` : s);
      const paths = extra.map((p) => `-p:${q(p)}`).join(" ");
      const dir = path.dirname(file);
      const term =
        vscode.window.terminals.find((t) => t.name === "Nimony Run") ??
        vscode.window.createTerminal({ name: "Nimony Run", cwd: dir });
      term.show(true);
      term.sendText(`${q(nimony)} c -r ${paths} ${q(file)}`.replace(/\s+/g, " ").trim());
    })
  );

  // Clear the LSP's per-file compile caches and restart — a self-heal button if
  // a nimcache ever gets into a bad state. Removes only the LSP's own dirs
  // (`nimcache/lsp`, `.nimlsp_livecache`), never the user's `nimony c` cache.
  context.subscriptions.push(
    vscode.commands.registerCommand("nimony.clearCache", async () => {
      const folders = vscode.workspace.workspaceFolders ?? [];
      let removed = 0;
      for (const f of folders) {
        for (const sub of ["nimcache/lsp", ".nimlsp_livecache"]) {
          const dir = path.join(f.uri.fsPath, sub);
          try {
            if (fs.existsSync(dir)) {
              fs.rmSync(dir, { recursive: true, force: true });
              removed++;
            }
          } catch {
            // ignore; best effort
          }
        }
      }
      await serializeLifecycle(async () => {
        await stopClient();
        await startClient(context);
      });
      vscode.window.setStatusBarMessage(
        `Nimony: cleared ${removed} cache dir(s), server restarted`,
        3000
      );
    })
  );

  // Restart automatically when relevant settings change so the new
  // serverPath / nimonyPath / extraPaths take effect.
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      if (
        e.affectsConfiguration("nimony.serverPath") ||
        e.affectsConfiguration("nimony.nimonyPath") ||
        e.affectsConfiguration("nimony.extraPaths") ||
        e.affectsConfiguration("nimony.daemonPath")
      ) {
        await serializeLifecycle(async () => {
          await stopClient();
          await startClient(context);
        });
      }
    })
  );

  await serializeLifecycle(() => startClient(context));
}

export async function deactivate(): Promise<void> {
  await stopClient();
}
