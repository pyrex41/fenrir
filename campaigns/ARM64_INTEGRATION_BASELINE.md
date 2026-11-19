# ARM64 integration baseline

This records development evidence for [draft PR #11](https://github.com/pyrex41/fenrir/pull/11), stacked on [PR #10](https://github.com/pyrex41/fenrir/pull/10). It does not register a qualification profile.

| Lane | Evidence retained at publication |
| --- | --- |
| ARM64 toolchain and Solo5 | Pinned sources built on Linux ARM64 with an explicit tool prefix. Nix evaluation is not a Nix build result. No ARM HVT/KVM boot was measured. |
| Controlled execution and remote effects | On integration snapshot `a8f0da2`, ARM64 `spt` agreed on 271 v1 programs (stride 25) and 16 v2 durable cases. All 86 remote schedules were accepted on the separate block-device transport. |
| A1/A2 | Fresh bounded ARM64 development run at `82847df`: 251,374 product states without truncation, and 68 fresh A2 executions compared with JavaScript and `spt` and cold-replayed. |
| A3 | Full process-crash campaign below. Notes that the prerequisite port was blocked describe the initial import, not the status of this run. |
| Typing and AArch64 proofs | Opt-in Shen checking covers TC0-A, H1/H2, and D1, not remote/serving schemas; no soundness proof. Historical compiler proofs target a handwritten instruction model; the integrated Linux proof matrix is a separate check. |

## Source-bound A3 run

- Source: `da1ec7459a7b8edb92dd887d49fb90d8f6e5088d`; tree: `03bfc19499effc670ec402fa5a11815a9ab3d915`. Run `1795123298-235`; clean worktree before and after execution.
- Host: Debian 13 Linux/aarch64 under OrbStack; stock Solo5 `spt` at `38e0c348be231a2a3c59510a5caabf562792679f`, SQLite 3.46.1. The runner used an explicit tool prefix, not Nix, and emitted the accepted-job artifact from source.
- Full scope completed: 706 scenarios, 548 normal histories accepted, 128 unit tests, 18 history fixtures, and 12 live controls. All eight mutant expectations matched, including the expected non-detection of `sync_off`.
- SHA-256 of retained raw artifacts: report `3df27f69a82d0d9d2edb981ada0122f8b00d9e75211c7bdf67aac924c1d9f7c8`; live control log `001561581396d362423192cad0362e77725c7ba5ae5e06b7490f0d35646a5a65`. The raw files are retained locally, not attached to the PR.

The result is **observed histories accepted** under the tested process-crash scope, not evidence of power-loss durability, authenticated tenant authority, or a qualification. Standalone receipts remain `qualification: UNKNOWN`.
