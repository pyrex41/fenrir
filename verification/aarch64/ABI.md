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

# fenrir-aarch64-call-abi/1

The convention between functions of one `fenrir-aarch64-checked-call/1`
image, and at its entry. It extends `fenrir-aarch64-result-abi/1` (same `x0`/`x1`
result and trap encoding) to calls inside the image. It is still not AAPCS64.

## Entry of every function (also the image entry)

| Item | Requirement |
| --- | --- |
| PC | The function's first instruction (`4 * nth g (fstarts prog) 0` bytes from the image start) |
| `x0` | The argument: an I64, or a Bool as 0/1 |
| `x30` | The return address. For the image entry: an address outside the image (the run ends when the PC reaches it) |
| `sp` | 16-byte aligned, with 16 × n bytes below it usable, where n is the stack need the source semantics returns for this call (below) |

## Frame

```
mov x9, sp               ; x9 = frame base B = entry sp
str x0,  [sp, #-16]!     ; slot 0 (B-16): the parameter
str x30, [sp, #-16]!     ; slot 1 (B-32): the return address
...                      ; let values and temporaries in slots 2, 3, ...
```

- **Call** `let r = call g a`: evaluate `a` into `x0`, `bl g`, then
  `add x9, sp, #16·d` (the caller recomputes its own frame base; the callee does
  not preserve `x9`), `ldr x30, [sp, #16·(d-2)]` (reload the caller's return
  address from slot 1), `cbz x1` to continue; otherwise `mov sp, x9 ; ret` with
  the callee's trap status still in `x1`.
- **Tail call** `call g a` in tail position: evaluate `a` into `x0`,
  `mov sp, x9` (release the whole frame), `b g`. `x30` still holds this
  function's return address, so `g` returns directly to our caller and the
  stack does not grow.
- **Return**: `mov sp, x9 ; mov x1, #0 ; ret`. **Trap**: `mov sp, x9 ; mov x1,
  #code ; ret`, from anywhere in the body (the expression profile's inline
  checks are reused). `x30` equals the return address everywhere a `ret` can
  execute, because it is reloaded right after every `bl`.

## Proved (CallCompile.call_correct, in the handwritten model)

On return the PC is the entry `x30`, `x30` holds it, `sp` equals the entry `sp`,
every register other than `x0`–`x3`, `x9` and `x30` is unchanged, memory at or
above the entry `sp` is unchanged, and `x1`/`x0` encode the result or the trap
exactly as in `fenrir-aarch64-result-abi/1`.

## Stack hypothesis and what is outside

The theorem requires `lo ≤ sp − 16·n`, where `n` is returned by the source
semantics `fcall` together with the result: the slots the evaluation uses below
the entry `sp`, summed over the chain of active non-tail calls (each callee's
need is added to the caller's slots in use at the call site; a tail call's need
is not added). For a table with only tail calls, `tail_calls_constant_stack`
bounds `n` by `table_need prog`, a constant of the program.

Stack overflow is **outside the theorem**: when less stack is available, nothing
is claimed (no guard page, no trap, no detection is modelled or emitted).
Nontermination is outside too: the theorem assumes the source evaluates to a
result within some fuel.
