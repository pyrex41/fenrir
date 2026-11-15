\\ Accepted-job contract: the properties, as checkable predicates on states and
\\ edges, and the property monitor. Contract text: spec/service/ACCEPTED_JOB.md
\\ section 4 (each check is named there with the Rocq theorem it was written to
\\ match; the correspondence is by reading, not proved). Load accepted-job.shen first.
\\
\\ The predicates read a state only through the shape [sys Stores Outbox Trace].
\\ Two of them (retry.delivery, progress.dischargeable) ask what a further step
\\ would do; they are given the machine's step function, so a mutant is judged by
\\ its own behaviour. Every check returns the list of [Property Check] it violates.

\\ ---------- helpers ----------

(define svcp.all?
  _ [] -> true
  P [X | Xs] -> (and (P X) (svcp.all? P Xs)))

(define svcp.any?
  _ [] -> false
  P [X | Xs] -> (or (P X) (svcp.any? P Xs)))

(define svcp.distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (svcp.distinct? Xs)))

(define svcp.key-set
  [] Acc -> Acc
  [[K _ _] | Rest] Acc -> (svcp.key-set Rest (if (element? K Acc) Acc [K | Acc])))

(define svcp.job?
  _ _ [] -> false
  J R [[J R _] | _] -> true
  J R [_ | Js] -> (svcp.job? J R Js))

(define svcp.terminal?
  done -> true
  failed -> true
  _ -> false)

(define svcp.terminal-job?
  _ _ [] -> false
  J R [[J R St] | Js] -> (or (svcp.terminal? St) (svcp.terminal-job? J R Js))
  J R [_ | Js] -> (svcp.terminal-job? J R Js))

(define svcp.pending-job?
  _ [] -> false
  J [[J _ pending] | _] -> true
  J [_ | Js] -> (svcp.pending-job? J Js))

(define svcp.tenant-of
  [submit T _ _] -> T
  [complete T _ _] -> T
  [internal _ T | _] -> T
  _ -> none)

(define svcp.acceptances
  [] -> []
  [[accepted Rc] | Es] -> [Rc | (svcp.acceptances Es)]
  [_ | Es] -> (svcp.acceptances Es))

(define svcp.flag
  true _ -> []
  false Check -> [Check])

\\ ---------- atomicity: the per-tenant invariant (Rocq: good) ----------

(define svcp.entry-good?
  T K [some D [receipt T K D R J]] Store -> (and (element? [R D] (svc.reports Store)) (svcp.job? J R (svc.jobs Store)))
  _ _ _ _ -> false)

(define svcp.backs?
  N D [some D [receipt _ _ _ N _]] -> true
  _ _ _ -> false)

(define svcp.report-good?
  Store Keys [N D] ->
    (and (< N (svc.next Store))
         (svcp.job? N N (svc.jobs Store))
         (svcp.any? (/. K (svcp.backs? N D (svc.lookup K (svc.keys Store)))) Keys)))

(define svcp.job-good?
  Store [J R _] -> (and (< J (svc.next Store)) (svcp.any? (/. Rep (= (hd Rep) R)) (svc.reports Store))))

(define svcp.good?
  T Store ->
    (let Keys (svcp.key-set (svc.keys Store) [])
      (and (svcp.all? (/. K (svcp.entry-good? T K (svc.lookup K (svc.keys Store)) Store)) Keys)
           (svcp.all? (/. Rep (svcp.report-good? Store Keys Rep)) (svc.reports Store))
           (svcp.all? (/. Job (svcp.job-good? Store Job)) (svc.jobs Store))
           (svcp.distinct? (map (/. Rep (hd Rep)) (svc.reports Store))))))

(define svcp.all-good?
  _ [] -> true
  T [Store | Stores] -> (and (svcp.good? T Store) (svcp.all-good? (+ T 1) Stores)))

\\ ---------- response discipline (Rocq: acceptance_durable, inv) ----------

\\ The receipt is the recorded answer for its tenant, key and digest.
(define svcp.recorded?
  Stores [receipt T K D R J] ->
    (and (svc.tenant? T Stores)
         (= (svc.lookup K (svc.keys (svc.store T Stores))) [some D [receipt T K D R J]]))
  _ _ -> false)

