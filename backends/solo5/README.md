# Local Solo5 development backend

Measured target: **Solo5 v0.9.3 SPT, Linux/AArch64**, inside the existing Docker server. This is a sandboxed-process target, not HVT/KVM or a machine-replay claim.

```sh
python3 tools/solo5/setup.py --repeats 10
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/solo5
```

Setup checks a pristine pinned upstream checkout, builds/reuses the Docker image by its build-spec hash, then compiles the guest in a network-disabled tmpfs container and runs it by immutable image ID. Guest inputs are read-only; no checkout, Docker socket or host credentials are mounted. Containers are uniquely owned and removed in `finally`; images remain as development cache. No privileged container, host TAP or KVM setup is performed.

Evidence: `build/solo5/setup.json`, `spike.json`, `spike.logs.json`, `probe.spt`, `build.log`. Package/compiler/tender inventory is in the logs. Upstream ISC license remains in `build/vendor/solo5/LICENSE`; APK dependencies are inventoried, not reproducibly repository-locked.

The measured spike covers:
- guest boot and explicit zero exit;
- strict length/sequence/termination framing, malformed startup rejection;
- ten cold runs with identical Pong/Terminal semantic payloads;
- benign `openat` and `socket` attempts killed with SIGSYS, protected sentinel unchanged;
- **stock wall-clock reads remain accessible and vary**.

Transport is command-line input and console output: **startup-only**, not an interactive scheduler channel. Time mediation, CPU-counter audit/enforcement, host Run/AdvanceTime transport, TC0 candidate integration and host-perturbation campaigns remain work. Diagnostics are separate from semantic frames. Repeated payload agreement is not whole-machine determinism or a blanket security certification; all qualification verdicts remain UNKNOWN.

Pi development continuation is provided by the project extension. After one `/reload`, use `/fenrir-workflow drive --turns=120 --minutes=120 [goal]`, review/confirm once, and the bounded development loop continues without periodic nudges. Required qualification remains external and cannot be self-promoted.

## Stock-tender free run on any Solo5 host (November 2026)

The measured profile above needs the retained Docker image and Linux/AArch64. This
path needs neither. It was run on Linux x86-64 without Docker and without KVM.

Solo5 comes from the flake, which needs only Nix (no apt, no Docker, no KVM):

```sh
nix build .#solo5          # Solo5 v0.9.3 at 38e0c348be23..., libseccomp and pkg-config from nixpkgs
node tools/solo5/freerun.mjs --max-cases 80
```

The flake fetches Solo5 at exactly commit `38e0c348be231a2a3c59510a5caabf562792679f`
(locked by NAR hash in `flake.lock`) and builds it with `./configure.sh && make`. Its only
build-side additions are the `include/version.h.distrib` a git-less tree needs (the
header `git describe` gives for the tag) and `-Wno-error=address`, because v0.9.3 predates
nixpkgs' gcc; no source file is modified. The output is the built tree, so the tools find
`tenders/spt/solo5-spt`, `elftool/solo5-elftool` and `toolchain/bin` where they do in a
hand-built checkout. The Solo5 location is chosen in this order, by `harness/solo5.sh` and
again by `tools/solo5/freerun.mjs`: `FENRIR_SOLO5` (a directory), the hand-built checkout
at `build/vendor/solo5`, the flake's `solo5` output. The guest build also needs a host `cc`
on `PATH` (the Solo5 wrapper calls it).

The hand-built route still works:

```sh
sudo apt-get install -y libseccomp-dev pkg-config
git clone --depth 1 --branch v0.9.3 https://github.com/Solo5/solo5.git build/vendor/solo5
(cd build/vendor/solo5 && ./configure.sh && make)        # must be commit 38e0c348be23
```

