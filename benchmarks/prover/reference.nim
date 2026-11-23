import std/[os, strutils]

type
  Formula = ref object
    op: char
    left, right: Formula
  Signed = tuple[positive: bool, term: Formula]
  Outcome = enum proof, model, exhausted

proc parse(tokens: seq[string], pos: var int): Formula =
  if pos >= tokens.len or tokens[pos].len != 1:
    raise newException(ValueError, "expected formula token")
  result = Formula(op: tokens[pos][0])
  inc pos
  case result.op
  of '!': result.left = parse(tokens, pos)
  of '&', '|', '>':
    result.left = parse(tokens, pos)
    result.right = parse(tokens, pos)
  of 'a'..'z': discard
  else: raise newException(ValueError, "unknown token")

proc search(queue: seq[Signed], head: int, pos, neg: uint32,
            fuel: var int, witness: var string): Outcome =
  if fuel == 0:
    witness = "-"
    return exhausted
  dec fuel
  if head == queue.len:
    witness = $pos
    return model
  let (sign, term) = queue[head]
  case term.op
  of 'a'..'z':
    let bit = 1'u32 shl (ord(term.op) - ord('a'))
    let opposite = if sign: neg else: pos
    if (opposite and bit) != 0:
      witness.add 'x'
      return proof
    witness.add 's'
    if sign: return search(queue, head + 1, pos or bit, neg, fuel, witness)
    return search(queue, head + 1, pos, neg or bit, fuel, witness)
  of '!':
    witness.add 's'
    return search(queue & @[(not sign, term.left)], head + 1, pos, neg, fuel, witness)
  else:
    let leftSign = if term.op == '>': not sign else: sign
    let first: Signed = (leftSign, term.left)
    let second: Signed = (sign, term.right)
    if (term.op == '&') == sign:
      witness.add 's'
      return search(queue & @[first, second], head + 1, pos, neg, fuel, witness)
    witness.add 'b'
    let firstResult = search(queue & @[first], head + 1, pos, neg, fuel, witness)
    if firstResult != proof: return firstResult
    return search(queue & @[second], head + 1, pos, neg, fuel, witness)

proc verify(queue: seq[Signed], head: int, pos, neg: uint32,
            tape: string, cursor: var int): bool =
  if cursor == tape.len or head == queue.len: return false
  let rule = tape[cursor]
  inc cursor
  let (sign, term) = queue[head]
  case term.op
  of 'a'..'z':
    let bit = 1'u32 shl (ord(term.op) - ord('a'))
    if ((if sign: neg else: pos) and bit) != 0: return rule == 'x'
    if rule != 's': return false
    if sign: return verify(queue, head + 1, pos or bit, neg, tape, cursor)
    return verify(queue, head + 1, pos, neg or bit, tape, cursor)
  of '!':
    return rule == 's' and verify(queue & @[(not sign, term.left)], head + 1,
                                  pos, neg, tape, cursor)
  else:
    let first: Signed = ((if term.op == '>': not sign else: sign), term.left)
    let second: Signed = (sign, term.right)
    if (term.op == '&') == sign:
      return rule == 's' and verify(queue & @[first, second], head + 1, pos, neg, tape, cursor)
    return rule == 'b' and verify(queue & @[first], head + 1, pos, neg, tape, cursor) and
                           verify(queue & @[second], head + 1, pos, neg, tape, cursor)

proc verifyProof(goal: Formula, tape: string): bool =
  var cursor = 0
  verify(@[(false, goal)], 0, 0, 0, tape, cursor) and cursor == tape.len

when not defined(proverBenchmark):
  for line in lines(paramStr(1)):
    let tokens = line.splitWhitespace()
    let budget = parseInt(tokens[2])
    var cursor = 3
    let goal = parse(tokens, cursor)
    doAssert cursor == tokens.len and budget >= 0
    var fuel = budget
    var witness = ""
    let status = search(@[(false, goal)], 0, 0, 0, fuel, witness)
    doAssert $status == tokens[1]
    if status == proof:
      doAssert verifyProof(goal, witness)
      doAssert not verifyProof(goal, witness[0 ..< witness.high])
      doAssert not verifyProof(goal, witness & "x")
      doAssert not verifyProof(goal, witness[0 ..< witness.high] & "?")
    echo tokens[0], " ", status, " ", budget - fuel, " ", witness
