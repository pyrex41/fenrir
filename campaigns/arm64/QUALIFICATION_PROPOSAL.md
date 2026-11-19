# ARM64 Linux G1 and TC1 qualification — owner review proposal

**Qualification: UNKNOWN.** This proposes one Pi-independent profile,
[`fenrir-g1-tc1-aarch64-linux-spt/1`](profile-v1.json), against integration
baseline `da1ec7459a7b8edb92dd887d49fb90d8f6e5088d`. It is not an authority
record or a receipt. The two registered check IDs, their manifests, and their
Pi registration are unchanged. The legacy evaluator now checks the documented
Linux x86-64 boundary before granting registration on a run: `uname -sm` and
its exit are reported, only exact successful `Linux x86_64` is eligible, and
other or unobserved platforms yield `UNREGISTERED` / `qualification: UNKNOWN`.
Bare runs still report row verdicts and may exit 0 on ARM64; would-be claims
are kept under `development_claims`, not credited. Nonce-framed runs emit
UNKNOWN, no claims, and exit 2 on an unsupported platform. The probe trusts
the runner's PATH and kernel; it is not hardware or runner attestation.

## Profile to review

- A native ARM64 Linux host or ARM64 Linux VM, with an identified kernel,
  explicitly configured namespace/credential boundary and usable seccomp.
  `node` must be native ARM64 Node 22.19+ within the Node 22 line, supplied
  from the locked toolchain for a qualification run. Darwin and user-mode
  emulation are out of scope. A generic managed runner/container is not
  admitted just by reporting `aarch64`.
- Same G1 and TC1 acceptance rows, checks, bounds, claim prerequisites,
  aggregation and claims as the exact manifests pinned in `profile-v1.json`,
  plus the platform/toolchain/evidence admission requirements in this
  proposal. No required row is dropped or replaced by development smokes.
  TC1 requires a fresh G1 on the same source, on this same ARM64 profile and
  in the same evaluation; no historical x86-64 results or loose report reuse.
- ARM64 flake outputs: `shen-jit` executable and its `lib/`, `solo5`
  (stock `spt`, architecture-specific wrappers/runtime, source revision in
  the profile), and `erlang` (`erl` and `erlc`) for TC1. Do not accept an
  installed `SOLO5_COMMIT` marker alone. The reviewer should see evaluated
  store paths, used executable identities and closure identities, not just
  names. Require no lock updates at evaluation time.
- No HVT/KVM, modified controlled Solo5 tender, proof/Coq/Rocq coverage,
  service A1–A3 or production claim. The TC1 remote rows are for the specified
  observed histories on stock SPT and bounded model exploration, not hardware
  fault/clock guarantees or proof of the semantics.

## What must be covered

| Requirement area | Evidence on this profile |
| --- | --- |
| G1 identity, ledger and boundary | Clean pinned inputs before/after; validate ledger; run the existing positive-control and denial probes on the actual runner. Namespace creation alone is not the boundary row. |
| G1 agreement and arithmetic | Full unit suite with no skips; hand expectations and strict replay; exhaustive grammar G ≤5, 5,695 programs; three independent mutant rows (kill requires completed divergence); 112 catalog transition keys; compare the full boundary-product with the independent C guest on `spt` (8,745 programs, both guest defects). This does not include IDs above 2^64 or a second Shen port. |
| G1 defect/repair | Run the named generated discovery, typed reduction and original/minimized replay, then build a fresh S3 packet and evaluate the exact retained patch. A patch that no longer applies is UNKNOWN. |
| TC1 handlers | Unit suite with no skips; 20 hand handler fixtures; grammar H ≤7, 12,693 programs; full JS and C guest comparisons; 20 fixed seeds × 1,000 generated cases and the same-run SPT batches; six JS defect rows, negative controls, reduction and fresh original/reduced re-comparison. The optional handler step measure is not strict replay or a transition catalog. |
| TC1 remote | Model: 10 exhaustive bounded systems, 13 properties, all model step kinds, 17 mutants, 23 hand schedules and negative control. SPT supervisor: 31 hand, 50 seeded and 5 free runs, 12 defect switches, two systems, observable consoles/stores and negative control. Peer: 22 hand + 400 generated single requests, three-machine agreement with store operations, writes and the read-own-writes defect controls. Preserve the absence of real-power-loss, torn-write or on-wire datatype coverage. |
| Optional rows | G1 second port remains DEFERRED (optional); record the optional wider G1 SPT agreement and TC1 handler step coverage honestly; neither can cover a required gap. |

Existing scope limitations are retained: model and harness share a Shen/JIT
process, no exhaustive result outside the two bounded grammars, no theorem
of typing/resumption or crash durability, and reduced examples are not
provably minimal. TC1 `not_covered` in the pinned manifest remains applicable.
Keep aggregate diagnostics for every row with FAIL > BLOCKED > UNKNOWN > PASS;
an infrastructure failure is not a mutant kill or semantic disagreement.

### Isolation decisions

