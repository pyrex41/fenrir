# Width-independent Shen model (proposed)

**Status: proposed and unqualified.** Nothing here is the registered oracle. The
registered model is `../arithmetic.shen` and `../pure-call-machine.shen`, and the
TC0-A gate and its receipts refer to those. Promoting this is an authority
change for the owner to review.

## Why

The registered `arithmetic.shen` computes with host integers and then checks the
I64 range. That needs a Shen port with integers wider than 64 bits. Observed on
12 November 2026:

| Port | Kernel | Integers | Registered model |
| --- | --- | --- | --- |
| shen-scheme 0.26 (flake pin) | S32.3 | Arbitrary precision | Works |
| shen-scheme 0.54 | 43.4 | Arbitrary precision | Model works. The gate's Python tools do not: they digest `lib/shen-scheme/shen.boot`, which 0.54 no longer ships |
| Shen/JIT 0.7 | 43.6 | 62-bit fixnums: `9223372036854775807` reads as the real `9.223372036854776e18`, and a wider result raises `integer overflow` | Fails. The batch aborts on the first Overflow program, and I64 literals near the range limits are silently inexact |

## What is here

- `i64.shen`: I64 values as canonical decimal strings, with add, subtract,
  multiply, truncating divide, negate and compare done on lists of decimal
  digits. No host number above 99 is formed. It defines `tc0.arithmetic` with
  the registered interface.
- `pure-call-overrides.shen`: loaded after the registered machine, it redefines
  the three functions that use host integers for language values or IDs
  (`tc0.pc.insert`, `tc0.pc.pure`, and the new helper `tc0.pc.index`). Every
  other transition is the registered machine's text, unchanged.
- `pure-call-oracle.shen`: the batch driver, same protocol as the registered
  one.

I64 literals and all IDs are sent to the model as Shen strings. The model's
output has the same shape, so the existing normalization is reused.

## Evidence (development)

```sh
node tools/tc0/check-portable-i64.mjs build/toolchain/shen-jit build/toolchain/shen-scheme-v0.54/bin/shen-scheme
sh harness/run-solo5-pure-call.sh
```

- **Arithmetic against exact results.** 5,478 cases (five binary operations and
  compare over a 33-value boundary set squared, plus negate) match results
  computed with BigInt, separately on Shen/JIT 0.7, shen-scheme 0.54 and
  shen-scheme 0.26. The set includes both I64 extremes, the multiplication
  boundary 3037000499/3037000500, and values on each side of 2^53, 2^61 and
  2^62.
- **Whole model against the Solo5 guest.** With this model on Shen/JIT 0.7,
  run by the Shen harness ([harness/](../../harness/README.md)), all 5,774
  pure-call programs (86,286 reference steps) agree with the guest. Before the
  harness moved to Shen the same held on shen-scheme 0.54 through a Python
  wrapper, since removed. The
  registered model on shen-scheme 0.26 and 0.54 gives the same traces on the
  same programs, which is the evidence that the two models agree on this scope.

## Not done

- The registered exact-arithmetic ledger (`tools/check-tc0-exact-arithmetic.py`,
  2,908 programs through the whole machine, including IDs above 2^64) has not
  been run against this model. It needs the gate's Python transport, which
  sends integers and IDs as bare tokens.
- No hand-derived fixtures, mutants, reduction or replay were rerun against it
  beyond the comparison above.
- The arithmetic-only expression model (`../expression-machine.shen`) is not
  ported; on Shen/JIT it is only right while every value fits 62 bits.

## What moving the oracle to a current port needs

1. Owner review of this model as a replacement for the registered arithmetic.
2. The gate tools' runtime identity generalized from `shen.boot` to whatever
   files the port ships (about fifteen places: the Python checkers, the replay
   admission checks, the Go native host and three tests).
3. The transports changed to send I64 literals and IDs as strings.
4. Flake pins. Built here from: Shen/JIT tag `v0.7`, commit `2f4b48bf9aab`
   (`make deps && make`); shen-scheme `shen-scheme-v0.54-src.tar.gz`, SHA-256
   `1de4a013690e204c5f3d61abd52f8adf1ecb2d2ebfa6bfdda184b312fd9bd007`
   (`make`, without `-j`).
5. A fresh gate run. Every existing receipt names shen-scheme 0.26.
