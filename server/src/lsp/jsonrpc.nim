## Content-Length framed JSON-RPC 2.0 transport over blocking File handles.
##
## The LSP base protocol frames each message with HTTP-like headers:
##   Content-Length: <n>\r\n
##   \r\n
##   <n bytes of UTF-8 JSON>

import std/[json, options, strutils]

type
  Message* = object
    ## A decoded JSON-RPC message. Requests have `id` + `meth`; notifications
    ## have `meth` and no `id`; responses have `id` + (`result` or `error`).
    id*: JsonNode          ## null when absent (notification)
    meth*: string          ## "" when absent (response)
    params*: JsonNode      ## nil when absent
    raw*: JsonNode         ## the full decoded object

proc isRequest*(m: Message): bool = m.meth.len > 0 and m.id != nil and m.id.kind != JNull
proc isNotification*(m: Message): bool = m.meth.len > 0 and (m.id == nil or m.id.kind == JNull)

proc readMessage*(inp: File): Option[Message] =
  ## Reads one framed message. Returns none() on EOF / malformed stream.
  var contentLength = -1
  # --- headers ---
  while true:
    var line = ""
    if not inp.readLine(line):
      return none(Message)          # EOF
    if line.len == 0:
      break                          # blank line terminates headers
    let idx = line.find(':')
    if idx > 0:
      let name = line[0 ..< idx].strip.toLowerAscii
      let val = line[idx+1 .. ^1].strip
      if name == "content-length":
        contentLength = parseInt(val)
  if contentLength < 0:
    return none(Message)
  # --- body ---
  var body = newString(contentLength)
  if contentLength > 0:
    let got = inp.readBuffer(addr body[0], contentLength)
    if got != contentLength:
      return none(Message)
  var node: JsonNode
  try:
    node = parseJson(body)
  except CatchableError:
    # Body was fully consumed (exactly Content-Length bytes), so the stream is
    # still framed — a bad JSON body is recoverable. Return an empty message the
    # dispatcher safely ignores, rather than none() (which the loop treats as EOF
    # and would exit on). Only a real EOF / framing loss ends the server.
    return some(Message(raw: nil, meth: "", id: nil, params: nil))
  var m = Message(raw: node)
  m.id = node{"id"}
  m.params = node{"params"}
  if node.hasKey("method"):
    m.meth = node["method"].getStr
  some(m)

proc writeMessage*(outp: File; msg: JsonNode) =
  ## Serialize + frame + flush a single message.
  let body = $msg
  outp.write("Content-Length: " & $body.len & "\r\n\r\n")
  outp.write(body)
  outp.flushFile()

# --- response / notification builders ---

proc response*(id: JsonNode; res: JsonNode): JsonNode =
  result = %*{"jsonrpc": "2.0", "id": id, "result": res}

proc errorResponse*(id: JsonNode; code: int; message: string): JsonNode =
  let idv = if id == nil: newJNull() else: id
  result = %*{"jsonrpc": "2.0", "id": idv,
              "error": {"code": code, "message": message}}

proc notification*(meth: string; params: JsonNode): JsonNode =
  result = %*{"jsonrpc": "2.0", "method": meth, "params": params}

# JSON-RPC / LSP error codes we use.
const
  ParseError* = -32700
  InvalidRequest* = -32600
  MethodNotFound* = -32601
  InvalidParams* = -32602
  InternalError* = -32603
  ServerNotInitialized* = -32002
