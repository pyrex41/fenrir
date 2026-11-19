\\ TC1-D1 durable machine: the TC1 handler machine plus durable effects that the
\\ host discharges. Contract: spec/tc1/DURABLE.md. UNQUALIFIED.
\\ Load ../tc0/i64.shen and handler-machine.shen first. The handler machine is used
\\ unchanged: every step that is not a host request or a host reply is tc1.step.
\\
\\ State [dm-state Inner Seq Context]:
\\   Inner    a tc1-state; while the host holds the continuation its control is
\\            [host-wait Node Effect Operation Value Seq] and nothing else differs
\\            from the Ready perform it came from (same environment, same frames)
\\   Seq      the number of host requests made so far (DURABLE.md section 4)
\\   Context  [dm-context Durables Results Datatypes]: the names of the durable
\\            effects; [Effect Operation ResultType] for each of their operations;
\\            the declared datatypes [Name [[Constructor FieldTypes] ...]]. Types are
\\            in artifact shape ("I64", ["Tuple" T ...], ["Data" Name]).
\\
\\ dm.step State gives [transition Next Events], or [awaiting Node Seq Effect Op Value]
\\ when the machine is in HostWait: it cannot step without the host.
\\ dm.reply State Value gives [transition Next Events] for a well-typed reply, or
\\ [violation Reason] for an ill-typed one (no step: the host broke its contract).
\\ dm.run State Host Fuel drives a run: Host is [replies V ...] (the host's replies in
\\ order) or [host F] (F applied to [request Seq Effect Op Value] gives the reply), so
\\ a run is a function of the program, the input and the host.
\\ Values are the handler machine's: [unit] [bool B] [int "N"] [bytes Octets]
\\ [tuple V ...] [data Type Constructor V ...]; I64 and IDs are decimal strings.

(define dm.initial
  Inner Context -> [dm-state Inner 0 Context])

(define dm.inner
  [dm-state Inner _ _] -> Inner)

(define dm.seq
  [dm-state _ Seq _] -> Seq)

(define dm.control
  [dm-state [tc1-state C | _] _ _] -> C)

(define dm.phase
  State -> (hd (dm.control State)))

(define dm.frames
  [dm-state [tc1-state _ _ Frames _ _] _ _] -> Frames)

(define dm.durable?
  Effect [dm-context Durables _ _] -> (element? Effect Durables))

\\ A perform of a durable effect selects a host request exactly when no active handler
\\ for the effect is in the frames: tc1.split, the handler machine's own selection,
\\ finds none (DURABLE.md section 3). Inactive handlers are inside clause frames'
\\ segments, never in the frame list, so they are not candidates.
(define dm.residual?
  Effect Frames Context -> (and (dm.durable? Effect Context)
                                (= (tc1.split Effect Frames []) [invalid unhandled-effect])))

(define dm.step
  [dm-state [tc1-state [ready Node perform [Effect Op] [V] Tail] Env Frames Codes Names] Seq Context] ->
    [transition [dm-state [tc1-state [host-wait Node Effect Op V Seq] Env Frames Codes Names] (+ Seq 1) Context]
                [[host-request Node Seq Effect Op V]]]
    where (dm.residual? Effect Frames Context)
  [dm-state [tc1-state [host-wait Node Effect Op V Seq] | _] _ _] -> [awaiting Node Seq Effect Op V]
  [dm-state Inner Seq Context] ->
    (let T (tc1.step Inner)
      [transition [dm-state (hd (tl T)) Seq Context] (hd (tl (tl T)))]))

\\ The site of the step from State: the reply step is at the perform node, rule
\\ host-reply; every other site is the handler machine's.
(define dm.site
  [dm-state [tc1-state [host-wait Node | _] | _] _ _] -> [node Node host-reply]
  [dm-state Inner _ _] -> (tc1.site Inner))

\\ ---------- the reply, checked at the boundary (DURABLE.md section 5) ----------

(define dm.result-type
  Effect Op [] -> none
  Effect Op [[Effect Op T] | _] -> T
  Effect Op [_ | Rs] -> (dm.result-type Effect Op Rs))

(define dm.reply
  [dm-state [tc1-state [host-wait Node Effect Op V Seq] Env Frames Codes Names] S [dm-context Ds Rs Types]] R ->
    (let Wrong (dm.ill-typed R (dm.result-type Effect Op Rs) Types [])
      (if (= Wrong [])
          [transition [dm-state [tc1-state [value R] Env Frames Codes Names] S [dm-context Ds Rs Types]]
                      [[host-reply Node Seq R]]]
          [violation Wrong]))
  _ _ -> [violation [not-waiting]])

