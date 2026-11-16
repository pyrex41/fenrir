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

```sh
sudo apt-get install -y libseccomp-dev pkg-config
git clone --depth 1 --branch v0.9.3 https://github.com/Solo5/solo5.git build/vendor/solo5
(cd build/vendor/solo5 && ./configure.sh && make)        # must be commit 38e0c348be23
node tools/solo5/freerun.mjs --max-cases 80
```

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

### Solo5 from the flake, and the hvt check

`nix build .#solo5` builds Solo5 at the same pinned commit from source and installs
`bin/solo5-spt`, `bin/solo5-hvt`, `bin/solo5-elftool` and the
`x86_64-solo5-none-static-{cc,ld,objcopy}` wrappers, with a `SOLO5_COMMIT` file. The
wrappers call the unwrapped nixpkgs gcc and binutils by store path, so guests compile and
link from outside the build tree. Either of these uses it instead of the checkout:

```sh
export FENRIR_SOLO5=$(nix build --no-link --print-out-paths .#solo5)
sh harness/run-solo5-pure-call.sh                       # likewise exact, tc1, tc1-exhaustive
node tools/solo5/freerun-pure-call.mjs --solo5 "$FENRIR_SOLO5" --tc1
```

A directory with `SOLO5_COMMIT` is checked against the pinned commit by that file; one
without it is still treated as a git checkout and checked by `git rev-parse HEAD` and a
clean status. Reports and `batch.json` record `solo5_source` (`installed` or
`checkout`), `solo5_path` and `tender_sha256`. With the flake build (November 2026)
the four Shen comparisons give the same counts as with the checkout: 5,774 programs /
86,286 steps; 8,745 exact-arithmetic programs; 20 TC1 fixtures (625 steps) and 12,693
exhaustive TC1 programs (263,222 steps), each with the 23 hand cases (839 steps) alongside.

`--abi hvt` on `freerun-pure-call.mjs` links the guest with `-z solo5-abi=hvt` and names
`solo5-hvt` as the tender; `--out DIR` chooses the batch directory. The hvt check is
`nix run .#hvt-compare` on a host with `/dev/kvm`, or the same inside a NixOS VM as
`nix build .#checks.x86_64-linux.hvt`; [.github/workflows/hvt.yml](../../.github/workflows/hvt.yml)
runs both. It takes two prebuilt batches (the TC1 fixtures with the hand cases, 43
programs; hand, generated and 4-node exhaustive TC0-A programs, 798), runs the Shen
harness against each tender's guest, and compares the spt and hvt frame streams byte for
byte in all three guest modes. The JS candidate is not part of it. **It has not been
executed:** the container this was written in has no `/dev/kvm`. What was done there:
the hvt guests link and `solo5-elftool query-abi` reports hvt, the spt half passes, and
the VM test driver builds.

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

Limits (both checks): development evidence only, `qualification: UNKNOWN`. The host
observes a free run; it does not select steps, so this is not the control-channel profile
and gives no replay. `spt` is a seccomp-sandboxed process, not a virtual machine. The
toolchain, tender and host kernel are trusted as built, and the build is not
reproducible-build pinned. The guest machine and the JS candidate share an author lineage.
The pure-call guest takes unit, bool and int entry inputs and IDs up to 2^64 − 1 only.

### Remote-perform guests (two images and a supervisor)

```sh
sh harness/run-tc1-remote-run.sh    # Erlang/OTP supervisor + caller and peer images on spt, judged by the Shen model
```

`backends/solo5/remote/` holds the two images of the first remote-perform system
(spec/tc1/EFFECTS.md §12.11): `caller.c` runs a TC1 program on the pure-call machine
above, unchanged, and turns a perform of a remote effect, bound to a member by the
system manifest (examples/remote/ledger-system.json), into a request to the supervisor; `peer.c` is the abstract counter peer with a durable store. They talk to the
supervisor through block devices used as mailboxes (`wire.h`, `support.c`): files, no
tap interface, no privileges. The images are built by `tools/solo5/remote-build.mjs`;
the supervisor is [supervisor/](../../supervisor/README.md). Development evidence only,
`spt` only; the limits are listed there.
