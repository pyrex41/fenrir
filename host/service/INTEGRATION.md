# A3 accepted-job integration on PR10

Base: `82db512` (`integration/arm64-baseline`). Service implementation, A1 model and
fixtures, A2 service handler and refinement inputs, protocol specs/vectors, and A3
history checker and campaigns are from the keen-ptolemy tree at `56fa792`. The A3
artifact and its pin are the repository-relative re-emit from `aad371b`
(`a1b54d060a2f579b2321cd269cbc95790a390752e059382436d7f277f7b9cfc1`).
`tests/host/a2-runs.json` is a retained upstream sample of 68 distinct runs, not
an A2 result produced in this checkout. No A4 artifacts, upgrade runtime, or service
gate rows were imported.

The toolchain lane has since added an ARM64 Linux Solo5 flake output and
restored `fenrir-a3-tools` for both Linux architectures. Offline evaluation
checks the host-tool packages, not their execution or the combined service
campaign. ARM64 Linux is now the primary development target.

## What can run here

- `sh host/service/check-host-only.sh`: compile the host and tests, pin-check the
  committed artifact, run framing/value/manifest checks and exercise the real
  SQLite port for storage semantics, WAL/FULL, busy, and a lost commit acknowledgment.
  The last test kills the SQLite port after `COMMIT`, observes `indeterminate`,
  reopens the store, and checks that a retry returns the original receipt without
  a new write. It does not exercise a Solo5 guest or OTP supervisor restart.
- `node --test tests/service/accepted-job.test.mjs`: JavaScript candidate tests
  against hand expectations and bounded driver tests; it does not run Shen.
- `sh harness/run-service-history.sh tests/host/histories/full-cycle.json` can be
  attempted independently of the guest with an already-built PR10 Shen/JIT
  (`FENRIR_SHEN_JIT` points to its install prefix). The runner's exit status is
  not a conformance verdict: inspect `verdicts.jsonl`. Run all 18 fixtures and
  compare every `verdict` to its input `expect` before claiming the checker works.
- `sh host/service/check.sh quick` exits 2 before a build while shared input files
  are absent. No A3 development report, new history acceptance, or qualification
  follows from that exit or from the host-only tests.

Validation on this worktree: 62 host-only tests passed using arm64 macOS, OTP
28.5.0.4 and Homebrew SQLite 3.54.0 (`SQLITE_PREFIX`); all 18 JavaScript tests
passed with Node 22. `check.sh quick` was confirmed blocked at `harness/solo5.sh`,
and a direct image-builder probe failed on the missing `residualEffects` export
before building. The Shen checker and A1/A2/A3 campaigns were not run.

## Shared integration, in dependency order

| Boundary | What to reconcile and how to verify it |
| --- | --- |
| **Choose the service ABI** | Preserve the owner-confirmed shape in amendment §8: OTP supervises Solo5, SQLite stays on the host, and infrastructure assumptions are tested, not proved. Keen-ptolemy A2 uses a residual `Store.commit : Tx → Reply` in `tc1-durable-demo/1` sent over `fenrir.solo5.pure-call-control/2`; PR10's remote caller/peer uses `tc1-handler-demo/3` and `/4`, `StoreRead`/`StoreWrite`, and a block-device wire protocol (EFFECTS §8, §12). These are not interchangeable. The smallest route to reproduce the imported evidence is a side-by-side TC1-D1 slice. Replacing or unifying either ABI instead needs an explicit owner decision, a mapping for tenant authority, retry/commit outcomes, and new A2/A3 evidence. Do not overwrite PR10's remote implementation or registered checks. |
| **Frontend and artifact validator** | Reconcile the declared durable effect, residual `main` row and typed entry lowering from `53b2d56` (plus datatype effect-name ordering from `b4f4af2`); see `frontend/{main,elaborate}.shen`, `frontend/validate.mjs`, `tools/tc0/pure-call-artifact.mjs`, and the `bf5cb36` durable validator/fixtures. PR10 has no `residualEffects` JS export, so the image builder fails at import even with pinned bytes. Keep PR10's reader/include, signatures, remote outcomes and serving schemas. Rescope the new rule to TC1-D1; test existing remote schemas and durable artifact positives/negatives, then emit `examples/service/accepted-job.fen` relative to the root and compare bytes and hash. If the pin differs, review the semantic/serialization change before repinning. If adopting the Shen derivation checker, include or reconcile durable schema coverage (`65f80f3`); no validator bypass to obtain a successful emit. |
| **Guest transport, lowerer and machine** | Port only the controlled guest lane: `9f9ca02`/`0206290` and `676f252` supply `backends/solo5/pure-call/control.c`, `tools/solo5/control-pure-call-build.mjs`, `tools/solo5/control-durable-build.mjs`, dedicated control/durable harnesses and the `FGC_V2` machine/format additions. Reconcile `tools/solo5/pure-call/lower.mjs` (bound input, identities, resumable host request) and v2's artifact/input hashes, manifest devices and batch metadata. Keep PR10's existing `backends/solo5/remote/*`, shared pure-call behavior and `supervisor/` intact. The end-to-end checks must boot the actual tender, compare protocol exchange and asset identities, reject a mismatched batch and another guest image, and refuse an unsupported residual effect before starting work. The control-v2 bytes and PR10's remote wire version numbers describe different transports. |
| **Pinned host/guest tools** | The `9e4b34d` `fenrir-a3-tools` package is now exposed on x86-64 and ARM64 Linux. The installed Solo5 pin uses `bin/solo5-spt` and `SOLO5_COMMIT`; a checkout uses `tenders/spt/solo5-spt`. Record the host OS and architecture separately from the guest triple and tender identity when collecting evidence. Neither package evaluation nor a development campaign qualifies ARM or HVT. |
| **Re-establish the evidence, then consider gates** | Run A1 bounded Shen exploration and match the history fixtures. Port `harness/tc1-durable-common.shen`, `models/tc1/durable-machine.shen`, `runtime/tc1/durable-machine.mjs`, the durable fixtures and `harness/run-solo5-durable.sh`/`harness/solo5-durable.shen` from `bf5cb36` for the A2 refinement. Run `harness/run-service-fenrir.sh` and compare the refinement scope/sample to `tests/host/a2-runs.json`; do not relabel a retained file as a fresh run. Then run `host/service/check.sh quick` with all families, record frontend vs committed artifact provenance, tool/image identities, actual histories, mutant outcomes and exact bounds. Gate work is separate and requires owner review: `2c7bed8` introduced a proposed service gate; `fd2a7e3` later re-pinned its host row to an A3+A4 report, which is not the A3 report imported here. |

## Evidence and limits

The A0 Rocq model proof remains an abstract result. The A3 host and SQLite
implementation are not proved to refine it. A process kill does not simulate
power loss; `sync_off` is outside the crash campaign's detection capability.
Do not infer confidentiality, general transaction isolation, authenticated tenant
capabilities, fairness, availability, or operation outside the guest's baked
finite request domain. No amendment, gate, or owner decision has been changed.
