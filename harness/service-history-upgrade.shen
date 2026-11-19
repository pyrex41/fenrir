\\ Fenrir harness, in Shen: stage A4, black-box conformance of a recorded history of the
\\ real service across an upgrade (schema fenrir.service.history/2, spec/service/HISTORY_FORMAT.md
\\ section 4) against the A4 model (models/service-a4/upgrade.shen). Loaded by
\\ harness/service-history.shen, which keeps checking schema /1 histories against the A1
\\ model exactly as before and hands /2 histories here. Evidence: "observed history
\\ accepted" for an accepted history, nothing more.
\\
\\ As for /1: a history is ADMITTED when some execution of the model, label by label,
\\ gives every recorded response, has stores (and upgrade state) equal to every recorded
\\ observation, no pending job at every drained, and every property predicate of
\\ models/service-a4/upgrade-properties.shen holds on each of its states and edges. What
\\ the recorder could not see is a choice the checker explores.

(map (/. F (load (cn (value fh.*root*) F)))
     ["models/service-a4/upgrade.shen" "models/service-a4/upgrade-properties.shen"])

(define shu.step-fn
  -> (/. L S (sua.step L S)))

\\ ---------- decoding ----------

(define shu.receipt-of
  [T K D R J] -> [receipt T K D R J]
  [T K D R J 2] -> [receipt T K D R J 2]
  X -> (error "history: not a receipt ~S" X))

(define shu.event-of
  ["accepted" R] -> [accepted (shu.receipt-of R)]
  ["conflict" T K] -> [conflict T K]
  X -> (error "history: not an event ~S" X))

(define shu.image
  "good" -> good
  "bad" -> bad
  X -> (error "history: not an image ~S" X))

(define shu.upgrade-of
  ["v1"] -> [v1]
  ["prepared" I] -> [prepared (shu.image I)]
  ["migrated" I] -> [migrated (shu.image I)]
  ["v2" I] -> [v2 (shu.image I)]
  X -> (error "history: not an upgrade state ~S" X))

\\ A model tenant store in the observed shape: lists sorted by their first field,
\\ statuses as text, receipts as lists.
(define shu.status-text
  pending -> "pending"
  done -> "done"
  failed -> "failed")

(define shu.observed-job
  [J R St] -> [J R (shu.status-text St)]
  [J R St A] -> [J R (shu.status-text St) A])

(define shu.observed-receipt
  [receipt T K D R J] -> [T K D R J]
  [receipt T K D R J 2] -> [T K D R J 2])

(define shu.observed-tenant
  [store Reports Jobs Keys N] ->
    [(sx.sort-by-head Reports)
     (map (/. J (shu.observed-job J)) (sx.sort-by-head Jobs))
     (map (/. E [(hd E) (nth 2 E) (shu.observed-receipt (nth 3 E))]) (sx.sort-by-head Keys))
     N])

\\ ---------- candidates: [State Monitor] ----------

(define shu.step
  [X M] Label Expect ->
    (let R (sua.step Label X)
      (if (= R disabled) []
          (let Y (nth 2 R)
               Resp (nth 3 R)
               _ (set sh.*model-steps* (+ 1 (value sh.*model-steps*)))
            (if (or (= Expect any) (= Expect Resp))
                (let M2 (sup.monitor-step X Label Resp M)
                     V (append (sup.edge-violations (shu.step-fn) X M Label Y Resp)
                               (sup.state-violations (shu.step-fn) M2 Y))
                     _ (set sh.*predicate-checks* (+ 1 (value sh.*predicate-checks*)))
                  (if (empty? V) [[Y M2]] [[violated V]]))
                [])))))

(define shu.enabled?
  [X _] Label -> (not (= (sua.step Label X) disabled)))

(define shu.outcome-expect
  ["accepted" R] -> [step (shu.event-of ["accepted" R])]
  ["conflict" T K] -> [step (shu.event-of ["conflict" T K])]
  ["delivered"] -> [step none]
  ["other"] -> [step none]
  ["busy"] -> no-step
  ["aborted"] -> no-step
  ["refused"] -> no-step
  ["unavailable"] -> unavailable
  ["indeterminate"] -> maybe
  X -> (error "history: not an outcome ~S" X))

