\\ Accepted-job upgrade contract: the properties, as checkable predicates on states and
\\ edges, and the property monitor. Contract text: spec/service/UPGRADE.md section 6.
\\ Load models/service/accepted-job.shen, models/service/accepted-job-properties.shen
\\ (A1, unchanged) and upgrade.shen first.
\\
\\ A1's predicates are reused on the v1 view of a state (sua.v1-sys): a job without its
\\ attempts, a receipt without its version. The predicates that ask what a further step
\\ would do are given the machine's own step function, so a mutant is judged by its
\\ own behaviour. Every check returns the list of [Property Check] it violates.

\\ ---------- helpers ----------

(define sup.flag
  true _ -> []
  false Check -> [Check])

(define sup.u
  [up4 U _] -> U)

(define sup.sys
  [up4 _ Sys] -> Sys)

(define sup.stores
  [up4 _ [sys Stores _ _]] -> Stores)

(define sup.outbox
  [up4 _ [sys _ Outbox _]] -> Outbox)

(define sup.trace
  [up4 _ [sys _ _ Trace]] -> Trace)

(define sup.acceptances
  [] -> []
  [[accepted Rc] | Es] -> [Rc | (sup.acceptances Es)]
  [_ | Es] -> (sup.acceptances Es))

\\ The request a label makes the store answer: a landing's run's request; any other
\\ label itself.
(define sup.effective
  [land I] X -> (let Runs (sua.runs (sup.outbox X))
                  (if (and (integer? I) (< I (length Runs))) (nth 3 (nth (+ I 1) Runs)) [land I]))
  L _ -> L)

(define sup.tenant-of
  [submit T _ _] -> T
  [complete T _ _] -> T
  [internal _ T | _] -> T
  _ -> none)

(define sup.receipt-fields
  [receipt T K D R J | _] -> [T K D R J]
  _ -> [none none none none none])

(define sup.tenant-store
  T Stores -> (if (svc.tenant? T Stores) (svc.store T Stores) none))

(define sup.jobs-of
  none -> []
  Store -> (svc.jobs Store))

\\ ---------- the schema a store is in (UPGRADE.md section 6, version.readable) ----------

(define sup.job1?
  [J R St] -> (and (integer? J) (integer? R) (element? St [pending done failed]))
  _ -> false)

(define sup.job2?
  [J R pending 0] -> (and (integer? J) (integer? R))
  [J R St 1] -> (and (integer? J) (integer? R) (element? St [done failed]))
  _ -> false)

(define sup.key-in?
  Versions [K D Rc] -> (element? (sua.receipt-version Rc) Versions)
  _ _ -> false)

(define sup.readable?
  1 Store -> (and (svcp.all? (/. J (sup.job1? J)) (svc.jobs Store))
                  (svcp.all? (/. K (sup.key-in? [1] K)) (svc.keys Store)))
  2 Store -> (and (svcp.all? (/. J (sup.job2? J)) (svc.jobs Store))
                  (svcp.all? (/. K (sup.key-in? [1 2] K)) (svc.keys Store))))

\\ ---------- the property monitor ----------

\\ Issued: every response ever computed for a submit, [accepted Rc] (either
\\ representation) or [conflict T K D], as a set in a canonical order; a crash does not
\\ reset it (A1 section 5).
(define sup.issued-key
  [accepted Rc] -> (append [0] (sup.receipt-fields Rc) [(sua.receipt-version Rc)])
  [conflict T K D] -> [1 T K D 0 0 0 0])

(define sup.add-issued
  E [] -> [E]
  E [E | Es] -> [E | Es]
  E [F | Fs] -> [E F | Fs] where (svc.key< (sup.issued-key E) (sup.issued-key F))
  E [F | Fs] -> [F | (sup.add-issued E Fs)])

(define sup.monitor-initial
  -> [])

(define sup.monitor-step
  X L Resp M -> (sup.monitor-with (sup.effective L X) Resp M))

(define sup.monitor-with
  [submit T K D] [conflict T K] M -> (sup.add-issued [conflict T K D] M)
  [submit _ _ _] [accepted Rc] M -> (sup.add-issued [accepted Rc] M)
  _ _ M -> M)

\\ ---------- state predicates ----------

\\ The receipt is exactly the recorded answer for its tenant, key and digest, and its
\\ report and job exist.
(define sup.recorded?
  Stores Rc -> (sup.recorded-with Stores (sup.receipt-fields Rc) Rc))

(define sup.recorded-with
  Stores [T K D R J] Rc ->
    (and (svc.tenant? T Stores)
         (= (svc.lookup K (svc.keys (svc.store T Stores))) [some D Rc])))

(define sup.durable?
  Stores Rc -> (let F (sup.receipt-fields Rc)
                    T (hd F)
                 (and (sup.recorded? Stores Rc)
                      (element? [(nth 4 F) (nth 3 F)] (svc.reports (svc.store T Stores)))
                      (svcp.job? (nth 5 F) (nth 4 F) (map (/. J (sua.v1-job J)) (svc.jobs (svc.store T Stores)))))))