(define svcp.durable-acceptance?
  Stores [receipt T K D R J] ->
    (and (svcp.recorded? Stores [receipt T K D R J])
         (element? [R D] (svc.reports (svc.store T Stores)))
         (svcp.job? J R (svc.jobs (svc.store T Stores))))
  _ _ -> false)

\\ ---------- the property monitor ----------

\\ Issued: every response ever computed, [accepted Receipt] or [conflict T K D],
\\ as a set in a canonical order. A crash does not reset it.
(define svcp.monitor-initial
  -> [])

(define svcp.issued-key
  [accepted [receipt T K D R J]] -> [0 T K D R J]
  [conflict T K D] -> [1 T K D])

(define svcp.add-issued
  E [] -> [E]
  E [E | Es] -> [E | Es]
  E [F | Fs] -> [E F | Fs] where (svc.key< (svcp.issued-key E) (svcp.issued-key F))
  E [F | Fs] -> [F | (svcp.add-issued E Fs)])

(define svcp.monitor-step
  [respond _] _ M -> M
  [submit T K D] [conflict T K] M -> (svcp.add-issued [conflict T K D] M)
  _ [accepted [receipt T K D R J]] M -> (svcp.add-issued [accepted [receipt T K D R J]] M)
  _ _ M -> M)

\\ ---------- state predicates ----------

\\ Progress: every acceptance a client was told can be discharged by one delivery.
(define svcp.dischargeable?
  Step X [receipt T K D R J] ->
    (svcp.all? (/. Ok (svcp.delivered-terminal? (Step [complete T J Ok] X) T J R)) [true false])
  _ _ _ -> false)

(define svcp.delivered-terminal?
  [ok [sys Stores _ _] _] T J R -> (and (svc.tenant? T Stores) (svcp.terminal-job? J R (svc.jobs (svc.store T Stores))))
  _ _ _ _ -> false)

(define svcp.state-violations
  Step _ [sys Stores Outbox Trace] ->
    (append
      (svcp.flag (svcp.all-good? 0 Stores) [atomicity "atomicity.records"])
      (svcp.flag (svcp.all? (/. Rc (svcp.durable-acceptance? Stores Rc)) (svcp.acceptances (append Outbox Trace)))
                 [response "response.durable"])
      (svcp.flag (svcp.all? (/. Rc (svcp.dischargeable? Step [sys Stores Outbox Trace] Rc)) (svcp.acceptances Trace))
                 [progress "progress.dischargeable"])))

\\ ---------- edge predicates ----------

(define svcp.frame?
  _ _ [] [] -> true
  T T [_ | Xs] [_ | Ys] -> (svcp.frame? T (+ T 1) Xs Ys)
  Owner T [X | Xs] [Y | Ys] -> (and (= X Y) (svcp.frame? Owner (+ T 1) Xs Ys))
  _ _ _ _ -> false)

\\ retry.replay: a known key changes nothing and gets the recorded answer.
(define svcp.replay?
  [submit T K D] Xs Ys Resp ->
    (svcp.replay-with (svc.lookup K (svc.keys (svc.store T Xs))) T K D Xs Ys Resp)
    where (svc.tenant? T Xs)
  _ _ _ _ -> true)

(define svcp.replay-with
  none _ _ _ _ _ _ -> true
  [some D0 Rc] T K D Xs Ys Resp ->
    (and (= (svc.store T Xs) (svc.store T Ys))
         (= Resp (if (= D D0) [accepted Rc] [conflict T K]))))

\\ retry.issued: consistent with every response already computed for this key.
(define svcp.issued-consistent?
  [submit T K D] M Xs Ys Resp ->
    (svcp.all? (/. I (svcp.consistent-with I T K D Xs Ys Resp)) M)
    where (svc.tenant? T Xs)
  _ _ _ _ _ -> true)

(define svcp.consistent-with
  [accepted [receipt T K D0 R J]] T K D Xs Ys Resp ->
    (and (= (svc.store T Xs) (svc.store T Ys))
         (= Resp (if (= D D0) [accepted [receipt T K D0 R J]] [conflict T K])))
  [conflict T K D] T K D Xs Ys Resp ->
    (and (= (svc.store T Xs) (svc.store T Ys)) (= Resp [conflict T K]))
  _ _ _ _ _ _ _ -> true)