(define shu.request
  Label Out Cs ->
    (let E (shu.outcome-expect Out)
      (cond ((= E no-step) Cs)
            ((= E unavailable) (sh.filter (/. C (= (hd (sup.u (hd C))) migrated)) Cs))
            ((= E maybe) (sh.each (/. C [C | (shu.step C Label any)]) Cs))
            (true (sh.each (/. C (shu.step C Label (nth 2 E))) Cs)))))

\\ An operator's upgrade step and its outcome (HISTORY_FORMAT.md section 4).
\\   ok             the step, response none
\\   refused        begin-upgrade: the step with response refused (an image the host
\\                  cannot discharge), or the label not enabled in the model; the other
\\                  steps: the label not enabled
\\   changed, busy, aborted   no step (nothing applied)
\\   indeterminate  the step, or no step
(define shu.upgrade
  Label ["ok"] Cs -> (sh.each (/. C (shu.step C Label none)) Cs)
  [begin-upgrade Img] ["refused"] Cs ->
    (sh.each (/. C (if (shu.enabled? C [begin-upgrade Img]) (shu.step C [begin-upgrade Img] refused) [C])) Cs)
  Label ["refused"] Cs -> (sh.filter (/. C (not (shu.enabled? C Label))) Cs)
  _ ["changed"] Cs -> Cs
  _ ["busy"] Cs -> Cs
  _ ["aborted"] Cs -> Cs
  Label ["indeterminate"] Cs -> (sh.each (/. C [C | (shu.step C Label any)]) Cs)
  _ X _ -> (error "history: not an upgrade outcome ~S" X))

(define shu.upgrade-label
  ["begin" Img] -> [begin-upgrade (shu.image Img)]
  ["abort"] -> [abort-upgrade]
  ["migrate"] -> [migrate]
  ["cut-over"] -> [cut-over]
  X -> (error "history: not an upgrade step ~S" X))

(define shu.pending-free?
  [X _] -> (svcp.all? (/. S (svcp.all? (/. J (not (= (nth 3 J) pending))) (svc.jobs S))) (sup.stores X)))

(define shu.stores-equal?
  Observed [X _] -> (= (map (/. S (shu.observed-tenant S)) (sup.stores X)) Observed))

(define shu.outbox-lacks?
  E [X _] -> (not (element? E (sup.outbox X))))

(define shu.event
  ["submit" T K D Out] Cs -> (sh.result (shu.request [submit T K D] Out Cs) "no model state has this submit with this outcome")
  ["complete" T J Ok Out] Cs -> (sh.result (shu.request [complete T J Ok] Out Cs) "no model state has this delivery with this outcome")
  ["respond" E] Cs -> (let Ev (shu.event-of E)
                        (sh.result (sh.each (/. C (shu.step C [respond Ev] Ev)) Cs)
                                   "a client was told a response that no model state has computed"))
  ["respond-refused" E] Cs -> (sh.result (sh.filter (/. C (shu.outbox-lacks? (shu.event-of E) C)) Cs)
                                         "the service refused a response every model state could deliver")
  ["crash" _] Cs -> (sh.result (sh.each (/. C (shu.step C [crash] none)) Cs) "crash not admitted")
  ["observe" Stores U] Cs -> (sh.result (sh.filter (/. C (and (shu.stores-equal? Stores C) (= (sup.u (hd C)) (shu.upgrade-of U)))) Cs)
                                        "the observed stores or upgrade state differ from those of every model state")
  ["upgrade" Step | Rest] Cs ->
    (let Out (hd (reverse Rest))
         Label (shu.upgrade-label [Step | (reverse (tl (reverse Rest)))])
      (sh.result (shu.upgrade Label Out Cs) "no model state has this upgrade step with this outcome"))
  ["drained"] Cs -> (sh.result (sh.filter (/. C (shu.pending-free? C)) Cs)
                               "the runner found no pending job, but every model state still has an accepted job pending")
  ["gap" Why] Cs -> [indeterminate (cn "the recorder lost events: " Why)]
  X _ -> [reject (make-string "not a history event: ~S" X)])

