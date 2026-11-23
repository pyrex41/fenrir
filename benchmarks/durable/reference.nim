import std/[json, strutils]

proc integer(n: int64): JsonNode = %*["int", $n]

proc data(typ, constructor: string, fields: varargs[JsonNode]): JsonNode =
  result = %*["data", typ, constructor]
  for field in fields: result.add field

proc transaction(op, tenant, key, digest: int): JsonNode =
  let k = integer(key)
  let d = integer(digest)
  let cap = data("Cap", "Tenant", integer(tenant))
  var writes = data("Writes", "Done")
  if op == 0:
    let payload = %*["bytes", toHex(digest, 2).toLowerAscii()]
    writes = data("Writes", "Then", data("Write", "RecordKey", k, d), writes)
    writes = data("Writes", "Then", data("Write", "PutReport", d, payload), writes)
    writes = data("Writes", "Then", data("Write", "StageJob"), writes)
    return data("Tx", "Tx", cap, data("Guard", "Once", k), writes)
  let ok = %*["bool", digest == 1]
  writes = data("Writes", "Then", data("Write", "Finish", k, ok), writes)
  return data("Tx", "Tx", cap, data("Guard", "Pending", k), writes)

proc handle(p: string): JsonNode =
  let isReply = p[0].ord == 2
  let start = int(isReply)
  if p.len < start + 4: raise newException(ValueError, "short command")
  let opcode = p[start].ord
  let tenant = p[start + 1].ord
  let wide = opcode in 3..4
  let last = start + (if wide: 10 else: 3)
  if p.len <= last or opcode notin {0,1,3,4} or tenant > 1:
    raise newException(ValueError, "invalid command header")
  var key = 0
  if (wide and p[start + 2].ord >= 128) or (not wide and p[start + 2].ord > 1):
    raise newException(ValueError, "invalid key")
  for i in start+2..<last: key = (key shl 8) or p[i].ord
  let digest = p[last].ord
  let command = if wide: opcode - 3 else: opcode
  if digest > 1: raise newException(ValueError, "invalid digest")
  if not isReply and p.len == last+1: return transaction(command, tenant, key, digest)
  let body = last+1
  if isReply and p.len > body:
    let reply = p[body].ord
    if p.len == body+1 and reply in 2..3:
      return data("Response", if command == 1: "Delivered" else: "Refused")
    if p.len == body+42 and command == 0 and reply in 0..1:
      if reply == 1 and digest != p[body+1].ord:
        return data("Response", "Conflict", integer(tenant), integer(key))
      var receipt = data("Receipt", "Receipt")
      for i in 0..<5:
        var word: uint64 = 0
        for j in 0..<8: word = (word shl 8) or uint64(p[body + 2 + 8*i + j].ord)
        receipt.add integer(cast[int64](word))
      return data("Response", "Accepted", receipt)
  raise newException(ValueError, "invalid reference command")

while true:
  var header: array[2, uint8]
  let count = stdin.readBuffer(addr header[0], 2)
  if count == 0: break
  if count != 2: raise newException(IOError, "truncated packet length")
  let size = int(header[0]) * 256 + int(header[1])
  if size notin 1..64: raise newException(ValueError, "invalid packet length")
  var packet = newString(size)
  if stdin.readBuffer(addr packet[0], size) != size:
    raise newException(IOError, "truncated packet")
  let reply = $handle(packet)
  stdout.write(char(reply.len div 256), char(reply.len mod 256), reply)
  stdout.flushFile()
