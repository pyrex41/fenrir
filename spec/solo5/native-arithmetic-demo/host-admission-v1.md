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

## Nested Node lowering bridge

The shared native/peer bridge decoder caps the complete response at 128 KiB and
checks a closed typed envelope down through lowering-data and row fields. It
requires the existing lowering schema, nonnull input/rows/literals/children,
1–100 rows, a root within the row set, and at most three in-range integer child
indices per row. Missing/extra keys, null scalar fields, fractional indices and
wrong field types are rejected before those values are used by the host.

`TestNativeBridgeNestedClosedShape` and `TestNativeBridgeSharedByteLimit` provide
negative and boundary vectors. `TestNativeBridgeRealNodeLowering`, enabled with
`FENRIR_BRIDGE_FIXTURES`, checks all 13 real Node-generated hand lowerings and
unchanged retained map/header values. These are adapter tests, not guest execution
or hand-trace verification. Node remains the artifact/semantic authority: this
check does not validate graph topology, tag/operator/literal semantics or digest
correctness. The adapter now independently renders the bounded data-only C
representation and requires byte-exact equality with the returned header. It binds
digest claims, all ordered rows, child padding, root/count/parameter and input to
that header; appended code and alternate C spellings reject. Rendering requires
canonical uint64 identifiers, lowercase 64-hex digest claims, the existing closed
tag/operator encoding, ASCII label domain and exact Unit/Bool/I64 literal forms.
These are safe representation checks, not a replacement AST/type/graph validator,
independent input/artifact hashing, compiler verification or binary attestation.
`TestNativeBridgeHeaderContradictions` and `TestNativeBridgeDataContradictions`
reproduce 19 previously accepted contradictions; hand-written literal byte vectors
cover I64 boundaries and unsafe tokens. Real Node hand vectors check compatibility.
No arbitrary C parser or oracle transitions are introduced.

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

## Resource hashing

`digest` hashes regular files incrementally rather than allocating their entire
contents. It opens nonblocking and checks the opened descriptor's file type before
reading, rejecting directories, FIFOs and other nonregular resources as
`DigestRegularFileRequired`. Symlinks to regular files retain their previous byte
identity; source confinement remains the separate `sealedPath` policy.
`TestDigestRegularFileRequired` and `TestDigestStreamingIdentity` cover file-type
rejection and unchanged SHA-256 identities across chunk boundaries.

This bounds hashing memory, not total bytes or elapsed time. It does not establish
atomic snapshots under concurrent mutation, safe device-open behavior on every OS,
or complete preflight resource closure. Those remain separate audit obligations.

## Checked CLI mode and build fuel

Session/replay flags admit only `normal` or `mutant` before source/path admission
or external tooling. An invalid mode is `CandidateMode`, not a later oracle or
candidate failure. `TestModeRejectedBeforeInputAdmission` checks this ordering.

Build receipts use the builder's canonical decimal string for fuel: `0` through
`200`, without signs, leading zeroes, fractions or exponent notation. The shared
`parseBuildFuel` rejects contradictions as `BuildFuelBounds`; native admission
checks this before dependency/Node tooling, and session/replay use the same
parser before model evaluation. `TestBuildFuelCanonicalBound` checks the bounds
and lexical policy. This policy is specific to the build's adapter-generated
field, not a prohibition on ordinary JSON numbers in diagnostic envelopes.

These checks do not establish independent binary-to-fuel/command binding or full
launch identity closure. Historical reports remain bound to their original host.

## Daemon-reported launch identity

Production build and session policy checks now receive the exact command array
used to construct Docker argv. Inspection retains `Config.Cmd`, `Config.Entrypoint`,
`Path` and `Args`; it requires no inherited entrypoint, exact Cmd, executable Path
and argument sequence. Build checks bind `sh -c` and the actual script (including
fuel); session checks bind the tender, memory/stdin switches, guest path, quiet
flag and mode. `TestContainerLaunchContradictions` reproduces 14 prior acceptances
of swapped/missing command metadata for build/session commands.

These checks run at the existing **post-launch inspection** point and fail
publication on contradiction. They do not prevent a substituted process from
starting, attest compiled binary fuel, validate historical advisory `os.Args`
receipt strings or establish trust beyond daemon-reported metadata. No guest
launch or live command-identity validation is claimed by these unit vectors.
Sandbox policy and historical receipt schemas remain unchanged.

## Retained session launch command admission

Replay now checks the recorded `result.command` as the exact Docker session argv,
including policy switches, tender/memory/stdin/quiet flags and selected mode.
Only the existing run-local container name/owner and separately bound image/guest
source fields vary. Names/owners/image IDs have closed lexical shapes; missing,
extra, reordered or substituted tokens reject. Production replay compares image
and guest mount source to independently admitted launch inputs before fresh Shen
model evaluation and again before native execution. This does not launch a guest
to inspect a saved command, normalize old argv or rehabilitate old receipts.

`TestStrictTape` reproduces seven previously ignored command contradictions;
`TestReplayLaunchInputsBeforeExecution` separately distinguishes well-shaped
swapped image/guest identities with no executable available. Existing source-set,
trace/choice/footer and exact-original identity checks remain required. Valid
shape is not historical command authenticity, binary attestation or live isolation.
The original build-report `Command` field remains advisory `os.Args`, not the
isolated compilation command; that separate obligation remains open.

## Saved partial campaign counters

Saved campaign inspection now bounds executions and two-build attempts by the
selected plan as well as the unchanged v1 cumulative 100/40 caps, even when
`first_error` is nonempty. `TestCampaignPartialCountsCannotExceedSelection`
reproduces two prior over-selection acceptances and retains selected-ceiling and
cancelled-zero-attempt controls. This is no-launch diagnostic consistency, not
independent attempt-ledger reconciliation or full partial-report verification.
Historical summaries and budget interpretation are unchanged; no larger envelope
or effective cap increase is introduced.

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
