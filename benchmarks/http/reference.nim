import std/[asyncdispatch, asyncnet, os, strutils]

const
  limit = 8192
  maxClients = 64
  timeoutMs = 5000
  tokenChars = {'a'..'z', 'A'..'Z', '0'..'9'} + {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~'}

type Reply = tuple[status, kind, body: string, close: bool]

proc route(head: string): Reply =
  const bad: Reply = ("400 Bad Request", "text/plain", "", true)
  if head.len > limit or (head.len == limit and not head.endsWith("\r\n\r\n")):
    return ("431 Request Header Fields Too Large", "text/plain", "", true)
  if not head.endsWith("\r\n\r\n"): return bad
  let lines = head[0 ..< head.len - 4].split("\r\n")
  let request = lines[0].split(' ')
  if request.len != 3 or request[0] != "GET" or request[2] != "HTTP/1.1": return bad
  let path = request[1]
  if not path.startsWith('/') or not path.allCharsInSet({'!'..'~'}): return bad
  var host, close: bool
  for i in 1 ..< lines.len:
    let colon = lines[i].find(':')
    if colon <= 0: return bad
    let name = lines[i][0 ..< colon]
    if not name.allCharsInSet(tokenChars): return bad
    let raw = lines[i][colon+1 .. ^1]
    if not raw.allCharsInSet({'\t', ' '..'~'}): return bad
    let value = raw.strip(chars = {' ', '\t'})
    case name.toLowerAscii
    of "host":
      if host or value.len == 0: return bad
      host = true
    of "transfer-encoding", "content-length": return bad
    of "connection":
      for token in value.split(','):
        if cmpIgnoreCase(token.strip(chars = {' ', '\t'}), "close") == 0: close = true
    else: discard
  if not host: return bad
  case path
  of "/": return ("200 OK", "text/plain", "fenrir\n", close)
  of "/status": return ("200 OK", "application/json", "{\"ok\":true}\n", close)
  else:
    if path.startsWith("/items/") and path.len > 7:
      let id = path[7 .. ^1]
      if id.allCharsInSet({'0'..'9'}): return ("200 OK", "text/plain", id, close)
    return ("404 Not Found", "text/plain", "", close)

var active: int

proc serve(client: AsyncSocket) {.async.} =
  try:
    var head = newStringOfCap(limit)
    while true:
      let reading = client.recv(limit)
      if not await reading.withTimeout(timeoutMs): return
      let chunk = reading.read()
      if chunk.len == 0: return
      for c in chunk:
        head.add(c)
        if head.len == limit or head.endsWith("\r\n\r\n"):
          let reply = route(head)
          let connection = if reply.close: "close" else: "keep-alive"
          let writing = client.send("HTTP/1.1 " & reply.status & "\r\nContent-Type: " &
            reply.kind & "\r\nContent-Length: " & $reply.body.len & "\r\nConnection: " &
            connection & "\r\n\r\n" & reply.body)
          if not await writing.withTimeout(timeoutMs): return
          writing.read()
          if reply.close: return
          head.setLen(0)
  except OSError:
    discard
  finally:
    client.close()
    dec active

proc main() {.async.} =
  let listener = newAsyncSocket(buffered = false)
  listener.bindAddr(Port(parseInt(paramStr(1))), "127.0.0.1")
  listener.listen()
  stderr.writeLine("127.0.0.1:" & $int(listener.getLocalAddr()[1]))
  while true:
    let client = await listener.accept()
    if active >= maxClients:
      client.close()
    else:
      inc active
      asyncCheck serve(client)

when not defined(routerBenchmark):
  waitFor main()
