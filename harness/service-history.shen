\\ Fenrir harness, in Shen: stage A3, black-box conformance of a recorded history of the
\\ real service (host/service: OTP host, SQLite adapter, Solo5 worker) against the A1
\\ model (models/service/accepted-job.shen). History format: spec/service/HISTORY_FORMAT.md.
\\ Evidence: "observed history accepted" for a history that is accepted, nothing more.
\\
\\   shen-jit script harness/service-history.shen LIBDIR ROOT OUTDIR check LISTFILE
\\
\\ LISTFILE names one history file per line. For each, one JSON line is written to
\\ standard output and to OUTDIR/verdicts.jsonl: the verdict and, for a rejection, the
\\ first inadmissible event. Exit 0 always when every file could be read (the caller
\\ compares verdicts with expectations); 2 when a file could not be read.
\\
\\ A history is ADMITTED when there is an execution of the model, label by label, whose
\\ responses are the recorded ones, whose stores equal every recorded observation of the
\\ stores, and on whose states and edges every property predicate of
\\ models/service/accepted-job-properties.shen holds. The model's own step and property
\\ functions are used; nothing of them is reimplemented here. What the recorder could not
\\ see is a choice the checker explores: an indeterminate submit or delivery either took
\\ its step (and its response was lost) or did not; the members of a concurrent group are
\\ tried in every order. The checker keeps the set of model states (with their property
\\ monitors) consistent with the history so far.
\\
\\ Verdicts: accepted; rejected, with the first event after which no model state is
\\ consistent, the reason, and for a store observation the property checks that the
\\ OBSERVED store fails (diagnostic only); indeterminate, when the history records a gap
\\ (the recorder lost events) or the candidate set exceeds its bound. An indeterminate
\\ verdict is never an acceptance.

(set sx.*as-library* true)
(load (cn (nth 3 (value *argv*)) "/harness/service-explore.shen"))

(set sh.*bound* 4096)
(set sh.*model-steps* 0)
(set sh.*predicate-checks* 0)

(define sh.step-fn
  -> (/. L S (svc.step L S)))

\\ ---------- decoding (numbers are [number "N"] after json.parse) ----------

(define sh.norm
  [number S] -> (json.integer [number S])
  [X | Xs] -> (map (/. Y (sh.norm Y)) [X | Xs])
  X -> X)

(define sh.event-of
  ["accepted" R] -> (sx.decode-event ["accepted" R])
  ["conflict" T K] -> (sx.decode-event ["conflict" T K])
  X -> (error "history: not an A1 event ~S" X))

(define sh.status
  "pending" -> pending
  "done" -> done
  "failed" -> failed
  X -> (error "history: not a job status ~S" X))

\\ An observed store (canonical JSON, normalized) as a model store.
(define sh.store-of
  [Reports Jobs Keys N] ->
    [store Reports
           (map (/. J [(hd J) (nth 2 J) (sh.status (nth 3 J))]) Jobs)
           (map (/. E [(hd E) (nth 2 E) [receipt | (nth 3 E)]]) Keys)
           N])

\\ ---------- candidates: [Sys Monitor] ----------

\\ One model step from a candidate: the candidates it leads to (none or one). Expect is
\\ the required response (an event or none) or any.
(define sh.step
  [X M] Label Expect ->
    (let R (svc.step Label X)
      (if (= R disabled) []
          (let Y (nth 2 R)
               Resp (nth 3 R)
               _ (set sh.*model-steps* (+ 1 (value sh.*model-steps*)))
            (if (or (= Expect any) (= Expect Resp))
                (let M2 (svcp.monitor-step Label Resp M)
                     V (append (svcp.edge-violations (sh.step-fn) X M Label Y Resp)
                               (svcp.state-violations (sh.step-fn) M2 Y))
                     _ (set sh.*predicate-checks* (+ 1 (value sh.*predicate-checks*)))
                  (if (empty? V) [[Y M2]] [[violated V]]))
                [])))))

(define sh.dedupe
  [] Acc -> (reverse Acc)
  [C | Cs] Acc -> (sh.dedupe Cs (if (element? C Acc) Acc [C | Acc])))

