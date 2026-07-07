## textDocument/selectionRange.  STUB: implemented by the selection agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc selectionRanges*(cfg: Config; doc: Document; positions: seq[Position]): seq[SelectionRange] =
  @[]
