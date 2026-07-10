## textDocument/codeLens: emit a "N references" lens above each top-level
## declaration.
##
## Counts come from `navindex.referenceCounts`, which does ONE in-process
## `.s.nif` walk (via the shared nifcache) and yields, for every top-level
## decl, its selectionRange + use-count — with zero per-symbol nimony spawns.
## (The old implementation ran `idetools.references` once per symbol: 2N cold
## compiler invocations per file. That is gone.)
##
## Reference counts are approximate: the index is young and may miss some
## usages, which is acceptable for a lens.
##
## Every path is defensively wrapped so a failure yields `@[]` (or the lens
## unchanged) and never takes the LSP process down.

import ../lsp/protocol
import ../lsp/uris
import ../server/state
import ../server/documents
import ./navindex

proc lensTitle(count: int): string =
  if count == 1: "1 reference" else: $count & " references"

proc codeLenses*(cfg: Config; doc: Document): seq[CodeLens] =
  ## One index walk: a "N references" lens on every top-level declaration.
  result = @[]
  try:
    let file = uriToPath(doc.uri)
    for entry in navindex.referenceCounts(cfg, file):
      result.add CodeLens(`range`: entry.rng,
                          command: Command(title: lensTitle(entry.count),
                                           command: ""))
  except CatchableError:
    result = @[]

proc resolveCodeLens*(cfg: Config; lens: CodeLens): CodeLens =
  ## codeLens/resolve. Titles are already computed eagerly in `codeLenses`
  ## (cheap now that counting is a single index walk), so resolution is an
  ## identity passthrough — we keep the endpoint so the client's
  ## `resolveProvider: true` contract is honoured and future lazy work has a
  ## home. Defensive: any failure returns the lens untouched.
  try:
    result = lens
  except CatchableError:
    result = lens
