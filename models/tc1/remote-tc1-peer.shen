\\ TC1 remote perform: a peer's program, run by the tc1 handler machine.
\\ Contract: spec/tc1/EFFECTS.md §8, §12.3, §12.12. UNQUALIFIED.
\\ Load ../tc0/i64.shen, handler-machine.shen and remote-system.shen first.
\\
\\ A peer's program (artifact schema tc1-handler-demo/4, a source file with a
\\ (serve ...) form) has one function for each operation it serves. Here it is
\\   Program [Tag HasStore Table Codes Names]
\\     Tag       a name for the program (the checker's ledger invariant asks for it)
\\     HasStore  false for a peer with no durable store
\\     Table     [[Operation Mode Parameter Body] ...], Operation "Effect.operation",
\\               Mode "keyed" or "read-only", Body the function's expression
\\     Codes, Names   the tc1 machine's tables for the program's functions and lambdas
\\ harness/common.shen (fh.peer) makes one from an artifact.
\\
\\ One request is one run of the operation's function on the request's input:
\\ tuple(key, argument) for a keyed operation, the argument for a read-only one.
\\ The machine is unchanged and has no notion of a store. The store is two
\\ effects that no frame handles, of the durable class of section 8: when the
\\ machine is Ready at
\\   perform(StoreRead, get, k)        its value is what this request last put at
\\                                     k, else the store's value, else 0;
\\   perform(StoreWrite, put, (k, v))  v is kept aside for k, and the value is unit.
\\ No machine step is taken for such a perform, and the frames stay where they
\\ are, exactly as for a caller's remote perform (remote-tc1-caller.shen).
\\ Nothing is committed here: remote.served says how the run ended and what it
\\ would write, and the peer's runtime in remote-system.shen commits that with
\\ the request's record, or not at all.
\\
\\ remote.served Stale Program Operation Input Store -> [Outcome Writes]
\\   Outcome  [ok Value] or [trap Code], as the machine ends
\\   Writes   [[Key Value] ...] in ascending key order: the final value of each
\\            cell the run wrote. Meaningful only with [ok ...].
\\   Stale    the deliberate defect: a read does not see the request's own writes
\\ A run that has not ended after remote.*peer-fuel* machine steps is an error
\\ here, as a caller that reaches no scheduling point is.

(set remote.*peer-fuel* 2000)
(set remote.*served* (shen.dict 4096))

\\ The store perform the machine is Ready at, when no frame handles its effect:
\\ [NextState Buffer Event], Event [get Key Value] or [put Key Value]; else [].
\\ Buffer is the request's writes so far, [[Key Value] ...], one entry for a key.
(define remote.store-perform
  [tc1-state [ready Node perform ["StoreRead" "get"] [[int K]] Tail] Env Frames Codes Names] Store Buffer Stale ->
    (let V (if (or Stale (= (remote.assoc K Buffer) [])) (remote.store-get K Store) (hd (remote.assoc K Buffer)))
      [[tc1-state [value [int V]] Env Frames Codes Names] Buffer [get K V]])
    where (= (tc1.split "StoreRead" Frames []) [invalid unhandled-effect])
  [tc1-state [ready Node perform ["StoreWrite" "put"] [[tuple [int K] [int V]]] Tail] Env Frames Codes Names] Store Buffer Stale ->
    [[tc1-state [value [unit]] Env Frames Codes Names] (remote.store-put K V Buffer) [put K V]]
    where (= (tc1.split "StoreWrite" Frames []) [invalid unhandled-effect])
  _ _ _ _ -> [])

(define remote.peer-function
  Op [[Op Mode Parameter Body] | _] -> [Parameter Body]
  Op [_ | Table] -> (remote.peer-function Op Table)
  Op [] -> (error "remote: this peer does not serve ~A" Op))

\\ The machine's first state for one request.
(define remote.peer-state
  [Tag HasStore Table Codes Names] Op Input ->
    (let F (remote.peer-function Op Table)
      [tc1-state [evaluate (hd (tl F)) true] [[(hd F) Input]] [] Codes Names]))

(define remote.peer-run
  [tc1-state [terminal Outcome] | _] Store Buffer Stale _ -> [Outcome Buffer]
  _ _ _ _ 0 -> (error "remote: a peer's program did not finish a request within its step bound")
  State Store Buffer Stale Fuel ->
    (let P (remote.store-perform State Store Buffer Stale)
      (if (= P [])
          (remote.peer-run (hd (tl (tc1.step State))) Store Buffer Stale (- Fuel 1))
          (remote.peer-run (hd P) Store (hd (tl P)) Stale Fuel))))

\\ The run of one request, remembered: an exploration acts on the same request
\\ and store many times.
(define remote.served
  Stale Program Op Input Store ->
    (let Key (make-string "~S" [(hd Program) Stale Op Input Store])
         Known (trap-error (shen.<-dict (value remote.*served*) Key) (/. E absent))
      (if (= Known absent)
          (let R (remote.peer-run (remote.peer-state Program Op Input) Store [] Stale (value remote.*peer-fuel*))
               Kept (shen.dict-> (value remote.*served*) Key R)
            R)
          Known)))
