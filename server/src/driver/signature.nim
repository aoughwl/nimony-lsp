## textDocument/signatureHelp — signature + active parameter for the call
## enclosing the cursor.  STUB: implemented by the signature agent.

import std/options
import ../lsp/protocol
import ../server/state
import ../server/documents

proc signatureHelp*(cfg: Config; doc: Document; pos: Position): Option[SignatureHelp] =
  none(SignatureHelp)