\\ retry.delivery: delivering the same job again, with either outcome, changes nothing.
(define svcp.redelivery-absorbed?
  Step [complete T J _] Y ->
    (svcp.all? (/. Ok (svcp.same-store? T Y (Step [complete T J Ok] Y))) [true false])
  _ _ _ -> true)

(define svcp.same-store?
  T [sys Ys _ _] [ok [sys Zs _ _] _] -> (= (svc.store T Ys) (svc.store T Zs))
  _ _ _ -> false)

\\ response.commit-before-respond: a client is told only a computed response, and an
\\ acceptance only after its commit.
(define svcp.respond-ok?
  [respond E] [sys Xs XOut XTrace] [sys _ _ YTrace] ->
    (and (element? E XOut) (= YTrace [E | XTrace]) (svcp.respond-commit? E Xs))
  _ _ _ -> true)

(define svcp.respond-commit?
  [accepted Rc] Xs -> (svcp.recorded? Xs Rc)
  _ _ -> true)

\\ recovery: a crash changes no store and no trace, and drops no held obligation of
\\ an acceptance a client was told.
(define svcp.held?
  [sys Stores Outbox _] [receipt T K D R J] ->
    (or (and (svc.tenant? T Stores) (svcp.job? J R (svc.jobs (svc.store T Stores))))
        (element? [job-message T J R] Outbox))
  _ _ -> false)

(define svcp.crash-frame?
  [crash] [sys Xs _ XTrace] [sys Ys _ YTrace] -> (and (= Xs Ys) (= XTrace YTrace))
  _ _ _ -> true)

(define svcp.obligations-kept?
  [crash] X Y -> (svcp.all? (/. Rc (or (not (svcp.held? X Rc)) (svcp.held? Y Rc))) (svcp.acceptances (svc.trace X)))
  _ _ _ -> true)

\\ progress: terminal jobs stay terminal; a delivery leaves its job not pending.
(define svcp.terminal-kept?
  [] [] -> true
  [X | Xs] [Y | Ys] ->
    (and (svcp.all? (/. Job (or (not (svcp.terminal? (nth 3 Job))) (element? Job (svc.jobs Y)))) (svc.jobs X))
         (svcp.terminal-kept? Xs Ys))
  _ _ -> false)

(define svcp.delivery-terminates?
  [complete T J _] [sys Ys _ _] -> (and (svc.tenant? T Ys) (not (svcp.pending-job? J (svc.jobs (svc.store T Ys)))))
  _ _ -> true)

\\ X -Label-> Y with response Resp; M is the monitor at X.
(define svcp.edge-violations
  Step X M Label Y Resp ->
    (let Xs (svc.stores X)
         Ys (svc.stores Y)
      (append
        (svcp.flag (svcp.frame? (svcp.tenant-of Label) 0 Xs Ys) [authority "authority.frame"])
        (svcp.flag (svcp.respond-ok? Label X Y) [response "response.commit-before-respond"])
        (svcp.flag (svcp.replay? Label Xs Ys Resp) [retry "retry.replay"])
        (svcp.flag (svcp.issued-consistent? Label M Xs Ys Resp) [retry "retry.issued"])
        (svcp.flag (svcp.redelivery-absorbed? Step Label Y) [retry "retry.delivery"])
        (svcp.flag (svcp.crash-frame? Label X Y) [recovery "recovery.crash-frame"])
        (svcp.flag (svcp.obligations-kept? Label X Y) [recovery "recovery.obligations"])
        (svcp.flag (svcp.terminal-kept? Xs Ys) [progress "progress.terminal-stable"])
        (svcp.flag (svcp.delivery-terminates? Label Y) [progress "progress.delivery-terminates"]))))

\\ Every check, for reporting.
(define svcp.checks
  -> [[authority "authority.frame"]
      [atomicity "atomicity.records"]
      [response "response.durable"] [response "response.commit-before-respond"]
      [retry "retry.replay"] [retry "retry.issued"] [retry "retry.delivery"]
      [recovery "recovery.crash-frame"] [recovery "recovery.obligations"]
      [progress "progress.dischargeable"] [progress "progress.terminal-stable"] [progress "progress.delivery-terminates"]])

(define svcp.properties
  -> [authority atomicity response retry recovery progress])
