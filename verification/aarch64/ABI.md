# fenrir-aarch64-result-abi/1

The calling and result convention of the AArch64 lane's compiled functions.
It is a custom convention for one entry function with one argument, **not**
AAPCS64 interoperability. Profiles that depend on it name it; a change is a
new version.

Used by: `fenrir-aarch64-checked-unary/1` (PR #8, statuses 0 and 1 only) and
`fenrir-aarch64-checked-expr/1`.

## Entry

| Item | Requirement |
| --- | --- |
| `x0` | The I64 argument, as its 64-bit two's-complement pattern |
| `x30` | The return address |
| `sp` | 16-byte aligned; the 16 × (1 + depth) bytes below it are writable and used by nobody else during the call (expr profile; the unary profile uses no stack) |
| PSTATE.NZCV | Any value |
| Other registers | Any value |

## Return (by `ret x30`)

| `x1` | Meaning | `x0` |
| --- | --- | --- |
| 0 | Completed | The result: an I64, or a Bool as 0 (false) / 1 (true) |
| 1 | Trap `Overflow` | Unspecified |
| 2 | Trap `DivZero` (expr profile only) | Unspecified |

No other status is produced. The proved theorems state the `x1`/`x0` contents
exactly for every input of the modelled machine (`observed` in `Compile.v`,
`compiler_correct` in `Core.v`).

## Preserved

For the expr profile, `compile_correct` proves (in the handwritten model):

- `sp` on return equals `sp` on entry, on the success path and on every trap path;
- every general register other than `x0`, `x1`, `x2`, `x3` and `x9` is unchanged,
  in particular `x19`–`x29` and `x30`;
- memory at and above the entry `sp` is unchanged;
- the PC after `ret` is the entry value of `x30`.

Scratch: `x0`–`x3`, `x9` (frame base), NZCV, and the stack area below `sp`.
The unary profile writes only `x0`, `x1` and NZCV.

## Not covered

How the function is loaded or placed, that `x30` points at executable code,
caller-saved/callee-saved conventions beyond the list above, SIMD/FP state,
exceptions, and calls from code that expects AAPCS64 (where a trap status in
`x1` would be meaningless). These belong to ARM-04.
