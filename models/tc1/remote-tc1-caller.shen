\\ TC1 remote perform: a real tc1 handler machine as a member's program.
\\ Contract: spec/tc1/EFFECTS.md §12. UNQUALIFIED.
\\ Load ../tc0/i64.shen, handler-machine.shen and remote-system.shen first.
\\
\\ Program [tc1 State Operations]: State is a tc1-state, Operations is
\\ [[Effect Operation Peer Mode] ...], every operation of every remote effect the
\\ program declares with the member the system manifest binds its effect to; Mode
\\ is "keyed" or "read-only". The build derives the list from the program's
\\ remote-effect declarations (tools/solo5/remote-build.mjs).
\\ A keyed operation op : A -> B is performed by the caller as
\\   perform(Effect, op, tuple(key, a))      with key : I64 chosen by the program
\\ and a read-only one, which has no key, as perform(Effect, op, a). Either has
\\ the type Remote B there:
\\   [data "RemoteResult" "reply" V]  [data "RemoteResult" "not_delivered"]  [data "RemoteResult" "timed_out"]
\\ V is the operation's own result. For a keyed operation that is the pair
\\ [tuple [int Status] [int Value]]: status 0 is ok, status 1 is conflict
\\ (remote-system.shen, remote.ok and remote.conflict), and the request id is the
\\ key. For a read-only operation it is the value. The operation name is not
\\ sent: the abstract peer of remote-system.shen has one operation of each mode.
\\
\\ The machine runs from one scheduling point to the next as a single system
\\ step. A perform is remote when no frame handles its effect and the operations
\\ name a peer for it. In a validated program no frame can handle a remote
\\ effect (EFFECTS.md §3); the frame search is the machine's rule all the same. A program that does not reach a scheduling point
\\ within remote.*tc1-fuel* steps is an error here: the compiler-inserted budget
\\ check of amendment §14 is not modelled.

(set remote.*tc1-fuel* 100000)

(define remote.tc1-initial
  Expr -> [tc1-state [evaluate Expr true] [] [] [] []])

(define remote.tc1-next
  [tc1-state [terminal _] | _] _ -> [halted]
  State Bindings -> (remote.tc1-run State Bindings [] (value remote.*tc1-fuel*)))

\\ [Peer Mode] of Effect.Operation, or [].
(define remote.tc1-operation
  Effect Op [[Effect Op Peer Mode] | _] -> [Peer Mode]
  Effect Op [_ | Operations] -> (remote.tc1-operation Effect Op Operations)
  _ _ [] -> [])

(define remote.tc1-remote
  [tc1-state [ready Node perform [Effect Op] [Arg] Tail] Env Frames Codes Names] Operations ->
    (if (= (tc1.split Effect Frames []) [invalid unhandled-effect]) (remote.tc1-operation Effect Op Operations) [])
  _ _ -> [])

(define remote.tc1-request
  [Peer "keyed"] [tc1-state [ready Node perform Meta [[tuple [int Key] Arg]] Tail] | Rest] Operations Events ->
    [request Peer Key Arg [tc1 [tc1-state [ready Node perform Meta [[tuple [int Key] Arg]] Tail] | Rest] Operations] Events]
  [Peer "read-only"] [tc1-state [ready Node perform Meta [Arg] Tail] | Rest] Operations Events ->
    [request Peer read [read-only Arg] [tc1 [tc1-state [ready Node perform Meta [Arg] Tail] | Rest] Operations] Events])

(define remote.tc1-run
  _ _ _ 0 -> (error "remote: tc1 program did not reach a scheduling point")
  [tc1-state [terminal Outcome] | Rest] Operations Events _ -> [halt [tc1 [tc1-state [terminal Outcome] | Rest] Operations] Events]
  State Operations Events Fuel ->
    (let Operation (remote.tc1-remote State Operations)
      (if (= Operation [])
          (let T (tc1.step State)
            (remote.tc1-run (hd (tl T)) Operations (append Events (hd (tl (tl T)))) (- Fuel 1)))
          (remote.tc1-request Operation State Operations Events))))

(define remote.tc1-result
  [reply V] -> [data "RemoteResult" "reply" V]
  [not-delivered] -> [data "RemoteResult" "not_delivered"]
  [timed-out] -> [data "RemoteResult" "timed_out"])

\\ The outcome is the value of the perform; the frames are those the image kept.
(define remote.tc1-resume
  [tc1-state [ready Node perform _ _ _] Env Frames Codes Names] Bindings Outcome ->
    [tc1 [tc1-state [value (remote.tc1-result Outcome)] Env Frames Codes Names] Bindings])
