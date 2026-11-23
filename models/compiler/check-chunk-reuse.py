"""Bounded comparison of chunk-local parent and child reuse with persistent updates."""
from collections import deque
from dataclasses import dataclass
import json


@dataclass(frozen=True)
class State:
    # The two groups each contain two child addresses. Snapshots retain the
    # whole root and the independent four-counter value expected at publication.
    root: tuple
    parents: tuple
    children: tuple
    expected: tuple
    saved: tuple = ()
    owned_groups: int = 0
    owned_keys: int = 0


def observe(state, root):
    return tuple(state.children[c] for p in root for c in state.parents[p])


def update(state, key, policy):
    group, field = divmod(key, 2)
    root, parents, children = list(state.root), list(state.parents), list(state.children)
    parent = root[group]
    if not state.owned_groups & (1 << group):
        root[group] = len(parents)
        parents.append(parents[parent])
        parent = root[group]
    fields = list(parents[parent])
    child = fields[field]
    can_reuse = state.owned_keys & (1 << key)
    if policy == 'parent-only':
        can_reuse = state.owned_groups & (1 << group)
    if not can_reuse:
        fields[field] = len(children)
        children.append(children[child])
        child = fields[field]
    children[child] += 1
    parents[parent] = tuple(fields)
    expected = list(state.expected)
    expected[key] += 1
    return State(tuple(root), tuple(parents), tuple(children), tuple(expected), state.saved,
                 state.owned_groups | (1 << group), state.owned_keys | (1 << key))


def transitions(s, policy):
    for key in range(4):
        yield f'update {key}', update(s, key, policy)
    # A client can keep the input to a feed and start another feed from any
    # published decoder. Ownership bits belong to one invocation only.
    saved = s.saved + ((s.root, s.expected),)
    for i, (root, expected) in enumerate(saved):
        keep = policy == 'keep-bits'
        yield f'publish and resume {i}', State(root, s.parents, s.children, expected, saved,
                                                s.owned_groups if keep else 0,
                                                s.owned_keys if keep else 0)


def explore(policy, depth):
    queue = deque()
    for name, parents, root in [('shared-parent', ((0, 0),), (0, 0)),
                                ('shared-child', ((0, 1), (0, 1)), (0, 1)),
                                ('disjoint', ((0, 1), (2, 3)), (0, 1))]:
        queue.append((State(root, parents, (0, 0, 0, 0), (0, 0, 0, 0)), (name,)))
    seen = set()
    while queue:
        state, trace = queue.popleft()
        if state in seen:
            continue
        seen.add(state)
        for index, (root, expected) in enumerate(((state.root, state.expected), *state.saved)):
            actual = observe(state, root)
            if actual != expected:
                return dict(states=len(seen), trace=trace,
                            observation="current" if index == 0 else f"snapshot {index - 1}",
                            expected=expected, actual=actual)
        if len(trace) <= depth:
            for action, successor in transitions(state, policy):
                queue.append((successor, trace + (action,)))
    return dict(states=len(seen), trace=None)


if __name__ == '__main__':
    results = {policy: explore(policy, 5) for policy in ('checked', 'parent-only', 'keep-bits')}
    print(json.dumps(results, indent=2))
    if results['checked']['trace'] or any(not results[p]['trace'] for p in ('parent-only', 'keep-bits')):
        raise SystemExit(1)
