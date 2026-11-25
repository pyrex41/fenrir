------------------------------ MODULE RemoteEffect ------------------------------
(***************************************************************************)
(* Remote-effect protocol, written from the prose contract only:           *)
(*   spec/tc1/EFFECTS.md §12 (especially §12.2–§12.9) and supervisor/README *)
(* This is not a translation of models/tc1/remote-system.shen.             *)
(*                                                                          *)
(* One caller, one peer, one keyed operation. The network may drop and     *)
(* duplicate. The peer's reply record is indexed by request id (the        *)
(* caller's key) and stores the operation and argument, which is how the   *)
(* peer decides replay versus conflict (EFFECTS §12.3; the implementation  *)
(* table is record_slot(caller, key) and then compares operation and       *)
(* argument).                                                               *)
(*                                                                          *)
(* everHanded is a history variable. It is not supervisor state. NDSound   *)
(* is judged from it, as §12.8 judges not-delivered-not-handed "from the   *)
(* history, not from the supervisor's own record of hand-overs".           *)
(***************************************************************************)

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxCrash, MaxDup, MaxIntent, MaxAttempt, MaxVer,
          VMLoss, UpgradeOn, SupRestartOn

ASSUME /\ MaxCrash \in Nat /\ MaxDup \in Nat /\ MaxIntent \in Nat
       /\ MaxAttempt \in Nat /\ MaxVer \in Nat
       /\ MaxIntent >= 1 /\ MaxAttempt >= 1 /\ MaxVer >= 1
       /\ VMLoss \in BOOLEAN /\ UpgradeOn \in BOOLEAN /\ SupRestartOn \in BOOLEAN

Keys == 1 .. (MaxIntent * MaxAttempt)
Tags == 1 .. (MaxIntent * MaxAttempt)
Intents == 1 .. MaxIntent
Versions == 1 .. MaxVer

\* One argument for every intent. The caller does not reuse a key with another
\* argument (the §12.3 caller obligation), so this model has no conflict branch.
Arg == 1

NetCap == 3
InboxCap == 2

\* F[version](arg). Two versions differ. The signature digest is not a
\* variable: Upgrade does not change it (EFFECTS §12.6: the digest covers the
\* effect name, operation names, types and read-only markers, not the body).
F(v, a) == v * 10 + a

NoRec == [kind |-> "none", op |-> "op", arg |-> 0, val |-> 0, at |-> 0]
NoOut == [kind |-> "none", key |-> 0, val |-> 0, expect |-> 0, arg |-> 0, intent |-> 0]
IdlePend == [kind |-> "none", tag |-> 0, key |-> 0, arg |-> 0, intent |-> 0, expect |-> 0]

VARIABLES ver, crashes, dups, peer, net, inbox,
          handed, everHanded, accepted,
          rec, applied, intentHits,
          pend, out, outCount,
          tagN, keyN, intent, tries, heldKey, mode,
          got, status

vars == <<ver, crashes, dups, peer, net, inbox,
          handed, everHanded, accepted,
          rec, applied, intentHits,
          pend, out, outCount,
          tagN, keyN, intent, tries, heldKey, mode,
          got, status>>

RemoveAt(s, i) == SubSeq(s, 1, i - 1) \o SubSeq(s, i + 1, Len(s))

RecOf(k, a, v, at) == [kind |-> "rec", op |-> "op", arg |-> a, val |-> v, at |-> at]
ReqOf(t, k, i, e) == [kind |-> "req", tag |-> t, key |-> k, intent |-> i,
                      expect |-> e, arg |-> Arg, val |-> 0]
RepOf(m, v) == [kind |-> "rep", tag |-> m.tag, key |-> m.key, intent |-> m.intent,
                expect |-> m.expect, arg |-> m.arg, val |-> v]
OutReply(m) == [kind |-> "reply", key |-> m.key, val |-> m.val, expect |-> m.expect,
                arg |-> m.arg, intent |-> m.intent]
OutND(p) == [kind |-> "nd", key |-> p.key, val |-> 0, expect |-> p.expect,
             arg |-> p.arg, intent |-> p.intent]
OutTO(p) == [kind |-> "to", key |-> p.key, val |-> 0, expect |-> p.expect,
             arg |-> p.arg, intent |-> p.intent]

(***************************************************************************)
(* Invariants                                                               *)
(***************************************************************************)

TypeOK ==
  /\ ver \in Versions
  /\ crashes \in 0 .. MaxCrash
  /\ dups \in 0 .. MaxDup
  /\ peer \in {"up", "down"}
  /\ Len(net) <= NetCap /\ Len(inbox) <= InboxCap
  /\ handed \subseteq Keys /\ everHanded \subseteq Keys /\ accepted \subseteq Keys
  /\ mode \in {"fresh", "same"}
  /\ intent \in 1 .. (MaxIntent + 1)
  /\ tries \in 0 .. MaxAttempt
  /\ heldKey \in (Keys \cup {0})
  /\ tagN \in 1 .. (MaxIntent * MaxAttempt + 1)
  /\ keyN \in 1 .. (MaxIntent * MaxAttempt + 1)
  /\ pend.kind \in {"none", "wait"}
  /\ \A t \in Tags: out[t].kind \in {"none", "reply", "nd", "to"} /\ outCount[t] \in 0 .. 1
  /\ \A k \in Keys: rec[k].kind \in {"none", "rec"} /\ applied[k] \in Nat
  /\ \A i \in Intents: status[i] \in {"open", "reply", "nd", "gaveup"} /\ got[i] \in BOOLEAN
  /\ \A i \in Intents: intentHits[i] \in Nat

\* The peer's own obligation (§12.3): one request id is applied at most once.
PerKey == \A k \in Keys: applied[k] <= 1

\* Across the fresh-key chain of one caller intent. Stronger than §12.8's
\* applied-at-most-once, which is per request id. See the report.
NoDoubleApply == \A i \in Intents: intentHits[i] <= 1

\* out = not_delivered(k) => k was never handed to the peer and has no record.
NDSound ==
  \A t \in Tags:
    out[t].kind = "nd" =>
      /\ out[t].key \notin everHanded
      /\ rec[out[t].key].kind = "none"

SingleOutcome == \A t \in Tags: outCount[t] <= 1

\* A reply value is the caller's expected version of F applied to the argument.
VersionSafe ==
  \A t \in Tags:
    out[t].kind = "reply" => out[t].val = F(out[t].expect, out[t].arg)

(***************************************************************************)
(* Initial state                                                            *)
(***************************************************************************)

Init ==
  /\ ver = 1
  /\ crashes = MaxCrash
  /\ dups = MaxDup
  /\ peer = "up"
  /\ net = << >>
  /\ inbox = << >>
  /\ handed = {}
  /\ everHanded = {}
  /\ accepted = {}
  /\ rec = [k \in Keys |-> NoRec]
  /\ applied = [k \in Keys |-> 0]
  /\ intentHits = [i \in Intents |-> 0]
  /\ pend = IdlePend
  /\ out = [t \in Tags |-> NoOut]
  /\ outCount = [t \in Tags |-> 0]
  /\ tagN = 1
  /\ keyN = 1
  /\ intent = 1
  /\ tries = 0
  /\ heldKey = 0
  /\ mode = "fresh"
  /\ got = [i \in Intents |-> FALSE]
  /\ status = [i \in Intents |-> "open"]

(***************************************************************************)
(* Issue: the caller picks a key. A retry after not_delivered uses a fresh *)
(* key (permitted by §12.4: the caller was told the peer has not acted).   *)
(* A retry after timed_out reuses the key (§12.3). expect is the peer      *)
(* version at issue, the version the caller is issuing against.            *)
(***************************************************************************)

Issue ==
  /\ intent \in Intents
  /\ pend.kind = "none"
  /\ tries < MaxAttempt
  /\ Len(net) < NetCap
  /\ LET k == IF mode = "fresh" \/ heldKey = 0 THEN keyN ELSE heldKey
     IN /\ k \in Keys
        /\ tagN \in Tags
        /\ pend' = [kind |-> "wait", tag |-> tagN, key |-> k, arg |-> Arg,
                    intent |-> intent, expect |-> ver]
        /\ net' = Append(net, ReqOf(tagN, k, intent, ver))
        /\ accepted' = accepted \cup {k}
        /\ tagN' = tagN + 1
        /\ keyN' = IF mode = "fresh" \/ heldKey = 0 THEN keyN + 1 ELSE keyN
        /\ heldKey' = k
        /\ tries' = tries + 1
        /\ mode' = "same"
        /\ UNCHANGED <<ver, crashes, dups, peer, inbox, handed, everHanded,
                       rec, applied, intentHits, out, outCount, intent, got, status>>

(***************************************************************************)
(* Deliver one in-flight message, in any order (§12.5 "any order").        *)
(* A request is handed over only to an up peer. The hand-over is recorded  *)
(* in the same step as the inbox write (§12.8 clarification: the record is *)
(* made before the write; this model does not split that pair).            *)
(***************************************************************************)

Deliver ==
  /\ Len(net) > 0
  /\ \E i \in 1 .. Len(net):
       LET m == net[i]
       IN \/ /\ m.kind = "req"
             /\ peer = "up"
             /\ Len(inbox) < InboxCap
             /\ net' = RemoveAt(net, i)
             /\ inbox' = Append(inbox, m)
             /\ handed' = handed \cup {m.key}
             /\ everHanded' = everHanded \cup {m.key}
             /\ UNCHANGED <<ver, crashes, dups, peer, accepted, rec, applied,
                            intentHits, pend, out, outCount, tagN, keyN,
                            intent, tries, heldKey, mode, got, status>>
          \/ /\ m.kind = "rep"
             /\ net' = RemoveAt(net, i)
             /\ IF pend.kind = "wait" /\ pend.tag = m.tag
                THEN /\ out' = [out EXCEPT ![m.tag] = OutReply(m)]
                     /\ outCount' = [outCount EXCEPT ![m.tag] = @ + 1]
                     /\ pend' = IdlePend
                     /\ got' = [got EXCEPT ![pend.intent] = TRUE]
                     /\ status' = [status EXCEPT ![pend.intent] = "reply"]
                     /\ intent' = intent + 1
                     /\ tries' = 0
                     /\ heldKey' = 0
                     /\ mode' = "fresh"
                     /\ UNCHANGED <<ver, crashes, dups, peer, inbox, handed,
                                    everHanded, accepted, rec, applied, intentHits,
                                    tagN, keyN>>
                ELSE \* Stale reply: discarded, not shown (§12.4).
                     /\ UNCHANGED <<ver, crashes, dups, peer, inbox, handed,
                                    everHanded, accepted, rec, applied, intentHits,
                                    pend, out, outCount, tagN, keyN, intent,
                                    tries, heldKey, mode, got, status>>

(***************************************************************************)
(* Act on the oldest inbox request (§12.3). No record: apply F[ver] and    *)
(* record the value with the operation and argument. Same op+arg: replay   *)
(* the recorded value. The reply is put in flight; it is not yet an        *)
(* outcome.                                                                 *)
(***************************************************************************)

Act ==
  /\ peer = "up"
  /\ Len(inbox) > 0
  /\ Len(net) < NetCap
  /\ LET m == Head(inbox)
         k == m.key
     IN /\ inbox' = Tail(inbox)
        /\ IF rec[k].kind = "none"
           THEN /\ rec' = [rec EXCEPT ![k] = RecOf(k, m.arg, F(ver, m.arg), ver)]
                /\ applied' = [applied EXCEPT ![k] = @ + 1]
                /\ intentHits' = [intentHits EXCEPT ![m.intent] = @ + 1]
                /\ net' = Append(net, RepOf(m, F(ver, m.arg)))
           ELSE /\ rec[k].op = "op" /\ rec[k].arg = m.arg
                /\ net' = Append(net, RepOf(m, rec[k].val))
                /\ UNCHANGED <<rec, applied, intentHits>>
        /\ UNCHANGED <<ver, crashes, dups, peer, handed, everHanded, accepted,
                       pend, out, outCount, tagN, keyN, intent, tries, heldKey,
                       mode, got, status>>

Drop ==
  /\ Len(net) > 0
  /\ \E i \in 1 .. Len(net):
       /\ net' = RemoveAt(net, i)
       /\ UNCHANGED <<ver, crashes, dups, peer, inbox, handed, everHanded,
                      accepted, rec, applied, intentHits, pend, out, outCount,
                      tagN, keyN, intent, tries, heldKey, mode, got, status>>

Dup ==
  /\ dups > 0
  /\ Len(net) > 0
  /\ Len(net) < NetCap
  /\ \E i \in 1 .. Len(net):
       /\ net' = Append(net, net[i])
       /\ dups' = dups - 1
       /\ UNCHANGED <<ver, crashes, peer, inbox, handed, everHanded, accepted,
                      rec, applied, intentHits, pend, out, outCount, tagN, keyN,
                      intent, tries, heldKey, mode, got, status>>

\* timed_out at any time while the caller waits (§12.4). The in-flight
\* messages stay. A later reply for this tag is discarded.
Timeout ==
  /\ pend.kind = "wait"
  /\ out[pend.tag].kind = "none"
  /\ out' = [out EXCEPT ![pend.tag] = OutTO(pend)]
  /\ outCount' = [outCount EXCEPT ![pend.tag] = @ + 1]
  /\ pend' = IdlePend
  /\ IF tries >= MaxAttempt
     THEN /\ status' = [status EXCEPT ![intent] = "gaveup"]
          /\ intent' = intent + 1
          /\ tries' = 0
          /\ heldKey' = 0
          /\ mode' = "fresh"
          /\ UNCHANGED <<got>>
     ELSE /\ mode' = "same"
          /\ UNCHANGED <<intent, tries, heldKey, status, got>>
  /\ UNCHANGED <<ver, crashes, dups, peer, net, inbox, handed, everHanded,
                 accepted, rec, applied, intentHits, tagN, keyN>>

\* Answers not_delivered iff the key is not in `handed` — the supervisor's
\* own record, not everHanded (§12.5, and the relay's enabled_steps).
\* Destroys in-flight request copies of that id first (§12.4).
NotDelivered ==
  /\ pend.kind = "wait"
  /\ pend.key \notin handed
  /\ out[pend.tag].kind = "none"
  /\ out' = [out EXCEPT ![pend.tag] = OutND(pend)]
  /\ outCount' = [outCount EXCEPT ![pend.tag] = @ + 1]
  /\ net' = SelectSeq(net, LAMBDA m: ~ (m.kind = "req" /\ m.key = pend.key))
  /\ pend' = IdlePend
  /\ got' = [got EXCEPT ![pend.intent] = TRUE]
  /\ IF tries >= MaxAttempt
     THEN /\ status' = [status EXCEPT ![intent] = "nd"]
          /\ intent' = intent + 1
          /\ tries' = 0
          /\ heldKey' = 0
          /\ mode' = "fresh"
     ELSE /\ mode' = "fresh"
          /\ UNCHANGED <<intent, tries, heldKey, status>>
  /\ UNCHANGED <<ver, crashes, dups, peer, inbox, handed, everHanded, accepted,
                 rec, applied, intentHits, tagN, keyN>>

\* Volatile loss. Inbox emptied, store kept (§12.7). Same crash budget as
\* CrashAfterCommit.
Crash ==
  /\ peer = "up"
  /\ crashes > 0
  /\ peer' = "down"
  /\ inbox' = << >>
  /\ crashes' = crashes - 1
  /\ UNCHANGED <<ver, dups, net, handed, everHanded, accepted, rec, applied,
                 intentHits, pend, out, outCount, tagN, keyN, intent, tries,
                 heldKey, mode, got, status>>

\* Commit, then die before any reply exists (§12.7 crash-after-commit).
CrashAfterCommit ==
  /\ peer = "up"
  /\ crashes > 0
  /\ Len(inbox) > 0
  /\ LET m == Head(inbox)
         k == m.key
     IN /\ rec[k].kind = "none"
        /\ rec' = [rec EXCEPT ![k] = RecOf(k, m.arg, F(ver, m.arg), ver)]
        /\ applied' = [applied EXCEPT ![k] = @ + 1]
        /\ intentHits' = [intentHits EXCEPT ![m.intent] = @ + 1]
        /\ peer' = "down"
        /\ inbox' = << >>
        /\ crashes' = crashes - 1
        /\ UNCHANGED <<ver, dups, net, handed, everHanded, accepted, pend, out,
                       outCount, tagN, keyN, intent, tries, heldKey, mode, got, status>>

PeerRestart ==
  /\ peer = "down"
  /\ peer' = "up"
  /\ inbox' = << >>
  /\ UNCHANGED <<ver, crashes, dups, net, handed, everHanded, accepted, rec,
                 applied, intentHits, pend, out, outCount, tagN, keyN, intent,
                 tries, heldKey, mode, got, status>>

\* Contract restart (§12.7): messages in flight lost; the accepted-id set is
\* kept and becomes the hand-over record (every id issued before the restart
\* counts as handed over). Members, store, inbox and the pending perform stay.
\* Disabled when it would change nothing, so it is not an infinite stutter.
SupRestart ==
  /\ SupRestartOn
  /\ \/ net /= << >>
     \/ handed /= accepted
  /\ net' = << >>
  /\ handed' = accepted
  /\ UNCHANGED <<ver, crashes, dups, peer, inbox, everHanded, accepted, rec,
                 applied, intentHits, pend, out, outCount, tagN, keyN, intent,
                 tries, heldKey, mode, got, status>>

\* The whole Erlang VM is lost. The journal is memory of another process in
\* the same VM (fenrir_journal.erl; supervisor/README "What is not shown":
\* the loss of the Erlang VM). handed and accepted vanish with it.
\* Also cleared, because they live in that same VM and not on the peer's
\* store: the in-flight network, and the peer inbox (a new boot writes empty
\* mailboxes; the store file is kept). everHanded, rec and applied stay.
\* The caller's pending attempt is left in place so the new supervisor can
\* still be asked for an outcome. See the report for this choice.
SupVMLoss ==
  /\ VMLoss
  /\ \/ handed /= {}
     \/ accepted /= {}
     \/ net /= << >>
     \/ inbox /= << >>
  /\ handed' = {}
  /\ accepted' = {}
  /\ net' = << >>
  /\ inbox' = << >>
  /\ UNCHANGED <<ver, crashes, dups, peer, everHanded, rec, applied, intentHits,
                 pend, out, outCount, tagN, keyN, intent, tries, heldKey, mode,
                 got, status>>

\* Peer moves to the next version. Same signature digest, different F.
\* At most one step, and ver stays <= MaxVer.
Upgrade ==
  /\ UpgradeOn
  /\ ver < MaxVer
  /\ ver' = ver + 1
  /\ UNCHANGED <<crashes, dups, peer, net, inbox, handed, everHanded, accepted,
                 rec, applied, intentHits, pend, out, outCount, tagN, keyN,
                 intent, tries, heldKey, mode, got, status>>

\* The caller has finished every intent and nothing else is required.
\* Stops TLC reporting a terminal state as a deadlock.
Quiesce ==
  /\ intent > MaxIntent
  /\ pend.kind = "none"
  /\ Len(net) = 0
  /\ Len(inbox) = 0
  /\ peer = "up"
  /\ UNCHANGED vars

Next ==
  \/ Issue \/ Deliver \/ Act \/ Drop \/ Dup \/ Timeout \/ NotDelivered
  \/ Crash \/ CrashAfterCommit \/ PeerRestart
  \/ SupRestart \/ SupVMLoss \/ Upgrade \/ Quiesce

Spec == Init /\ [][Next]_vars

\* Progress actions are weakly fair. Timeout, drop, duplicate, crash and
\* supervisor restart are faults: they may be taken, and the attempt bound
\* plus the crash and duplicate budgets make them finite. VM loss and upgrade
\* are off in the liveness configuration.
FairSpec ==
  /\ Spec
  /\ WF_vars(Issue)
  /\ WF_vars(Deliver)
  /\ WF_vars(Act)
  /\ WF_vars(PeerRestart)
  /\ WF_vars(NotDelivered)

\* Each caller intent eventually observes a reply or a not_delivered.
\* timed_out does not count: §12.4 says it concludes nothing.
EventuallySettled == <> (\A i \in Intents: got[i])

=============================================================================
