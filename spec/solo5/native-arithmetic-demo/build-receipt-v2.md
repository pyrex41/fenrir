# Native arithmetic build receipt v2 — development only

Fresh Go builds emit `fenrir.solo5.native-arithmetic-build/2`. All existing
receipt fields retain their meaning; the required `compile_command` is the exact
`["sh", "-c", script]` array passed to isolated compilation, not advisory CLI argv.
`command` remains diagnostic `os.Args` and is not reinterpreted as compilation.

Admission derives the unchanged fixed recipe from canonical fuel 0..200 and
requires byte-exact command equality before dependency/Node/Docker tooling.
Missing, substituted, appended or mismatched-fuel recipes reject. The existing
required source sets, data/dependency hashes, two-build equality, immutable image
and tender checks remain required. Docker post-launch inspection separately checks
the command actually reported by the daemon. Compiler flags, candidate/protocol
sources, manifest, sandbox limits and stock/tender policies are unchanged.

`TestBuildCompileCommandContradictions` reproduces seven command contradictions;
`TestNativeFuelRejectedBeforeDependencyTooling` includes a missing-command vector
with consistent fake inventory and no external executables. Unit rendering and
receipt consistency are not independent binary-to-fuel attestation, toolchain
inventory qualification, live compilation or language conformance evidence.

Historical v1 receipts remain unchanged with their original advisory-command
meaning. The current host requires v2 for fresh session/replay admission; it does
not migrate old receipts or infer compilation claims from `os.Args`. Original
source-bound historical hosts/evidence remain separate; exact-original replay is
not obtained by rewriting a receipt or by using this changed host.

No guest build/execution or enlarged campaign budget is authorized by this
contract. Qualification and native startup/counter closure remain UNKNOWN.
