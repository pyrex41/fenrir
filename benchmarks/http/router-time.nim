include reference
import std/[monotimes, times, json]
let rounds = parseInt(paramStr(1))
var cases: seq[tuple[head, status, kind, body: string, close: bool]]
for row in parseFile(paramStr(2)):
  cases.add((readFile(row[0].getStr), row[1].getStr, row[2].getStr,
             row[3].getStr, row[4].getBool))
let start = getMonoTime()
var count = 0
for n in 0..<rounds:
  for item in cases:
    let r = route(item.head)
    if (r.status, r.kind, r.body, r.close) != (item.status, item.kind, item.body, item.close):
      quit(1)
    inc count
echo count, " ", (getMonoTime() - start).inNanoseconds
