## callHierarchy: prepare + incoming/outgoing.  STUB: implemented by the agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc prepareCallHierarchy*(cfg: Config; doc: Document; pos: Position): seq[CallHierarchyItem] =
  @[]

proc incomingCalls*(cfg: Config; item: CallHierarchyItem): seq[CallHierarchyIncomingCall] =
  @[]

proc outgoingCalls*(cfg: Config; item: CallHierarchyItem): seq[CallHierarchyOutgoingCall] =
  @[]
