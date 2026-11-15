\\ Accepted-job contract: the machines Gleipnir explores. "model" is the
\\ authoritative model (models/service/accepted-job.shen) unchanged. Every other
\\ entry is a mutant: the model's own pieces with one change, kept here so that the
\\ model file stays the clean statement. spec/service/ACCEPTED_JOB.md section 7
\\ describes each; spec/service/mutant-predictions.json holds the hand-derived
\\ predictions of what catches it.
\\
\\ A machine is [machine Name Step Labels]: Step Label Sys gives [ok Sys' Response]
\\ or disabled; Labels Params Sys gives the alphabet at Sys.
\\
\\ Mutant volatile state shares the outbox with the responses: response events
\\ first, in the model's canonical order, then the mutant's own volatile items
\\ ([job-message T J R], [pending-commit T K D], [stage-job T J]) in insertion
\\ order. A crash empties all of it, as in the model. A mutant's internal steps are
\\ labelled [internal Name T | Args] and act under tenant T's capability.

(define smu.events
  [] -> []
  [E | Es] -> [E | (smu.events Es)] where (svc.event? E)
  [_ | Es] -> (smu.events Es))

(define smu.items
  [] -> []
  [E | Es] -> (smu.items Es) where (svc.event? E)
  [I | Is] -> [I | (smu.items Is)])

(define smu.add-event
  none Outbox -> Outbox
  E Outbox -> (append (svc.add-event E (smu.events Outbox)) (smu.items Outbox)))

(define smu.add-items
  [] Outbox -> Outbox
  [I | Is] Outbox -> (smu.add-items Is (if (element? I Outbox) Outbox (append Outbox [I]))))

(define smu.reply
  _ _ none -> none
  T K Result -> (svc.reply T K Result))

\\ ---------- the generic mutant step ----------

\\ Tx T K D Stores gives [Stores' Result Items]: Result [accepted Rc], conflict, or
\\ none when the response is computed later. Deliver T J Ok Sys gives Sys'.
\\ Internal Label Sys gives [ok Sys' Response] or disabled.
(define smu.step
  Tx _ _ [submit T K D] [sys Stores Outbox Trace] ->
    (let R (Tx T K D Stores)
         Event (smu.reply T K (nth 2 R))
      [ok [sys (hd R) (smu.add-items (nth 3 R) (smu.add-event Event Outbox)) Trace] Event])
    where (svc.tenant? T Stores)
  _ Deliver _ [complete T J Ok] [sys Stores Outbox Trace] -> [ok (Deliver T J Ok [sys Stores Outbox Trace]) none]
    where (svc.tenant? T Stores)
  _ _ Internal [internal | Rest] Sys -> (Internal [internal | Rest] Sys)
  _ _ _ Label Sys -> (svc.step Label Sys))

(define smu.internal-labels
  [] -> []
  [[pending-commit T K D] | Is] -> [[internal commit T K D] | (smu.internal-labels Is)]
  [[stage-job T J] | Is] -> [[internal stage T J] | (smu.internal-labels Is)]
  [_ | Is] -> (smu.internal-labels Is))

(define smu.labels
  Params [sys Stores Outbox Trace] -> (append (svc.labels Params [sys Stores Outbox Trace]) (smu.internal-labels Outbox)))

(define smu.no-internal
  _ _ -> disabled)

\\ The model's transaction and delivery, in the generic shape.
(define smu.model-tx
  T K D Stores -> (let R (svc.submit T K D (svc.store T Stores)) [(svc.replace T (hd R) Stores) (hd (tl R)) []]))

(define smu.model-deliver
  T J Ok [sys Stores Outbox Trace] -> [sys (svc.replace T (svc.complete J Ok (svc.store T Stores)) Stores) Outbox Trace])

(define smu.with-store
  T Stores Store -> (svc.replace T Store Stores))

\\ ---------- (a) volatile-mailbox ----------
\\ The transaction stores the report and the key entry; the job is only a volatile
\\ message. A delivery that finds the message turns it into a completed job record.

(define smu.mailbox-tx
  T K D Stores -> (smu.mailbox-with (svc.lookup K (svc.keys (svc.store T Stores))) T K D Stores))

(define smu.mailbox-with
  none T K D Stores ->
    (let Store (svc.store T Stores)
         N (svc.next Store)
         Rc [receipt T K D N N]
      [(smu.with-store T Stores [store [[N D] | (svc.reports Store)] (svc.jobs Store) [[K D Rc] | (svc.keys Store)] (+ N 1)])
       [accepted Rc] [[job-message T N N]]])
  Found T K D Stores ->
    (let R (svc.submit-with Found T K D (svc.store T Stores)) [(smu.with-store T Stores (hd R)) (hd (tl R)) []]))

(define smu.find-message
  _ _ [] -> none
  T J [[job-message T J R] | _] -> [job-message T J R]
  T J [_ | Is] -> (smu.find-message T J Is))

(define smu.mailbox-deliver
  T J Ok [sys Stores Outbox Trace] -> (smu.mailbox-deliver-with (smu.find-message T J Outbox) T J Ok [sys Stores Outbox Trace]))

(define smu.mailbox-deliver-with
  none T J Ok Sys -> (smu.model-deliver T J Ok Sys)
  [job-message T J R] T J Ok [sys Stores Outbox Trace] ->
    (let Store (svc.store T Stores)
         Staged [store (svc.reports Store) [[J R pending] | (svc.jobs Store)] (svc.keys Store) (svc.next Store)]
      [sys (smu.with-store T Stores (svc.complete J Ok Staged)) (remove [job-message T J R] Outbox) Trace]))

\\ ---------- (b) respond-before-commit ----------
\\ The response is computed at once; the transaction is installed by a later
\\ internal commit step, which a crash can prevent.

(define smu.early-tx
  T K D Stores -> [Stores (hd (tl (svc.submit T K D (svc.store T Stores)))) [[pending-commit T K D]]])

(define smu.commit-internal
  [internal commit T K D] [sys Stores Outbox Trace] ->
    [ok [sys (smu.with-store T Stores (hd (svc.submit T K D (svc.store T Stores)))) (remove [pending-commit T K D] Outbox) Trace] none]
    where (element? [pending-commit T K D] Outbox)
  _ _ -> disabled)

\\ ---------- (c) non-atomic-write ----------
\\ A new key's report and key entry are installed first; the job record by a later
\\ internal stage step, which also computes the acceptance.

(define smu.split-tx
  T K D Stores -> (smu.split-with (svc.lookup K (svc.keys (svc.store T Stores))) T K D Stores))

(define smu.split-with
  none T K D Stores ->
    (let Store (svc.store T Stores)
         N (svc.next Store)
      [(smu.with-store T Stores [store [[N D] | (svc.reports Store)] (svc.jobs Store) [[K D [receipt T K D N N]] | (svc.keys Store)] (+ N 1)])
       none [[stage-job T N]]])
  Found T K D Stores ->
    (let R (svc.submit-with Found T K D (svc.store T Stores)) [(smu.with-store T Stores (hd R)) (hd (tl R)) []]))

(define smu.receipt-for-job
  _ [] -> none
  J [[_ _ [receipt T K D R J]] | _] -> [accepted [receipt T K D R J]]
  J [_ | Keys] -> (smu.receipt-for-job J Keys))

(define smu.stage-internal
  [internal stage T J] [sys Stores Outbox Trace] ->
    (let Store (svc.store T Stores)
         Event (smu.receipt-for-job J (svc.keys Store))
      [ok [sys (smu.with-store T Stores [store (svc.reports Store) [[J J pending] | (svc.jobs Store)] (svc.keys Store) (svc.next Store)])
               (smu.add-event Event (remove [stage-job T J] Outbox)) Trace]
          Event])
    where (element? [stage-job T J] Outbox)
  _ _ -> disabled)

\\ ---------- (d) retry-reapplies ----------
\\ A known key with the same digest runs the mutation again under a new receipt.

(define smu.drop-key
  _ [] -> []
  K [[K _ _] | Rest] -> (smu.drop-key K Rest)
  K [E | Rest] -> [E | (smu.drop-key K Rest)])

(define smu.reapply-tx
  T K D Stores -> (smu.reapply-with (svc.lookup K (svc.keys (svc.store T Stores))) T K D Stores))

(define smu.reapply-with
  [some D _] T K D Stores ->
    (let Store (svc.store T Stores)
         Fresh [store (svc.reports Store) (svc.jobs Store) (smu.drop-key K (svc.keys Store)) (svc.next Store)]
         R (svc.submit T K D Fresh)
      [(smu.with-store T Stores (hd R)) (hd (tl R)) []])
  _ T K D Stores -> (smu.model-tx T K D Stores))

\\ ---------- (e) key-reuse-accepted ----------
\\ A known key with another digest is answered with the recorded receipt.

(define smu.reuse-tx
  T K D Stores -> (smu.reuse-with (svc.lookup K (svc.keys (svc.store T Stores))) T K D Stores))

(define smu.reuse-with
  [some D0 Rc] T K D Stores -> [Stores [accepted Rc] []] where (not (= D D0))
  _ T K D Stores -> (smu.model-tx T K D Stores))

\\ ---------- (f) cross-tenant-counter ----------
\\ Ids come from a counter shared by all tenants: a new key under T advances every
\\ tenant's counter, a write into the other tenants' stores.

(define smu.bump-others
  _ _ [] -> []
  T T [S | Ss] -> [S | (smu.bump-others T (+ T 1) Ss)]
  Owner T [[store R J K N] | Ss] -> [[store R J K (+ N 1)] | (smu.bump-others Owner (+ T 1) Ss)])

(define smu.shared-counter-tx
  T K D Stores ->
    (let R (smu.model-tx T K D Stores)
      (if (= (svc.lookup K (svc.keys (svc.store T Stores))) none)
          [(smu.bump-others T 0 (hd R)) (nth 2 R) []]
          R)))

\\ ---------- (g) undeduplicated-delivery ----------
\\ A delivery sets a matching job's status whatever it was.

(define smu.overwrite
  J true [J R _] -> [J R done]
  J false [J R _] -> [J R failed]
  _ _ E -> E)

(define smu.overwrite-deliver
  T J Ok [sys Stores Outbox Trace] ->
    (let Store (svc.store T Stores)
      [sys (smu.with-store T Stores [store (svc.reports Store) (map (/. E (smu.overwrite J Ok E)) (svc.jobs Store)) (svc.keys Store) (svc.next Store)])
           Outbox Trace]))

\\ ---------- (h) volatile-status ----------
\\ Status changes are held in memory: a crash puts every terminal job back to pending.

(define smu.revert-job
  [J R _] -> [J R pending])

(define smu.revert-store
  [store Reports Jobs Keys N] -> [store Reports (map (/. E (smu.revert-job E)) Jobs) Keys N])

(define smu.volatile-status-step
  [crash] [sys Stores _ Trace] -> [ok [sys (map (/. S (smu.revert-store S)) Stores) [] Trace] none]
  Label Sys -> (svc.step Label Sys))

\\ ---------- (i) failure-not-terminal ----------
\\ A failed delivery is not recorded: the job stays pending.

(define smu.success-only-deliver
  T J true Sys -> (smu.model-deliver T J true Sys)
  _ _ false Sys -> Sys)

\\ ---------- equivalent control ----------
\\ The same meaning by other code: lookup by filtering then taking the first match;
\\ delivery by explicit recursion, testing the status before the id. Must not be
\\ flagged and must give the model's graph.

(define smu.matching
  _ [] -> []
  K [[K D Rc] | Rest] -> [[K D Rc] | (smu.matching K Rest)]
  K [_ | Rest] -> (smu.matching K Rest))

(define smu.lookup-by-filter
  K Keys -> (let M (smu.matching K Keys) (if (empty? M) none [some (nth 2 (hd M)) (nth 3 (hd M))])))

(define smu.control-tx
  T K D Stores ->
    (let R (svc.submit-with (smu.lookup-by-filter K (svc.keys (svc.store T Stores))) T K D (svc.store T Stores))
      [(smu.with-store T Stores (hd R)) (hd (tl R)) []]))

(define smu.finish-all
  _ _ [] -> []
  J Ok [[I R St] | Rest] ->
    [(if (and (= St pending) (= I J)) [I R (if Ok done failed)] [I R St]) | (smu.finish-all J Ok Rest)])

(define smu.control-deliver
  T J Ok [sys Stores Outbox Trace] ->
    (let Store (svc.store T Stores)
      [sys (smu.with-store T Stores [store (svc.reports Store) (smu.finish-all J Ok (svc.jobs Store)) (svc.keys Store) (svc.next Store)])
           Outbox Trace]))

\\ ---------- the table ----------

(define smu.mutant
  Name Tx Deliver Internal ->
    [machine Name (/. L S (smu.step Tx Deliver Internal L S)) (/. P S (smu.labels P S))])

(define smu.machine
  "model" -> [machine "model" (/. L S (svc.step L S)) (/. P S (svc.labels P S))]
  "volatile-mailbox" -> (smu.mutant "volatile-mailbox" (fn smu.mailbox-tx) (fn smu.mailbox-deliver) (fn smu.no-internal))
  "respond-before-commit" -> (smu.mutant "respond-before-commit" (fn smu.early-tx) (fn smu.model-deliver) (fn smu.commit-internal))
  "non-atomic-write" -> (smu.mutant "non-atomic-write" (fn smu.split-tx) (fn smu.model-deliver) (fn smu.stage-internal))
  "retry-reapplies" -> (smu.mutant "retry-reapplies" (fn smu.reapply-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "key-reuse-accepted" -> (smu.mutant "key-reuse-accepted" (fn smu.reuse-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "cross-tenant-counter" -> (smu.mutant "cross-tenant-counter" (fn smu.shared-counter-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "undeduplicated-delivery" -> (smu.mutant "undeduplicated-delivery" (fn smu.model-tx) (fn smu.overwrite-deliver) (fn smu.no-internal))
  "volatile-status" -> [machine "volatile-status" (/. L S (smu.volatile-status-step L S)) (/. P S (svc.labels P S))]
  "failure-not-terminal" -> (smu.mutant "failure-not-terminal" (fn smu.model-tx) (fn smu.success-only-deliver) (fn smu.no-internal))
  "equivalent-control" -> (smu.mutant "equivalent-control" (fn smu.control-tx) (fn smu.control-deliver) (fn smu.no-internal))
  Name -> (error "service: unknown machine ~A" Name))

(define smu.mutant-names
  -> ["volatile-mailbox" "respond-before-commit" "non-atomic-write" "retry-reapplies"
      "key-reuse-accepted" "cross-tenant-counter" "undeduplicated-delivery" "volatile-status"
      "failure-not-terminal" "equivalent-control"])
