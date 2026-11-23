module reference
import std/os/env
import std/num/int32
import std/num/int64

extern import
  c file "koka-io.c"

extern read-chunk(n:int32): console int32
  c inline "stream_read(#1)"

extern byte-at(i:int32): console int32
  c inline "stream_buffer[#1]"

extern reject(offset:int64): console ()
  c inline "(fprintf(stderr,\"reject %lld\\n\",(long long)#1),exit(1),kk_Unit)"

extern usage(): console ()
  c inline "(exit(2),kk_Unit)"

fun sum-range(i:int32,end:int32,sum:int32): <div,console> int32
  if i >= end then sum else sum-range(i + 1.int32,end,sum + byte-at(i))

fun main()
  val args = get-args()
  val chunk = args.head("8192").parse-int.default(0)
  if args.length > 1 || chunk < 1 || chunk > 65536 then usage()
  var records := vector(64,0)
  var sizes := vector(64,0)
  var sums := vector(64,0)
  var phase := 0
  var remaining := 0
  var key := 0
  var offset := 0
  var n := read-chunk(chunk.int32).int
  var i := 0
  while{ n > 0 } {
    i := 0
    while{ i < n } {
      if phase == 3 then {
        val count = min(remaining,n - i)
        val end = i + count
        sums[key] := sums[key] + sum-range(i.int32,end.int32,0.int32).int
        remaining := remaining - count
        if remaining == 0 then phase := 0
        offset := offset + count
        i := end
      } else {
        val b = byte-at(i.int32).int
        if phase == 0 then {
          remaining := 256 * b
          phase := 1
        } elif phase == 1 then {
          remaining := remaining + b
          if remaining == 0 then reject((offset - 1).int64)
          phase := 2
        } else {
          if b >= 64 then reject(offset.int64)
          key := b
          remaining := remaining - 1
          records[b] := records[b] + 1
          sizes[b] := sizes[b] + remaining
          phase := (if remaining == 0 then 0 else 3)
        }
        offset := offset + 1
        i := i + 1
      }
    }
    n := read-chunk(chunk.int32).int
  }
  if phase != 0 then reject(offset.int64)
  for(64) fn(k) {
    if records[k] > 0 then println(k.show ++ " " ++ records[k].show ++ " " ++ sizes[k].show ++ " " ++ sums[k].show)
  }
