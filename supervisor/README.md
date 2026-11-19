# The supervisor between images

Erlang/OTP implementation of the supervisor's part of remote perform. The
contract is [spec/tc1/EFFECTS.md](../spec/tc1/EFFECTS.md) §12; the model is
[models/tc1/remote-system.shen](../models/tc1/remote-system.shen). First
implementation, development code. Its check is the row `remote-run` of the TC1
gate, registered on 15 November 2026 and amended four times on 16 November 2026
([record](../campaigns/tc1/TC1_GATE_REGISTRATION.md)); that row's evidence is
observed histories on `spt` accepted by the model, nothing stronger.

A system is one image per member, a static manifest of the members, the
declared connections and the member each remote effect is bound to, and this
supervisor, which is outside the images and carries every message. A
remote operation returns exactly one of `reply v`, `not_delivered`,
`timed_out`. `not_delivered` was called `peer_down` until 16 November 2026;
it says that no copy of the request was handed to the peer, whether the peer
is up or down. A reply value is the operation's own result, `(status, value)`:
status 0 is ok, status 1 is conflict, the peer's refusal of a key it has
applied with another argument. That is a *keyed* operation. A *read-only*
operation (EFFECTS.md §12.3) has no key and leaves no record; its reply value
is the operation's value itself.

```sh
sh harness/run-tc1-remote-run.sh    # the check: real system against the model, about 70 s
sh harness/run-tc1-gate.sh          # the TC1 gate; the check is its remote-run row
sh supervisor/run.sh                # one free-running run by hand; prints where result.json is
sh supervisor/build.sh ERLC EBIN    # compile only: erlc, no rebar, no hex
```

