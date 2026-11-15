# The supervisor between images

Erlang/OTP implementation of the supervisor's part of remote perform. The
contract is [spec/tc1/EFFECTS.md](../spec/tc1/EFFECTS.md) §12; the model is
[models/tc1/remote-system.shen](../models/tc1/remote-system.shen). First
implementation, development code, `qualification: UNKNOWN`, in no gate.

A system is one image per member, a static manifest of declared connections,
and this supervisor, which is outside the images and carries every message. A
remote operation returns exactly one of `reply v`, `peer_down`, `timed_out`.

```sh
sh harness/run-tc1-remote-run.sh    # the check: real system against the model, about 35 s
sh supervisor/run.sh                # one free-running run by hand; prints where result.json is
sh supervisor/build.sh ERLC EBIN    # compile only: erlc, no rebar, no hex
```

Erlang/OTP comes from the flake (`nix build .#erlang`, OTP 28 without wx), or
set `FENRIR_ERLANG` to an installation, or have `erl` and `erlc` on `PATH`.
Solo5 as for the other guests: `FENRIR_SOLO5` or `build/vendor/solo5`.

## The pieces

| Piece | Where | What it is |
| --- | --- | --- |
| Caller image | [backends/solo5/remote/caller.c](../backends/solo5/remote/caller.c) | A real TC1 program ([fixtures/tc1/remote-caller.mjs](../fixtures/tc1/remote-caller.mjs)) on the unchanged C machine of `backends/solo5/pure-call`. A perform of an effect that no handler frame handles and that the build binds to a peer is the remote operation: request out, one outcome in, given to the machine as the value of that perform. The frames never leave the image |
| Peer image | [backends/solo5/remote/peer.c](../backends/solo5/remote/peer.c) | The model's abstract peer: a counter, idempotent per request id, with a durable store on a block device |
| Wire format | [backends/solo5/remote/wire.h](../backends/solo5/remote/wire.h), [src/fenrir_wire.erl](src/fenrir_wire.erl) | Version 1: 512-byte blocks, little-endian, explicit lengths, sequence numbers, incarnation numbers, CRC-32; strict decoding on both sides |
| Image build | [tools/solo5/remote-build.mjs](../tools/solo5/remote-build.mjs) | JavaScript, as for the other guests |
| Supervisor | [src/](src/) | This directory |
| Judgement | [harness/tc1-remote-run.shen](../harness/tc1-remote-run.shen) | Shen: replays what a run recorded through the model |

### Transport, and why it is not the network device

Each member has two mailboxes, an inbox and an outbox, each a Solo5 block
device backed by a plain file of 64 blocks. A mailbox has exactly one writer:
the supervisor writes inboxes, the image writes its outbox. Record *n* is block
*n*; block 0 is a header with the count of records. The writer writes the
record and then the header, and the reader polls the header (the image once a
millisecond with `solo5_yield`). An inbox header also carries a *grant*: how
many records the image may consume. That is how the supervisor schedules when a
peer image acts.

This was chosen because it runs without privileges. A Solo5 `spt` net device
needs a tap interface. A tap can be created in this development container (as
root, with `CAP_NET_ADMIN`; tried with `TUNSETIFF`), and on a GitHub hosted
runner only with `sudo`, which was not tried. A net transport would also need
a privileged helper next to the supervisor to create the taps and pass frames
to Erlang, which cannot open a tap itself. For a net transport the following
would change: `support.c` (mailbox open, send, receive) and
`fenrir_member.erl` (mailbox files) would be replaced by frame I/O, the record
format of `wire.h` would be carried in Ethernet frames, and the grant would
become an explicit message. The relay, the event log and the judgement would
not change. What the mailboxes do not give: no interrupt-driven wake-up (the
image polls), a fixed capacity of 63 records per mailbox per incarnation, and
no distribution across hosts.

### OTP structure

```text
fenrir_supervisor (application)
  fenrir_sup (supervisor, one_for_all, no restarts)
    fenrir_member_sup (supervisor, simple_one_for_one, temporary children)
      fenrir_member (gen_server), one per member: the port of the tender
        process, the mailbox files, the store file
    fenrir_relay (gen_server): the step machine and the event log
fenrir_run     who chooses the next step: a schedule, a seed, or the clock
fenrir_main    command line
```

OTP does not restart anything here. Restarting an image is a step of the
contract (`restart`), taken and logged by the relay. If the relay or a member
process fails, the tree stops: the relay's record of what was handed over is
gone, and the contract (§12.9) does not cover a supervisor that fails.

## A run

`erl -noshell -pa EBIN -run fenrir_main main -extra SPEC`, where SPEC is a JSON
file or JSON text:

```json
{"dir": "/path/for/this/run",
 "tender": "/path/to/solo5-spt",
 "manifest": {"members": [{"name": "caller", "kind": "caller", "image": "/path/caller.spt"},
                          {"name": "peer", "kind": "peer", "image": "/path/peer.spt"}],
              "connections": [["caller", "peer"]]},
 "schedule": {"mode": "free"},
 "start_check": true, "defects": [], "life_ms": "60000"}
```

