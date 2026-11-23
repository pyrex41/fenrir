"""Generate a legal match whose branch-local roots exceed one frame if summed."""
from pathlib import Path
import sys
arms = 16
tags = [f'Case{i}' for i in range(arms)]
choose = tags[-1]
for i in reversed(range(arms - 1)):
    choose = f'(if (= n {i}) {tags[i]} {choose})'
branches = []
for i, tag in enumerate(tags):
    tree = '(Leaf n)'
    for _ in range(28 + i):
        tree = f'(Wrap {tree})'
    branches.append(f'({tag} -> {tree})')
Path(sys.argv[1]).write_text(f"""
(datatype Choice {' '.join(tags)})
(datatype Tree (Leaf I64) (Wrap Tree))
(define choose {{I64 --> Choice}} n -> {choose})
(define make-tree {{(Tuple Choice I64) --> Tree}}
  tag n -> (match tag {' '.join(branches)}))
(define depth {{(Tuple Tree I64) --> I64}}
  tree acc -> (match tree ((Leaf n) -> (+ n acc)) ((Wrap inner) -> (depth inner (+ acc 1)))))
(define main {{I64 --> I64}} n -> (depth (make-tree (choose n) n) 0))
""")