\\ Cut over first if the upgrade is migrated (assumption F3), then deliver.
(define sup.ready
  Step X -> (if (= (hd (sup.u X)) migrated) (sup.after (Step [cut-over] X) X) X))

(define sup.after
  [ok Y _] _ -> Y
  _ X -> X)

(define sup.terminal-after?
  Step X T J R -> (svcp.all? (/. Ok (sup.terminal-in? (Step [complete T J Ok] (sup.ready Step X)) T J R)) [true false]))

(define sup.terminal-in?
  [ok Y _] T J R -> (let Stores (sup.stores Y)
                      (and (svc.tenant? T Stores) (svcp.terminal-job? J R (map (/. E (sua.v1-job E)) (svc.jobs (svc.store T Stores))))))
  _ _ _ _ -> false)

(define sup.told-dischargeable?
  Step X Rc -> (let F (sup.receipt-fields Rc) (sup.terminal-after? Step X (hd F) (nth 5 F) (nth 4 F))))

(define sup.pending-jobs
  _ [] -> []
  T [Store | Stores] ->
    (append (mapcan (/. J (if (= (nth 3 J) pending) [[T (hd J) (nth 2 J)]] [])) (svc.jobs Store))
            (sup.pending-jobs (+ T 1) Stores)))

(define sup.state-violations
  Step _ X ->
    (let Stores (sup.stores X)
         V1 (sua.v1-sys X)
         U (sup.u X)
      (append
        (sup.flag (svcp.all-good? 0 (svc.stores V1)) [atomicity "atomicity.records"])
        (sup.flag (svcp.all? (/. Rc (sup.durable? Stores Rc)) (sup.acceptances (append (sup.outbox X) (sup.trace X))))
                  [response "response.durable"])
        (sup.flag (svcp.all? (/. Rc (sup.told-dischargeable? Step X Rc)) (sup.acceptances (sup.trace X)))
                  [progress "progress.dischargeable"])
        (sup.flag (svcp.all? (/. P (sup.terminal-after? Step X (hd P) (nth 2 P) (nth 3 P))) (sup.pending-jobs 0 Stores))
                  [pending "pending.deliverable"])
        (sup.flag (svcp.all? (/. S (sup.readable? (sua.schema U) S)) Stores) [version "version.readable"])
        (sup.flag (or (= (sua.image U) none) (sua.admitted? (sua.image U))) [manifest "manifest.admitted"]))))

\\ ---------- edge predicates ----------

