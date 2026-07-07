## Minimal file:// URI <-> filesystem path conversion (RFC 8089, POSIX).

import std/[strutils, os]

proc percentDecode(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      result.add(chr(parseHexInt(s[i+1 .. i+2])))
      inc i, 3
    else:
      result.add(s[i])
      inc i

proc percentEncode(s: string): string =
  const unreserved = {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'}
  result = newStringOfCap(s.len)
  for c in s:
    if c in unreserved:
      result.add(c)
    else:
      result.add('%')
      result.add(toHex(ord(c), 2))

proc uriToPath*(uri: string): string =
  ## `file:///home/x%20y.nim` -> `/home/x y.nim`. Non-file URIs returned as-is.
  if not uri.startsWith("file://"):
    return uri
  var rest = uri[len("file://") .. ^1]
  # strip authority (host) if present: file://host/path
  if rest.len > 0 and rest[0] != '/':
    let slash = rest.find('/')
    rest = if slash >= 0: rest[slash .. ^1] else: "/"
  result = percentDecode(rest)

proc pathToUri*(path: string): string =
  ## `/home/x y.nim` -> `file:///home/x%20y.nim`.
  var p = path
  if not p.isAbsolute:
    p = absolutePath(p)
  result = "file://" & percentEncode(p)