Identity: a git checkout must be at the pinned commit with no modified tracked files. The
flake output has no `.git`: the tools require it to be in the Nix store with a `COMMIT`
file equal to the pin, and the store path, which derives from the locked source hash, is
what reports record (`solo5_identity` in the reports and in a guest batch's `batch.json`)
in place of a `git rev-parse`.

`freerun.mjs` checks the Solo5 checkout is the pinned commit with no modified tracked
files, lowers each artifact with the existing `native-arithmetic/lower.mjs`, compiles
`native-arithmetic/freerun.c` with the unchanged `machine.c` and `format.c` using Solo5's
own toolchain wrapper, runs the guest under the stock `solo5-spt` tender in `normal` and
`mutant` modes, and compares every reference step with the JS expression machine.

Add `--shen build/toolchain/shen-scheme` (the flake's pinned shen-scheme v0.26) to put the
Shen expression model in the same comparison.

Recorded run: 81 programs (the left-trap fixture and 80 generated), 1,051 reference
steps; guest, Shen model and JS candidate agree on every step; 41 DivZero traps and 40
results; the reverse-operand defect detected on all 81. Report:
`build/solo5/freerun/<run>/report.json`.

### Pure-call guest (calls, closures, data, bytes)

```sh
sh harness/run-solo5-pure-call.sh                              # guest against the Shen model, in Shen
node tools/solo5/freerun-pure-call.mjs --exhaustive-nodes 5    # guest against the JS candidate
```

`backends/solo5/pure-call/` is a new C candidate for schemas `/1` and `/2`: named and
tail calls, closures with captured bindings, tuples, declared and recursive datatypes,
match, bytes primitives, structural `eq`, checked I64 and emit. Values live in a 4 MiB
bump arena reset per program; exhausting it is a guest failure (exit 2), never a language
trap. `tools/solo5/pure-call/lower.mjs` lowers a whole batch of validated artifacts to one
data header (node tables, child and callee indices, each lambda's free bindings in numeric
order), so one guest image holds every program and one tender launch runs a range of them.

Recorded runs: 5,774 programs (23 hand cases, 32 + 24 generated, and all 5,695 programs of
the 5-node exhaustive grammar), 86,286 reference steps. The guest agrees with the Shen
model and, separately, with the JS candidate on every step. `reverse-operands` mode is
detected on 4,019 programs and `wrap-overflow` on 238 by both comparisons.

The comparison with the Shen model is a Shen program,
[harness/solo5-pure-call.shen](../../harness/README.md), running on Shen/JIT 0.7: it runs
the model in-process, launches the tender, parses the guest's frames and compares, in
about 5 seconds. The model's integers are decimal strings (`models/tc0/i64.shen`), since
Shen/JIT integers are 62-bit. Earlier in
this lane the same scope also agreed with the registered model on shen-scheme 0.26 and
0.54 through a Python wrapper, which has been removed.

Limits (both free-run checks): development evidence only, `qualification: UNKNOWN`. The
host observes a free run; it does not select steps, so these are not the control-channel
profile and give no replay; that is the next section. `spt` is a seccomp-sandboxed process, not a virtual machine. The
toolchain, tender and host kernel are trusted as built, and the build is not
reproducible-build pinned. The guest machine and the JS candidate share an author lineage.
The pure-call guest takes unit, bool and int entry inputs and IDs up to 2^64 − 1 only.

### Host-controlled guest and strict replay (protocol v1, 15 November 2026)

```sh
sh harness/run-solo5-control.sh        # build both images, then the Shen controller, ~20 s
```

**Transport, found by experiment: the stock tender is enough.** `spt` at `38e0c348be23`
attaches a Solo5 net device to an already-open descriptor given as `--net:NAME=@N`
(`tenders/common/tap_attach.c`), sets it non-blocking, puts it in its epoll set and allows
`read`/`write` on it and nothing else (`tenders/spt/spt_module_net.c`); the guest's
`solo5_net_read`/`_write` are plain `read`/`write` and `solo5_yield` waits on that epoll
set. So the guest declares two net devices and the host launches

```sh
solo5-spt --mem=32 --net:ctlin=@0 --net:ctlout=@2 control.spt
```

with the tender's stdin and stderr as pipes held by the Shen process (stdout, the console,
goes to a file and is never parsed). A throwaway echo guest (not kept) answered three
requests in about 0.1 ms each and sent nothing before the first; the same exchange then
ran from Shen/JIT's own subprocess library, and the check below is the standing evidence.
No tender patch, no tap device, no root and no helper process are involved, so the
earlier `overlays/control-stdin` route (a patched `spt_core.c`) is not needed and no
dependency epoch is reopened: the Solo5 identity is still the flake's store path of the
unmodified pinned commit. The other stock candidate, a block device as a mailbox, was not
built: it has no readiness signal, so the guest would have to spin or read the clock.

**Guest.** [pure-call/control.c](pure-call/control.c) is a second `main` for the same
`machine.c` and `format.c`; `guest.c` (free run) is unchanged and still used by the gates.
It speaks [fenrir.solo5.pure-call-control/1](../../spec/solo5/pure-call-control-v1.md):
Hello (protocol, machine profile, batch hash, program count); Init (program index,
artifact SHA-256, schema, protocol, defect mode, fuel), answered by Ready; Run *n* (1–64
steps), answered by the step records, the epoch, the execution state and a state digest;
Digest; Terminate, answered by Bye. It advances only inside Run and otherwise blocks in
`solo5_yield` with no deadline. Any malformed, truncated, duplicated, out-of-order,
over-limit or out-of-state request gets one Error frame and exit 3. The guest reads the
monotonic clock only to pace a refused pipe write; no clock value enters a frame.

**Host.** [harness/solo5-control.shen](../../harness/solo5-control.shen), in Shen; see
[harness/README.md](../../harness/README.md). Building the images stays JavaScript
(`tools/solo5/control-pure-call-build.mjs`), as for the free run.

Recorded run (15 November 2026; tender `c1b82476…`, guest image `9d2f225c…`, batch
`0637210c…`; 1,033 tender boots in about 14 s):

| Check | Measured |
| --- | --- |
| Scope | 271 programs: 23 TC0-A hand cases (`/1` and `/2`, closures and data), 20 TC1 handler fixtures (both slices), and 228 of the 5,695 programs of the 5-node exhaustive grammar (every 25th) |
| Normal mode | 271 of 271 agree with the Shen model at every step: 4,658 steps; hand and TC1 one step per request, the sample under the host schedule 1, 2, 5, 16, 64 |
| `reverse-operands` | detected on 196 programs (23 hand, 16 TC1, 157 sample) |
| `wrap-overflow` | detected on 15 programs (5 hand, 10 sample) |
| Exact stop | in every mode and program the controlled run stopped at the epoch where the complete free-run trace first differs from the complete model trace, the guest was one step past it (Bye's epoch), and its records equal the free-run guest's |
| Stop and no advance | hand case 0 stopped at epoch 3 of 84; no frame in 300 ms after Hello or after a Run; state digest and epoch unchanged across the wait; nothing on a half-sent request until it completes; two requests in one write answered in order |
| Strict replay | 43 tapes (every hand and TC1 run), each replayed on 3 cold boots: 43 of 43 byte-identical every time; one tape on 10 cold boots and a run stopped mid-program (`reverse-operands`) on 3: all exact; all 43 re-recorded independently: byte-identical tapes |
| Negative tests | 16 tape drifts, 25 hostile-host inputs, 21 hostile guest outputs, 3 non-responding peers and 16 byte vectors: each rejected (or accepted) exactly as expected |

With stride 1 (`sh harness/run-solo5-control.sh 1`, about 2 minutes, 17,434 boots) the
scope is the whole 5-node grammar: 5,738 programs, 82,527 steps, no difference in normal
mode, `reverse-operands` caught on 3,979 (3,940 of them exhaustive) and `wrap-overflow` on
238 (233 exhaustive), the counts the JS candidate's mutants give, again each at the exact
first diverging step; replay and negative tests as above. The default stays the sample.

The negative tests, with the rejection each must produce, are listed in the report
(`build/solo5/control-pure-call/<run>/run/report.json`) and in
[harness/README.md](../../harness/README.md).

Limits: development evidence, `qualification: UNKNOWN`. This is `spt`, a
seccomp-sandboxed process; `hvt` needs `/dev/kvm`, which this machine does not have, and
is not attempted. The pipes are the trust boundary; the tender, toolchain and kernel are
trusted as built. One program per boot; entry input fixed at `["int","0"]`; the exhaustive
scope is sampled, not complete (the free-run checks cover all of it). Replay is exact at
the protocol boundary for this image and tender; it claims nothing about machine-level
determinism of the tender or kernel.

### TC1-C1 tasks in the guest (protocol v3, 15 November 2026)

```sh
sh harness/run-solo5-tasks.sh          # build the v3 image, then the Shen host, ~20 s
```

[pure-call/tasks.c](pure-call/tasks.c) is the task layer of slice C1
([spec/tc1/CONCURRENCY.md](../../spec/tc1/CONCURRENCY.md)): a task table, scopes,
channels and pending awaits, one local handler machine per task (`machine.c` is included
unchanged; its enums gain values at their ends only, so v1 and v2 images and their data
headers are as before), the scheduling-point steps, the step records of §10 and the FIFO
production policy of §9. `control.c` built with `-DFGC_V3` and linked with `tasks.c`
speaks [fenrir.solo5.pure-call-control/3](../../spec/solo5/pure-call-control-v3.md): Init
names a scheduler, `reference` (every Run names the task that steps; a task that is not
Runnable is `NotRunnable`) or `fifo` (the guest chooses and each record names its
choice). Four injected defects are Init modes: `fifo-reversed`, `cancel-off-point`,
`lost-wakeup`, `capacity-off-by-one`. Limits: 16 tasks, 64 scopes, 16 channels, capacity
8, 96 events per step (`GuestLimit` beyond). The free-running guest refuses task
programs (the lowering rejects them for it).

Recorded run: 90 programs (18 hand fixtures, 72 of grammar G), 1,338 tender boots; 151
recorded reference runs, 248 exploration witnesses and 90 guest-FIFO runs agree with the
Shen task model step for step (22,725 steps); each defect detected; 169 tapes replay
exactly on 2 cold boots each. Details in [harness/README.md](../../harness/README.md).
Development evidence, `qualification: UNKNOWN`; `spt` only.
