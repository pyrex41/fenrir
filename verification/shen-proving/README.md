# What "proved in Shen" establishes

A small experiment behind decision 1 of
[04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md): can Shen's own
sequent type system be the place Fenrir's theorems are proved?

```sh
sh verification/shen-proving/check.sh build/toolchain/shen-scheme
```

Run with shen-scheme v0.26 (the flake's pinned oracle binary).

| File | What is loaded | Observed |
| --- | --- | --- |
| `sound-rules.shen` | `anything : A --> B`, defined as a function that calls itself forever | Accepted. Under a programs-as-proofs reading, every proposition is inhabited |
| `sound-rules.shen` | Two rules for addition on unary numbers, then the claim 2 + 1 = 3 | Accepted: Shen finds the derivation |
| `false-claim.shen` | The claim 1 + 1 = 1 under those rules | Rejected: `type error` |
| `unsound-rule.shen` | One more rule, 0 + 1 = 0, then the same false claim | Accepted, without any warning |

## Reading

Shen's type checker is a programmable proof **search** over whatever sequent
rules a program declares. That is exactly what Fenrir wants for typing
extensions. Three things it does not provide by itself:

1. **No soundness check on rules.** A declared rule is an axiom. A wrong rule
   makes false statements derivable and nothing objects.
2. **Typed functions are not proofs.** Functions may diverge, so a function of
   type `A --> B` is not evidence that `A` implies `B`.
3. **No induction or universal statements for free, and no proof object.** A
   claim about all inputs needs an induction principle someone has to state as
   a rule, and "typechecked" leaves nothing an independent checker can replay.

So Shen can be where derivations are searched for and where certificates are
checked, provided the rule set has been proved sound somewhere. Búri already
does that for one logic: its contract calculus over KLambda has every rule
proved sound in Rocq, with a certificate checker in Rocq and an executable one
in Shen. The amendment's §3 builds on that instead of a separate Rocq core for
Fenrir.
