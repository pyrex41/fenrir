# Pure-call guest control protocol, version 1

Identity: `fenrir.solo5.pure-call-control/1`. Machine profile: `fenrir.solo5.pure-call-machine/1`.
Tape: `fenrir.solo5.pure-call-control-tape/1`. Status: development, `qualification: UNKNOWN`.

Implementations: guest [backends/solo5/pure-call/control.c](../../backends/solo5/pure-call/control.c);
host [harness/solo5-control.shen](../../harness/solo5-control.shen). Byte vectors:
[pure-call-control-v1.vectors](pure-call-control-v1.vectors), checked by the host on every run (§9).

The host selects every step the guest takes. The guest holds a batch of validated
pure-call/TC1 programs as data, runs exactly one of them per boot, and advances its
machine only inside a `Run` request. Every frame is semantic: no clock value, random
number or other input outside the image and the host's requests enters a frame.

## 1 Transport

The stock Solo5 `spt` tender at commit `38e0c348be23` attaches a `NET_BASIC` device to a
file descriptor it inherits when given `--net:NAME=@N` (`tenders/common/tap_attach.c`:
"Syntax @<number> indicates a pre-existing open fd"). It sets the descriptor
non-blocking, adds it to the tender's epoll set and allows `read`/`write` on it in its
seccomp filter (`tenders/spt/spt_module_net.c`). The guest's `solo5_net_read` and
`solo5_net_write` are plain `read`/`write` on that descriptor, and `solo5_yield` waits on
the epoll set. Nothing in the tender inspects the bytes.

The guest manifest declares two net devices, and the host launches:

```
solo5-spt --mem=32 --net:ctlin=@0 --net:ctlout=@2 control.spt
```

