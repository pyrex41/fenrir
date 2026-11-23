import std/[os, strutils]

type
  Phase = enum highLength, lowLength, readKey, payload
  Aggregate = object
    records, bytes, sum: uint64

proc reject(offset: uint64) =
  stderr.writeLine("reject ", offset)
  quit(1)

proc process(chunk: int) =
  var buffer = newSeq[uint8](chunk)
  var groups: array[64, Aggregate]
  var phase = highLength
  var offset: uint64
  var remaining, key: int
  while true:
    let n = stdin.readBuffer(addr buffer[0], chunk)
    if n == 0: break
    var i = 0
    while i < n:
      let b = int(buffer[i])
      var consumed = 1
      case phase
      of highLength:
        remaining = b shl 8
        phase = lowLength
      of lowLength:
        remaining += b
        if remaining == 0: reject(offset - 1)
        phase = readKey
      of readKey:
        if b >= groups.len: reject(offset)
        key = b
        inc groups[key].records
        dec remaining
        phase = if remaining == 0: highLength else: payload
      of payload:
        consumed = min(n - i, remaining)
        var sum = 0'u64
        for j in i ..< i + consumed: sum += uint64(buffer[j])
        groups[key].sum += sum
        groups[key].bytes += uint64(consumed)
        remaining -= consumed
        if remaining == 0: phase = highLength
      i += consumed
      offset += uint64(consumed)
  if phase != highLength: reject(offset)
  for k, group in groups:
    if group.records > 0:
      echo k, " ", group.records, " ", group.bytes, " ", group.sum

if paramCount() > 1: quit(2)
var chunk = 8192
if paramCount() == 1:
  try: chunk = parseInt(paramStr(1))
  except ValueError: quit(2)
if chunk notin 1..65536: quit(2)
process(chunk)
