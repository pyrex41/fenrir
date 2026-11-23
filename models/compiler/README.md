# Constructor reuse contract

Run the bounded comparison on the development host with Maude 3.5.1.

```sh
nix shell .#maude -c python3 models/compiler/check-constructor-reuse.py
```

The model consumes the first root, keeps the second root live, flips the selected Boolean and observes both the result and the surviving root. It searches three initial heap shapes up to address renaming. The roots may refer to the same parent, to distinct parents pointing at one child, or to disjoint parents and children. The checker enumerates all four assignments to the two initial child payloads. The one-argument start state defaults both to false for the interactive witness. The source observation follows immutable value semantics. The lowered observation reads from the updated heap.

The checked rule may overwrite a parent only when the other root refers to a different parent. It may overwrite the selected child only when that parent is exclusive and the surviving parent reaches a different child. The parent-only mutation omits the second condition. Its shortest failing path is `shared-child` followed by `lower`: the expected observation is `observed(true,false)`, and the mutated heap produces `observed(true,true)`. To inspect the path interactively, run the following commands in Maude.

```maude
load models/compiler/constructor-reuse.maude
search start(parentOnly) =>! result(Q,H,K,S:Observation,T:Observation) such that S:Observation =/= T:Observation .
show path labels 5 .
```

Use the state number printed by the search for the final command. The executable source witness is `shared-child.fen`. For input zero, Shen and both native backends should return the pair `true false`.

```sh
sh frontend/fenrir.sh run models/compiler/shared-child.fen
bin/fenrir run --target macos-arm64 models/compiler/shared-child.fen 0
bin/fenrir run --target solo5-arm64-spt models/compiler/shared-child.fen 0
```

The bounds cover one update, two roots, one selected child field per parent and one Boolean field per child. A compiler verifier must also account for other fields, captured references, static objects, roots across collecting calls and external callers.

Run `python3 models/compiler/check-chunk-reuse.py` to compare a chunk-local copy-on-write policy with immutable four-counter updates. The model explores two groups with two children each, three initial sharing patterns, and up to five updates or snapshot transitions. Each transition checks the current root and every retained snapshot. The first update copies the selected group and child separately as needed. Publishing and resuming a snapshot clears both sets of ownership bits. The checker also exercises mutations that infer child ownership from the parent or preserve ownership across publication.

To replay one of the twelve heap and payload combinations, run
`bin/fenrir run --target macos-arm64 models/compiler/ownership-shapes.fen 9`
or select `solo5-arm64-spt`. Inputs 0–3 share a parent, 4–7 share only the
child, and 8–11 use disjoint children. Within each group the two low bits
encode the first and second initial payloads respectively (first has weight
two). The result contains the flipped first value and the surviving parent's
value. For example, input 9 returns `(tuple true true)`.

To compare native receipts with Maude, build both images and record each
indexed input in a fresh directory. Run the final command with Maude on PATH.

```sh
out=$(mktemp -d)
for target in macos-arm64 solo5-arm64-spt; do
  bin/fenrir build --target "$target" models/compiler/ownership-shapes.fen -o "$out/$target" || exit 1
  for input in 0 1 2 3 4 5 6 7 8 9 10 11; do
    bin/fenrir record "$target" "$out/$target" "$input" "$out/$target-$input.json" || exit 1
  done
done
python3 models/compiler/check-constructor-reuse.py --receipts "$out"
```
