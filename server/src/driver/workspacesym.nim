## workspace/symbol — project-wide symbol search by name.
## STUB: implemented by the workspace-symbol agent.

import ../lsp/protocol
import ../server/state

proc workspaceSymbols*(cfg: Config; query: string): seq[SymbolInformation] =
  @[]
