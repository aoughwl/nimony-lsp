## typeHierarchy: prepare + supertypes + subtypes.
## STUB: implemented by the type-hierarchy agent.

import ../lsp/protocol
import ../server/state
import ../server/documents

proc prepareTypeHierarchy*(cfg: Config; doc: Document; pos: Position): seq[TypeHierarchyItem] =
  @[]

proc supertypes*(cfg: Config; item: TypeHierarchyItem): seq[TypeHierarchyItem] =
  @[]

proc subtypes*(cfg: Config; item: TypeHierarchyItem): seq[TypeHierarchyItem] =
  @[]
