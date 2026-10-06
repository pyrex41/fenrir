# Next Solo5 campaign: opt-in interactive stdin transport

Status: task packet prepared after the human request “do it do it! prepare the next workflow”. That request accepts the recommended narrowly bounded, opt-in stdin approach for preparation. Execution starts only after the human reviews/confirms the next controller drive. No patch, image build or resumed run has occurred during preparation.

Scope: S2 cooperative transport development only. Qualification stays UNKNOWN. This does not qualify D1, D2, TC0-A or G4. Keep stock time APIs/counters explicitly unmediated; do not attempt S3 clock-policy expansion, a native language port or an emulator in this campaign.

## Launch a fresh finite run

The previous run `0bd83525-96ba-4149-a0d1-c74d9c8a89fd` is blocked at35/120 with confirmed cleanup and no occupied lease as measured during preparation. Preserve its evidence; do not edit its journal or silently resume it.

In Pi:

```text
/fenrir-workflow drive --turns=120 --minutes=120 --repairs=6 Follow campaigns/solo5/NEXT_TRANSPORT_SLICE.md. Implement the reviewed opt-in bounded stdin transport using a project-owned Solo5 overlay, preserve stock defaults and isolation, measure a real two-boundary host/guest handshake and strict transport replay/negative tests. Keep qualification UNKNOWN. Stop after S2 development evidence or at any new boundary requiring review. No evaluator-authority changes, privileged setup, network devices, push/deploy or automatic renewal.
```

Review the displayed full command/authority manifest and confirm. The only configured check is `workflow-tests`, a DEVELOPMENT check. Do not invoke the unconfigured `tc0-a-qualification`. The controller's fixed TC0 prompts/claims do not confer backend qualification; report the actual selected Solo5 scope.

## Read and prerequisites

Read `DETERMINISTIC_WORKFLOW.md` S0–S3/S5/S6 and `TRANSPORT_BOUNDARY_REVIEW.json`; normative `01_FULL_VISION.md` §§7–10, `03_PHASED_EXECUTION_PLAN.md` §8 and `02_TINY_LANGUAGE_CORE.md` §§11–14. Inspect existing build/client/policy/framing helpers before extending them. Read upstream/local instructions before touching an external checkout; no external checkout edit is authorized.

Starting evidence, retained without overwrite:

- `build/solo5/baseline-0bd83525/baseline.json` and its two stock build reports.
- `build/solo5/transport-0bd83525-retry/{feasibility,diagnostics}.json`.
- `build/solo5/unit-logs-0bd83525/tests-fixed-cleanup.log`.
- Previous workflow checkpoint45 and its source-bound receipts.

Verify actual environment anew: pristine Solo5 commit `38e0c348be231a2a3c59510a5caabf562792679f`, supported Linux/AArch64 Docker server, matching installed stock image/buildspec, compiler/libseccomp availability, no leftover owned resources. Missing required toolchain/transport isolation stops affected work. Do not install moving APK dependencies or pull a new base during evidence runs.

## Permitted implementation boundaries

- `backends/solo5/overlays/control-stdin/`: small source-bound tender patch, project build recipe and patch inventory.
- New `backends/solo5/interactive-guest.c` and `protocol.{h,c}`. Preserve `interactive-probe.c` as the stock capability-denial regression rather than replacing its behavior.
- `tools/solo5/build-control-stdin.py` and `interactive.py`; narrowly necessary shared-client changes, with fresh evidence after any source change.
- `spec/solo5/protocol-demo.json`: distinct UNQUALIFIED transport-demo identity, not a TC0 schema/catalog replacement.
- `tests/solo5/`; immutable evidence beneath fresh `build/solo5/` output directories.

Unchanged: pristine vendor checkout, stock image/tag and historical evidence, `.pi` extension/config, protected workflow tests, all three normative plans, and language model/catalog/golden authority. Do not bypass the input restriction by declaring a network/block device or enabling arbitrary syscall access.

## T1 — narrow opt-in tender overlay and isolated build

Inspect `tenders/spt/spt_core.c` command-argument/setup paths and common loader behavior. Create a project-owned overlay applied only to an isolated source copy.

- Add opt-in `--fenrir-control-stdin`; without it, existing core policy remains unchanged.
- Before guest launch, validate fd0 is an explicitly supplied pipe/socket. Reject TTY, regular file, missing descriptor and wrong mode. An anonymous host-controlled pipe is the intended supported implementation; socket acceptance requires equivalent verified confinement.
- Grant only `read(fd=0, count<=65536)` when enabled. Do not add `open`, `socket`, `connect`, descriptor creation, other-fd reads or additional write permissions. Keep the existing fd1 output path.
- Preserve all stock device/network restrictions. No executable heap, privilege/capability expansion or host TAP/KVM setup.
- Build using installed content-addressed dependencies in a network-disabled, unprivileged scratch container. Preserve upstream license and exact patch applicability checks.
- Keep stock image unchanged. Produce a separately identified immutable overlay image from verified local inputs; bind source/patch/compiler/libs/tender hashes. If safely assembling an image needs unapproved moving dependencies or a broader environment change, stop for review. Never execute through an unchecked moving tag.

