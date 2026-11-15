\\ TC1 remote perform: a real tc1 handler machine as a member's program.
\\ Contract: spec/tc1/EFFECTS.md §12. UNQUALIFIED.
\\ Load ../tc0/i64.shen, handler-machine.shen and remote-system.shen first.
\\
\\ Program [tc1 State Bindings]: State is a tc1-state, Bindings is
\\ [[Effect Peer] ...], the image's build-time map from remote effects to members.
\\ A remote operation op : A -> B is performed by the caller as
\\   perform(Effect, op, tuple(key, a))      with key : I64 chosen by the program
\\ and has the type RemoteResult B there:
\\   [data "RemoteResult" "reply" V]  [data "RemoteResult" "peer_down"]  [data "RemoteResult" "timed_out"]
\\ The request id is the key. The operation name is not sent: the abstract peer of
\\ remote-system.shen has one operation.
\\
\\ The machine runs from one scheduling point to the next as a single system
\\ step. A perform is remote when no frame handles its effect and the bindings
\\ name a peer for it; a user handler for the same effect name takes precedence,
\\ as dynamic selection says. A program that does not reach a scheduling point
\\ within remote.*tc1-fuel* steps is an error here: the compiler-inserted budget
\\ check of amendment §14 is not modelled.

(set remote.*tc1-fuel* 100000)

(define remote.tc1-initial
  Expr -> [tc1-state [evaluate Expr true] [] [] [] []])

(define remote.tc1-next
  [tc1-state [terminal _] | _] _ -> [halted]
  State Bindings -> (remote.tc1-run State Bindings [] (value remote.*tc1-fuel*)))

(define remote.tc1-remote
  [tc1-state [ready Node perform [Effect Op] [[tuple [int Key] Arg]] Tail] Env Frames Codes Names] Bindings ->
    (if (= (tc1.split Effect Frames []) [invalid unhandled-effect]) (remote.assoc Effect Bindings) [])
  _ _ -> [])

(define remote.tc1-request
  [Peer] [tc1-state [ready Node perform Meta [[tuple [int Key] Arg]] Tail] | Rest] Bindings Events ->
    [request Peer Key Arg [tc1 [tc1-state [ready Node perform Meta [[tuple [int Key] Arg]] Tail] | Rest] Bindings] Events])

(define remote.tc1-run
  _ _ _ 0 -> (error "remote: tc1 program did not reach a scheduling point")
  [tc1-state [terminal Outcome] | Rest] Bindings Events _ -> [halt [tc1 [tc1-state [terminal Outcome] | Rest] Bindings] Events]
  State Bindings Events Fuel ->
    (let Peer (remote.tc1-remote State Bindings)
      (if (= Peer [])
          (let T (tc1.step State)
            (remote.tc1-run (hd (tl T)) Bindings (append Events (hd (tl (tl T)))) (- Fuel 1)))
          (remote.tc1-request Peer State Bindings Events))))

(define remote.tc1-result
  [reply V] -> [data "RemoteResult" "reply" V]
  [peer-down] -> [data "RemoteResult" "peer_down"]
  [timed-out] -> [data "RemoteResult" "timed_out"])

\\ The outcome is the value of the perform; the frames are those the image kept.
(define remote.tc1-resume
  [tc1-state [ready Node perform _ _ _] Env Frames Codes Names] Bindings Outcome ->
    [tc1 [tc1-state [value (remote.tc1-result Outcome)] Env Frames Codes Names] Bindings])
