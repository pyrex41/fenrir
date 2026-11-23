# Fenrir: development activity and code history

This is a snapshot of the Git history reachable from `master` at **`458dcff`**, dated November 23, 2026. It tracks when commits were recorded and when changes landed, not hours worked. A day without a commit can still include research, uncommitted work, or work on a branch outside this snapshot.

The repository starts with a substantial checkpoint on October 5: plans, Shen models, candidate implementations, and Solo5 experiments were already present. The history does not show when that earlier work was written.

## Activity over time

The first number counts **non-merge commits by author date**, including reachable branch commits. The second counts **first-parent commits by committer date**: the changes recorded directly along `master`, including merges. A squash commit can include earlier work whose individual commits are not reachable, so these are two views of the history, not two sets to add together. Dates use the dates recorded in Git.

| Date or interval | Non-merge commits authored | Changes landed on master | What the history records |
| --- | ---: | ---: | --- |
| Oct 5 | 3 | 3 | Initial checkpoint and host hardening. |
| Oct 6 | 2 | 2 | Host launch, receipts, and bridge bounds. |
| Oct 7 | 0 | 0 | No commits in this view. |
| Oct 8 | 1 | 1 | Pi handoff. |
| Oct 9 | 0 | 0 | No commits in this view. |
| Oct 10 | 2 | 2 | Unikernel direction and pure-call oracle. |
| Oct 11 | 18 | 1 | TC0-A data, generated cases, repair experiments, and a narrow qualification; merged in PR #3. |
| Oct 12–25 | 0 | 0 | No commits in this view. |
| Oct 26 | 0 | 1 | M0 checkpoint merged in PR #4. |
| Oct 27–30 | 0 | 0 | No commits in this view. |
| Oct 31 | 1 | 0 | AArch64 checked-arithmetic proof work on a branch. |
| Nov 1–11 | 0 | 0 | No commits in this view. |
| Nov 12 | 11 | 0 | Direction amendment, Solo5 work, and Shen harness work. |
| Nov 13 | 7 | 0 | Shen evaluator and model checks. |
| Nov 14 | 3 | 1 | TC1 effects and frontend landed in PR #9. |
| Nov 15 | 12 | 0 | Branch work on service models, tasks, durable effects, and evidence. |
| Nov 16 | 5 | 0 | Remote effects and service work on a branch. |
| Nov 17–18 | 0 | 0 | No commits in this view. |
| Nov 19 | 67 | 2 | ARM64 proof, Solo5, durable service, and integration work; PRs #10 and #11 merged. |
| Nov 20–22 | 0 | 0 | No commits in this view. |
| Nov 23 | 1 | 1 | Developer preview checkpoint: native ARM64 targets, applications, benchmarks, and documentation. |

The Nov 19 and Nov 23 totals are especially concentrated: integrations and checkpoints can contain work developed over multiple days. Similarly, the single Nov 14 squash represents more development than one ordinary commit. No conclusion about continuous work or daily effort follows from these counts.

## Code lines added when changes landed

Each bar is approximately **1,000 added lines** in code-like files in a first-parent diff. The exact figure is alongside it. Additions count changed lines, including rewritten, moved, imported, generated, and test code; they are **not unique lines authored**, net project growth, or a productivity measure. A line changed twice may count twice. The initial checkpoint includes work predating the repository. Binary files are excluded.

```text
Date        Code lines added   Chart (█ ≈ 1,000 lines)
2026-10-05          12,915   █████████████
2026-10-06             764   █
2026-10-08               0
2026-10-10             458   ▌
2026-10-11           2,236   ██
2026-10-26               4   ·
2026-11-14           8,833   █████████
2026-11-19          43,172   ███████████████████████████████████████████
2026-11-23          16,931   █████████████████
```

The code filter includes Fenrir, Shen, KLambda, JavaScript/TypeScript, C/C++, Rust, Go, Python, shell, Erlang/Elixir, Rocq, Koka, Nim, and SQL file extensions. It includes code in tests, examples, and benchmarks; it excludes Markdown, JSON, configuration, and files without one of those extensions. This is a simple file-extension approximation, not a parser-based source census. On the same first-parent basis, all text files together show **124,217 additions and 4,064 deletions**; these totals include documentation and other non-code text.

## How to reproduce

Run from the repository root. Pin the same snapshot to avoid changing the result as the repository grows:

```sh
git log 458dcff --no-merges --format='%as' | sort | uniq -c
git log 458dcff --first-parent --format='%cs %h %s' --reverse
```

For each first-parent commit, `git diff-tree --root --first-parent -m --no-commit-id --numstat -r <commit>` produces additions and deletions relative to its first parent; the root commit is compared with an empty tree. Sum numeric additions for the extensions listed above to reproduce the code chart. Merge diffs are counted once when they land; binary numstat entries (`-`) are excluded.

For the architectural and evidence history behind these numbers, see [DEVELOPMENT_HISTORY.md](DEVELOPMENT_HISTORY.md) and [04_DIRECTION_AMENDMENT.md](../design/04_DIRECTION_AMENDMENT.md).