(define shu.run
  [] _ Cs Max -> [accepted Max]
  [E | Es] I Cs Max ->
    (let R (shu.event E Cs)
      (cond ((= (hd R) ok) (shu.run Es (+ I 1) (nth 2 R) (sh.max Max (length (nth 2 R)))))
            ((= (hd R) indeterminate) [indeterminate I E (nth 2 R) Cs])
            (true [rejected I E (nth 2 R) Cs]))))

\\ The /2 verdict row, in the shape of sh.check-file's.
(define shu.check
  File H Base ->
    (let Tenants (fh.field "tenants" H)
         _ (if (and (integer? Tenants) (> Tenants 0) (<= Tenants 64)) ok (error "bad A4 tenant count"))
         Raw (fh.field "events" H)
         HP (fh.field "handler_pin" H)
         MP (fh.field "migration_pin" H)
         _ (if (and (shu.pin? HP) (shu.pin? MP) (not (= HP MP))) ok (error "bad A4 evidence pins"))
         Events (map (/. E (shu.project E HP MP)) Raw)
         Start [[(sua.initial Tenants) (sup.monitor-initial)]]
         Gap (shu.gap-at Events 0)
         Invalid (shu.invalid-at Events 0)
         Missing (shu.unobserved Events 0)
         R (cond ((cons? Gap) [indeterminate (hd Gap) (nth 2 Gap) "recorder gap"])
                 ((cons? Invalid) [rejected (hd Invalid) (nth 2 Invalid) "identity mismatch or unsupported pilot event"])
                 ((cons? Missing) [indeterminate (hd Missing) (nth 2 Missing) "missing required phase/store observation"])
                 (true (shu.run Events 0 Start 1)))
         Verdict (str (hd R))
         Rows (append Base [["verdict" Verdict] ["events" (length Events)]
                            ["model_steps" (value sh.*model-steps*)] ["predicate_evaluations" (value sh.*predicate-checks*)]
                            ["model" "models/service-a4/upgrade.shen"]])
      (if (= (hd R) accepted)
          [object | (append Rows [["max_candidates" (nth 2 R)]])]
          [object | (append Rows [["first_inadmissible" [object ["index" (nth 2 R)] ["event" (nth 3 R)] ["reason" (nth 4 R)]]]])])))

\\ Pilot format: only the closed, sequential worker fixture vocabulary.
\\ Pins are checked before projection to the model's abstract image `good`.
(define shu.pin?
  B -> (and (string? B) (= (length (explode B)) 256)
            (svcp.all? (/. C (element? C (explode "0123456789abcdef"))) (explode B))))

(define shu.project
  ["upgrade" "begin" HP MP ["ok"]] HP MP -> ["upgrade" "begin" "good" ["ok"]]
  ["observe" Stores ["v1"]] _ _ -> ["observe" Stores ["v1"]]
  ["observe" Stores [Phase HP MP]] HP MP ->
    ["observe" Stores [Phase "good"]] where (element? Phase ["prepared" "migrated" "v2"])
  ["upgrade" "begin" | X] _ _ -> ["invalid-observation-or-unsupported-event" ["upgrade" "begin" | X]]
  E _ _ -> E where (not (element? (hd E) ["observe" "concurrent" "fault" "crash"]))
  E _ _ -> ["invalid-observation-or-unsupported-event" E])

(define shu.gap-at
  [] _ -> none
  [["gap" Why] | _] I -> [I ["gap" Why]]
  [_ | Es] I -> (shu.gap-at Es (+ I 1)))

(define shu.invalid-at
  [] _ -> none
  [["invalid-observation-or-unsupported-event" E] | _] I -> [I E]
  [_ | Es] I -> (shu.invalid-at Es (+ I 1)))

(define shu.unobserved
  [] I -> [I []]
  [["observe" _ _]] _ -> none
  [["upgrade" | X] ["observe" S U] | Es] I -> (shu.unobserved [["observe" S U] | Es] (+ I 1))
  [["upgrade" | X] | _] I -> [I ["upgrade" | X]]
  [_ | Es] I -> (shu.unobserved Es (+ I 1)))