\\ Apply F to every candidate and collect; a model property violation stops everything.
(define sh.each
  F Cs -> (sh.collect (mapcan F Cs)))

(define sh.collect
  Cs -> (let V (sh.violations Cs [])
          (if (empty? V) (sh.dedupe Cs []) [violated V])))

(define sh.violations
  [] Acc -> Acc
  [[violated V] | Cs] Acc -> (sh.violations Cs (append V Acc))
  [_ | Cs] Acc -> (sh.violations Cs Acc))

(define sh.outcome-expect
  ["accepted" R] -> [step (sh.event-of ["accepted" R])]
  ["conflict" T K] -> [step (sh.event-of ["conflict" T K])]
  ["delivered"] -> [step none]
  ["other"] -> [step none]
  ["busy"] -> no-step
  ["aborted"] -> no-step
  ["refused"] -> no-step
  ["indeterminate"] -> maybe
  X -> (error "history: not an outcome ~S" X))

\\ A labelled request with its recorded outcome.
(define sh.request
  Label Out Cs ->
    (let E (sh.outcome-expect Out)
      (cond ((= E no-step) Cs)
            ((= E maybe) (sh.each (/. C [C | (sh.step C Label any)]) Cs))
            (true (sh.each (/. C (sh.step C Label (nth 2 E))) Cs)))))

(define sh.pending-free?
  [[sys Stores _ _] _] -> (svcp.all? (/. S (svcp.all? (/. J (not (= (nth 3 J) pending))) (svc.jobs S))) Stores))

(define sh.stores-equal?
  Observed [[sys Stores _ _] _] -> (= (map (/. S (sx.tenant S)) Stores) Observed))

(define sh.filter
  P [] -> []
  P [X | Xs] -> (if (P X) [X | (sh.filter P Xs)] (sh.filter P Xs)))

(define sh.outbox-lacks?
  E [[sys _ Outbox _] _] -> (not (element? E Outbox)))

(define sh.permutations
  [] -> [[]]
  Xs -> (mapcan (/. X (map (/. P [X | P]) (sh.permutations (remove X Xs)))) Xs))

