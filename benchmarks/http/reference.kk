module reference
import std/os/env
import std/time/timer
import std/time/duration

alias head = vector<int>
alias reply = (int,int,int,int)

fun lower(c:int)
  if c >= 65 && c <= 90 then c + 32 else c

fun token(c:int)
  (c >= 48 && c <= 57) || (lower(c) >= 97 && lower(c) <= 122) ||
    [33,35,36,37,38,39,42,43,45,46,94,95,96,124,126].any(fn(x) x == c)

fun white(c:int)
  c == 32 || c == 9

fun scan(h:head, i:int, end:int, test:int -> bool): <div,exn> int
  if i < end && test(h[i]) then scan(h,i + 1,end,test) else i

fun trim-end(h:head, i:int, end:int): <div,exn> int
  if end > i && white(h[end - 1]) then trim-end(h,i,end - 1) else end

fun same(h:head, i:int, end:int, word:list<char>, fold:bool): <div,exn> bool
  match word
    Nil -> i == end
    Cons(c,cs) -> i < end && (if fold then lower(h[i]) else h[i]) == c.int && same(h,i + 1,end,cs,fold)

fun closes(h:head,i:int,end:int): <div,exn> bool
  val comma = scan(h,i,end,fn(c) c != 44)
  val start = scan(h,i,comma,white)
  same(h,start,trim-end(h,start,comma),"close".list,True) ||
    (comma < end && closes(h,comma + 1,end))

fun headers(h:head,i:int,path:int,host:bool,close:bool): <div,exn> reply
  val n = h.length
  val bad = (400,1,0,0)
  if i + 2 == n && host && h[i] == 13 && h[i + 1] == 10 then {
    val flag = if close then 1 else 0
    if path == 5 then (200,flag,0,0)
    elif same(h,4,path,"/status".list,False) then (200,flag,-1,0)
    elif path > 11 && same(h,4,11,"/items/".list,False) &&
         scan(h,11,path,fn(c) c >= 48 && c <= 57) == path then (200,flag,11,path - 11)
    else (404,flag,0,0)
  } else {
    val colon = scan(h,i,n,token)
    if colon == i || colon >= n || h[colon] != 58 then bad else {
      val start = colon + 1
      val end = scan(h,start,n,fn(c) c == 9 || (c >= 32 && c <= 126))
      if end + 2 > n || h[end] != 13 || h[end + 1] != 10 then bad
      elif same(h,i,colon,"host".list,True) then {
        if host || scan(h,start,end,white) == end then bad else headers(h,end + 2,path,True,close)
      }
      elif same(h,i,colon,"content-length".list,True) || same(h,i,colon,"transfer-encoding".list,True) then bad
      else headers(h,end + 2,path,host,close || (same(h,i,colon,"connection".list,True) && closes(h,start,end)))
    }
  }

fun route(h:head): <div,exn> reply
  val n = h.length
  if n > 8192 then (431,1,0,0)
  elif n < 5 || !same(h,0,5,"GET /".list,False) then (400,1,0,0)
  else {
    val end = scan(h,4,n,fn(c) c > 32 && c <= 126)
    if end + 11 <= n && same(h,end,end + 11," HTTP/1.1\r\n".list,False)
      then headers(h,end + 11,end,False,False) else (400,1,0,0)
  }

fun nibble(c:char)
  if c.int <= 57 then c.int - 48 else c.int - 87

fun decode(xs:list<char>, acc:list<int>): div head
  match xs
    Cons(a,Cons(b,rest)) -> decode(rest,Cons(16 * nibble(a) + nibble(b),acc))
    _ -> acc.reverse.vector

fun repeat-cases(n:int, cases:list<(head,reply)>, acc:int): <div,exn> int
  if n <= 0 then acc else {
    val count = cases.foldl(0,fn(total,item) {
      val (h,expected) = item
      val (a,b,c,d) = route(h)
      val (w,x,y,z) = expected
      if a == w && b == x && c == y && d == z then total + 1 else total
    })
    repeat-cases(n - 1,cases,acc + count)
  }
