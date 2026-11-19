# A4 bounded development evidence

Default scope: `2 1 2 2 2 1 1 1 4 1500000` (tenants, keys, digests, submits,
deliveries, responses, crashes, dispatches, upgrade steps, product-state cap).
This is not a gate verdict; qualification remains `UNKNOWN`.

| Check | Observed on ARM64 Linux |
|---|---|
| `sh harness/run-service-upgrade.sh` | 12 hand traces; 545,360 product states, 64,676 system states and 3,511,584 edges; untruncated, no normal violations; A1 sub-scope matched. All 12 model mutants were caught and the equivalent control stayed clean. |
| Fenrir refinement | Same graph; 8,652,088 step comparisons with no differences; 84 compare-and-swap checks with no failures; six program mutants caught and both equivalent controls clean. |
| Sandboxed JavaScript and stock `solo5-spt` | All 189 completed runs (24 v1, 32 v2, 133 migration) and 48,332 steps agreed in both implementations. Solo5 replayed all 189 tapes exactly on one cold boot each (`quick`). |
| `replay-retained` on both runners | 43 model witnesses and 16 Fenrir witnesses reproduced. The freshly generated witness files matched the retained ones apart from replay paths. |
| Negative evidence checks | A product-state cap of 10 was rejected as truncated. Disabled and over-budget schedules were not reproduced. Node service tests also reject wrong-scope/altered samples, missing replay coverage, or a replay success report with the wrong process exit. |

Development environment: ARM64 Linux in local OrbStack/Docker,
`node:22-bookworm` image `sha256:e13726ca604184d7a91fcacab1fc09eefd642dc28e79ac34e85540dd93b78cfb`.
Shen/JIT 0.7 built from the flake's source and archive pins
(`2f4b48bf9aabc2b93379d15f1818e4209137eb60`, binary SHA-256
`5eaeff9082edd94e2569eb68a4eda9651b69c9c2c2b4d0641b6ec83a05e58b0a`);
Solo5 built from `38e0c348be231a2a3c59510a5caabf562792679f` against the
container's libseccomp, tender SHA-256
`cdd20cf055fd233ddcdbf15f9b6ed0cc3ccf70826180cda6b3dc6ef1e2c6c0b3`.
These were local development builds, not qualified toolchain artifacts.

The local worktree keeps the JSON reports and replay logs under
`build/a4-evidence/` and the generated samples, witness files, and tapes under
`build/harness/` and `build/solo5/`. To repeat, set `FENRIR_SHEN_JIT` and
`FENRIR_SOLO5` to suitable installs and run the commands in
[the contract](UPGRADE.md#9-fenrir-handlers-and-the-refinement-check).

No A4 OTP/SQLite campaign, independent Solo5 rerecording, or power-loss experiment
ran. See [host port blockers](../../host/service/A4_PORT.md).
