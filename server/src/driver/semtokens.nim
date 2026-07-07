## textDocument/semanticTokens/full — type-aware token colouring from the NIF.
## STUB: implemented by the semantic-tokens agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc semanticTokensFull*(cfg: Config; doc: Document): SemanticTokens =
  SemanticTokens(data: @[])
