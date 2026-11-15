# Pure-call guest control protocol, version 2

Identity: `fenrir.solo5.pure-call-control/2`. Machine profile: `fenrir.solo5.pure-call-machine/2`.
Tape: `fenrir.solo5.pure-call-control-tape/2`. Status: development, `qualification: UNKNOWN`.

Version 2 is [version 1](pure-call-control-v1.md) plus **host requests**: the TC1-D1
durable effects of [spec/tc1/DURABLE.md](../tc1/DURABLE.md). A durable operation of
the program crosses the Solo5 boundary as a guest→host observation and the host's
reply comes back as a host→guest frame; the guest holds no store. Everything below
that is not stated is exactly v1 (transport, frame layout, limits, fail-closed
order, comparison discipline, tape layout, strict replay).

Implementations: guest [backends/solo5/pure-call/control.c](../../backends/solo5/pure-call/control.c)
built with `-DFGC_V2` (without the flag the same source is the v1 guest, and nothing of
v2 is compiled in); host [harness/solo5-durable.shen](../../harness/solo5-durable.shen),
which loads the v1 host for its frame, session, tape and replay code and redefines what
v2 changes. Byte vectors: [pure-call-control-v2.vectors](pure-call-control-v2.vectors).
v1 and its vectors are unchanged and still checked by `sh harness/run-solo5-control.sh`.

## 1 Frame

Unchanged. The magic `FGC1 ` names the frame **layout**, which v2 keeps; the protocol
version is the identity string in Hello, Init, Ready and the tape header. A v1 peer and
a v2 peer refuse each other at Hello or Init (`Identity`).

## 2 Messages: what v2 adds

| Type | Dir | Kind | Payload fields (in order) | Answer to |
| --- | --- | --- | --- | --- |
| `A` | H | Reply | `kind`, `request` (decimal), `value` (a canonical value, below) | — |
| `S` | G | Steps | as v1; `execution` may be `HostWait` | Run, Reply |

- **Run.** As v1, and a Run also stops after a step that leaves the machine in
  `HostWait` (DURABLE.md §4): that step's record carries the `HostRequest` event
  (`{"kind":"HostRequest","task":"0","node":N,"seq":S,"effect":E,"operation":op,"value":v}`)
  and the response's `execution` is `HostWait`. A Run while `HostWait` is `NotRunning`.
- **Reply.** Only while `HostWait`. `request` must be the `seq` of the pending request.
  `value` is the reply in the artifact's value encoding, in its one canonical spelling:
  no white space, I64 as a canonical decimal string, bytes as lowercase hex. The guest
  parses it **against the pending operation's result type** (lowered into the image with
  the program) before the program sees it, takes the `HostReply` step and answers with a
  Steps frame holding exactly that one record
  (`{"kind":"HostReply","task":"0","node":N,"seq":S,"value":r}`, after `Value`).
- `execution` values: `Running`, `HostWait`, `Completed`, `BudgetExhausted`.
- **Digest.** As v1, and the walk also covers the number of host requests made and, in
  `HostWait`, the pending argument. (v1 digests are unchanged: a v1 image never mixes
  them.)

Template of a Reply payload, the only spelling the guest accepts:

```
{"kind":"Reply","request":"0","value":["data","Reply","Committed",["data","Receipt","Receipt",["int","0"],["int","1"],["int","1"],["int","0"],["int","0"]]]}
```

## 3 Programs and inputs

One image entry is one (artifact, input) pair: the entry input is lowered into the image
as a canonical value with its type, parsed and checked at Init (a value the image itself
holds; nothing new crosses the channel). The batch identity `PC_BATCH_SHA256` covers each
entry's artifact hash and its input hash (`artifact:input` per line), so Init's
`program` index binds the input too. The host's replies are not in the image: they are
the host's to choose, request by request.

## 4 Fail-closed rules: what v2 adds

Guest, after v1's header checks: type not in `IRDXA` → `UnknownType`; a Reply payload
that does not match the template → `BadPayload`; a Reply before Init or while not
`HostWait` → `BadState`; `request` other than the pending `seq` → `BadReply`; a `value`
that is not one canonical value of the operation's result type, or that leaves bytes
before the closing brace → `BadReply` (the host's contract violation: DURABLE.md §5;
the program does not run). Each sends one Error frame and exits 3.

Host: a Steps response may report `HostWait`; anything else is v1.

## 5 Comparison discipline (host)

As v1, one step per Run. When the model is in `HostWait`, the host takes the next reply
the batch declares for the program, checks it with the model (DURABLE.md §5), and sends
it. If the model accepts it, the guest's one-record Steps answer must equal the model's
`HostReply` step. If the model calls it a violation, the guest must answer Error
`BadReply` and exit 3; that is agreement. With no reply left, the host terminates the
session in `HostWait` (execution `AwaitingHost`).

## 6 What v2 does not cover

Everything v1 §6 lists, and: a host-initiated discontinue (there is none in D1); more
than one outstanding request (D1 has none: the program is stopped while one is
pending); replies longer than the 512-byte host payload limit; the **free-running
guest**, which has no host: it is not built for v2 batches, and a residual perform there
would stop the machine (`pc_step` refuses to step in `HostWait`, an infrastructure exit).
Free-run mode therefore refuses programs with residual effects rather than taking a
scripted reply table.

## 7 Tape and strict replay

Tape layout as v1 with tape schema `fenrir.solo5.pure-call-control-tape/2`. A tape records
every Reply frame and its Steps answer like any other pair, so strict replay re-sends the
recorded replies byte for byte and requires the guest's frames to be identical. The
structure check adds: a Run only while `Running`, a Reply only while `HostWait`
(`Structure:ReplyNotAwaited`), judged from the last Steps response recorded.

Vectors ([pure-call-control-v2.vectors](pure-call-control-v2.vectors)): two Reply frames
the host must encode exactly, a `BadReply` Error frame and a `HostWait` Steps frame the
host parser must accept and re-encode unchanged, and a guest frame of type `A` it must
refuse (`UnknownType`).

## 8 Measured

See [harness/README.md](../../harness/README.md) ("TC1-D1: durable effects", "Service
example A2"). *Bounded exploration passed*, development grade.