\\ authority.frame: a request under T changes no other tenant's store; a label with no
\\ tenant changes none, except migrate (the operator's transition over every tenant).
(define sup.frame?
  [migrate] _ _ _ -> true
  L X Xs Ys -> (svcp.frame? (sup.tenant-of (sup.effective L X)) 0 Xs Ys))

(define sup.respond-ok?
  [respond E] X Y -> (and (element? E (sup.outbox X)) (= (sup.trace Y) [E | (sup.trace X)])
                          (sup.respond-commit? E (sup.stores X)))
  _ _ _ -> true)

(define sup.respond-commit?
  [accepted Rc] Stores -> (sup.recorded? Stores Rc)
  _ _ -> true)

(define sup.unchanged?
  T Xs Ys -> (= (svc.store T Xs) (svc.store T Ys)))

\\ retry.replay: a submit of a recorded key changes nothing and gets the recorded answer
\\ or is refused.
(define sup.replay?
  [submit T K D] Xs Ys Resp ->
    (sup.replay-with (svc.lookup K (svc.keys (svc.store T Xs))) T K D Xs Ys Resp)
    where (svc.tenant? T Xs)
  _ _ _ _ -> true)

(define sup.replay-with
  none _ _ _ _ _ _ -> true
  [some D0 Rc] T K D Xs Ys Resp ->
    (and (sup.unchanged? T Xs Ys)
         (or (= Resp unavailable) (= Resp (if (= D D0) [accepted Rc] [conflict T K])))))

\\ receipts.retry-stable: consistent with every response already issued for the key.
(define sup.issued-consistent?
  [submit T K D] M Xs Ys Resp -> (svcp.all? (/. I (sup.consistent-with I T K D Xs Ys Resp)) M) where (svc.tenant? T Xs)
  _ _ _ _ _ -> true)

(define sup.consistent-with
  [accepted Rc] T K D Xs Ys Resp ->
    (let F (sup.receipt-fields Rc)
      (if (and (= (hd F) T) (= (nth 2 F) K))
          (and (sup.unchanged? T Xs Ys)
               (or (= Resp unavailable) (= Resp (if (= D (nth 3 F)) [accepted Rc] [conflict T K]))))
          true))
  [conflict T K D] T K D Xs Ys Resp -> (and (sup.unchanged? T Xs Ys) (or (= Resp unavailable) (= Resp [conflict T K])))
  _ _ _ _ _ _ _ -> true)

\\ retry.delivery: after an applied delivery, delivering the job again changes nothing.
(define sup.redelivery-absorbed?
  Step [complete T J _] Y Resp ->
    (or (= Resp unavailable)
        (svcp.all? (/. Ok (sup.same-store? T Y (Step [complete T J Ok] Y))) [true false]))
  _ _ _ _ -> true)

(define sup.same-store?
  T Y [ok Z _] -> (= (svc.store T (sup.stores Y)) (svc.store T (sup.stores Z)))
  _ _ _ -> false)

\\ receipts.immutable: every key entry survives every step unchanged.
(define sup.keys-kept?
  [] _ -> true
  [X | Xs] [Y | Ys] -> (and (svcp.all? (/. K (element? K (svc.keys Y))) (svc.keys X)) (sup.keys-kept? Xs Ys))
  _ _ -> false)

\\ pending.preserved: every pending job of x is in y with the same id and report, and
\\ leaves pending only by a delivery of that job.
(define sup.pending-kept?
  L Xs Ys -> (svcp.all? (/. P (sup.pending-kept-one? L P Ys)) (sup.pending-jobs 0 Xs)))

(define sup.pending-kept-one?
  L [T J R] Ys ->
    (and (svc.tenant? T Ys)
         (let Jobs (map (/. E (sua.v1-job E)) (svc.jobs (svc.store T Ys)))
           (or (element? [J R pending] Jobs)
               (and (svcp.job? J R Jobs) (sup.delivers? L T J))))))

(define sup.delivers?
  [complete T J _] T J -> true
  _ _ _ -> false)

\\ version.transitions: U changes only along the upgrade, each by its own label.
(define sup.transition?
  _ U U -> true
  [begin-upgrade Img] [v1] [prepared Img] -> true
  [abort-upgrade] [prepared _] [v1] -> true
  [migrate] [prepared Img] [migrated Img] -> true
  [cut-over] [migrated Img] [v2 Img] -> true
  _ _ _ -> false)

(define sup.crash-frame?
  [crash] X Y -> (and (= (sup.stores X) (sup.stores Y)) (= (sup.trace X) (sup.trace Y)) (= (sup.u X) (sup.u Y)))
  _ _ _ -> true)

(define sup.delivery-terminates?
  [complete T J _] Y Resp ->
    (or (= Resp unavailable)
        (let Stores (sup.stores Y)
          (and (svc.tenant? T Stores) (not (svcp.pending-job? J (svc.jobs (svc.store T Stores)))))))
  _ _ _ -> true)

\\ X -Label-> Y with response Resp; M is the monitor at X.
(define sup.edge-violations
  Step X M L Y Resp ->
    (let Xs (sup.stores X)
         Ys (sup.stores Y)
         E (sup.effective L X)
         V1x (sua.v1-sys X)
         V1y (sua.v1-sys Y)
      (append
        (sup.flag (sup.frame? L X Xs Ys) [authority "authority.frame"])
        (sup.flag (sup.respond-ok? L X Y) [response "response.commit-before-respond"])
        (sup.flag (sup.replay? E Xs Ys Resp) [retry "retry.replay"])
        (sup.flag (sup.redelivery-absorbed? Step E Y Resp) [retry "retry.delivery"])
        (sup.flag (sup.crash-frame? L X Y) [recovery "recovery.crash-frame"])
        (sup.flag (svcp.obligations-kept? L V1x V1y) [recovery "recovery.obligations"])
        (sup.flag (svcp.terminal-kept? (svc.stores V1x) (svc.stores V1y)) [progress "progress.terminal-stable"])
        (sup.flag (sup.delivery-terminates? E Y Resp) [progress "progress.delivery-terminates"])
        (sup.flag (sup.pending-kept? E Xs Ys) [pending "pending.preserved"])
        (sup.flag (sup.keys-kept? Xs Ys) [receipts "receipts.immutable"])
        (sup.flag (sup.issued-consistent? E M Xs Ys Resp) [receipts "receipts.retry-stable"])
        (sup.flag (sup.transition? L (sup.u X) (sup.u Y)) [version "version.transitions"]))))

\\ Every check, for reporting.
(define sup.checks
  -> [[authority "authority.frame"]
      [atomicity "atomicity.records"]
      [response "response.durable"] [response "response.commit-before-respond"]
      [retry "retry.replay"] [retry "retry.delivery"]
      [recovery "recovery.crash-frame"] [recovery "recovery.obligations"]
      [progress "progress.dischargeable"] [progress "progress.terminal-stable"] [progress "progress.delivery-terminates"]
      [pending "pending.preserved"] [pending "pending.deliverable"]
      [receipts "receipts.immutable"] [receipts "receipts.retry-stable"]
      [version "version.readable"] [version "version.transitions"]
      [manifest "manifest.admitted"]])

(define sup.properties
  -> [authority atomicity response retry recovery progress pending receipts version manifest])