Acceptance: pristine vendor before/after, reproducible patched tender builds within the installed-image scope, default fd0 denial still SIGSYS, opt-in valid pipe input readable, regular-file/TTY input rejected before guest execution. Independent probes still deny other-fd reads, read count65537, open/socket/connect. These are sandbox capability tests, not language traps or conformance.

## T2 — closed protocol and real cooperative exchange

Publish a distinct demo profile/schema with exact allowed records, fields, sequence rules, framing, limits and diagnostic handling. Closed canonical payloads: decimal strings for IDs/counts, no numeric JSON tokens, duplicates/unknown fields rejected. Reuse tested encoding concepts, not oracle transitions.

Transport uses explicitly piped host stdin (`docker -i`, no TTY) and guest fd1 framing. Do not inherit the user's terminal or use files/network as response sources. Framing has version, byte length, bounded payload and exact termination; split/coalesced reads must behave identically.

Initial hand-derived sequence, with independently counted transport state:

1. Guest Hello, guest-direction sequence0; host Init, host-direction sequence0, binding profile/run/config identities.
2. Guest Boundary0, guest sequence1, epoch0, explicit `Probe0` site and singleton enabled-domain hash; host Proceed0, host sequence1, matching identity/site/domain.
3. Guest Boundary1, guest sequence2, epoch1, explicit `Probe1` site; host Proceed1, host sequence2, matching identity/site/domain.
4. Guest Terminal, guest sequence3, epoch2, accepted-boundary count2; host Ack, host sequence3; clean guest exit0/EOF.

`Probe0/Probe1` are transport-demo sites, not invented TC0 AST rules. The accepted-boundary count is a hand-derived protocol result, not a language I64 evaluation claim. A guest must wait for each response before advancing its protocol state.

Retain stock banner bytes as a bounded, explicitly allowed diagnostic prefix before Hello. After Hello, unexpected stdout bytes are protocol failures; do not silently discard arbitrary lines. Retain bounded stderr diagnostics separately. If a physically separate channel is necessary, stop for descriptor-layout review instead of broadening permissions.

Bounds:64KiB maximum per frame/read,8MiB aggregate captured output, bounded total input bytes and exact finite record count,16MiB guest memory,128MiB container memory,pids32,32MiB buildtmpfs,30-second infrastructure watchdog per execution. Declare the precise payload/framing overhead relationship; no advertised frame may require an oversized single read. Guest parser has fixed bounded storage and checks every read result/EOF.

Acceptance: ten cold positive runs; delayed response0/response1 runs have identical semantic frames. Hold a response for a declared bounded host observation interval, verify no subsequent boundary/terminal is observed, then release it. This is a measured cooperative protocol check, not a universal proof or deterministic native instruction budget. No wall-clock value enters semantic fields.

## T3 — strict restart-and-replay and negatives

Bind tape/report to guest artifact/config, overlay patch, tender/image/compiler, protocol/profile, adapter, initial state and every bound. Record each response, including singleton choices and terminal Ack; retain exact input bytes and normalized semantic observations with distinct diagnostics.

Replay from a cold start with matching identities and materialized response bytes. No randomness, missing-response fallback, alternative schedule or cross-binary exactness claim. Changed guest/tender/options are a new scenario, not exact original replay.

Required negatives: duplicate/reordered/missing/extra record, wrong run/sequence/epoch/site/domain, unknown field/kind, malformed length, duplicate decoded key, numeric token, oversized input, unexpected bytes after Hello, premature EOF/Terminal, trailing records, output flood, guest crash and non-yielding watchdog. Add a deliberately mismatched protocol guest/control to demonstrate detection; a crash alone is not a semantic mutant kill.

Acceptance: admitted transport completion replays exactly across cold starts; a retained protocol failure reproduces the same independently observed first error where deterministic. Watchdog/crash/truncation remains incomplete unless an independently validated mechanism captures that boundary. No machine-level snapshot/native determinism claim.

## T4 — evidence and stopping

Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/solo5 -v` for unit checks and newly implemented synchronous integration commands for actual overlay/guest evidence. Use fresh named `fenrir_check workflow-tests` receipts at controller measure boundaries; passing controller tests do not verify Solo5 semantics.

Retain commands, source/toolchain/image/binary/input hashes before/after, actual positive/negative counts, classifications, cap hits, raw diagnostics and cold-repeat comparisons. Give containers exact ownership labels/names. Always join owned client groups and remove/independently confirm absence of owned containers, including timeout/cancel/error paths. Do not classify an arbitrary daemon error as successful removal.

Checkpoint after each measured vertical slice and before handoffs/budget exhaustion. Stop after T1–T3 development exit with an S3 clock-mediation task packet, NOT by automatically applying new clock/yield/counter policy. Also stop on cancellation, missing prerequisites, ambiguity requiring language/authority changes, unsupported descriptor wiring, new isolation expansion, drift or unresolved cleanup.

Final report: interactive transport demonstrated within declared cooperative scope, exact transport replay/negative evidence, known remaining clock/counter/native-control gaps, cleanup and qualification UNKNOWN. No G4/PASS promotion, backend completion claim, push/deploy or automatic renewal.
