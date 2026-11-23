# ARM64 backend migration evidence

The baseline is `94f3b1b4c7b1092645c139df07a92392406bb535`. The tested Apple Silicon package is `/nix/store/8yss5qdzad3lcaha4d9y8m5h6ywnsnrj-fenrir-0.1-dev`. Extracting the source archive with SHA-256 `a566416c32e7cc366aacd27718727505a8644722f67c81c58708075f97dca642` outside the checkout and building its flake reproduced that store path.

## Reproduce the installed checks

Run from the repository root on Apple Silicon with Nix, Apple Command Line Tools and the project's Docker setup. The application gate builds its own disposable editable package copy, removes both comparison emitters, rebuilds the applications and exercises both targets. The package gate also tests the historical handler failures, resource boundaries and native replay. The full application checks include OTP and SQLite recovery.

```sh
root=$PWD
pkg=$(sh tools/aarch64/package-mac.sh)
work=$(mktemp -d)
(cd "$work" && sh "$root/verification/backend-migration/check-release.sh" "$pkg" release)
```

The [backend guide](../../docs/design/SHEN_NATIVE_BACKEND.md) describes the pass boundaries, ABI, independent oracle, remaining Node tooling and exact-image commands. The [scalar evidence](scalar-proofs.json) identifies each of the 70 expression and 14 call profiles by artifact and emitted bytes. Five call instances also have tail-stack proofs. The unary compiler has its own 12 proof instances. Managed images, instrumented builds, linking and the runtime have execution evidence. Whole-image correctness remains open. The [archived receipt checks](archived-replays.json) identify the ten historical executable/receipt pairs replayed on the two targets.

## Generated-program performance

Each ratio is Shen elapsed time divided by baseline JavaScript elapsed time for the same workload. A ratio above one means the Shen-generated code took longer. The raw reports retain samples, timing boundaries, compiler/build times and input identities. Five alternating measurement pairs followed warmup. The durable benchmark uses the direct worker protocol. Supervised recovery is a separate correctness exercise.

| Workload | macOS ARM64 | Solo5 ARM64 SPT |
| --- | ---: | ---: |
| Prover search | 1.40 | 2.81 |
| Certificate check | 1.01 | 3.60 |
| HTTP router | 2.14 | 2.18 |
| Framed-log mixed stream | 1.32 | 3.08 |
| Durable worker request/reply | 1.04 | 1.11 |

[Prover timings and emission times](prover-performance.json) · [Application timings and build times](application-performance.json)

To reproduce the measurements, use a fresh directory for each report. Generate and validate the prover rows before starting the timed runs.

```sh
work=$(mktemp -d)
git worktree add --detach "$work/baseline" 94f3b1b4c7b1092645c139df07a92392406bb535
rustc -O -C overflow-checks=yes benchmarks/prover/reference.rs -o "$work/reference"
"$work/reference" benchmarks/prover/corpus-v1.txt > "$work/rows"
python3 benchmarks/prover/verify.py benchmarks/prover/corpus-v1.txt < "$work/rows"
python3 benchmarks/prover/compare-backends.py "$work/baseline" "$work/rows" "$work/prover"
python3 benchmarks/compare-native-apps.py "$work/baseline" "$work/apps"
```

On 2,000 prover rounds, both backends allocated 250,000 cells in search and 126,000 in checking. Shen linked 3.01 million root slots during search versus 914,000 for JavaScript, and 1.20 million versus 348,000 during checking. That identifies unnecessary root-frame work as a concrete optimization target. The counts alone cannot assign it a fraction of elapsed time. [Prover counters](prover-counters.json)

Direct tuple arguments and scratch-slot reuse narrowed the prover gap. A bounded byte scan reduced an earlier roughly tenfold HTTP gap to about twofold. An intermediate framed-log control disabled the baseline's byte-sum fast path. Its guest median moved from 2.82 ms to 2.63 ms, while that revision of the Shen program took 10.69 ms. The missing byte-sum shortcut alone does not explain the mixed-stream gap. These intermediate experiments and the final table use different compiler revisions.

## Installed results

The [release record](release.json) includes the installed compiler source hashes, six successful qualification commands, application output hashes and recovery verdicts. The standalone suite passed 49 annotated cases on each target. All 46 source-model cases agreed on both targets (92 comparisons). Both targets also reproduced forced dispatch order and rejected invalid replay choices. The explicit JavaScript comparison returned 55 on both targets. The separate scheduler ABI suite passed 18 cases on each target.