Erlang/OTP comes from the flake (`nix build .#erlang` on x86-64 or ARM64 Linux,
OTP 28 without wx), or
set `FENRIR_ERLANG` to an installation, or have `erl` and `erlc` on `PATH`
([harness/find-erlang.sh](../harness/find-erlang.sh) is the lookup; the gate
uses the same one and requires the flake's).
Solo5 as for the other guests: `FENRIR_SOLO5` or `build/vendor/solo5`.

## The pieces

| Piece | Where | What it is |
| --- | --- | --- |
| Caller image | [backends/solo5/remote/caller.c](../backends/solo5/remote/caller.c) | A real TC1 program, the source file [examples/remote/ledger-caller.fen](../examples/remote/ledger-caller.fen) elaborated by the frontend, on the unchanged C machine of `backends/solo5/pure-call`. A perform of an operation of an effect the program declares remote is the remote operation: request out, one outcome in, given to the machine as the value of that perform. The frames never leave the image |
| Peer image | [backends/solo5/remote/peer.c](../backends/solo5/remote/peer.c), [serve.c](../backends/solo5/remote/serve.c) | A program of the language too, the source file [examples/remote/ledger-peer.fen](../examples/remote/ledger-peer.fen), which *serves* the effect (EFFECTS.md §12.12), on the same C machine, and a runtime in C around it: transport, a durable store on a block device, and a transaction for each request. What an operation does is the program's; the hand-written counter is gone. The runtime runs the operation's function once for each request it applies, with the store reached through two effects. A keyed request is idempotent per request id: a reply record keeps the operation and argument it was made with, the same key with another is answered `conflict` and changes nothing, and the request's writes and its reply record are committed in one step before the reply is sent. A read-only request is answered by the function on the store as it is, and nothing is written. A function that traps commits nothing and nothing is replied |
| Wire format | [backends/solo5/remote/wire.h](../backends/solo5/remote/wire.h), [src/fenrir_wire.erl](src/fenrir_wire.erl) | Version 4: 512-byte blocks, little-endian, explicit lengths, sequence numbers, incarnation numbers, CRC-32; strict decoding on both sides. A request names its operation, `Effect.operation`. The peer's store is a log of cell records and reply records behind a header that counts them. An inbox header also has `hold` and `where`, below |
| Image build | [tools/solo5/remote-build.mjs](../tools/solo5/remote-build.mjs) | JavaScript, as for the other guests. It reads the system manifest ([examples/remote/ledger-system.json](../examples/remote/ledger-system.json)), runs the frontend on the source file the manifest names for each member, and derives from each program the line its image carries about itself: for a caller from its remote-effect declarations and the manifest's bindings, for a peer from what its program serves, with a digest of each effect's signature on both sides. It holds no binding of its own, and writes `manifest.json`, the manifest with each member's image, for the supervisor |
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
peer image acts. An inbox header may also carry a *hold*: the number of a
granted record at which the image is to stop, without exiting, and *where*:
just before it would send its reply, or inside its commit, when every record
of the commit is written and the store header that would count them is not.
That is how the supervisor places a kill between a peer's durable commit and
its reply, and one inside the commit.

Version 2 of the format (16 November 2026) changed three records, and a block
of version 1 is now malformed. An OUTCOME of kind reply carries a status in
what was a zero field: 0 ok, 1 conflict. A REPLY may say `conflict` (how 3,
value zero) beside `applied` and `replayed`. A STORED record carries the
argument the request id was applied with, between the key and the value. The
outcome kinds are unchanged on the wire: kind 2 is `not_delivered`, the code
`peer_down` had, and only its name and when it may be sent changed. The
record magic still reads "FRW1"; it names the format, and the version is the
field after it.

Version 3 (also 16 November 2026) added the mode. A REQUEST and a DELIVER
carry, between the name and the key, a mode: 1 keyed, 2 read-only. A
read-only request has no key and, in this version, a unit argument, so both
fields are zero. A REPLY may say `read` (how 4) with the operation's value. A
block of version 2 is now malformed. The operation's name was not sent: a peer
served at most one operation of each mode.

Version 4 (also 16 November 2026) came with peers written in the language
(EFFECTS.md §12.12), and a block of version 3 is now malformed. A REQUEST and
a DELIVER end with the operation's name, `Effect.operation`, in a field of 64
bytes, so a peer serves any number of operations of each mode. A REPLY may
say `trapped` (how 5, value zero): the peer's program trapped, nothing was
committed, and the supervisor carries no reply to the caller. A header has
one more field, `where`, after its CRC: with a hold, 0 means stop just before
the reply and 1 means stop inside the commit.

**The peer's store** is a block device too, a plain file of 64 blocks: a
header and a log. A CELL record (type 7: key, value) is one write of the
peer's program to its key-value store; a STORED record is the reply record of
one request id, and now ends with the operation's name. The header's count is
the number of log records and its grant the number of STORED records among
them. The value of a cell is that of the latest CELL record for its key, and 0
if there is none. **A commit** is the request's CELL records, in ascending
key order, and its STORED record, written to the blocks after the last
counted one, and then one write of the header with the new count. A record
the header does not count does not exist: the image does not read it when it
opens the store, and the next commit writes over it. A kill before the header
write therefore leaves the store as it was, and a kill after it leaves the
whole request. That is atomic at the granularity of a record if a 512-byte
block write is atomic and a write that returned is not lost when the image
dies; nothing here tests either. The log is never compacted, so a store holds
63 records: fifteen applied requests of the ledger example.

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
  fenrir_sup (supervisor, rest_for_one)
    fenrir_member_sup (supervisor, simple_one_for_one, temporary children)
      fenrir_member (gen_server), one per member: the port of the tender
        process, the mailbox files, the store file
    fenrir_journal (gen_server): what survives a restart of the relay
    fenrir_relay (gen_server): the step machine, the record of hand-overs,
      the messages in flight
fenrir_run     who chooses the next step: a schedule, a seed, or the clock
fenrir_main    command line
```

OTP restarts one thing here, the relay, and only as a step of the contract.
Restarting an image is the step `restart`, taken and logged by the relay; OTP
never restarts a member process. Restarting the supervisor is the step
`supervisor-restart` (EFFECTS.md §12.7): the relay process is killed and
`fenrir_sup` starts another, which is why the relay is the last child of a
`rest_for_one` supervisor. See "What the contract's words are here". A relay
that dies in any other way is also started again, finds no planned restart in
the journal, and answers every call with an error, so the run ends in an
error. If the member supervisor or the journal fails, the relay is started
with nothing and the run ends in an error too.

## A run

`erl -noshell -pa EBIN -run fenrir_main main -extra SPEC`, where SPEC is a JSON
file or JSON text:

```json
{"dir": "/path/for/this/run",
 "tender": "/path/to/solo5-spt",
 "manifest": {"members": [{"name": "caller", "kind": "caller", "image": "/path/caller.spt"},
                          {"name": "peer", "kind": "peer", "image": "/path/peer.spt"}],
              "connections": [["caller", "peer"]],
              "bindings": [["caller", "Ledger", "peer"]]},
 "schedule": {"mode": "free"},
 "start_check": true, "defects": [], "life_ms": "60000"}
```

`"manifest"` may also be the name of a file that holds that object; the image
build writes one, `manifest.json`, next to the images.

**The system manifest.** One description of the system, used by the image
build and by the supervisor (EFFECTS.md §12.6; owner ruling of 16 November
2026 on §12.10 question 14). In the repository it is a file,
[examples/remote/ledger-system.json](../examples/remote/ledger-system.json):

```json
{"schema": "fenrir.system-manifest/2",
 "members": [{"name": "caller", "kind": "caller", "program": "examples/remote/ledger-caller.fen"},
             {"name": "peer", "kind": "peer", "program": "examples/remote/ledger-peer.fen", "store": true}],
 "connections": [["caller", "peer"]],
 "bindings": [["caller", "Ledger", "peer"]]}
```

| Field | Meaning |
| --- | --- |
| `members` | Each has a `name` (`[a-z0-9-]`, 1 to 15 characters, unique) and a `kind`, `caller` or `peer`. In the file every member has `program`, its source, named relative to the repository, and a peer has `store`, whether it has a durable store (schema /2; in schema /1 a peer had neither). In the manifest the supervisor is given, every member has `image`, the image file, instead of both; that is the only difference, and the build makes it |
| `connections` | `[caller, member]`: the caller may send requests to that member. Both are members |
| `bindings` | `[caller, Effect, member]`: the operations of the remote effect `Effect` that the caller's program performs are carried out by `member`. One binding at most for a caller and an effect. A manifest without the field binds nothing |

A binding says who serves an effect; a connection says the caller may reach
that member. Neither implies the other and both are required. The build
refuses a file that is not of this shape (closed fields, the schema name),
and makes the assembly check below on it before compiling anything. A second
manifest, [examples/remote/rates-system.json](../examples/remote/rates-system.json),
describes a system whose caller only reads and whose peer has no store. For
the ledger system the build also makes two peer images that belong to no
system, so that their refusal can be exercised: the ledger peer without a
store device, and a peer whose program declares the effect differently.

**Assembly.** Before anything is started the supervisor reads from each image
file one line that says what the image is:

```text
FENRIR-REMOTE-DECL/3 connects=peer uses=peer/Ledger.add/keyed,peer/Ledger.total/read-only signatures=Ledger:b4db3da2...     a caller
FENRIR-REMOTE-SERVES/2 store=yes writes=yes operations=Ledger.add/keyed,Ledger.total/read-only signatures=Ledger:b4db3da2...   a peer
```

Neither line is written by hand. The build derives each from that image's own
program: the caller's line from its remote-effect declarations and the
manifest's binding of each remote effect to a member, naming the members its
effects were bound to when it was built; the peer's line from what its
program serves. `store` is whether the image was linked with a store device,
and `writes` whether the peer's program mentions `StoreWrite` at all.
`signatures` has, for each remote effect the image uses or serves, a digest
of the effect's signature: SHA-256, 64 hexadecimal digits (shortened above),
of the canonical encoding of the effect's name and its operations' names,
types and read-only markers, in the order of the operations' names
(EFFECTS.md §12.6). The caller's program and the peer's include one
declarations file, [examples/remote/ledger.decl.fen](../examples/remote/ledger.decl.fen),
so their digests are equal. At assembly the member an effect goes to is
the one the manifest binds it to; the caller's line says which effects and
operations it uses. The supervisor compares the lines with the manifest and
with each other, and starts nothing (status `refused-at-start`, exit status
2, `refusals` in the report) when:

| Refusal in the report | Meaning |
| --- | --- |
| `[Caller, "unbound", "Effect"]` | the caller's program uses a remote effect and the manifest binds it to no member |
| `[Caller, "unknown-member", "Effect", Name]` | the manifest binds the effect to a name that is no member of the system |
| `[Caller, Member]` | the effect is bound to a member, and the manifest declares no connection from the caller to it |
| `[Peer, "no-store", "Effect.op"]` | the peer image has no durable store and serves an operation that is not read-only (EFFECTS.md §12.3) |
| `[Peer, "no-store", "StoreWrite"]` | the peer image has no durable store and its program mentions the store's write effect |
| `[Caller, Member, "unserved", "Effect.op"]` | the caller uses an operation the bound member's image does not serve in that mode; a member that is not a peer serves nothing |
| `[Caller, Member, "signature", "Effect"]` | the bound member serves the effect, and its digest of the effect's signature is not the caller's: the two programs were built from different declarations (EFFECTS.md §12.10 question 15) |

The report lists them in that order. An error of the manifest is something
else: the run ends with status `error`, exit status 1, and no refusal. These
are errors: a caller image without its line, or a peer image without its
line; a member name outside the alphabet or given twice; a connection that
names no member; a binding that is not `[caller, Effect, member]` with a
caller of the system first (`bad_binding`); two bindings of one effect for
one caller (`duplicate_binding`); a binding for an effect the caller's image
does not use (`binding_of_unused_effect`); and a manifest that binds an
effect to a member other than the one the caller image was built for
(`image_built_for_another_member`: the image sends its requests to the member
compiled into it, so it is not an image of this system).

`"start_check": false` switches off the third check only, for the harness;
behind it the check at run time stays as a backstop: every request is checked
against the manifest's connections when it is accepted, whatever the image
declares, and an undeclared one gets `not_delivered` with nothing put in
flight (`refuse`). Nothing at run time stands behind the other six, so they
cannot be switched off. A member is given a store file only if its image
says it has a store.

**Modes.**

| `schedule` | Meaning |
| --- | --- |
| `{"mode":"list","steps":[...],"crashes":"1","duplicates":"0","supervisor_restarts":"0"}` | Take exactly these steps. A step is a label or a prefix of one. A step that is not enabled ends the run: `step-not-enabled`, exit status 3 |
| `{"mode":"seeded","seed":"7","crashes":"1","duplicates":"1","supervisor_restarts":"1","max_steps":"160"}` | At each point choose one of the enabled steps with a fixed 64-bit generator, until none is enabled. One seed is one schedule |
| `{"mode":"free","timeout_ms":"2000","deadline_ms":"20000"}` | Free-running: deliver at once, never drop or duplicate; after `timeout_ms` on the wall clock report `not_delivered` if the request does not count as handed over and `timed_out` otherwise; record as a crash (or a crash after commit) a member found dead; restart a member that is down. The relay is not restarted in this mode |

`crashes`, `duplicates` and `supervisor_restarts` are budgets: how many
crash, duplicate and supervisor-restart steps are enabled in the run, as in
the model. A budget that is not given is zero.

**Steps and the event log.** The labels are the model's:

```text
["issue",C,P,Key]  ["refuse",C,P,Key]  ["finish",C]
["deliver-request",Tag]  ["act",P,Tag,"applied"|"replayed"|"conflict"|"read"|"trapped"]
["deliver-reply",Tag,V]  ["discard-reply",Tag,V]
["drop","request",Tag]  ["drop","reply",Tag,V]  ["duplicate","request",Tag]  ["duplicate","reply",Tag,V]
["timeout",Tag]  ["not-delivered",Tag]  ["crash",M]  ["restart",M]
["crash-after-commit",P,Tag]  ["supervisor-restart"]
```

`Tag` is `[Caller, N]`: the supervisor's number for one attempt, never reused,
not even after the caller restarts. The request id is `(Caller, Key)`; the key
is the program's. A read-only request has no key: in a label its place is
taken by `"read-N"`, N being the number of the attempt, and the supervisor
keeps the request in its records under that name, each perform its own
request. A value `V` is `["tuple",["int",Status],["int",Value]]` from a keyed
operation and `["int",Value]` from a read-only one.
`<dir>/result.json` holds the status, the events in order, the steps that
were enabled before each event, each incarnation's console file, the peer's
store as read from its file after the run (`cells`, each cell with its value,
and `records`, each reply record with its operation, its argument and its
value), `kills_in_commit` (below), and `supervisor_incarnations`, the number
of relay processes the run had.

**A kill inside a commit** is not a step of its own. A peer killed before its
store header counts a commit has committed nothing, which is the model's step
`crash`. The command `["crash", P, "in-commit"]` takes that step in a
particular way, where a `crash-after-commit` of `P` is enabled: the
supervisor grants the peer one inbox record with a hold inside the commit,
waits until the store file shows that request's reply record beyond the
header's count, and kills the tender process. It logs `["crash", P]` when
the store then has no counted record of the request, and
`["crash-after-commit", P, Tag]` if it has one. `kills_in_commit` lists each
such kill with `uncounted`, the records that were written and not counted
when the image was killed.

**What the contract's words are here.**

- *Handed over*: the supervisor records the request id as handed over and then
  writes the request into the peer's inbox file. From then on `not_delivered`
  is never offered for that request id.
- *not-delivered*: offered for every pending request that does not count as
  handed over, with the peer up or down. The supervisor destroys every copy of
  the request id it holds and then gives the caller the outcome.
- *act*: the supervisor grants the peer image one inbox record and waits for
  its reply record, which says `applied`, `replayed` or `conflict`, or, of a
  read-only request, `read`; or `trapped`, when the peer's program trapped,
  and then nothing is carried to the caller.
- *supervisor-restart* (EFFECTS.md §12.7): the relay logs the step and leaves
  its state with the journal, and is then killed with `exit(Pid, kill)`;
  `fenrir_sup` starts a new relay process. The guests and the member
  processes are not touched. The relay never gives the journal its record of
  hand-overs or the messages in flight, so those are lost with the process.
  The new relay gets from the journal what the contract says is kept: what was
  known of each member (up or down, the pending perform, the inbox entries not
  yet acted on, the next scheduling point), the attempt numbering, and the set
  of request ids ever accepted, which it takes as its record of hand-overs;
  and, for the harness, the event log, the budgets and the defect switches.
  The journal is another process of the same Erlang VM. Nothing is written to
  disk, so this is a restart of the relay, not of the VM. The step exists in
  the scheduled modes only and is taken between steps.
- *crash*: `kill -9` of the tender process. *restart*: a new tender process, a
  new incarnation number, empty mailboxes, the same store file.
- *crash-after-commit* (EFFECTS.md §12.7): the supervisor grants the peer one
  inbox record with a hold on it, waits until the peer's store file has the
  reply record for that request id, and then kills the tender process. The
  peer has applied the request; no reply exists. The step is offered where
  acting would apply and a crash is left in the budget, never for a read-only
  request, which commits nothing; whether acting would
  apply is read from the store file, not from the event log. In the
  free-running mode the supervisor places no kills, but when a peer dies
  inside an act it compares the store with what it read before the grant, and
  records `crash-after-commit` if the record appeared and `crash` otherwise.
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
  atomic with respect to a process kill. The journal process is assumed to
  outlive the relay; the supervisor's hand-over record may be lost, by the
  `supervisor-restart` step, and only by it (§12.7, §12.9).
- The peer's own report of `applied`, `replayed`, `conflict`, `read` or
  `trapped`. A peer that lied would be seen only through the values it
  returns and its store file. That the *program* of an operation declared
  read-only writes nothing is checked before an image exists (EFFECTS.md
  §12.12); that the peer's *runtime* writes nothing while serving one is not:
  the supervisor cannot see a write, only its consequences.
- The two assumptions the commit rests on: a 512-byte block write is atomic,
  and a write that returned is not lost when the image is killed.
- The peer's cooperation with a hold. An image that ignored it would reply,
  and the supervisor would record an act and a crash instead of the step it
  was asked for. The store file is not trusted to the event log: it is the
  authority on what was applied (owner ruling, EFFECTS.md §12.10 question 10),
  and the judgement compares it with the model's store.
- What an image declares of itself, for the checks at assembly. The run-time
  check of connections does not rely on it; the store, the served operations,
  the effects a caller uses and the signature digests have no other check:
  the supervisor compares what two builds wrote and recomputes nothing. Nothing ties an image file to the build
  that derived its line.

## What is not shown

- No `hvt` run: this container has no `/dev/kvm`. Only the `spt` tender.
- No proof. A set of observed histories was accepted by the model; nothing
  says every history of this supervisor would be.
- Two systems, each one caller and one peer: in one, two request ids (one of
  them performed with two arguments) and a read; in the other, two reads.
  I64 arguments, replies of a status and an I64 or of an I64.
- A peer program that traps: `trapped` is implemented and no run has one. The
  supervisor cannot know beforehand that acting will trap, so where it would,
  it offers a `crash-after-commit` that the model does not.
- The errors of a manifest listed under Assembly were tried by hand, once
  each; no check runs them. The three refusals about a binding are hand
  schedules of the check.
- A system of another shape than one caller and one peer; a caller with two
  remote effects bound to two members.
- A peer that calls onward, a request that says who its caller is to the
  peer's program, compaction of the store's log.
- The scheduled modes take crash steps between steps, when the images are at
  rest, and at two places inside a step: after a peer's store commit and
  before its reply (`crash-after-commit`), and inside the commit when every
  record is written and none counted (`["crash", P, "in-commit"]`). A kill at
  any other instant inside a step is not placed: between two record writes of
  a commit, or between the reply record and the outbox header. A torn block
  and a lost write are not injected.
- A peer that dies inside an act in the free-running mode is handled as above;
  one run exercises it, with a kill placed after the commit. A caller image
  that dies while the supervisor waits for its next scheduling point is still
  an error of the run.
- A restart of the supervisor at any instant other than between two steps of
  a scheduled run; a restart in the free-running mode; the loss of the Erlang
  VM, which would need the journal on disk; and redelivery after a restart,
  which the contract allows and this relay does not do.
- Free-running mode with several faults, long runs, mailbox capacity, and torn
  header reads under load: not exercised.
- Liveness. A caller image that never reaches a scheduling point makes a
  scheduled run end in an error after five seconds; nothing bounds it otherwise
  than the image's own step budget and the lifetime on its command line.
- Timeouts in the scheduled modes have no clock: `timeout` is a step. Only the
  free-running mode uses the wall clock.

## Defect switches

For the harness only. `"defects"` in the spec may name:

| Switch | Where | Effect |
| --- | --- | --- |
| `not-delivered-after-handover` | relay | `not_delivered` is offered although the request was handed over |
| `late-reply-accepted` | relay | a reply for an attempt that timed out is handed to the caller |
| `relay-undeclared` | relay | requests are carried whatever the manifest says (use with `"start_check": false`) |
| `non-idempotent-peer` | peer image (`non-idempotent` on its command line) | a request id that has a record is applied again |
| `reply-before-commit` | peer image (`reply-before-commit` on its command line) | the reply is sent first and the commit made after it; killed in between, the peer has replied with nothing in its store |
| `forgetful-supervisor-restart` | relay | the relay started by a `supervisor-restart` takes nothing as handed over, so it offers `not_delivered` for requests the peer may have applied |
| `replay-different-argument` | peer image (`replay-different-argument` on its command line) | a key that has a record is answered from it whatever the argument: no `conflict` is ever reported |
| `read-only-writes` | peer image (`read-only-writes` on its command line) | before it serves a read-only request, the runtime adds one to cell 0 and commits it |
| `writes-without-record` | peer image | the commit leaves out the reply record |
| `record-without-writes` | peer image | the commit leaves out the program's writes |
| `torn-commit` | peer image | the store header is written after every record of a commit, not once at its end: a kill inside leaves a part |
| `stale-reads` | peer image | a read of the store does not see what its own request has written |

The eight of the peer image are defects of its runtime, each a word on its
command line; none is a defect of the peer's program.
`harness/run-tc1-remote-run.sh` requires each of the twelve to be caught. Ten
are caught because the recorded steps are not the model's.
`reply-before-commit` and `torn-commit` are caught only by the store: the log
of the first shows an act and a crash, and that of the second a crash, which
the model accepts.

For tests of the free-running mode the schedule may also carry
`"kill": [[Member, N]]` (kill the member's process from outside once N steps
have been taken) and `"kill_in_act": [[Member, N]]` (kill it inside its Nth
act, after its commit and before its reply). Neither is recorded by the
supervisor: it has to find out. It may also carry `"lose": [[Caller, N]]`: the
relay drops the request of that caller's Nth attempt instead of handing it
over, and at the timeout reports `not_delivered`, with the peer up.
