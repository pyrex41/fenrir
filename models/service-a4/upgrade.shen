\\ Accepted-job upgrade contract (application example, stage A4): the authoritative,
\\ executable statement. Contract text: spec/service/UPGRADE.md. Properties:
\\ upgrade-properties.shen. Load models/service/accepted-job.shen (A1, unchanged) first:
\\ the v1 transaction is A1's own (svc.submit, svc.complete), used unchanged.
\\
\\ System state  [up4 U [sys Stores Outbox Trace]]
\\   U       the durable upgrade state: [v1] | [prepared Img] | [migrated Img] | [v2 Img]
\\           (UPGRADE.md section 3); Img is good (a v2 image the host can discharge) or
\\           bad (one whose manifest names a storage contract the host does not provide)
\\   Stores  A1's stores, in the schema U names: schema 1 jobs [Id Report Status],
\\           schema 2 jobs [Id Report Status Attempts]; receipts [receipt T K D R J]
\\           (accepted under v1) or [receipt T K D R J 2] (accepted under v2)
\\   Outbox  volatile: response events in canonical order (sua.add-event), then the
\\           in-flight runs [run V Label] (and a mutant's own items) in dispatch order
\\   Trace   what clients have been told, most recent first
\\ Labels  A1's [submit T K D] [complete T J Ok] [respond E] [crash], and
\\         [dispatch L] [land I] [begin-upgrade Img] [abort-upgrade] [migrate] [cut-over]
\\ sua.step Label State gives [ok State' Response] or disabled; Response is an event,
\\ none, unavailable (a refused request: nothing applied) or refused (begin-upgrade of
\\ an image the host cannot discharge).

\\ ---------- receipts and events of either version ----------

(define sua.receipt-version
  [receipt _ _ _ _ _] -> 1
  [receipt _ _ _ _ _ 2] -> 2
  _ -> 0)

(define sua.event?
  [accepted Rc] -> (> (sua.receipt-version Rc) 0)
  [conflict _ _] -> true
  _ -> false)

\\ The canonical order: A1's (accepted before conflict, field by field), a v1 receipt
\\ before a v2 receipt with the same five fields. On v1 events alone it is A1's order.
(define sua.event-key
  [accepted [receipt T K D R J]] -> [0 T K D R J 1]
  [accepted [receipt T K D R J 2]] -> [0 T K D R J 2]
  [conflict T K] -> [1 T K 0 0 0 0])

(define sua.insert-event
  E [] -> [E]
  E [E | Es] -> [E | Es]
  E [F | Fs] -> [E F | Fs] where (svc.key< (sua.event-key E) (sua.event-key F))
  E [F | Fs] -> [F | (sua.insert-event E Fs)])

(define sua.events
  [] -> []
  [E | Es] -> [E | (sua.events Es)] where (sua.event? E)
  [_ | Es] -> (sua.events Es))

(define sua.items
  [] -> []
  [E | Es] -> (sua.items Es) where (sua.event? E)
  [I | Is] -> [I | (sua.items Is)])

(define sua.add-event
  E Outbox -> (append (sua.insert-event E (sua.events Outbox)) (sua.items Outbox)) where (sua.event? E)
  _ Outbox -> Outbox)

\\ Items are appended, never merged: two runs of one request are two runs.
(define sua.add-item
  I Outbox -> (append Outbox [I]))

(define sua.runs
  [] -> []
  [[run V L] | Is] -> [[run V L] | (sua.runs Is)]
  [_ | Is] -> (sua.runs Is))

\\ Remove the I-th run (from 0), and only it.
(define sua.drop-run
  _ [] -> []
  0 [[run V L] | Is] -> Is
  N [[run V L] | Is] -> [[run V L] | (sua.drop-run (- N 1) Is)]
  N [X | Is] -> [X | (sua.drop-run N Is)])

\\ ---------- the durable upgrade state (UPGRADE.md section 3) ----------

(define sua.schema
  [v1] -> 1
  [prepared _] -> 1
  [migrated _] -> 2
  [v2 _] -> 2)

\\ The version whose runs may commit, and to which new runs are dispatched.
(define sua.in-force
  [v1] -> 1
  [prepared _] -> 1
  [migrated _] -> none
  [v2 _] -> 2)

(define sua.image
  [prepared Img] -> Img
  [migrated Img] -> Img
  [v2 Img] -> Img
  _ -> none)

\\ The capability-manifest check of begin-upgrade (UPGRADE.md section 4.1): the host
\\ discharges contract 2 and the migration contract for the good image only.
(define sua.admitted?
  good -> true
  _ -> false)

\\ ---------- the v2 transaction (UPGRADE.md section 2.1) ----------

(define sua.submit2
  T K D Store -> (sua.submit2-with (svc.lookup K (svc.keys Store)) T K D Store))

(define sua.submit2-with
  [some D Rc] _ _ D Store -> [Store [accepted Rc]]
  [some _ _] _ _ _ Store -> [Store conflict]
  none T K D [store Reports Jobs Keys N] ->
    (let Rc [receipt T K D N N 2]
      [[store [[N D] | Reports] [[N N pending 0] | Jobs] [[K D Rc] | Keys] (+ N 1)] [accepted Rc]]))

\\ Only a pending job moves; the delivery is counted.
(define sua.finish2
  J true [J R pending A] -> [J R done (+ A 1)]
  J false [J R pending A] -> [J R failed (+ A 1)]
  _ _ Entry -> Entry)

(define sua.complete2
  J Ok [store Reports Jobs Keys N] -> [store Reports (map (/. E (sua.finish2 J Ok E)) Jobs) Keys N])

\\ ---------- the migration (UPGRADE.md section 2.1) ----------

(define sua.mig-job
  [J R pending] -> [J R pending 0]
  [J R St] -> [J R St 1])

(define sua.mig-key
  Entry -> Entry)

(define sua.mig-store
  [store Reports Jobs Keys N] -> [store Reports (map (/. J (sua.mig-job J)) Jobs) (map (/. K (sua.mig-key K)) Keys) N])

\\ ---------- runs ----------

(define sua.label-tenant
  [submit T _ _] -> T
  [complete T _ _] -> T)

(define sua.request?
  [submit T K D] Stores -> (svc.tenant? T Stores)
  [complete T J Ok] Stores -> (svc.tenant? T Stores)
  _ _ -> false)

\\ Version V's transaction for request L on one store: [Store' Result], Result
\\ [accepted Receipt], conflict, or none (a delivery).
(define sua.tx
  1 [submit T K D] Store -> (svc.submit T K D Store)
  2 [submit T K D] Store -> (sua.submit2 T K D Store)
  1 [complete _ J Ok] Store -> [(svc.complete J Ok Store) none]
  2 [complete _ J Ok] Store -> [(sua.complete2 J Ok Store) none])

(define sua.reply
  [submit T K _] Result -> (svc.reply T K Result)
  [complete | _] _ -> none)

\\ A run of version V commits under U: applied when V is in force (fencing,
\\ UPGRADE.md section 4.3), else refused with nothing applied.
(define sua.commit
  V L U [sys Stores Outbox Trace] ->
    (if (and (not (= V none)) (= V (sua.in-force U)))
        (let T (sua.label-tenant L)
             Done (sua.tx V L (svc.store T Stores))
             Resp (sua.reply L (nth 2 Done))
          [ok [up4 U [sys (svc.replace T (hd Done) Stores) (sua.add-event Resp Outbox) Trace]] Resp])
        [ok [up4 U [sys Stores Outbox Trace]] unavailable]))

\\ ---------- the system ----------

(define sua.step
  L [up4 U Sys] -> (sua.commit (sua.in-force U) L U Sys) where (sua.request? L (svc.stores Sys))
  [dispatch L] [up4 U [sys Stores Outbox Trace]] ->
    [ok [up4 U [sys Stores (sua.add-item [run (sua.in-force U) L] Outbox) Trace]] none]
    where (and (sua.request? L Stores) (not (= (sua.in-force U) none)))
  [land I] [up4 U [sys Stores Outbox Trace]] ->
    (let Runs (sua.runs Outbox)
         Run (nth (+ I 1) Runs)
      (sua.commit (nth 2 Run) (nth 3 Run) U [sys Stores (sua.drop-run I Outbox) Trace]))
    where (and (integer? I) (>= I 0) (< I (length (sua.runs Outbox))))
  [respond E] [up4 U [sys Stores Outbox Trace]] ->
    [ok [up4 U [sys Stores Outbox [E | Trace]]] E]
    where (and (sua.event? E) (element? E Outbox))
  [crash] [up4 U [sys Stores _ Trace]] -> [ok [up4 U [sys Stores [] Trace]] none]
  [begin-upgrade Img] [up4 [v1] Sys] ->
    (if (sua.admitted? Img) [ok [up4 [prepared Img] Sys] none] [ok [up4 [v1] Sys] refused])
  [abort-upgrade] [up4 [prepared _] Sys] -> [ok [up4 [v1] Sys] none]
  [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    [ok [up4 [migrated Img] [sys (map (/. S (sua.mig-store S)) Stores) Outbox Trace]] none]
  [cut-over] [up4 [migrated Img] Sys] -> [ok [up4 [v2 Img] Sys] none]
  _ _ -> disabled)

(define sua.initial
  Tenants -> [up4 [v1] (svc.initial Tenants)])

\\ ---------- the step alphabet over finite parameters ----------

\\ A1's submits and deliveries (svc.submit-labels, svc.complete-labels: every id in use
\\ and the next unused one), their dispatches while a version is in force, every
\\ in-flight run's landing, every response in the outbox, crash, and the upgrade
\\ labels enabled in U.
(define sua.respond-labels
  [] -> []
  [E | Es] -> [[respond E] | (sua.respond-labels Es)] where (sua.event? E)
  [_ | Es] -> (sua.respond-labels Es))

(define sua.land-labels
  I [] -> []
  I [_ | Rs] -> [[land I] | (sua.land-labels (+ I 1) Rs)])

(define sua.upgrade-labels
  [v1] -> [[begin-upgrade good] [begin-upgrade bad]]
  [prepared _] -> [[abort-upgrade] [migrate]]
  [migrated _] -> [[cut-over]]
  [v2 _] -> [])

(define sua.requests
  [Tenants Keys Digests] Stores -> (append (svc.submit-labels Tenants Keys Digests) (svc.complete-labels 0 Stores)))

(define sua.labels
  Params [up4 U [sys Stores Outbox Trace]] ->
    (let Requests (sua.requests Params Stores)
      (append Requests
              (if (= (sua.in-force U) none) [] (map (/. L [dispatch L]) Requests))
              (sua.land-labels 0 (sua.runs Outbox))
              (sua.respond-labels Outbox)
              [[crash]]
              (sua.upgrade-labels U))))

\\ ---------- the v1 view (UPGRADE.md section 6) ----------

\\ A job without its attempts, a receipt without its version: A1's shapes, so that A1's
\\ predicates can judge a state of either schema.
(define sua.v1-receipt
  [receipt T K D R J | _] -> [receipt T K D R J]
  X -> X)

(define sua.v1-job
  [J R St | _] -> [J R St]
  X -> X)

(define sua.v1-key
  [K D Rc] -> [K D (sua.v1-receipt Rc)]
  X -> X)

(define sua.v1-store
  [store Reports Jobs Keys N] -> [store Reports (map (/. J (sua.v1-job J)) Jobs) (map (/. K (sua.v1-key K)) Keys) N])

(define sua.v1-event
  [accepted Rc] -> [accepted (sua.v1-receipt Rc)]
  E -> E)

(define sua.v1-sys
  [up4 _ [sys Stores Outbox Trace]] ->
    [sys (map (/. S (sua.v1-store S)) Stores) (map (/. E (sua.v1-event E)) Outbox) (map (/. E (sua.v1-event E)) Trace)])
