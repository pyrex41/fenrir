\\ PROPOSED, UNQUALIFIED. Load after ../pure-call-machine.shen and i64.shen.
\\ Redefines only the three places where the registered pure-call model uses
\\ host integers for language values or identifiers, so that I64 values and
\\ IDs travel as canonical decimal strings. Every other transition is the
\\ registered model's, unchanged.

\\ Capture order: IDs are unsigned canonical decimal strings, ordered numerically.
(define tc0.pc.insert
 Id [] -> [Id]
 Id [Id | Rest] -> [Id | Rest]
 Id [X | Rest] -> [Id X | Rest] where (< (tc0.i64.compare Id X) 0)
 Id [X | Rest] -> [X | (tc0.pc.insert Id Rest)])

(define tc0.pc.index
 Os N -> [ok (str (nth (+ N 1) Os))] where (and (>= N 0) (< N (length Os)))
 _ _ -> [trap bounds])

(define tc0.pc.pure
 not [[bool B]] -> [ok-bool (not B)]
 lt [[int A] [int B]] -> [ok-bool (< (tc0.i64.compare A B) 0)]
 le [[int A] [int B]] -> [ok-bool (<= (tc0.i64.compare A B) 0)]
 gt [[int A] [int B]] -> [ok-bool (> (tc0.i64.compare A B) 0)]
 ge [[int A] [int B]] -> [ok-bool (>= (tc0.i64.compare A B) 0)]
 eq [A B] -> [ok-bool (= A B)]
 bytes_length [[bytes Os]] -> [ok (str (length Os))]
 bytes_concat [[bytes A] [bytes B]] -> [ok-value [bytes (append A B)]]
 bytes_index [[bytes Os] [int I]] -> (tc0.pc.index Os (tc0.i64.small I))
 Op Values -> (tc0.arithmetic Op (tc0.pc.numbers Values)))
