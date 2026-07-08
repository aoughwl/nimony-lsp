## textDocument/codeLens — "N references" above top-level declarations.
## STUB: implemented by the codeLens agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc codeLenses*(cfg: Config; doc: Document): seq[CodeLens] =
  @[]
