# Classical propositional search, profile 1

Each ASCII corpus row gives a unique name, expected outcome, node budget and
one prefix formula. Atoms are a through z. Tokens !, &, | and > denote
negation, conjunction, disjunction and implication. Search attempts to refute
the false goal by expanding signed formulas. Each visited state costs one
node, including closed and open leaves. On entry with zero remaining budget
return exhausted. Process pending formulas first-in first-out. Append children
in operand order. Keep signed atoms as bit sets. Close a branch when processing
an atom with the opposite sign already present. An empty queue yields a model
with exactly the positive atoms set. No memoization or simplification.

For negation flip the sign. True conjunction and false disjunction append
both operands with the parent sign. False implication appends true antecedent
then false consequent. The remaining binary cases branch, exploring the first
operand before the second, flipping the antecedent sign for true implication.
Both branches must close for a proof. Stop at the first countermodel or budget
exhaustion. Budgets are shared across branches.

Output name, outcome, visited nodes and witness separated by whitespace.
Proof witnesses are preorder trees: x closes, s takes a single successor
(including recording a consistent atom), b has two children. A countermodel
witness is a decimal bit mask (a is bit 0). Exhaustion uses a dash.

The Fenrir reference implements the search in `search.fen`.
`python3 benchmarks/prover/run-fenrir.py macos-arm64` builds one executable
containing the corpus formulas and runs each case by index. Use
`solo5-arm64-spt` for the guest. The driver converts the resulting Fenrir
values into profile rows and invokes the independent checker. These runs
include executable launch and witness formatting; they establish correctness
and work counts. Separate persistent search and certificate-check timings
are required for the performance scorecard.

To run your own formula, pass it in space-separated prefix notation. The
driver embeds the formula in Fenrir source, builds it for the selected
target and runs the native image. Search reports the outcome, visited nodes
and proof tape or countermodel. Certificate mode returns exit status 0 for
a valid tape and 1 for an invalid tape. Both modes check the answer against
an independent traversal. For example, the first command returns
`goal proof 3 ssx` and the second returns `valid`.

```sh
python3 benchmarks/prover/run-fenrir.py macos-arm64 --formula '> z z' --budget 3
python3 benchmarks/prover/run-fenrir.py solo5-arm64-spt --formula '> z z' --certificate ssx
```

Run `python3 benchmarks/prover/check-certificates.py TARGET` for the independent
Fenrir checker executable. It consumes the six frozen Rust-generated proof
witnesses and rejects a truncated, extended, and invalid-rule version of each.
It shares the formula and queue representation with search. Its verification
procedure consumes the supplied preorder rules and checks full consumption.

On macOS ARM64, run `python3 benchmarks/prover/measure-fenrir.py NEW_OUTPUT_DIR`
for twenty paired measurements of Fenrir, Rust, Nim, Koka, and Shen/JIT on
each of search and certificate checking. Before timing, the runner independently
validates the rows emitted by Rust, Nim, Koka and Shen/JIT. It retains the
four outputs and preflight log in `reference-checks/` and records their
digests and the verifier digest in the report. All five search implementations
construct corpus formulas from literals and verify outcomes inside the repeated
loop. The checkers consume the same six proof tapes. Their correctness tests
also reject truncated, extended and invalid-rule tapes. Nim uses release mode,
ORC memory management and checked arithmetic. Each sample runs 5,000 corpus
rounds in one process. The runner rotates the ten commands through all positions
and reverses the direction for the second rotation. The report retains startup
and warmup samples, source and binary digests, per-pair timings, work rates,
and paired bootstrap intervals against each reference. Each reference constructs its immutable input formulas once per process.
Each round starts fresh search state and checks the complete expected result.
The fastest measured reference is selected independently for each kernel. The report compares
peak memory with that same reference. Shen/JIT loads its script at each
launch. Its zero-round sample includes that cost, and its measured wall time
includes launch and JIT activity as well as the kernel.

Run `sh benchmarks/prover/check-references.sh` to build Rust, Nim, Koka
and Shen/JIT references, independently check their ten rows, and compare
the rows byte for byte. Supply Koka 3.2.3 on PATH or set `KOKA` to its
absolute executable path. The Koka driver embeds corpus formulas before
compilation and runs proof search in the resulting native executable.

On Apple Silicon, run `python3 benchmarks/prover/measure-spt.py NEW_OUTPUT_DIR`
to build the search and certificate-checking kernels as Fenrir and optimized
C guests. The C reference embeds the frozen formula trees as prefix-indexed
arrays and uses a bounded work queue. Fenrir constructs the corresponding
algebraic values from source literals. Both traverse the same signed formulas
in the same order. Search checks the status, fuel consumed, and complete
proof or model. The checking lane consumes each frozen proof in full.

