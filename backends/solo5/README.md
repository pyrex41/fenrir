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

Recorded run: 81 programs (the left-trap fixture and 80 generated), 1,051 reference
steps, no divergence; 41 DivZero traps and 40 results; the reverse-operand defect
detected on all 81. Report: `build/solo5/freerun/<run>/report.json`.

Limits: development evidence only, `qualification: UNKNOWN`. The comparison is against
the JS candidate, not Shen. The host observes a free run; it does not select steps, so
this is not the control-channel profile and gives no replay. `spt` is a seccomp-sandboxed
process, not a virtual machine. The toolchain, tender and host kernel are trusted as
built, and the build is not reproducible-build pinned.