**Assembly.** Before anything is started the supervisor reads from each image
file the connections its program was built with (a
`FENRIR-REMOTE-DECL/1 connects=...` line in the image) and compares them with
the manifest. If a program declares a connection the manifest lacks, nothing
is started: status `refused-at-start`, exit status 2. The check at run time
stays as a backstop: every request is checked against the manifest when it is
accepted, whatever the image declares, and an undeclared one gets `peer_down`
with nothing put in flight (`refuse`).

**Modes.**

| `schedule` | Meaning |
| --- | --- |
| `{"mode":"list","steps":[...],"crashes":"1","duplicates":"0"}` | Take exactly these steps. A step is a label or a prefix of one. A step that is not enabled ends the run: `step-not-enabled`, exit status 3 |
| `{"mode":"seeded","seed":"7","crashes":"1","duplicates":"1","max_steps":"120"}` | At each point choose one of the enabled steps with a fixed 64-bit generator, until none is enabled. One seed is one schedule |
| `{"mode":"free","timeout_ms":"2000","deadline_ms":"20000"}` | Free-running: deliver at once, never drop or duplicate, report `timed_out` (or `peer_down`, when the contract allows it) after `timeout_ms` on the wall clock, record as a crash a member found dead, restart a member that is down |

`crashes` and `duplicates` are budgets: how many crash and duplicate steps are
enabled in the run, as in the model.

**Steps and the event log.** The labels are the model's:

```text
["issue",C,P,Key]  ["refuse",C,P,Key]  ["finish",C]
["deliver-request",Tag]  ["act",P,Tag,"applied"|"replayed"]
["deliver-reply",Tag,V]  ["discard-reply",Tag,V]
["drop","request",Tag]  ["drop","reply",Tag,V]  ["duplicate","request",Tag]  ["duplicate","reply",Tag,V]
["timeout",Tag]  ["peer-down",Tag]  ["crash",M]  ["restart",M]
```

`Tag` is `[Caller, N]`: the supervisor's number for one attempt, never reused,
not even after the caller restarts. The request id is `(Caller, Key)`; the key
is the program's. `<dir>/result.json` holds the status, the events in order,
the steps that were enabled before each event, each incarnation's console file,
and the peer's store as read from its file after the run.

**What the contract's words are here.**

- *Handed over*: the supervisor records the request id as handed over and then
  writes the request into the peer's inbox file. From then on `peer_down` is
  never offered for that request id.
- *act*: the supervisor grants the peer image one inbox record and waits for
  its reply record, which says `applied` or `replayed`.
- *crash*: `kill -9` of the tender process. *restart*: a new tender process, a
  new incarnation number, empty mailboxes, the same store file.
- *Scheduling point*: before each step the supervisor waits until every caller
  image that is not waiting for an outcome has written its next request or its
  halt record. Until then it does not know that image's next step.

## What is trusted

- The supervisor itself. Its event log is its own account of what it did. The
  judgement checks that account against the model and against what the images
  printed and stored; it cannot check that the supervisor did nothing else.
- The Solo5 tender, the toolchain and the host kernel, as built. `spt` is a
  seccomp-sandboxed process, not a virtual machine.
- The file system: a 512-byte write to a mailbox or store file is taken to be
  atomic with respect to a process kill, and the supervisor's memory (its
  hand-over record) is assumed not to be lost (§12.9).
- The peer's own report of `applied` or `replayed`. A peer that lied would be
  seen only through the values it returns and its store file.
- The image's declaration of its connections, for the start-time check only.
  The run-time check does not rely on it.

## What is not shown

- No `hvt` run: this container has no `/dev/kvm`. Only the `spt` tender.
- No proof. A set of observed histories was accepted by the model; nothing
  says every history of this supervisor would be.
- One system: one caller, one peer, two request ids, I64 arguments and
  replies, one operation per bound effect (the operation name is not sent).
- The scheduled modes take crash steps only between steps, when the images are
  at rest. A peer killed after its store commit and before its reply record is
  written has acted without the event log showing an `act`; the model would
  then reject a later `replayed`. The free-running mode can produce this; it
  was not observed and is not handled (EFFECTS.md §12.10, question 10).
- Free-running mode with several faults, long runs, mailbox capacity, torn
  header reads under load, and a supervisor that itself fails: not exercised.
- Liveness. A caller image that never reaches a scheduling point makes a
  scheduled run end in an error after five seconds; nothing bounds it otherwise
  than the image's own step budget and the lifetime on its command line.
- Timeouts in the scheduled modes have no clock: `timeout` is a step. Only the
  free-running mode uses the wall clock.

## Defect switches

For the harness only. `"defects"` in the spec may name:

| Switch | Where | Effect |
| --- | --- | --- |
| `peer-down-after-handover` | relay | `peer_down` is offered although the request was handed over |
| `late-reply-accepted` | relay | a reply for an attempt that timed out is handed to the caller |
| `relay-undeclared` | relay | requests are carried whatever the manifest says (use with `"start_check": false`) |
| `non-idempotent-peer` | peer image (`non-idempotent` on its command line) | a request id that has a record is applied again |

`harness/run-tc1-remote-run.sh` requires each to be caught.
