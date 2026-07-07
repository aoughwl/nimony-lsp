## textDocument/prepareRename + textDocument/rename.
## STUB: implemented by the rename agent.

import std/options
import ../lsp/protocol
import ../server/state
import ../server/documents

proc prepareRename*(cfg: Config; doc: Document; pos: Position): Option[PrepareRenameResult] =
  none(PrepareRenameResult)

proc rename*(cfg: Config; doc: Document; pos: Position; newName: string): Option[WorkspaceEdit] =
  none(WorkspaceEdit)
