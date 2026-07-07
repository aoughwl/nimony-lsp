## textDocument/documentHighlight — occurrences of the symbol under the cursor
## within the current file.  STUB: implemented by the highlight agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc documentHighlights*(cfg: Config; doc: Document; pos: Position): seq[DocumentHighlight] =
  @[]
