\\ Accepted-job upgrade contract: the machines Gleipnir explores for stage A4. "model"
\\ is the authoritative model (models/service-a4/upgrade.shen) unchanged; every other
\\ entry is a mutant built from the model's own pieces with one change, kept here so
\\ that the model file stays the clean statement. spec/service/UPGRADE.md section 8
\\ describes each; spec/service/upgrade-mutant-predictions.json holds the hand-derived
\\ predictions of what catches it.
\\
\\ A machine is [machine Name Step Labels], as in harness/service-mutants.shen. A
\\ mutant's internal steps are labelled [internal Name T | Args] and act under tenant
\\ T's capability; its volatile items live in the outbox after the responses, and a
\\ crash empties them with everything else.

(define umu.model-step
  L S -> (sua.step L S))

(define umu.model-labels
  P S -> (sua.labels P S))

\\ ---------- migrations ----------

\\ (a) migration-drops-pending: only terminal jobs are carried over.
(define umu.drop-pending-store
  [store Reports Jobs Keys N] ->
    [store Reports (mapcan (/. J (if (= (nth 3 J) pending) [] [(sua.mig-job J)])) Jobs) Keys N])

\\ (e) keys-not-migrated: the v2 key table is built empty.
(define umu.no-keys-store
  [store Reports Jobs Keys N] -> [store Reports (map (/. J (sua.mig-job J)) Jobs) [] N])

\\ (f) receipt-rewritten: every v1 receipt is rewritten to the v2 representation.
(define umu.rewrite-key
  [K D [receipt T K2 D2 R J]] -> [K D [receipt T K2 D2 R J 2]]
  E -> E)

(define umu.rewrite-store
  [store Reports Jobs Keys N] -> [store Reports (map (/. J (sua.mig-job J)) Jobs) (map (/. K (umu.rewrite-key K)) Keys) N])

