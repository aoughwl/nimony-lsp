## textDocument/typeDefinition + textDocument/implementation.
## STUB: implemented by the extra-navigation agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc typeDefinition*(cfg: Config; doc: Document; pos: Position): seq[Location] =
  @[]

proc implementation*(cfg: Config; doc: Document; pos: Position): seq[Location] =
  @[]
