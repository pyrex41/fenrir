# S3 candidate-only repair task

Goal: repair the independent TC0-A pure-call candidate so that it conforms to the
Shen model for schema `tc0-a-pure-call-demo/2`.

- Start revision: `{{start_revision}}` (exported without history).
- Allowed change: `{{candidate}}` only. Every other file in this workspace is a
  protected input, including the Shen model (`models/tc0/`), the catalog
  (`spec/tc0/`), fixtures, tools and tests. The evaluator rejects any change to them.
- You may add scratch files under `build/`; they are ignored.

## Failure

`s3/failure-bundle.json` holds two retained failures: a generated program and its
reduced form. For each it gives the Shen-observed reference trace (`model_steps`)
and the first epoch where the current candidate's trace differs from the model's.
The candidate's step records are `{epoch, site, after, depth, events}`, as produced
by `PureCallMachine.run`.

Read `02_TINY_LANGUAGE_CORE.md` §3–4 and `spec/tc0/pure-call-demo.json` for the
intended semantics. Do not change the model, the expected traces or the catalog. A
disagreement you believe is a model or specification defect is reported as a
separate proposal, never fixed by editing those inputs.

## Checks you can run

```sh
node tools/tc0/run-pure-call.mjs PROGRAM.json          # candidate on one artifact
node --test tests/tc0/*.test.mjs                        # regression suite
# With a Shen executable (shen-scheme with lib/shen-scheme/shen.boot):
python3 -I tools/check-tc0-pure-call.py --shen-executable SHEN --output build/hand.json
python3 -I tools/check-tc0-pure-data-exhaustive.py --shen-executable SHEN --max-nodes 4 --output build/small4.json
```

The evaluator also uses held-out evaluation inputs that are frozen before this
task is handed out.

## Completion

Report the patch, a short explanation of the defect and the fix, the checks you
ran with their results, and remaining limitations. Never report a timeout,
skipped check or truncated run as passing.
