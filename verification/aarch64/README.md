# Fenrir AArch64 verification lane

This is an executable first milestone, separate from TC0 qualification and the
historical Solo5 campaign. It compiles a closed subset of existing TC0-A artifacts
to real AArch64 function bytes, proves the lowering in Rocq/Coq, and compares the
bytes' execution under QEMU with the existing independent Fenrir candidate.

**The proof currently ends at a handwritten instruction model.** It does not yet
prove correspondence with authoritative ARM/Sail semantics, the JSON projection,
Linux process execution, Solo5, Chez, or the complete Fenrir language. These are
explicit missing theorems, not axioms silently introduced into the proof.

## Run

Tested with Coq 8.18.0 (Rocq's former name), GNU AArch64 binutils 2.42, Node 22+
and QEMU 8.2.2 on Linux x86-64. No runtime dependency is downloaded by the check.

```sh
# Ubuntu 24.04, when these tools are not already installed:
sudo apt-get install coq binutils-aarch64-linux-gnu qemu-user
node --test tests/aarch64/*.test.mjs
node tools/aarch64/check.mjs

# Compile an individual existing-format artifact:
node tools/aarch64/compile.mjs fixtures/aarch64/checked-roundtrip.json build/arm-example
```

The full check creates a fresh directory under `build/aarch64/`, compiles the
universal theorem and twelve concrete image theorems, replays the resulting
objects with `coqchk`, independently assembles equivalent mnemonics, executes 564
QEMU comparisons, and rejects three mutated binaries both by proof and by execution.
Missing tools, timeouts and proof-checker errors fail the gate. The one-shot compile
command emits **candidate** bytes and a proof obligation; it does not certify them.

The report is `development-pass`, never a TC0 qualification receipt. It includes
exact artifact/code identities, proof source identity, tool versions, claim scope,
and remaining obligations. `assumptions.log` must show closure under the global
context. `coqchk.log` is retained. Coqchk is separate replay of compiled proof
objects, not an independently implemented proof kernel. The Linux test launcher
and its syscalls are tested infrastructure, outside the function theorem.

## Closed admitted profile

`fenrir-aarch64-checked-unary/1` accepts one pure I64-to-I64 function with no
additional declarations. Its body is the parameter or a chain of:

- `add expression literal`, where the literal is in 0..4095;
- `sub expression literal`, in the same range;
- `neg expression`.

The existing `validatePureCallArtifact` runs first, including schema, types,
unique IDs and source-map coverage. The narrower profile then rejects all other
well-typed syntax. Neither unsupported operations nor unused functions disappear
silently. Both existing pure-call schema versions are supported without changes.

Input is a signed I64 in x0. On return, x1 is 0 for success and x0 is the signed
result, or x1 is 1 for Overflow with x0 unspecified. x30 supplies the caller return
address in real execution. This is a custom two-register result convention, not
a proof of general AAPCS64 interoperability. Generated instructions touch x0, x1
and NZCV and return through x30. No emitted instruction accesses data memory, but
the model has no memory subsystem: there is no whole-machine memory-safety claim.

Each arithmetic operation is followed by `b.vc` over an overflow-return path.
Intermediate overflow is observable: `(x + 1) - 1` traps at maximum I64. It must
not be optimized into identity. Negating minimum I64 traps too.

## What is proved

`Core.v` defines mathematical checked arithmetic, a unary source AST, its lowering,
word encoding/decoding, little-endian byte decoding and a fuelled instruction
interpreter. Integer registers are represented by their signed mathematical
values. Results are normalized modulo 2^64. V is calculated independently from
input/output sign conditions for each supported instruction, then proved equal
to Fenrir's out-of-range predicate for admitted operands.

| Theorem | Meaning |
|---|---|
| `source_lowering` | Source AST evaluation equals sequential operation evaluation |
| `signed_fits` | Signed normalization preserves in-range integers |
| `flag_correct` | Instruction sign conditions detect exactly mathematical overflow |
| `decode_word` | Every admitted arithmetic encoding decodes back to its operation |
| `compiler_correct` | Every finite admitted operation sequence returns the correct result/trap in the handwritten model, regardless of initial V/status |
| `expression_binary_correct` | Composition from admitted source AST to encoded instructions for all signed-I64 inputs |
| Generated `image_identity` | Exact emitted byte list decodes to the proved instruction sequence |
| Generated `exact_image_correct` | Those exact bytes implement the projected source AST in the model for every signed-I64 input |

The bound `4 * operation_count + 2` is sufficient for modeled return. This is a
termination theorem for the closed loop-free profile, not a wall-clock guarantee
or a statement about blocking I/O. The proofs introduce no custom axioms.

## Trust and evidence boundaries

1. **Source authority:** TC0 defines language meaning; `Core.v` is a scoped
   formalization. JavaScript JSON admission/projection into the Rocq AST is not
   verified. The existing candidate supplies differential evidence, not semantic
   authority. The gate does not execute the Shen oracle and says so explicitly.
2. **ISA:** the decoder and interpreter are handwritten. GNU assembly agreement
   and QEMU comparisons test the encoding and model; they do not prove ARM
   semantics. The next research task is a checked Sail/Islaris bridge for exactly
   this instruction set, including flags and control transfer.
3. **Execution:** code loading, executable permissions, instruction fetch, address
   placement, return-address validity, exceptions, other registers, cache effects
   and hardware faults are outside this model. The model's remaining-list PC is
   not yet related to architectural addresses.
4. **Checking:** Rocq's kernel and its execution environment remain trusted.
   Native computation is not used as an unproved acceptance axiom; generated
   instances use kernel-checked `vm_compute` proof terms.
5. **Scope:** neither the existing TC0-A qualification status nor the frozen Solo5
   image epoch changes. No existing oracle, goldens, controller or gate is edited.

See [PLAN.md](PLAN.md) for the route to a reusable, authoritative ARM backend.