| Device | Descriptor | Direction | Host side |
| --- | --- | --- | --- |
| `ctlin` | 0 (the tender's stdin) | host → guest | write end of a pipe |
| `ctlout` | 2 (the tender's stderr) | guest → host | read end of a pipe |
| console | 1 (stdout) | guest → file | banner only; never parsed |

Both are anonymous pipes created by the host's subprocess library: byte streams, so a
frame may arrive in pieces or several frames in one read; both sides reassemble. The guest
writes each frame in chunks of at most 4,096 bytes (`PIPE_BUF`), so a chunk is written
whole or not at all; a refused chunk is retried after a 1 ms `solo5_yield` (up to 5,000
times, then exit 2). That retry is the only place the guest reads the monotonic clock,
and the value never reaches a frame or the machine state. While waiting for a request the
guest calls `solo5_yield` with no deadline; it returns when `ctlin` is readable, or when
`ctlout` reports an error (the host closed it), which ends the guest with exit 4.

The tender's own diagnostics (`errx`/`warnx`) also go to descriptor 2. They occur only
when the tender fails; the host then sees bytes that are not a frame and fails closed.

## 2 Frame

Both directions use one layout, all ASCII:

| Offset | Bytes | Content |
| --- | --- | --- |
| 0 | 5 | `FGC1 ` (magic and protocol version) |
| 5 | 1 | direction: `H` host → guest, `G` guest → host (`T` only in tapes, §7) |
| 6 | 1 | type (§3) |
| 7 | 1 | space |
| 8 | 8 | sequence number, decimal, zero-padded |
| 16 | 1 | space |
| 17 | 8 | payload length L, decimal, zero-padded |
| 25 | 1 | LF |
| 26 | L | payload: bytes 0x20–0x7E only (no LF) |
| 26+L | 1 | LF (trailer) |

Frame size is 27 + L. Limits: host payload L ≤ 512; guest payload L ≤ 61,440, so a guest
frame (≤ 61,467 bytes) fits in a default 64 KiB pipe buffer; one Steps record ≤ 16,384.

Payloads are JSON objects in one canonical spelling: keys in the order given below
(sorted), no whitespace, every number a decimal string without sign or leading zero
(at most 9 digits in requests), `kind` naming the type. The guest accepts requests only
in exactly this spelling, by template; the host parses guest payloads as JSON with
duplicate keys refused and then checks fields.

## 3 Messages

Sequence numbers: the guest's Hello is 0. The host numbers its requests 1, 2, 3, … with
no gap or repeat; the guest's response to request *k* carries *k*. Exactly one response
follows each request, and the host sends the next request only after reading it.

| Type | Dir | Kind | Payload fields (in order) | Answer to |
| --- | --- | --- | --- | --- |
| `H` | G | Hello | `batch_sha256`, `kind`, `limits` {`fuel`, `guest_payload`, `host_payload`, `run_steps`}, `machine_profile`, `programs`, `protocol` | boot (seq 0) |
| `I` | H | Init | `artifact_sha256`, `batch_sha256`, `fuel`, `kind`, `mode`, `program`, `protocol`, `schema` | — |
| `Y` | G | Ready | `artifact_sha256`, `digest`, `epoch`, `execution`, `fuel`, `kind`, `mode`, `program`, `schema` | Init |
| `R` | H | Run | `kind`, `steps` (1–64) | — |
| `S` | G | Steps | `digest`, `epoch`, `execution`, `kind`, `steps` (array of step records) | Run |
| `D` | H | Digest | `kind` | — |
| `D` | G | Digest | `digest`, `epoch`, `execution`, `kind` | Digest |
| `X` | H | Terminate | `kind` | — |
| `B` | G | Bye | `digest`, `epoch`, `execution`, `kind` | Terminate |
| `E` | G | Error | `code`, `kind` | any |

**Handshake.** Hello binds the protocol, the machine profile, the batch (`PC_BATCH_SHA256`,
the SHA-256 over the batch's artifact hashes) and the number of programs. Init binds the
program: its index, the SHA-256 of its canonical artifact bytes, its schema, the protocol
again, the mode (`normal`, or an injected defect `reverse-operands` / `wrap-overflow`) and
the fuel bound (1–100,000). The guest compares each with what its image holds; any
difference is `Identity`. Ready repeats the binding and gives the initial state digest.

**Run *n*.** The guest takes up to *n* reference steps, stopping early at the terminal
state, at the fuel bound, or when the next record might not fit the payload limit. Each
record is exactly the free-run guest's step record (`pc_format_sample`). `epoch` is the
machine epoch after the last step. `execution` is `Running`, `Completed` (terminal) or
`BudgetExhausted` (epoch = fuel without terminal). Run when the execution is not
`Running` is `NotRunning`.

**Digest.** The state digest is FNV-1a 64 (16 lowercase hex digits) over a structural
walk of the machine's semantic state: epoch, control, node, tail, trap, depth, the current
value where it is live, ready operands, the environment chain, every frame (kind, node,
tail, collected operands, environment, suspended segments) and closures and
resumptions by content, never by address. It is not cryptographic; it detects change,
and makes replay bind state as well as records.

**Terminate.** The guest checks that no input follows the Terminate frame (bytes already
received or immediately readable are `TrailingInput`), answers Bye and exits 0. A
controlled run can therefore stop at any epoch.

## 4 Fail-closed rules

Guest, on host input, in this order: fewer than 26 bytes before EOF → `Truncated`, or
`Hangup` if none; magic → `BadMagic`; direction ≠ `H` → `BadDirection`; type not in
`IRDX` → `UnknownType`; spaces, LF or non-digits in the header → `BadHeader`; sequence ≠
expected → `BadSequence`; L > 512 → `Oversize` (before reading the payload); EOF inside
the payload → `Truncated`; trailer ≠ LF → `BadTrailer`; a byte outside 0x20–0x7E or any
deviation from the template → `BadPayload`; Run/Digest/Terminate before Init, or a second
Init → `BadState`; identity mismatch → `Identity`; steps outside 1–64 or fuel outside
1–100,000 → `BadBudget`; Run after the end → `NotRunning`; input after Terminate →
`TrailingInput`. The guest's own limits (arena, record size, frame stack) → `GuestLimit`.
Each sends one Error frame with the expected sequence number and exits 3 (2 for
`GuestLimit`); the guest never skips, resynchronises or guesses.

Host, on guest output, in the same header order (`BadMagic`, `BadDirection`,
`UnknownType` for a type outside `HYSDBE`, `BadHeader`, `BadSequence`, `Oversize` for L >
61,440, `Truncated`, `BadTrailer`, `BadPayload` for a non-printable byte, invalid JSON, a
duplicate key or a `kind` that does not match the type), then: a response type other than
the one requested → `UnexpectedType`; Hello or Ready not naming what the host bound →
`Identity`; a Steps response with no records, more than requested, epochs not consecutive
from the current epoch, or an unknown execution → `BadSteps`; any byte after Bye →
`TrailingOutput`; an Error frame → `GuestError`. No complete frame within 10 s (1 s in
the timeout tests) is `HarnessTimeout`. A tender exit status other than 0 after Bye is
`TenderFailure`. None of these is ever a pass.

## 5 Comparison discipline (host)

The host runs the Shen model in its own process. For each Run it compares every record,
in order, with the model's next step; at the first record that differs it stops: it sends
Terminate, and records the divergence epoch. It also requires the response's `execution`
to equal the model's (`Completed` exactly when the model is terminal). With one step per
request the guest is then exactly one step past the divergence, which Bye's epoch shows.

## 6 What the protocol does not cover

Entry inputs other than `["int","0"]` (the batch fixes them); IDs above 2^64 − 1; more
than one program per boot; resuming a terminated session; `hvt`; authentication of the
host (the pipes are the boundary); any claim about the tender, toolchain or kernel, which
are trusted as built.

## 7 Tape

A tape is a sequence of frames in the same layout:

1. Header: direction `T`, type `H`, sequence 0, payload `{"artifact_sha256", "batch_sha256",
   "control_sha256" (guest image), "fuel", "kind":"TapeHeader", "machine_profile",
   "mode", "program", "protocol", "schema", "solo5" (store path or checkout),
   "tape":"fenrir.solo5.pure-call-control-tape/1", "tender_sha256"}`.
2. Every exchanged frame, byte for byte, in order: the guest's Hello, then each request
   followed by its response.
3. Footer: direction `T`, type `F`, sequence = exchanged frames + 1, payload
   `{"frames", "kind":"TapeFooter", "sha256"}` with the SHA-256 of every byte before the
   footer.

Recording adds nothing that varies between runs: two recordings of the same program,
mode and schedule are byte-identical.

## 8 Strict replay

Before any boot: the tape must parse as frames (`TapeIntegrity:Malformed-<code>`), start
with a header and end with a footer (`TapeIntegrity:Header`/`Footer`), with matching count
(`TapeIntegrity:Count`) and digest (`TapeIntegrity:Digest`). Its exchange must have the
structure of §3 — Hello at 0, then (request *k*, response *k*) for *k* = 1, 2, …, Init
first and only once, each response of its request's type or Error, Terminate last, and no
Run after a Steps response that is not `Running` (`Structure:Sequence`, `Init`,
`ResponseType`, `AfterTerminal`, `AfterEnd`, …). The header must name this tape schema,
protocol and machine profile (`Incompatible:TapeSchema`/`Protocol`/`Profile`), the batch,
guest image and tender in use (`Incompatible:Image`), and a program whose artifact hash
and schema match the batch (`Incompatible:Artifact`); the recorded Init must be the one
the header implies (`Incompatible:Init`).

Then a cold boot: the recorded requests are written as they are; every guest frame must
equal the recorded frame byte for byte (`Diverged:frame N`, N counting the exchanged
frames from Hello = 0); after the last response the guest must end as recorded (exit 0
after Bye, 3 after Error) with nothing more on `ctlout`. There is no fallback, no
re-synchronisation and no alternative schedule.

## 9 Byte vectors

Each line of [pure-call-control-v1.vectors](pure-call-control-v1.vectors) is
`NAME ROLE EXPECTED HEX`. The host checks all of them on every run. The same bytes, as
text (`␊` is LF, 0x0A):

```
init-seq-1        FGC1 HI 00000001 00000305␊{"artifact_sha256":"aaaa…aaaa","batch_sha256":"bbbb…bbbb","fuel":"200","kind":"Init","mode":"normal","program":"0","protocol":"fenrir.solo5.pure-call-control/1","schema":"tc0-a-pure-call-demo/2"}␊
run-1-seq-2       FGC1 HR 00000002 00000026␊{"kind":"Run","steps":"1"}␊
run-64-seq-9      FGC1 HR 00000009 00000027␊{"kind":"Run","steps":"64"}␊
digest-seq-3      FGC1 HD 00000003 00000017␊{"kind":"Digest"}␊
terminate-seq-86  FGC1 HX 00000086 00000020␊{"kind":"Terminate"}␊
error-badsequence FGC1 GE 00000003 00000037␊{"code":"BadSequence","kind":"Error"}␊
digest-response   FGC1 GD 00000003 00000079␊{"digest":"463bdef321c45ce8","epoch":"2","execution":"Running","kind":"Digest"}␊
bye-seq-86        FGC1 GB 00000086 00000079␊{"digest":"febaad5103a8d849","epoch":"84","execution":"Completed","kind":"Bye"}␊
```

(`aaaa…aaaa` and `bbbb…bbbb` are 64 characters each.) In hex, the Run vector is

```
46474331204852203030303030303032203030303030303236 0a
7b226b696e64223a2252756e222c227374657073223a2231227d 0a
```

Reject vectors (the host must refuse them with the code shown):

```
bad-magic                  FGC2 GE 00000003 00000002␊{}␊      BadMagic
host-direction-from-guest  FGC1 HE 00000003 00000002␊{}␊      BadDirection
unknown-type               FGC1 GZ 00000003 00000002␊{}␊      UnknownType
non-digit-length           FGC1 GE 00000003 0000000x␊{}␊      BadHeader
oversize                   FGC1 GS 00000003 00061441␊          Oversize
bad-trailer                FGC1 GE 00000003 00000002␊{}X      BadTrailer
truncated-header           FGC1 GE 0000                         Truncated
truncated-payload          FGC1 GE 00000003 00000010␊{"co      Truncated
```

A real exchange, the start of the tape of hand case 0 (`mutual-tail-countdown`, schema
`/1`), as recorded on 15 November 2026 (identities are those of that build):

```
FGC1 GH 00000000 00000303␊{"batch_sha256":"0637…5350","kind":"Hello","limits":{"fuel":"100000","guest_payload":"61440","host_payload":"512","run_steps":"64"},"machine_profile":"fenrir.solo5.pure-call-machine/1","programs":"271","protocol":"fenrir.solo5.pure-call-control/1"}␊
FGC1 HI 00000001 00000305␊{"artifact_sha256":"13a3…1eef","batch_sha256":"0637…5350","fuel":"200","kind":"Init","mode":"normal","program":"0","protocol":"fenrir.solo5.pure-call-control/1","schema":"tc0-a-pure-call-demo/1"}␊
FGC1 GY 00000001 00000240␊{"artifact_sha256":"13a3…1eef","digest":"4096da7bec450a51","epoch":"0","execution":"Running","fuel":"200","kind":"Ready","mode":"normal","program":"0","schema":"tc0-a-pure-call-demo/1"}␊
FGC1 HR 00000002 00000026␊{"kind":"Run","steps":"1"}␊
FGC1 GS 00000002 00000179␊{"digest":"8188b4ebb9514054","epoch":"1","execution":"Running","kind":"Steps","steps":[{"after":"Eval","depth":"1","epoch":"0","events":[],"site":{"node":"3","rule":"Dispatch"}}]}␊
…
FGC1 HX 00000086 00000020␊{"kind":"Terminate"}␊
FGC1 GB 00000086 00000079␊{"digest":"febaad5103a8d849","epoch":"84","execution":"Completed","kind":"Bye"}␊
```
