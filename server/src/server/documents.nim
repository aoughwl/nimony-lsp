## In-memory text document with LSP<->byte-offset position mapping.
##
## LSP columns are UTF-16 code units. We keep the raw UTF-8 text plus a cached
## index of line-start byte offsets, and translate between the two.

import std/[strutils, unicode]
import ../lsp/protocol

type
  Document* = ref object
    uri*: string
    languageId*: string
    version*: int
    text*: string
    lineStarts: seq[int]   ## byte offset of the start of each line

proc computeLineStarts(text: string): seq[int] =
  result = @[0]
  for i in 0 ..< text.len:
    if text[i] == '\n':
      result.add(i + 1)

proc newDocument*(uri, languageId: string; version: int; text: string): Document =
  Document(uri: uri, languageId: languageId, version: version,
           text: text, lineStarts: computeLineStarts(text))

proc update*(d: Document; version: int; text: string) =
  ## Full-document replacement (full-sync path).
  d.version = version
  d.text = text
  d.lineStarts = computeLineStarts(text)

proc lineCount*(d: Document): int = d.lineStarts.len

proc utf16Len(s: string): int =
  ## number of UTF-16 code units in a UTF-8 string
  for r in s.runes:
    result += (if r.int32 > 0xFFFF: 2 else: 1)

proc offsetAt*(d: Document; pos: Position): int =
  ## Byte offset in `d.text` for an LSP position. Clamps out-of-range input.
  if d.lineStarts.len == 0: return 0
  let line = clamp(pos.line, 0, d.lineStarts.len - 1)
  let lineStart = d.lineStarts[line]
  let lineEnd =
    if line + 1 < d.lineStarts.len: d.lineStarts[line + 1]
    else: d.text.len
  # walk runes counting UTF-16 units until we reach pos.character
  var utf16 = 0
  var i = lineStart
  while i < lineEnd:
    if utf16 >= pos.character: break
    let r = d.text.runeAt(i)
    let sz = r.size
    utf16 += (if r.int32 > 0xFFFF: 2 else: 1)
    i += sz
  result = i

proc applyChange*(d: Document; version: int; r: Range; newText: string) =
  ## Incremental change: splice `newText` over the byte span the LSP `range`
  ## denotes. `offsetAt` clamps out-of-range input, so this is safe against a
  ## client that sends a stale range.
  let startOff = d.offsetAt(r.start)
  let endOff = max(startOff, d.offsetAt(r.`end`))
  d.text = d.text[0 ..< startOff] & newText & d.text[endOff .. ^1]
  d.version = version
  d.lineStarts = computeLineStarts(d.text)

proc positionAt*(d: Document; offset: int): Position =
  ## LSP position for a byte offset in `d.text`.
  let off = clamp(offset, 0, d.text.len)
  # binary search for the line
  var lo = 0
  var hi = d.lineStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if d.lineStarts[mid] <= off: lo = mid
    else: hi = mid - 1
  result.line = lo
  let lineStart = d.lineStarts[lo]
  result.character = utf16Len(d.text[lineStart ..< off])

proc lineText*(d: Document; line: int): string =
  if line < 0 or line >= d.lineStarts.len: return ""
  let s = d.lineStarts[line]
  let e = if line + 1 < d.lineStarts.len: d.lineStarts[line + 1] else: d.text.len
  result = d.text[s ..< e].strip(leading = false, trailing = true, chars = {'\n', '\r'})

proc wordAt*(d: Document; pos: Position): string =
  ## Identifier surrounding the position (Nim identifier chars).
  const idChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  let off = d.offsetAt(pos)
  var s = off
  while s > 0 and d.text[s-1] in idChars: dec s
  var e = off
  while e < d.text.len and d.text[e] in idChars: inc e
  result = d.text[s ..< e]
