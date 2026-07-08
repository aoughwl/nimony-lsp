# nimony-lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
implementation for **[Nimony](https://github.com/nim-lang/nimony)**, plus a full
VSCode extension. Built directly on Nimony's own `idetools` and NIF libraries — one
statically linked binary speaking JSON-RPC over stdio.

**📖 Full docs → [aoughwl.github.io/docs/nimony-lsp](https://aoughwl.github.io/docs/nimony-lsp)**

- Diagnostics from `nimony check`; go-to-def / references from `idetools`.
- Outline, hover, completion by reading typed `.s.nif` / `.s.idx.nif` **in-process**
  — not a regex approximation of the source.
- TextMate grammar (`source.nimony`) shipped with the extension.

See the docs for build, editor setup, configuration, and coordinate conventions.