\\ A machine whose migrate applies Mig to every store.
(define umu.migrating
  Mig [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    [ok [up4 [migrated Img] [sys (map Mig Stores) Outbox Trace]] none]
  _ L S -> (sua.step L S))

\\ ---------- (b) migration-not-atomic ----------
\\ migrate converts tenant 0 only and leaves the volatile item [migrating Img 1]; an
\\ internal step [internal migrate-tenant T] converts tenant T, and the last one sets U
\\ to [migrated Img]. U stays [prepared Img] (v1 serving) in between; a crash loses the
\\ item and leaves the store half migrated.

\\ Converting a tenant twice (migrate offered again after a crash) leaves a converted
\\ job as it is.
(define umu.mig-job-once
  [J R St] -> (sua.mig-job [J R St])
  E -> E)

(define umu.migrate-one
  T Stores -> (let S (svc.store T Stores)
                (svc.replace T [store (svc.reports S) (map (/. J (umu.mig-job-once J)) (svc.jobs S)) (svc.keys S) (svc.next S)] Stores)))

(define umu.partial-step
  [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    (let S1 (umu.migrate-one 0 Stores)
      (if (= (length Stores) 1)
          [ok [up4 [migrated Img] [sys S1 Outbox Trace]] none]
          [ok [up4 [prepared Img] [sys S1 (sua.add-item [migrating Img 1] Outbox) Trace]] none]))
  [internal migrate-tenant T] [up4 U [sys Stores Outbox Trace]] ->
    (let Img (umu.migrating-item T Outbox)
      (if (= Img none) disabled
          (let S1 (umu.migrate-one T Stores)
               Out (remove [migrating Img T] Outbox)
            (if (= (+ T 1) (length Stores))
                [ok [up4 [migrated Img] [sys S1 Out Trace]] none]
                [ok [up4 U [sys S1 (sua.add-item [migrating Img (+ T 1)] Out) Trace]] none]))))
  L S -> (sua.step L S))

(define umu.migrating-item
  _ [] -> none
  T [[migrating Img T] | _] -> Img
  T [_ | Is] -> (umu.migrating-item T Is))

(define umu.partial-internal
  [] -> []
  [[migrating _ T] | Is] -> [[internal migrate-tenant T] | (umu.partial-internal Is)]
  [_ | Is] -> (umu.partial-internal Is))

(define umu.partial-labels
  P [up4 U [sys Stores Outbox Trace]] ->
    (append (sua.labels P [up4 U [sys Stores Outbox Trace]]) (umu.partial-internal Outbox)))

\\ ---------- (c) cutover-before-migration ----------

(define umu.early-cutover-step
  [cut-over] [up4 [prepared Img] Sys] -> [ok [up4 [v2 Img] Sys] none]
  L S -> (sua.step L S))

(define umu.early-cutover-labels
  P [up4 [prepared Img] Sys] -> (append (sua.labels P [up4 [prepared Img] Sys]) [[cut-over]])
  P S -> (sua.labels P S))

\\ ---------- v1's statements on a store of either schema ----------
\\ What v1's code does to rows it does not know: a submit adds A1's three-field job and
\\ a v1 receipt; a delivery sets the status of a pending job and keeps every other
\\ field (the attempts are not counted).

(define umu.oblivious-finish
  J true [J R pending | Rest] -> [J R done | Rest]
  J false [J R pending | Rest] -> [J R failed | Rest]
  _ _ E -> E)

(define umu.oblivious-tx
  [submit T K D] Store -> (svc.submit T K D Store)
  [complete _ J Ok] [store Reports Jobs Keys N] ->
    [[store Reports (map (/. E (umu.oblivious-finish J Ok E)) Jobs) Keys N] none])

(define umu.apply-v1
  L U [sys Stores Outbox Trace] ->
    (let T (sua.label-tenant L)
         Done (umu.oblivious-tx L (svc.store T Stores))
         Resp (sua.reply L (nth 2 Done))
      [ok [up4 U [sys (svc.replace T (hd Done) Stores) (sua.add-event Resp Outbox) Trace]] Resp]))

\\ (d) stale-v1-commit: the store does not fence; a landing v1 run is applied with v1's
\\ statements whatever the schema.
(define umu.stale-step
  [land I] [up4 U [sys Stores Outbox Trace]] ->
    (let Run (nth (+ I 1) (sua.runs Outbox))
         Rest [sys Stores (sua.drop-run I Outbox) Trace]
      (if (and (= (nth 2 Run) 1) (not (= (sua.in-force U) 1)))
          (umu.apply-v1 (nth 3 Run) U Rest)
          (sua.step [land I] [up4 U [sys Stores Outbox Trace]])))
    where (and (integer? I) (>= I 0) (< I (length (sua.runs Outbox))))
  L S -> (sua.step L S))

\\ (g) deliver-to-v1: after cut-over, deliveries still run v1's statements.
(define umu.v1-delivery-step
  [complete T J Ok] [up4 [v2 Img] Sys] -> (umu.apply-v1 [complete T J Ok] [v2 Img] Sys)
    where (svc.tenant? T (svc.stores Sys))
  L S -> (sua.step L S))

\\ ---------- (h) no-manifest-check ----------

(define umu.no-manifest-step
  [begin-upgrade Img] [up4 [v1] Sys] -> [ok [up4 [prepared Img] Sys] none]
  L S -> (sua.step L S))

\\ ---------- (i) volatile-upgrade-state ----------

\\ After such a crash the operator may begin and migrate again; the second migration
\\ leaves the jobs it already converted as they are (the model's migration is defined on
\\ schema-1 stores only).
(define umu.volatile-upgrade-step
  [crash] [up4 _ [sys Stores _ Trace]] -> [ok [up4 [v1] [sys Stores [] Trace]] none]
  [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    [ok [up4 [migrated Img] [sys (umu.migrate-all 0 Stores) Outbox Trace]] none]
  L S -> (sua.step L S))

(define umu.migrate-all
  T Stores -> Stores where (= T (length Stores))
  T Stores -> (umu.migrate-all (+ T 1) (umu.migrate-one T Stores)))

\\ ---------- v2 code that is wrong (aimed at A1's properties across the upgrade) ----------
\\ Tx2 L T Stores gives [Stores' Result]: v2's transaction replaced, for every v2 run
\\ (atomic or landing) once v2 is in force.

(define umu.commit2
  Tx2 L U [sys Stores Outbox Trace] ->
    (let Done (Tx2 L (sua.label-tenant L) Stores)
         Resp (sua.reply L (nth 2 Done))
      [ok [up4 U [sys (hd Done) (sua.add-event Resp Outbox) Trace]] Resp]))

(define umu.v2-step
  Tx2 L [up4 [v2 Img] Sys] -> (umu.commit2 Tx2 L [v2 Img] Sys) where (sua.request? L (svc.stores Sys))
  Tx2 [land I] [up4 [v2 Img] [sys Stores Outbox Trace]] ->
    (let Run (nth (+ I 1) (sua.runs Outbox))
      (if (= (nth 2 Run) 2)
          (umu.commit2 Tx2 (nth 3 Run) [v2 Img] [sys Stores (sua.drop-run I Outbox) Trace])
          (sua.step [land I] [up4 [v2 Img] [sys Stores Outbox Trace]])))
    where (and (integer? I) (>= I 0) (< I (length (sua.runs Outbox))))
  _ L S -> (sua.step L S))

(define umu.model-tx2
  L T Stores -> (let Done (sua.tx 2 L (svc.store T Stores)) [(svc.replace T (hd Done) Stores) (nth 2 Done)]))

\\ (j) v2-shared-counter: v2 allocates ids from one counter for all tenants, so a new
\\ key under T advances every tenant's counter.
(define umu.shared-counter-tx2
  [submit T K D] T Stores ->
    (let New (= (svc.lookup K (svc.keys (svc.store T Stores))) none)
         Done (umu.model-tx2 [submit T K D] T Stores)
      (if New [(smu.bump-others T 0 (hd Done)) (nth 2 Done)] Done))
  L T Stores -> (umu.model-tx2 L T Stores))

\\ (k) v2-duplicate-delivery-counted: the attempt is counted outside the Pending guard.
(define umu.count-always
  J Ok [J R pending A] -> (sua.finish2 J Ok [J R pending A])
  J _ [J R St A] -> [J R St (+ A 1)]
  _ _ E -> E)

(define umu.count-always-tx2
  [complete T J Ok] T Stores ->
    (let S (svc.store T Stores)
      [(svc.replace T [store (svc.reports S) (map (/. E (umu.count-always J Ok E)) (svc.jobs S)) (svc.keys S) (svc.next S)] Stores) none])
  L T Stores -> (umu.model-tx2 L T Stores))

\\ (l) v2-retry-reapplies: v2 runs the mutation again for a recorded key with the same
\\ digest (A1's retry-reapplies, in v2 code).
(define umu.reapply-tx2
  [submit T K D] T Stores ->
    (let S (svc.store T Stores)
      (if (= (svc.lookup K (svc.keys S)) none)
          (umu.model-tx2 [submit T K D] T Stores)
          (if (= (nth 2 (svc.lookup K (svc.keys S))) D)
              (let Fresh [store (svc.reports S) (svc.jobs S) (smu.drop-key K (svc.keys S)) (svc.next S)]
                   Done (sua.submit2 T K D Fresh)
                [(svc.replace T (hd Done) Stores) (nth 2 Done)])
              (umu.model-tx2 [submit T K D] T Stores))))
  L T Stores -> (umu.model-tx2 L T Stores))

\\ ---------- equivalent control ----------
\\ The migration by explicit recursion with the status tested by cases, and the v2
\\ delivery by explicit recursion testing the id after the status. Must not be flagged
\\ and must give the model's graph.

(define umu.control-mig-jobs
  [] -> []
  [[J R St] | Rest] -> [[J R St (if (element? St [done failed]) 1 0)] | (umu.control-mig-jobs Rest)])

(define umu.control-finish
  _ _ [] -> []
  J Ok [[I R St A] | Rest] ->
    [(if (and (= St pending) (= I J)) [I R (if Ok done failed) (+ A 1)] [I R St A]) | (umu.control-finish J Ok Rest)]
  J Ok [E | Rest] -> [E | (umu.control-finish J Ok Rest)])

(define umu.control-step
  [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    [ok [up4 [migrated Img] [sys (map (/. S [store (svc.reports S) (umu.control-mig-jobs (svc.jobs S)) (svc.keys S) (svc.next S)]) Stores) Outbox Trace]] none]
  [complete T J Ok] [up4 [v2 Img] [sys Stores Outbox Trace]] ->
    (let S (svc.store T Stores)
      [ok [up4 [v2 Img] [sys (svc.replace T [store (svc.reports S) (umu.control-finish J Ok (svc.jobs S)) (svc.keys S) (svc.next S)] Stores) Outbox Trace]] none])
    where (svc.tenant? T Stores)
  L S -> (sua.step L S))

\\ ---------- the table ----------

(define umu.machine
  "model" -> [machine "model" (/. L S (umu.model-step L S)) (/. P S (umu.model-labels P S))]
  "migration-drops-pending" -> [machine "migration-drops-pending" (/. L S (umu.migrating (/. X (umu.drop-pending-store X)) L S)) (/. P S (sua.labels P S))]
  "migration-not-atomic" -> [machine "migration-not-atomic" (/. L S (umu.partial-step L S)) (/. P S (umu.partial-labels P S))]
  "cutover-before-migration" -> [machine "cutover-before-migration" (/. L S (umu.early-cutover-step L S)) (/. P S (umu.early-cutover-labels P S))]
  "stale-v1-commit" -> [machine "stale-v1-commit" (/. L S (umu.stale-step L S)) (/. P S (sua.labels P S))]
  "keys-not-migrated" -> [machine "keys-not-migrated" (/. L S (umu.migrating (/. X (umu.no-keys-store X)) L S)) (/. P S (sua.labels P S))]
  "receipt-rewritten" -> [machine "receipt-rewritten" (/. L S (umu.migrating (/. X (umu.rewrite-store X)) L S)) (/. P S (sua.labels P S))]
  "deliver-to-v1" -> [machine "deliver-to-v1" (/. L S (umu.v1-delivery-step L S)) (/. P S (sua.labels P S))]
  "no-manifest-check" -> [machine "no-manifest-check" (/. L S (umu.no-manifest-step L S)) (/. P S (sua.labels P S))]
  "volatile-upgrade-state" -> [machine "volatile-upgrade-state" (/. L S (umu.volatile-upgrade-step L S)) (/. P S (sua.labels P S))]
  "v2-shared-counter" -> [machine "v2-shared-counter" (/. L S (umu.v2-step (/. A B C (umu.shared-counter-tx2 A B C)) L S)) (/. P S (sua.labels P S))]
  "v2-duplicate-delivery-counted" -> [machine "v2-duplicate-delivery-counted" (/. L S (umu.v2-step (/. A B C (umu.count-always-tx2 A B C)) L S)) (/. P S (sua.labels P S))]
  "v2-retry-reapplies" -> [machine "v2-retry-reapplies" (/. L S (umu.v2-step (/. A B C (umu.reapply-tx2 A B C)) L S)) (/. P S (sua.labels P S))]
  "equivalent-control" -> [machine "equivalent-control" (/. L S (umu.control-step L S)) (/. P S (sua.labels P S))]
  Name -> (error "service-upgrade: unknown machine ~A" Name))

(define umu.mutant-names
  -> ["migration-drops-pending" "migration-not-atomic" "cutover-before-migration" "stale-v1-commit"
      "keys-not-migrated" "receipt-rewritten" "deliver-to-v1" "no-manifest-check" "volatile-upgrade-state"
      "v2-shared-counter" "v2-duplicate-delivery-counted" "v2-retry-reapplies" "equivalent-control"])
