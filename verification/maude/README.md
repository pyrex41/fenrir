# Accepted-job differential check

Run `sh verification/maude/run-accepted-job-retry.sh` from the checkout. The
driver uses local Shen/JIT under build/toolchain or FENRIR_SHEN_JIT, and Maude
from PATH, MAUDE, or the flake. Logs and difference files go under build/.

The bounds are one tenant, one key, one digest, two submissions, two worker
deliveries, two client responses, and one crash. A terminal history is a
maximal enabled schedule within those budgets. Crashing after the last
submission can end a schedule with unused response budget. A crash clears the
outbox. Issuing an acknowledgement leaves its receipt eligible for redelivery.

The Shen driver uses Gleipnir's label, step, budget and observation functions.
It retains each path. Maude independently rewrites bounded states and searches
to normal forms. The comparison checks the entire ordered schedule, durable
records and job statuses, current key receipt, outbox membership and ordered
response trace. In this slice report and job IDs coincide; the Maude decoder
reconstructs the report and receipt fields from that invariant. This check
cannot independently detect a bug in that reconstruction assumption.

Both models yielded 2,928 terminal schedules for the contract and 8,460 for
the retry mutation. Every paired observation matched. Comparing correct Shen
against faulty Maude yielded 9,028 differences. Of those schedules, 2,360
were maximal in both models and produced different observations. Another 568
were maximal only in correct Gleipnir and 6,100 only in faulty Maude. A fresh
enumeration reproduced the [complete witness file](retry-all-differences.tar.gz)
byte for byte.
The three-step witness submits, crashes before acknowledgement, and resubmits.
Maude reaches two pending jobs. Gleipnir first flags retry.replay at step 3.

Under a shell with Maude available, run the mutation control and replay one
difference as follows. Each invocation exits 1 when it finds a difference.
A null observation means the schedule was absent on that side.

```sh
python3 verification/maude/compare.py build/maude-control --mutation-control
head -1 build/maude-control/model.differences.jsonl > build/maude-control/example.json
python3 verification/maude/compare.py build/maude-replay --replay build/maude-control/example.json
```

The compiler-side experiment and its heap bounds are in
[the constructor reuse model](../../models/compiler/README.md).
