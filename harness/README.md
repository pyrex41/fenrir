# Harness in Shen

The owner's direction (12 November 2026): the machinery around the Shen model
should itself be Shen, not Python or JavaScript. This directory is where it
moves to, piece by piece. Host: Shen/JIT 0.7, using its own JSON, buffer and
subprocess libraries.

## What runs today

```sh
sh harness/run-solo5-pure-call.sh          # Solo5 guest against the model, full scope, ~5 s
sh harness/run-solo5-pure-call.sh exact    # exact arithmetic: C guest against the model, ~4 s
sh harness/run-model-vs-candidate.sh       # JavaScript implementation against the model, ~11 s
```

[common.shen](common.shen) holds what the programs share: turning a program
(decoded JSON) into a model state as data, running the model, putting its
observations in JSON shape, and comparing JSON values regardless of key order.
Nothing is printed and re-read between the harness and the model: they are one
Shen process.

**[solo5-pure-call.shen](solo5-pure-call.shen)** runs the model on each program,
launches the Solo5 tender on the guest image, parses the guest's frames
strictly, compares every step, then reruns the guest with each injected defect
and requires that the comparison detects it.

| Batch | Programs | Steps | Result |
| --- | --- | --- | --- |
| Hand, generated and 5-node exhaustive | 5,774 | 86,286 | No difference; defects detected on 4,019 and 238 programs |
| Exact arithmetic (`exact`) | 8,745 | 78,639 | No difference; 975 Overflow, 33 DivZero; defects detected on 8,712 and 975 |

The exact-arithmetic batch is every binary I64 operation over a 33-value
boundary set squared, and negation over the set, each as a whole program. No
expected results are attached. The two sides are independent by construction:
the guest uses the C compiler's checked 64-bit arithmetic, the model uses
decimal digit lists. This replaces Python's exact integers as the independent
side of the arithmetic ledger, as the owner agreed.

**[model-vs-candidate.shen](model-vs-candidate.shen)** launches `node` on the
existing batch runner for the JavaScript implementation and its three mutants,
runs the model here, and compares. At the 5-node bound: 5,695 of 5,695 programs
agree (81,063 steps; 4,350 Ok, 595 DivZero, 517 Bounds, 233 Overflow), with
reverse-operands killed on 3,940, arm-by-position on 975 and wrap-overflow on
233, and no mutant crash. Those are the counts the Python checker
`tools/check-tc0-pure-data-exhaustive.py` reports for the same scope.

The same comparisons took about 100 s and 82 s through the Python route, most
of it printing Shen terms and parsing them back.

## What is still not Shen

| Piece | Now | Notes |
| --- | --- | --- |
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
| Second implementation | JavaScript (`runtime/tc0/`) and C (`backends/solo5/pure-call/`) | Stays non-Shen on purpose: it has to be independent of the model |
| Hand cases with their hand-derived expectations (staging, depth, emission order, descriptors) | Python (`tools/check-tc0-pure-call.py`) | Next to move |
| Python checkers now duplicated in Shen: exhaustive scope, exact arithmetic | Python (`check-tc0-pure-data-exhaustive.py`, `check-tc0-exact-arithmetic.py`) | Kept only because the registered gate calls them; they go when the gate moves |
| Reduction of failing programs, repair evaluation | Python and JavaScript | After the hand cases |
| Validator | JavaScript | Natural fit for Shen sequent rules; this is also Fenrir's type checker in the amendment |
| Generators, enumerator, reducer | JavaScript | Plain list processing |
| TC0-A gate and its receipts | Python, registered | Untouched. Replacing it is an authority change for the owner |
| Solo5 host tooling of the earlier Docker profile | Python and Go | Superseded in part by the stock-tender lane |

## Limits of what runs today

- Development evidence, `qualification: UNKNOWN`. It is not registered with
  the workflow controller.
- The model is the registered pure-call machine plus the proposed
  width-independent integer layer ([models/tc0/portable/](../models/tc0/portable/README.md)),
  because Shen/JIT integers are 62-bit. That layer is not the registered model.
- The harness and the model run in one Shen process. A bug in Shen/JIT itself
  could affect both; the guest is the independent side.
- Entry input is fixed at `["int","0"]`.
- Shen/JIT and its libraries are built from source by hand
  (`make deps && make && make process` at tag `v0.7`) and are not in the flake.
