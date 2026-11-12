# Harness in Shen

The owner's direction (12 November 2026): the machinery around the Shen model
should itself be Shen, not Python or JavaScript. This directory is where it
moves to, piece by piece. Host: Shen/JIT 0.7, using its own JSON, buffer and
subprocess libraries.

## What runs today

```sh
sh harness/run-solo5-pure-call.sh        # full scope, about 5 s after the guest is built
sh harness/run-solo5-pure-call.sh 0      # hand and generated cases only
```

[solo5-pure-call.shen](solo5-pure-call.shen) is one Shen program that:

1. reads the batch of programs as JSON and turns each into a model state, as
   data (no text is printed and re-read);
2. runs the Shen model on each program **in the same process**;
3. launches the Solo5 tender on the guest image and captures its output;
4. parses the guest's frames strictly and compares every step with the model;
5. reruns the guest with each injected defect and requires that the comparison
   detects it;
6. prints a JSON report and exits 0 only on full agreement.

Recorded run: 5,774 programs, 86,286 steps, no difference; the reversed-operand
defect detected on 4,019 programs and wrapping overflow on 238. The same scope
took about 100 s through the earlier Python and JavaScript path, most of it
printing Shen terms and parsing them back.

It replaces, for this comparison: the Python trace wrapper, the Python
translation and normalization of Shen terms, and the JavaScript step
comparison against Shen.

## What is still not Shen

| Piece | Now | Notes |
| --- | --- | --- |
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
| Second implementation | JavaScript (`runtime/tc0/`) and C (`backends/solo5/pure-call/`) | Stays non-Shen on purpose: it has to be independent of the model |
| Model against the JavaScript implementation: hand cases, exhaustive scope | Python (`tools/check-tc0-pure-call.py`, `check-tc0-pure-data-exhaustive.py`) | Next to move: same shape as this harness with `node` as the launched process |
| Exact-arithmetic ledger | Python | Its expected results must come from something other than the model's own arithmetic; needs a decision on what that is in a Shen-only harness |
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
