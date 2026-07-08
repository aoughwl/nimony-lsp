## textDocument/documentLink — import/include statements → module file targets.
## STUB: implemented by the documentLink agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc documentLinks*(cfg: Config; doc: Document): seq[DocumentLink] =
  @[]