Each guest uses the same launcher and monotonic clock around 5,000 corpus
rounds, including result validation. VM startup and console output fall
outside that interval. The runner checks the count from every guest, sets
aside one warm-up pair and retains twelve pairs in alternating order. The
report includes raw guest output, source and image hashes, and paired
bootstrap intervals. The Mac runner also records peak RSS separately for
each of its ten commands over twenty rounds of measurement.


Fenrir search counts consecutive unary rules in a tail call. A successful
branch writes that many `s` bytes before its certificate, while a failing
branch returns the model or exhaustion directly. Run
`python3 benchmarks/prover/check-prefixes.py TARGET` to check certificates
that cross the eight-step batching and 56-byte inline storage boundaries.
Each generated proof runs with exactly the fuel it requires and with one
fewer step. The independent FIFO tableau supplies the expected bytes for both
unary chains and branching certificates up to 401 rules long. The frozen benchmark corpus and search order remain the same.

Solo5 timed pairs also record Linux maximum resident set size from
`/usr/bin/time -f %M` around each tender invocation, converted from KiB to
bytes. This process measurement includes tender overhead. The elapsed timer
still surrounds the repeated kernel inside the guest. Guest heap occupancy
and the Linux VM's total memory have different measurement boundaries.

Run `python3 benchmarks/prover/check-rule-substitutions.py TARGET` to test
certificate rejection at every rule position in the six frozen proofs and
the 273-rule branching witness. Each valid tape is checked against the
independent Python tableau. The native program substitutes each of the two
other legal rules at every position and checks every strict prefix. It also
tries the valid tapes against the corpus formulas with verified countermodels.

Run `python3 benchmarks/prover/measure-representation.py NEW_OUTPUT_DIR` on the Mac to compare three Solo5 ARM64 guests. The persistent C control uses 80-byte slots for interned formula nodes and queue entries, promotes the rear when the front empties, and shares that front across branches. Appending with an occupied front copies the rear spine in pairs. A diagnostic build counts allocations separately from the timed version. C retains its bounded proof buffer, bitset operations and resettable queue arena. Results include raw output, rotated paired samples and tender RSS. Compact C remains the release reference.

### Queue-width diagnostic

`queue-width-v1.txt` pairs balanced disjunctions with right-leaning disjunctions containing the same number of identical atom leaves, from 2 to 64. At each size both searches return countermodel 0 after twice as many tableau steps as leaves. The 64-leaf balanced case copies 1,240 queue cells in the persistent C control. Its right-leaning counterpart copies zero. This supplemental corpus is separate from the fixed alpha scorecard.

The companion `queue-width-branches-v1.txt` checks branch sharing after the frontier widens. It uses a 36-step countermodel and a 160-step proof at three fuel budgets each: one step short, exactly sufficient, and one step spare. The verifier checks the complete FIFO proof tape or the first countermodel.

Run the checked Rust reference and independent Python verifier from the checkout root:

```sh
work=$(mktemp -d)
rustc -O -C overflow-checks=yes benchmarks/prover/reference.rs -o "$work/prover"
for corpus in benchmarks/prover/queue-width-v1.txt benchmarks/prover/queue-width-branches-v1.txt; do
  "$work/prover" "$corpus" > "$work/width.rows"
  python3 benchmarks/prover/verify.py "$corpus" < "$work/width.rows" || exit 1
  python3 benchmarks/prover/count-queue.py "$corpus" < "$work/width.rows" || exit 1
done
```

The host-only counter also reports the largest pending rear at a nonbranching binary expansion with an empty remaining front, where the hybrid search can switch representations. In the fixed corpus this width peaks at two, below the candidate threshold of four. The eight-leaf balanced case reaches four exactly, every spine stays at zero, and both branching families reach eight across all three fuel budgets. These widths describe the original FIFO traversal up to each decision site.

Supply `--corpus PATH` to the native prover driver to build all listed search
cases into a single target image. Each row has a name, expected outcome
(`proof`, `model` or `exhausted`), fuel budget and space-separated prefix
formula. For example, run
`python3 benchmarks/prover/run-fenrir.py macos-arm64 --corpus benchmarks/prover/queue-width-branches-v1.txt`.
The driver starts the built image once per case and independently verifies
every row before printing the batch. Omitting the option uses the fixed corpus.
