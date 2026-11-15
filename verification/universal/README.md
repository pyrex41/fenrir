# First universal-claim test: checked `add` through Búri

[04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §3 sets the test: one
TC0-A property, certified through Búri's checker against
`models/tc0/pure-call-machine.shen`. Until that works, universal claims about Fenrir
are reported as open. This directory is that attempt, against Búri
[`pyrex41/buri`](https://github.com/pyrex41/buri) at commit
`47491e21b0747f6d62623aa9fc445c229838aa8c`.

**Outcome: the property is open.** Búri's certificate format cannot state it, and
its calculus has no rule for `cond`, `and` or `or`, which make up most of the
KLambda the model compiles to. What the checkers do accept carries no claim about
values. Two helper lemmas were proved separately in Rocq inside Búri's calculus. A
bounded check of `add` was added. None of these is *model property proved* for the
TC0-A property.

```sh
sh verification/universal/check.sh
```

The script fetches Búri by git at the pinned commit into `build/universal/` and
builds Búri's pinned tools from Búri's own flake at that commit (`nix build
git+https://github.com/pyrex41/buri?rev=47491e2…#dotTools`: Shen-Scheme v0.52 with
kernel 43.1, and Coq 8.18.0). Shen/JIT comes from this repository's flake
(`.#shen-jit`, v0.7) unless `FENRIR_SHEN_JIT` is set. No local Búri checkout is
used. A run takes under a minute once the tools are in the nix store.

## 1 The property, stated on the model's functions

*Canonical I64 string*: a Shen string matching `0|-?[1-9][0-9]*` whose value *n*
satisfies −2^63 ≤ *n* ≤ 2^63−1. For a canonical string *s*, ⟦*s*⟧ is its value.

| Strength | Statement |
| --- | --- |
| S1, range only | For all canonical *a*, *b*: `(tc0.arithmetic add [a b])` terminates without exception and returns either `[ok s]` with *s* canonical, or `[trap overflow]`. |
| S2, range and exactness | S1, and the result is `[ok s]` with ⟦*s*⟧ = ⟦*a*⟧+⟦*b*⟧ exactly when that sum is in range, and `[trap overflow]` otherwise. |
| S3, the machine step | For every state `[pure-call-state [ready Node add Meta [[int a] [int b]] Tail] Env Frames Codes Names]` with *a*, *b* canonical, `tc0.pc.step` returns `[transition [pure-call-state C Env Frames Codes Names] []]` with `C = [value [int s]]` and ⟦*s*⟧ = ⟦*a*⟧+⟦*b*⟧ when the sum is in range, and `C = [unwind overflow]` otherwise. |

The functions are those of `models/tc0/i64.shen`: `tc0.arithmetic`'s `add` clause is
`(tc0.i64.checked (tc0.i64.add (tc0.i64.parse A) (tc0.i64.parse B)))`.
`tc0.i64.checked` returns `[ok (tc0.i64.show V)]` when `tc0.i64.fits?` holds
(magnitude compared with `tc0.i64.max-mag` = 2^63−1 or `tc0.i64.min-mag` = 2^63) and
`[trap overflow]` otherwise. `tc0.pc.step` reaches it through the last `ready`
clause: `tc0.pc.pure-return (tc0.pc.pure add Values)`, where `tc0.pc.pure` falls
through to `(tc0.arithmetic Op (tc0.pc.numbers Values))` and `tc0.pc.pure-return`
maps `[trap Code]` to `[unwind Code]`.

S2 was attempted; it implies S1, and S3 adds only the dispatch.

## 2 The KLambda the contract would be about

`extract.shen`, run on the pinned Shen/JIT after loading the two model files, takes
the call closure of three roots, prints each definition's KLambda as `ps` returns
it, and converts it to the program format of Búri's checker. The conversion follows
Búri's own reader `KLSemantics.parse` (`rocq/KLSemantics.v`): a bound symbol is a
variable, any other symbol a literal, a non-keyword head a call. Nothing is
simplified. The output is committed as `extracted.kl`, and `check.sh` regenerates it
and compares.

| Closure of | Definitions | With `cond`, `and` or `or` |
| --- | --- | --- |
| the `add` clause (`tc0.i64.checked`, `tc0.i64.add`, `tc0.i64.parse`) | 21 | 11 |
| `tc0.arithmetic` | 32 | 21 |
| `tc0.pc.step` | 59 | 45 |

The kernel compiles every multi-clause `define` to a `cond` whose tests are `and`
chains, ending in `(true (shen.f-error F))`. Two definitions as extracted:

```
(defun tc0.i64.checked (V270)
  (if (tc0.i64.fits? V270) (cons ok (cons (tc0.i64.show V270) ())) (cons trap (cons overflow ()))))
(defun tc0.i64.add-carry (V163 V164 V165)
  (cond ((and (= () V163) (and (= () V164) (= 0 V165))) ())
        ((and (= () V163) (= () V164)) (cons V165 ()))
        ((= () V163) (tc0.i64.add-carry (cons 0 ()) V164 V165))
        ((= () V164) (tc0.i64.add-carry V163 (cons 0 ()) V165))
        ((and (cons? V163) (cons? V164))
         (let W166 (+ (hd V163) (+ (hd V164) V165))
           (if (> W166 9) (cons (- W166 10) (tc0.i64.add-carry (tl V163) (tl V164) 1))
                          (cons W166 (tc0.i64.add-carry (tl V163) (tl V164) 0)))))
        (true (shen.f-error tc0.i64.add-carry))))
```

The ten definitions in the `add` closure without `cond`, `and` or `or` are
`tc0.i64.checked`, `cmp`, `max-mag`, `min-mag`, `add-mag`, `strip`, `sub-mag`,
`parse`, `mag` and `digit`. The work is all in the other eleven: `add`,
`add-carry`, `sub-borrow`, `cmp-length`, `cmp-msd`, `fits?`, `show`, `digits`,
`drop-zeros`, `parse-chars` and `norm`. The closure also calls the kernel functions
`reverse`, `map`, `length`, `explode` and `shen.f-error`. These are not KLambda
primitives, so they would have to be program definitions or named premises.

## 3 What Búri's calculus and checkers can do at 47491e2

Sources: `docs/CONTRACT-LOGIC.md`, `rocq/ContractLogic.v`, `rocq/ContractPrims.v`,
`rocq/ContractCert.v`, `shen/contract-cert.shen`, `rocq/KLSemantics.v`,
`rocq/KLValue.v`, `TODO.md`, `toolchain.lock.json`.

- **The calculus** (`ContractLogic.deriv`, line 225) has rules for literals,
  variables, `lambda` and `freeze` (`r_val`), `let`, `if`, `type`, `defun`,
  `trap-error`, application, global calls, consequence, existentials and framing.
  It has **no rule for `cond`, `and` or `or`**. The semantics has them
  (`KLSemantics.v`, lines 325–353), but the calculus does not. Búri records this as
  OB-CONTRACT-RULES-COVERAGE. Every rule is proved sound
  (`ContractLogic.soundness`). Primitive call contracts are proved
  (`ContractPrims.prim_spec_valid`). Recursion goes through `rec_partial`
  (step-indexed) or `rec_total` (an explicit `nat` measure). Assertions are shallow
  Rocq predicates.
- **Data.** Lists are `cons`/`hd`/`tl`/`cons?`, and strings are code-point lists
  with `string->n`, `str`, `cn`, `pos` and `tlstr` as primitives, so `i64.shen`'s
  representation is expressible. Integers are unbounded `Z` (`KLValue.int_or`,
  line 74), but Shen/JIT's are 62-bit fixnums. A theorem about Búri's semantics
  therefore transfers to Shen/JIT only for programs that never form a large
  integer. `i64.shen` is written to form none above 99, but that is not proved.
- **The certificate** (`ContractCert.v`, `Record cert`, line 53) carries a format,
  theory, program and evaluator identity, a statement that is **only a name and a
  mode** (`c_stmt : text * cmode`), declared host contracts, measures **as names**,
  and one rule skeleton per body plus one for `main`. **It carries no pre- or
  postcondition.** `main` is a closed expression, so a universal statement over all
  inputs has nowhere to go. The checker decides identity, declaration discipline,
  that measures are named, and that each skeleton fits the syntax. Semantic side
  conditions are returned unchecked. That an accepted skeleton plus proofs of its
  side conditions yields a derivation is **open** (OB-CONTRACT-CERT-SEM, which
  "needs a deep-embedded assertion language"). That the Shen checker computes the
  Rocq checker is also open (OB-CONTRACT-CERT-SHEN; sampled on 19 cases).
- **The worked example** (`ContractExample.v`, `ContractTransport.v`) is `map` with
  a closure, derived directly in Rocq with `rec_total`. Its certificate
  (`tests/contracts.shen`) is the fit check for a closed `map dbl [1 2 3]`.
- **Toolchain.** The Shen checker runs on Shen-Scheme v0.52 with kernel 43.1. The
  contract modules are checked with Coq 8.18.0. Búri's Rocq 9.3 pin is its Shen/JIT
  lane, and retiring 8.18 is TODO round 3a. Búri pins Shen/JIT v0.6; Fenrir runs
  v0.7.

## 4 The attempt and the results

`certify.shen` builds certificates by deterministic synthesis from each body's
syntax. A primitive gets its proved contract, a program function a recursive leaf,
and anything else a declared host contract. The certificates go to
`buri.contract-check` as inert data, and the 16 verdicts are compared with the
expected ones. `FenrirCert.v` is the same set of certificates generated as Rocq
terms, with each verdict checked by `vm_compute` against `ContractCert.check`. Both
checkers agree on every case run.

| Case | Shen checker | Rocq checker |
| --- | --- | --- |
| **Fragment**: the 10 rule-covered definitions of the `add` closure; main = the `add` clause on `"9223372036854775807"`, `"1"` | accepted. 12 premises: the 8 uncovered model functions called directly (`add`, `fits?`, `show`, `cmp-length`, `add-carry`, `drop-zeros`, `sub-borrow`, `parse-chars`) and 4 kernel functions (`length`, `reverse`, `explode`, `map`). 0 obligations | accepted |
| **Whole closure** of `tc0.arithmetic` (32 definitions) | rejected `body-shape` | rejected `body-shape` |
| Bounded search: every rule over ≤ 3 of 5 leaf shapes, and every rule over one of those (65,520 skeletons), against each of the 21 `cond`/`and`/`or` bodies | 0 fit | not run |
| Everything as premise: no definitions, main = `(tc0.arithmetic add [...])` | accepted, premise `tc0.arithmetic` | not run |

The accepted fragment certificate and its program are in `fragment.cert`. The
search agrees with the code. `buri.cc-fits` and `ContractCert.fits` have no case
for `cond`, `and` or `or` except the structural rules, which pass the same
expression down, so no skeleton of any size fits.

The fragment's acceptance establishes only this: the skeletons fit the syntax, the
fingerprint matches, and the 12 named functions are premises. It says nothing about
values, which the negative controls show.

### Negative controls

| Control | Expected | Shen | Rocq |
| --- | --- | --- | --- |
| Same certificate, statement renamed `fenrir-tc0-checked-add-can-return-2^63` (a false contract) | – | **accepted** | **accepted** |
| Model with the injected off-by-one I64 bound (`max-mag` = 2^63), certificate built the same way | – | **accepted** | **accepted** |
| Off-by-one model, original certificate | rejected | `stale-program` | `stale-program` |
| Fingerprint + 1 | rejected | `stale-program` | – |
| Theory hash changed | rejected | `stale-theory` | – |
| `r_call` replaced by `r_if` | rejected | `body-shape` | `body-shape` |
| One premise left undeclared | rejected | `undeclared-hypothesis` | – |
| `[prim "cons"]` replaced by `[prim "launch"]` | rejected | `unknown-primitive` | – |
| Measures removed (total mode) | rejected | `missing-measure` | – |
| Forged `accepted` label | rejected | `forged-label` | – |
| **Every host call discharged by `[prim "cons"]`, no premises declared** | – | **accepted, premises `[]`** | **accepted, premises `[]`** |
| **main = `(launch-missiles 1)`, a function defined nowhere, discharged by `[prim "cons"]`** | – | **accepted, statement `harmless`, premises `[]`** | **accepted, premises `[]`** |

Corruption of the certificate's identity or shape is rejected. A false contract
and the off-by-one model are accepted. That does not mean the checker validates a
false claim, because no certificate states any claim: the statement is a label.

**The last two rows are a defect in what an acceptance reports.** Neither checker
compares the contract leaf of a call with the function called. The `r_call` fit
ignores the callee (`shen/contract-cert.shen` line 121, `[call _ ...]`;
`ContractCert.v` line 150, `ECall _`). A call to any function, including one that
is not defined, can therefore be discharged by a primitive's proved contract. The
verdict then lists no premises for it. Búri's documentation says host operations
"remain a named premise", and the checker theorems (`check_hyps_declared` and the
others) are not contradicted, since they speak only of leaves. The exact input is
built by `fu.cons-leaf` and `fu.launch` in `certify.shen`, and both are in
`FenrirCert.v` (`mislabel_*`, `launch_*`). Under OB-CONTRACT-CERT-SEM such a
skeleton would not yield a derivation (`aj_ctx` needs `In c Gamma` with
`c_name c` equal to the callee), so this is a gap in the checker, not in the
calculus.

**Búri's Shen checker does not run on Shen/JIT.** On Shen/JIT 0.7,
`(buri.cc-theory)` raises `integer overflow`: the fingerprint computes `H * 257`
with `H` below 2^61−1. That is the 62-bit fixnum limit that made `i64.shen` use
digit lists. `check.sh` step 5 records it.

## 5 A separate result: two helper lemmas in Búri's calculus

`HelperLemmas.v` uses a different route from the one §3 describes: a derivation in
Búri's calculus, checked by Rocq, in the style of Búri's own worked example, rather
than a certificate checked by Búri's checker. It is reported separately and does not
change the status above. No term is written by hand. The bodies are
`extracted_digit` and `extracted_checked`, generated into `FenrirCert.v` from
`extracted.kl`. Each proof first pins the extracted body to the shape it expects,
by computation, so a change in the model or in the compiler breaks the proof.

- `digit_correct` (no premises). For every code *c* with 48 ≤ *c* ≤ 57, every
  profile, every policy covering its limits, and every store binding `-` and
  `string->n` to their primitives: the body of `tc0.i64.digit` with `V117` bound to
  the one-character string *c* terminates, raises nothing, leaves the store and the
  trace unchanged, and returns *c*−48 ∈ [0, 9].
- `checked_correct`, under two named premises: call contracts saying
  `tc0.i64.fits?` returns `fitsb x` and `tc0.i64.show` returns `showv x`, purely, on
  a domain *D*. Under these, the body of `tc0.i64.checked` returns exactly
  `[ok (showv V)]` if `fitsb V`, and `[trap overflow]` otherwise, with no exception
  and no effect. This is the outer shape of S1. It does not prove that `fitsb` is
  the I64 range test, that `showv` yields a canonical string, or that the argument
  is the exact sum.

Both are closed under the global context (`Print Assumptions`), checked by Coq
8.18.0 against Búri's compiled `ContractLogic`/`ContractPrims`. Three false variants
are rejected by Rocq: the range `0..8`, the domain `48..58` (the off-by-one), and
swapped branches. Together the two lemmas are 252 lines for two non-recursive,
`cond`-free functions. That is the first measurement of the cost the amendment calls
unknown.

## 6 A separate, weaker result: bounded exploration of `add`

`tools/tc0/check-i64.mjs` checks 1,089 `add` cases over 33 boundary values. It has
no carry or borrow chains across digit-length boundaries above 100 (10^k−1,
10^k for k ≥ 3). `bounded-add.mjs` adds ±(10^k−1),
±10^k and ±(10^k+1) for k = 1..18, and 228 fixed-seed values of every length from
1 to 19. That gives 351 values and all 123,201 ordered pairs, run on Shen/JIT and
compared with exact BigInt sums. Each `ok` string is also checked to be canonical.
Result: 120,939 ok and 2,262 overflow, no failures. Status: *bounded exploration
passed*, on these inputs only.

## 7 Status and trust chain

**The TC0-A property (S1, S2, S3): open.** Under the §9 vocabulary nothing here is
*model property proved*. The reason is the chain below: the certificate route breaks
at links 4 and 5, before any statement about values.

| # | Link | Standing |
| --- | --- | --- |
| 1 | `i64.shen` → KLambda, by Shen/JIT 0.7's kernel (`ps`) | Trusted. Shen/JIT then lowers this KLambda to bytecode, which is Búri's Phase 2 target (v0.6, 148 of 955 kernel definitions); v0.7 is not covered |
| 2 | KLambda → Búri program data (`extract.shen`) | Unverified Shen code that mirrors `KLSemantics.parse`. For the two lemmas, pinned by `*_body_is` |
| 3 | Program data → Rocq terms (`certify.shen` printer) | Unverified. Pinned by the same lemmas and by the fingerprint, which both checkers compute equally |
| 4 | Certificate → acceptance, Shen checker | Runs. That it computes `ContractCert.check` is Búri's open OB-CONTRACT-CERT-SHEN; agreement is sampled (Búri's 19 cases, these 10) |
| 5 | Acceptance → a derivation in the calculus | **Open in Búri (OB-CONTRACT-CERT-SEM)**, and the certificate has no assertions to derive. The chain stops here |
| 6 | Derivation → triple (`soundness`, `prim_spec_valid`) | Proved in Búri. Used directly by `HelperLemmas.v` |
| 7 | Triple about `KLSemantics.next` → behaviour of Shen/JIT | Búri's goal, unproved. Integer width differs (unbounded `Z` against 62-bit fixnums) |
| 8 | Host contracts (kernel functions, uncovered model functions) | Premises. For `checked_correct`, the `fits?` and `show` contracts are unproved premises |

## 8 What Búri would need (note for the owner)

The smallest set of changes that would let this property go through Búri's checker,
in order of necessity. These are notes only; no change was made to Búri.

1. **Rules for `cond`, `and` and `or`** (OB-CONTRACT-RULES-COVERAGE), proved sound,
   added to the skeleton grammar and to both checkers. Every multi-clause `define`
   compiles to them, and the final `(true (shen.f-error F))` clause needs a contract
   for `shen.f-error`. A proved `cond`→`if` desugaring would also do.
2. **Assertions in certificates** (OB-CONTRACT-CERT-SEM): a deep-embedded assertion
   language for per-function pre- and postconditions, and the theorem that an
   accepted certificate with discharged side conditions yields `deriv`. Without
   this, an acceptance states nothing about values.
3. **Function contracts as the statement**, not only a closed `main`: certificates
   for `body_ok_total` of each definition against `ctx_below`, with measures as
   terms (for `add-carry`, 2·max(|A|,|B|) + [A = []] + [B = []] decreases on every
   recursive call) and their decrease checked or emitted as obligations.
4. **A decision procedure or proof format for the side conditions** this property
   generates: digit-list arithmetic (value of a little-endian list, carry and
   borrow invariants, comparison with 2^63−1 and 2^63) and string facts (`explode`,
   code points 48–57).
5. **Callee matching in the fit check**: an `aj_ctx` leaf must name the called
   function (and have its arity), in `buri.cc-fits` and `ContractCert.fits`, with a
   checker theorem that every non-primitive, non-program callee appears among the
   premises. This is the defect in §4.
6. **Contracts for the kernel functions used** (`reverse`, `map`, `length`,
   `explode`, `shen.f-error`), either proved over their kernel KLambda or kept as
   named premises.
7. **A Shen checker that runs on Shen/JIT**: a fingerprint within 62-bit integers,
   or a declared host profile. And OB-CONTRACT-CERT-SHEN.
8. **A numeric profile matching Shen/JIT**, or a lemma that programs forming only
   small integers behave the same under both, so that link 7 can be crossed for
   this model.

Items 1, 2 and 5 are enough to make a certificate *mean* something for the ten
covered functions. Items 3 and 4 are what the actual arithmetic needs.

## Files

| File | Role |
| --- | --- |
| `extract.shen`, `extract-run.shen` | KLambda extraction and conversion (Shen/JIT) |
| `extracted.kl` | Committed extraction: raw KLambda (`fu-kl`) and program data (`fu-def`) for the three closures |
| `certify.shen` | Certificate synthesis, the 16 Shen-checker verdicts, generation of `FenrirCert.v` and `fragment.cert` (Búri's Shen-Scheme) |
| `fragment.cert` | The accepted fragment's program and certificate as data, with its verdict |
| `FenrirCert.v` | Generated: the certificates as Rocq terms, 10 verdict examples for `ContractCert.check`, the two extracted bodies |
| `HelperLemmas.v` | The separate result of §5 |
| `bounded-add.mjs` | The separate result of §6 |
| `check.sh` | Reruns all of it |
