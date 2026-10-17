# TC0-A gate receipts

Copies of `gate.json` from runs of `tools/check-tc0-a-gate.py`, named
`gate-<head12>-<UTC time>.json`. Each binds its verdict to a commit (`head`) and
records a SHA-256 for every evidence file in the run directory
(`evidence_sha256`). The bulk evidence stays under the ignored `build/tc0/gate/`;
to check a receipt, re-run the gate at its `head` or compare the digests against a
retained run directory.

A receipt is development-grade, single-author differential agreement; see
[Limits of the TC0-A PASS](../../../README.md#limits-of-the-tc0-a-pass). It holds
only for its `head`. Receipts are committed after the run, so the commit that adds
one is never the commit it describes.