\\ One history event: [ok Cands'] | [reject Reason] | [indeterminate Reason].
(define sh.event
  ["submit" T K D Out] Cs -> (sh.result (sh.request [submit T K D] Out Cs) "no model state has this submit with this outcome")
  ["complete" T J Ok Out] Cs -> (sh.result (sh.request [complete T J Ok] Out Cs) "no model state has this delivery with this outcome")
  ["respond" E] Cs -> (let Ev (sh.event-of E)
                        (sh.result (sh.each (/. C (sh.step C [respond Ev] Ev)) Cs)
                                   "a client was told a response that no model state has computed"))
  ["respond-refused" E] Cs -> (sh.result (sh.filter (/. C (sh.outbox-lacks? (sh.event-of E) C)) Cs)
                                         "the service refused a response every model state could deliver")
  ["crash" _] Cs -> (sh.result (sh.each (/. C (sh.step C [crash] none)) Cs) "crash not admitted")
  ["fault" | _] Cs -> [ok Cs]
  ["observe" Stores] Cs -> (sh.result (sh.filter (/. C (sh.stores-equal? Stores C)) Cs)
                                      "the observed stores differ from the stores of every model state")
  ["drained"] Cs -> (sh.result (sh.filter (/. C (sh.pending-free? C)) Cs)
                               "the runner found no pending job, but every model state still has an accepted job pending")
  ["concurrent" Evs] Cs -> (sh.result (sh.group (sh.permutations Evs) Cs []) "no order of the concurrent group is admitted")
  ["gap" Why] Cs -> [indeterminate (cn "the recorder lost events: " Why)]
  X _ -> [reject (make-string "not a history event: ~S" X)])

(define sh.result
  [violated V] _ -> [reject (make-string "a model property predicate failed on a model state: ~S" V)]
  [] Reason -> [reject Reason]
  Cs _ -> (if (> (length Cs) (value sh.*bound*)) [indeterminate "candidate bound exceeded"] [ok Cs]))

(define sh.group
  [] _ Acc -> (sh.dedupe Acc [])
  [P | Ps] Cs Acc -> (let R (sh.sequence P Cs)
                       (sh.group Ps Cs (if (= (hd R) ok) (append (nth 2 R) Acc) Acc))))

(define sh.sequence
  [] Cs -> [ok Cs]
  [E | Es] Cs -> (let R (sh.event E Cs) (if (= (hd R) ok) (sh.sequence Es (nth 2 R)) R)))

\\ ---------- one history ----------

(define sh.run
  [] _ Cs Max -> [accepted Max]
  [E | Es] I Cs Max ->
    (let R (sh.event E Cs)
      (cond ((= (hd R) ok) (sh.run Es (+ I 1) (nth 2 R) (sh.max Max (length (nth 2 R)))))
            ((= (hd R) indeterminate) [indeterminate I E (nth 2 R) Cs])
            (true [rejected I E (nth 2 R) Cs]))))

(define sh.max
  A B -> (if (> A B) A B))

\\ Diagnostic for a rejected observation: the checks the OBSERVED stores fail, judged
\\ with the first candidate's outbox and trace (not part of the verdict).
(define sh.diagnose
  ["observe" Stores] [[[sys _ Outbox Trace] _] | _] ->
    (map (/. V (nth 2 V)) (svcp.state-violations (sh.step-fn) [] [sys (map (/. S (sh.store-of S)) Stores) Outbox Trace]))
  _ _ -> [])

(define sh.check-file
  File ->
    (let _ (set sh.*model-steps* 0)
         _ (set sh.*predicate-checks* 0)
         H (sh.norm (json.parse (read-file-as-string File) [[byte-limit 67108864]]))
      (sh.check-schema (fh.field "schema" H) File H)))

(define sh.check-schema
  "fenrir.service.history/1" File H -> (sh.check-file-1 File H)
  "fenrir.service.history/2" File H -> (shu.check File H [["history" File]
            ["scenario" (fh.field "scenario" H)] ["schema" "fenrir.service.history/2"]])
  _ _ _ -> (error "unknown service history schema"))

(define sh.check-file-1
  File H ->
    (let Tenants (fh.field "tenants" H)
         Events (fh.field "events" H)
         Expect (trap-error (fh.field "expect" H) (/. E "none"))
         Start [[(svc.initial Tenants) (svcp.monitor-initial)]]
         R (sh.run Events 0 Start 1)
         Verdict (str (hd R))
         Base [["history" File]
               ["scenario" (trap-error (fh.field "scenario" H) (/. E ""))]
               ["verdict" Verdict]
               ["expect" Expect]
               ["events" (length Events)]
               ["model_steps" (value sh.*model-steps*)]
               ["predicate_evaluations" (value sh.*predicate-checks*)]]
      (if (= (hd R) accepted)
          [object | (append Base [["max_candidates" (nth 2 R)]])]
          [object | (append Base [["first_inadmissible" [object ["index" (nth 2 R)] ["event" (nth 3 R)] ["reason" (nth 4 R)]
                                                               ["observed_state_violations" (sh.diagnose (nth 3 R) (nth 5 R))]]]])])))

(define sh.lines
  S -> (sh.filter (/. L (not (= L ""))) (fh.lines S)))

(define sh.main
  "check" ->
    (let Files (sh.lines (read-file-as-string (hd (value sx.*args*))))
         Out (cn (value fh.*out*) "verdicts.jsonl")
         Rows (map (/. F (trap-error (sh.check-file F)
                                    (/. E [object ["history" F] ["verdict" "unreadable"] ["error" (error-to-string E)]])))
                   Files)
         Text (sh.join (map (/. R (sx.json R)) Rows))
         _ (write-to-file Out Text)
      (do (output "~A" Text)
          (shen-jit.exit (if (svcp.any? (/. R (= (fh.field "verdict" R) "unreadable")) Rows) 2 0))))
  Mode -> (do (output "unknown mode ~A~%" Mode) (shen-jit.exit 2)))

(define sh.join
  [] -> ""
  [L | Ls] -> (cn L (cn (make-string "~%") (sh.join Ls))))

(load (cn (value fh.*root*) "harness/service-history-upgrade.shen"))
(sh.main (value sx.*mode*))
