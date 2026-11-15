\\ Accepted-job contract (application example, stage A1): the authoritative,
\\ executable statement. Contract text: spec/service/ACCEPTED_JOB.md. Properties:
\\ accepted-job-properties.shen. Written to match verification/service/AcceptedJob.v
\\ by reading; that correspondence is NOT proved.
\\
\\ A tenant-scoped request atomically writes business state (a report), records a
\\ durable job, records its retry result (the request-key entry and receipt), and
\\ only then can be answered with an acceptance.
\\
\\ System state  [sys Stores Outbox Trace]
\\   Stores  one durable store per tenant 0 .. N-1, [store Reports Jobs Keys Next]
\\           Reports [Id Digest]; Jobs [Id Report Status], Status pending|done|failed;
\\           Keys [Key Digest Receipt]; Next the id counter. Newest entries first.
\\   Outbox  volatile set of computed responses, in canonical order (svc.add-event)
\\   Trace   responses clients have been told, most recent first
\\ Receipt [receipt Tenant Key Digest Report Job]. Event [accepted Receipt] | [conflict Tenant Key].
\\ Labels  [submit T K D] | [complete T J Ok] | [respond Event] | [crash]
\\ svc.step Label Sys gives [ok Sys' Response], Response an event or none, or disabled.

\\ ---------- durable data ----------

(define svc.empty-store
  -> [store [] [] [] 0])

(define svc.empty-stores
  0 -> []
  N -> [(svc.empty-store) | (svc.empty-stores (- N 1))])

(define svc.initial
  Tenants -> [sys (svc.empty-stores Tenants) [] []])

(define svc.reports
  [store Reports _ _ _] -> Reports)

(define svc.jobs
  [store _ Jobs _ _] -> Jobs)

(define svc.keys
  [store _ _ Keys _] -> Keys)

(define svc.next
  [store _ _ _ Next] -> Next)

(define svc.stores
  [sys Stores _ _] -> Stores)

(define svc.outbox
  [sys _ Outbox _] -> Outbox)

(define svc.trace
  [sys _ _ Trace] -> Trace)

\\ Tenant T's store; tenants are numbered from 0.
(define svc.store
  T Stores -> (nth (+ T 1) Stores))

(define svc.tenant?
  T Stores -> (and (integer? T) (and (>= T 0) (< T (length Stores)))))

(define svc.replace
  0 X [_ | Ys] -> [X | Ys]
  N X [Y | Ys] -> [Y | (svc.replace (- N 1) X Ys)])

\\ The key entry for K: [some Digest Receipt], or none.
(define svc.lookup
  K [] -> none
  K [[K D Rc] | _] -> [some D Rc]
  K [_ | Rest] -> (svc.lookup K Rest))

\\ ---------- the request transaction ----------

\\ The whole request as a pure function on tenant T's store: [Store' Result],
\\ Result [accepted Receipt] or conflict. The receipt is created here and nowhere
\\ else: holding one is evidence of this commit.
(define svc.submit
  T K D Store -> (svc.submit-with (svc.lookup K (svc.keys Store)) T K D Store))

(define svc.submit-with
  [some D Rc] _ _ D Store -> [Store [accepted Rc]]
  [some _ _] _ _ _ Store -> [Store conflict]
  none T K D [store Reports Jobs Keys N] ->
    (let Rc [receipt T K D N N]
      [[store [[N D] | Reports] [[N N pending] | Jobs] [[K D Rc] | Keys] (+ N 1)] [accepted Rc]]))

\\ ---------- worker delivery, with durable deduplication ----------

\\ Only a pending job moves.
(define svc.finish
  J true [J R pending] -> [J R done]
  J false [J R pending] -> [J R failed]
  _ _ Entry -> Entry)

(define svc.complete
  J Ok [store Reports Jobs Keys N] -> [store Reports (map (/. E (svc.finish J Ok E)) Jobs) Keys N])

\\ ---------- responses ----------

(define svc.reply
  _ _ [accepted Rc] -> [accepted Rc]
  T K conflict -> [conflict T K])

(define svc.event?
  [accepted [receipt _ _ _ _ _]] -> true
  [conflict _ _] -> true
  _ -> false)

\\ The outbox is a set. Rocq's outbox is a list read only by membership and
\\ cleared by a crash, so order and repetition are unobservable; the canonical
\\ order here is: accepted before conflict, then field by field.
(define svc.event-key
  [accepted [receipt T K D R J]] -> [0 T K D R J]
  [conflict T K] -> [1 T K])

(define svc.key<
  [A | As] [B | Bs] -> (or (< A B) (and (= A B) (svc.key< As Bs)))
  _ _ -> false)

(define svc.add-event
  E [] -> [E]
  E [E | Es] -> [E | Es]
  E [F | Fs] -> [E F | Fs] where (svc.key< (svc.event-key E) (svc.event-key F))
  E [F | Fs] -> [F | (svc.add-event E Fs)])

\\ ---------- the system ----------

(define svc.step
  [submit T K D] [sys Stores Outbox Trace] ->
    (let Done (svc.submit T K D (svc.store T Stores))
         Event (svc.reply T K (hd (tl Done)))
      [ok [sys (svc.replace T (hd Done) Stores) (svc.add-event Event Outbox) Trace] Event])
    where (svc.tenant? T Stores)
  [complete T J Ok] [sys Stores Outbox Trace] ->
    [ok [sys (svc.replace T (svc.complete J Ok (svc.store T Stores)) Stores) Outbox Trace] none]
    where (svc.tenant? T Stores)
  [respond E] [sys Stores Outbox Trace] ->
    [ok [sys Stores Outbox [E | Trace]] E]
    where (and (svc.event? E) (element? E Outbox))
  [crash] [sys Stores _ Trace] -> [ok [sys Stores [] Trace] none]
  _ _ -> disabled)

\\ ---------- the step alphabet over finite parameters ----------

\\ Params is [Tenants Keys Digests]: the counts of each. Every submit; every
\\ delivery of an id in use or the one next unused id (all unused ids have the
\\ same successor), with both outcomes; every response in the outbox; crash.
(define svc.upto
  N N -> []
  I N -> [I | (svc.upto (+ I 1) N)])

(define svc.submit-labels
  Tenants Keys Digests ->
    (mapcan (/. T (mapcan (/. K (map (/. D [submit T K D]) (svc.upto 0 Digests))) (svc.upto 0 Keys)))
            (svc.upto 0 Tenants)))

(define svc.complete-labels
  T [] -> []
  T [Store | Stores] ->
    (append (mapcan (/. J [[complete T J true] [complete T J false]]) (svc.upto 0 (+ (svc.next Store) 1)))
            (svc.complete-labels (+ T 1) Stores)))

(define svc.respond-labels
  [] -> []
  [E | Es] -> [[respond E] | (svc.respond-labels Es)] where (svc.event? E)
  [_ | Es] -> (svc.respond-labels Es))

(define svc.labels
  [Tenants Keys Digests] [sys Stores Outbox _] ->
    (append (svc.submit-labels Tenants Keys Digests)
            (svc.complete-labels 0 Stores)
            (svc.respond-labels Outbox)
            [[crash]]))