\\ [] when V is a value of type T, else the path to the first ill-typed component.
(define dm.ill-typed
  [unit] "Unit" _ _ -> []
  [bool B] "Bool" _ _ -> [] where (boolean? B)
  [int N] "I64" _ _ -> [] where (dm.i64? N)
  [bytes Os] "Bytes" _ _ -> [] where (dm.octets? Os)
  [data "TrapCode" C] "TrapCode" _ _ -> [] where (element? C ["Overflow" "DivZero" "Bounds" "InvalidDuration" "TaskLimit" "ChildFailed"])
  [tuple | Vs] ["Tuple" | Ts] Types Path -> (dm.ill-typed-fields Vs Ts Types Path 0) where (= (length Vs) (length Ts))
  [data Name C | Fs] ["Data" Name] Types Path ->
    (let Fields (dm.fields C (dm.constructors Name Types))
      (if (and (not (= Fields none)) (= (length Fields) (length Fs)))
          (dm.ill-typed-fields Fs Fields Types Path 0)
          (dm.at Path)))
  _ _ _ Path -> (dm.at Path))

(define dm.at
  [] -> [root]
  Path -> (reverse Path))

(define dm.ill-typed-fields
  [] [] _ _ _ -> []
  [V | Vs] [T | Ts] Types Path I ->
    (let Wrong (dm.ill-typed V T Types [I | Path])
      (if (= Wrong []) (dm.ill-typed-fields Vs Ts Types Path (+ I 1)) Wrong)))

(define dm.constructors
  _ [] -> []
  Name [[Name Cs] | _] -> Cs
  Name [_ | Ts] -> (dm.constructors Name Ts))

(define dm.fields
  _ [] -> none
  C [[C Fields] | _] -> Fields
  C [_ | Cs] -> (dm.fields C Cs))

(define dm.octets?
  [] -> true
  [O | Os] -> (and (integer? O) (>= O 0) (<= O 255) (dm.octets? Os))
  _ -> false)

\\ A canonical decimal in the I64 range: no sign on zero, no leading zero.
(define dm.digits?
  [] -> true
  [C | Cs] -> (and (element? C ["0" "1" "2" "3" "4" "5" "6" "7" "8" "9"]) (dm.digits? Cs)))

(define dm.magnitude?
  Cs Limit -> (and (dm.digits? Cs) (not (= Cs [])) (or (= Cs ["0"]) (not (= (hd Cs) "0")))
                   (or (< (length Cs) (length Limit))
                       (and (= (length Cs) (length Limit)) (dm.not-above? Cs Limit)))))

(define dm.not-above?
  [] [] -> true
  [C | Cs] [L | Ls] -> (or (< (string->n C) (string->n L)) (and (= C L) (dm.not-above? Cs Ls))))

(define dm.i64?
  N -> false where (not (string? N))
  N -> (let Cs (explode N)
         (if (= (hd Cs) "-")
             (and (not (= (tl Cs) ["0"])) (dm.magnitude? (tl Cs) (explode "9223372036854775808")))
             (dm.magnitude? Cs (explode "9223372036854775807"))))
    where (not (= N ""))
  _ -> false)

\\ ---------- a run under a host ----------

\\ [Execution Records Final], Records a list of [Site Next Events] in order. Execution is
\\ completed, budget-exhausted, awaiting-host (a reply list ran out) or
\\ [host-violation Reason].
(define dm.run
  State Host Fuel -> (dm.run-from State Host Fuel []))

(define dm.run-from
  State _ _ Acc -> [completed (reverse Acc) State] where (= (dm.phase State) terminal)
  State _ 0 Acc -> [budget-exhausted (reverse Acc) State]
  State Host Fuel Acc ->
    (let T (dm.step State)
      (if (= (hd T) awaiting)
          (dm.answer State T Host Fuel Acc)
          (dm.run-from (hd (tl T)) Host (- Fuel 1) [[(dm.site State) (hd (tl T)) (hd (tl (tl T)))] | Acc]))))

(define dm.answer
  State _ [replies] _ Acc -> [awaiting-host (reverse Acc) State]
  State T [replies R | Rs] Fuel Acc -> (dm.deliver State (dm.reply State R) [replies | Rs] Fuel Acc)
  State [awaiting Node Seq Effect Op V] [host F] Fuel Acc ->
    (dm.deliver State (dm.reply State (F [request Seq Effect Op V])) [host F] Fuel Acc))

(define dm.deliver
  State [violation Reason] _ _ Acc -> [[host-violation Reason] (reverse Acc) State]
  State [transition Next Events] Host Fuel Acc ->
    (dm.run-from Next Host (- Fuel 1) [[(dm.site State) Next Events] | Acc]))