The evaluator itself runs trusted-local; candidate isolation is measured, not
general host isolation. The candidate uses `unshare -n` and Node permissions
with a stripped environment. Check both the launcher PATH and the candidate's
fixed `/usr/bin:/bin` path. Missing namespaces, failed controls/denials or
unsupported SPT behavior cannot be waived implicitly. Do not use a privileged
container as a drop-in substitute for a reviewed runner boundary. Existing
trusted-local evaluator limitations apply to source-driven builds and the
compilers/tender; agree on the external job boundary and runner provenance
before admitting evidence. No test should use actual credentials.

The historical G1 waiver is instruction-only repairer isolation, tied to
patch SHA-256 `5991317d47198014a1109b530ecd2354eb0a64b6f1142c30c69ea81c11cdcc50`.
The proposed ARM64 G1 profile does **not** inherit it silently: confirm it
for ARM64 G1, or replace the record with measured repairer isolation. The
record says to revisit before relying beyond G1; for ARM64 TC1 require
enforced repairer isolation unless the owner explicitly extends the waiver to
that scope. The existing TC1 evaluator propagates the G1 waiver, which is
diagnostic, not a new waiver decision. A technical PASS with an unapproved
waiver is still qualification UNKNOWN in this profile.

## Preflight (not a gate)

Run from a clean committed checkout on a reviewed Linux ARM64 runner:

```sh
nix build --no-link .#shen-jit .#solo5 .#erlang
nix develop --command node tools/evidence/arm64-preflight.mjs tc1 --head FULL_COMMIT
```

Use `g1` to omit the Erlang requirement. The command checks clean, exact
tracked source and pinned row-manifest scope, Linux/ARM64/Node identity,
availability of the installed ARM64 Nix outputs, and namespace creation on
both PATHs. It evaluates output paths without asking Nix to build outputs
or update the lock. `READY-FOR-DEVELOPMENT` is exit 0; BLOCKED and UNKNOWN are
exit 2. It neither runs a guest nor proves seccomp, the sandbox controls,
toolchain usage by a later evaluator, runner provenance or cleanup. A clean
preflight, even with all prerequisites, always says `qualification: UNKNOWN`.

For bounded ARM development measurements, use the standalone runner's
[`arm-development-g1` or `arm-development-tc1`](../../tools/evidence/README.md#arm64-development-capture-no-qualification)
mode. The separate development frame and receipt require same-run identity
and report digests but cannot grant eligibility. The legacy check IDs still
expect a registered frame and are not ARM adapters. Bare stock gate launchers
also remain available for direct development measurement.

## Evaluator and evidence work still required before approval can take effect

1. **Separate ARM Shen entry points/report schema from legacy status.**
   Reuse the row dispatch and aggregation, not `.pi`'s `owner-accepted`
   registration check. Bind eligibility to the reviewed exact profile digest
   and an out-of-band owner-controlled authority record; a candidate checkout
   must not be able to self-approve by editing its manifest. For this proposal
   there is no admission branch. On future approval, use distinct profile-ID
   and gate-ID report fields and leave legacy qualification behavior intact.
2. **Add required ARM runtime checks.** Verify actual used ARM Shen executable
   and libraries, Node, `solo5-spt`, `solo5-elftool`, compiler/linker
   wrappers and guest ABI/runtime inputs, and `erl`/`erlc` for TC1, against the
   evaluated pinned outputs. Run a real SPT smoke plus full boundary probes
   before the expensive gate rows; avoid ambient PATH/wrapper fallbacks. Pin
   the input environment for guests, supervisor and shell prerequisites and
   carry usage identities in their reports. A missing output/probe facility is
   BLOCKED; wrong identity or partial/corrupt evidence is UNKNOWN; a confirmed
   violation or semantic divergence is FAIL.
3. **Complete nested G1 admission.** ARM development capture now binds the
   nested role, run nonce, source, profile and manifest digests on every
   reported status; it retains the exact nested report digest and validates
   the row inventory. The future evaluator still needs pinned toolchain
   identity on every status and approved waiver disposition. Bare legacy
   development PASS must not serve as that prerequisite.
4. **Use a Pi-independent receipt envelope.** Bind exact full Git HEAD,
   tracked bytes/modes, evaluator/protected paths (including the profile,
   flake/lock and waiver), manifest digests, command/args, runner and tool
   identities and bounded logs to one run. Retain every row result plus
   subordinate report, input batch/seed, binary/image and counterexample
   digest needed for review, not only `gate.json`. Require clean source and
   stable identities before and after, fresh owned output directories and
   independently confirmed job and descendant cleanup. Hashes detect drift;
   they do not make a same-user process or uncontrolled runner trustworthy.
5. **Negative controls before any admission.** Require ARM/no-owner-record,
   wrong OS/architecture, unavailable sandbox, wrong tender/toolchain,
   absent/duplicate/unknown required row status, skipped tests, omitted mutant
   kills, stale nested G1/different profile, unapproved waiver, wrong
   commit/digest, source drift, missing evidence/hash mismatch and unresolved
   cleanup to be unable to credit a PASS. The legacy guard controls are
   executable now; ARM row/receipt controls must accompany that evaluator.

The owner should review the exact profile and both manifest hashes, the
runner/TCB and isolation policy, G1 and TC1 waiver handling, the evaluator
and receipt policy, then a fresh source-bound evidence bundle. Record the
approved checkout and profile digest separately from this proposal. Any source
change needs fresh evidence; changes to scope, evaluator authority, pinning
policy or waivers need explicit review before credit.
