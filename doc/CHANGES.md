# nimony-lsp — Issues Fixed & Features Added

The ledger of what the language server (and its VS Code client) fixes/adds. The
server drives both the nimony (`.nim`) and aowl (`.aowl`) extensions; every
feature request runs a one-shot `nimony check` against a warm nimcache (no
daemon — aligned with Araq's `nim track` direction).

**Keep this current: every fix/feature gets a row** with what, why, and how it's
verified (this server is verified over the LSP wire against a real project, not
just by tests).

---

## Features Added

| Feature | What it enables | Where |
|---|---|---|
| Priority scheduling + as-you-type debounce | interactive requests (hover/definition/completion) are served BEFORE the background feature burst VS Code fires each edit; typing marks the doc dirty and one coalesced live-check runs only after a 200ms idle, so fast typing never stacks compiles | `dcabad8` |
| Eager main-cache warm on `didOpen` | the main nimcache is warmed once when a file opens (ungated by the idle flush a burst can starve), so the first hover/definition is fast instead of a cold recompile | `7abc5b9` |
| Live-buffer navigation | hover / definition / references reflect UNSAVED edits (routed through the same live temp the diagnostics use) instead of the last-saved file; falls back to the disk/daemon answer when the buffer is mid-edit so nav never blanks | `1c674fa` |
| Go-to-definition into stdlib source | F12 on an `import std/x` module name, or on a resolved stdlib symbol, opens the real source under `<nimony>/lib` | `dcabad8` |
| Run file (F6) | `nimony.run.file` / F6 runs `nimony c -r` on the active file in a reused "Nimony Run" terminal | `dcabad8` |
| `$/cancelRequest` | a background request the client abandoned (cursor moved on) is dropped and answered Cancelled | `48baee2` |
| Crash-resilience | a handler exception becomes an error response and a malformed JSON frame is absorbed — neither can take the server down | `d998176` |

---

## Issues Fixed

| # | Issue | Root cause | Fix | Verified |
|---|---|---|---|---|
| 1 | "Loading forever": every hover/definition/references recompiled the whole project (~1.5s) on every request, forever, on a real multi-module project | nimony keys its incremental cache by the file path string AS GIVEN; diagnostics warmed it with the ABSOLUTE path while nav (`--def`/`--usages`) queried with the RELATIVE path, so the two never shared a cache entry | `nimonycli.canonFile` funnels every check through one canonical (relative-to-projectRoot) path form; eager warm on open | `7abc5b9` — definition 1481ms→62ms, def-on-import 1467ms→36ms after one 1.47s warm |
| 2 | Bogus `: int` inlay hints landed in comments, inside `import` words, and on `inc`/`result`/call statements | the semchecked NIF carries compiler-synthesized decls (loop temps, `result`, lowered statements, module symbols) whose line-info points at arbitrary source tokens | `inlay.validTypeHintPos` gates each hint to sit exactly at an identifier end on a line that starts with `let`/`var`/`const` | `a9c76c7` — 8 bogus removed, 12 real + param-name hints kept |
| 3 | Live-as-you-type diagnostics silently produced nothing on EVERY dirty (unsaved) buffer | the live temp file was a DOTFILE (`.nimlsp_live_*`); nimony derives a module id from the filename and a leading-dot name yields an empty id, crashing the checker (`nifreader: r.thisModule.len > 0`) | rename the temp to a non-dot sibling `nimlsp_live_*`; hide it from the explorer via the client's `files.exclude` contribution | `1c674fa` — an unsaved type error now publishes a live "type mismatch" while disk stays clean |
| 4 | Hover/definition/references showed stale (last-saved) results while editing | the handlers read the file ON DISK, ignoring unsaved buffer edits | route nav through the live buffer temp when the buffer differs from disk; remap temp→real by path (coords are buffer-correct); disk fallback when mid-edit | `1c674fa` — def/hover on an unsaved `proc bar` resolve to the buffer line (disk has no `bar`) |
| 5 | Restart/reload churn spawned up to 3 overlapping servers thrashing one shared nimcache ("why do we have 3 servers?!") | VS Code delivers restart/config-change as independent async callbacks; a second event ran `startClient()` before the first `stopClient()` finished, spawning a new server before the old exited | the client chains every stop→start through one lifecycle promise, capping concurrent servers at one | `f218b23` |
| 6 | Interactive hover stalled ~9s behind the per-edit feature burst; typing stacked compiles | requests served strictly in arrival order, each its own ~1.1s compile | priority scheduling (interactive before background), interruptible/superseding background queue, debounce | `dcabad8` — hover 9.4s→~1s; flat under rapid typing |

---

## Known limits / next

- **Cold-open cost is real**: the first interaction after opening a project pays
  one full `nimony check` (~1.1–1.5s) to warm the cache; no daemon keeps it hot
  across sessions. Making that first check cheap is a compiler-side problem
  (incremental `check`).
- **Cross-file references while a buffer is dirty** use the disk coordinate for
  the other open modules (they import the real module, not the temp), so an edit
  that shifts lines above the symbol can momentarily mis-resolve cross-file
  usages — same as before the live-nav change, not a regression.
- The NIF-reading in `driver/nifindex.nim` (hover/completion/symbols/semtokens/
  inlay) duplicates niflens's core; the plan is to link a shared niflens core lib
  and keep only LSP shaping here (see the niflens ⇄ nimony-lsp convergence notes).
</content>
