## textDocument/foldingRange.  STUB: implemented by the folding agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc foldingRanges*(cfg: Config; doc: Document): seq[FoldingRange] =
  @[]
