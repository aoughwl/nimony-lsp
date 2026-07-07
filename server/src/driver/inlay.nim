## textDocument/inlayHint — inferred-type hints for untyped let/var/const.
## STUB: implemented by the inlay-hint agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc inlayHints*(cfg: Config; doc: Document; rng: Range): seq[InlayHint] =
  @[]
