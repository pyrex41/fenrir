# Native arithmetic host admission — development contract v1

This is an adapter-only contract, not a TC0 schema, evaluator or qualification
receipt. Existing artifact validation and FGCTL canonical rules remain authority.
Historical source-bound reports are not portable snapshots and are not rewritten.
Changed host sources require fresh builds/captures; this contract grants no
cross-patch exact-original replay.

## Closed host JSON readers

`loadJSON` reads at most 4 MiB plus one overflow byte before decoding. Its token
walk rejects duplicate object keys (including nested maps), trailing values,
more than 128 levels of nesting and more than 100,000 values. Typed envelopes
require every declared exported field, exact field-name spelling, no unknown
fields, matching types and no null scalar values. Existing nil map/slice fields
remain permitted; semantic checks determine whether empty traces are admissible.
JSON integers in diagnostic envelopes are allowed and checked for target range
and integral form; the no-number policy remains specific to FGCTL records.

Artifact/input map fields retain the existing Node validator's semantic authority.
This generic reader does not substitute a Go AST validator. Semantic bounds,
noncanonical wire bytes and model/candidate mismatch are separate admission tests.
The legacy control dependency envelope includes all existing known fields; its
scope and toolchain diagnostics are preserved, not silently ignored or replaced.

Executable vectors: `TestHostJSONDistinguishingNegatives` and
`TestHostJSONAllowsDiagnosticNumbers` in
`tools/solo5/native-arithmetic/json_admission_test.go`.

## Required capture/replay inventory

`requiredSessionFiles` derives host Go sources/module, host executable, selected
Node executable, independent Shen executable/boot, arithmetic/expression models,
build/artifact/input/guest, validator/canonical/lowering/admission modules,
protected candidate/protocol sources, data header, transport dependency receipt
and the six known dependency source files. It validates the independently derived
build source set before snapshotting. Captures bind these realpath-resolved files;
replay requires exact set/hash equality before oracle or guest execution. Supplied
map entries do not define which authority is required. Added/removed/swapped files
invalidate admission. This intentionally rejects historical incomplete source sets
under a changed host; their preserved pre-change replay evidence remains historical.

Executable set vectors: `TestReplayRequiresIndependentInventory`. These are unit
checks, not proof of live CLI rejection or complete mode/image/command binding.

## Captured output

Synchronous commands and guest sessions share one 1 MiB budget between stdout and
stderr. A write exceeding the remaining budget fails without retaining that write;
already retained bytes remain bounded. Each standalone test buffer retains its
own cap. The shared mutex accounts concurrent stdout/stderr writes atomically.
`TestCombinedOutputBudget` distinguishes this from the prior two independent caps.
A shared cap does not by itself establish cancellation, drain joining or live
flood-peer cleanup; those require separate lifecycle measurements.

## Verdict separation and outstanding work

Existing development session/replay schemas and wire profile are unchanged.
`Completed`/`BudgetExhausted`, `Diverged`, protocol/infrastructure errors, cleanup
and replay exactness are not interchangeable. Watchdog/crash/cancellation must not
be reported as modeled semantic traps or aggregated into admitted completion.
Qualification and native startup/counter closure remain **UNKNOWN**.

This first implementation covers capped generic JSON and required inventory/set
checks plus combined output accounting. It is not H1/H2 completion: live rejection,
per-envelope semantic/record caps, full launch-mode/image/command binding, bounded
inspection, joined cancellation and real isolated hostile peers remain outstanding.
