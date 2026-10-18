# Attic

Superseded code kept out of the hot path. Nothing here is built, tested,
hashed by the TC0-A gate, or counted as evidence. Paths under `attic/tc0-legacy/`
mirror their original locations; imports inside them are not maintained.

- Arithmetic-only candidate and probe (superseded by the pure-call machine and
  `tools/check-tc0-exact-arithmetic.py`).
- Closure machine, its Shen model, validator, replay and tests (superseded by
  the pure-call machine; the alias case lives on in `fixtures/tc0/pure-call-hand-cases.mjs`).
- Expression-level generator, reducer, replay and reduction bridge (superseded
  by the `pure-call-*` tools).
- `DETERMINISTIC_LANGUAGE_SPECIFICATIONS.zip`, the historical v0.1 snapshot.

The expression machine, `tools/tc0/artifact.mjs` and `tools/check-tc0-expression.py`
stay in place: the native host and the pure-call checkers still use them.
