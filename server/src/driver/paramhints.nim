## textDocument/inlayHint (parameter-name half) — `paramName:` before positional
## call arguments.  STUB: implemented by the parameter-hints agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc parameterHints*(cfg: Config; doc: Document; rng: Range): seq[InlayHint] =
  @[]
