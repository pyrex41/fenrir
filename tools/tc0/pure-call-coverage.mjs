// Mechanical catalog coverage for the pure-call demo, UNQUALIFIED development measure.
// Maps each observed step to a catalog transition key using only the artifact and the
// step record, then compares the covered set with the transitions the catalog
// (spec/tc0/pure-call-demo.json) defines for schema /2. A key is covered only by
// traces supplied by the caller; this module does not decide which traces are evidence.
const PRIMS = [
  'add',
  'sub',
  'mul',
  'div',
  'neg',
  'lt',
  'le',
  'gt',
  'ge',
  'not',
  'bytes_length',
  'bytes_index',
  'bytes_concat',
  'eq'
];
const TRAPS = {
  add: ['Overflow'],
  sub: ['Overflow'],
  mul: ['Overflow'],
  neg: ['Overflow'],
  div: ['DivZero', 'Overflow'],
  bytes_index: ['Bounds']
};
const LEAVES = ['unit', 'bool', 'int', 'bytes', 'var', 'lambda'];
const COLLECTING = [
  ...PRIMS.map(p => 'prim.' + p),
  'tuple',
  'project',
  'construct',
  'apply',
  'call',
  'emit'
];
const arity = op => ({ neg: 1, not: 1, bytes_length: 1 })[op] ?? 2;
// Every transition key the catalog defines for this demo, with the rule it comes from.
export function catalogKeys() {
  const keys = new Map(),
    add = (k, rule) => keys.set(k, rule);
  for (const t of LEAVES) add(`Dispatch ${t} -> Value`, 'dispatch_rules: produce Value only');
  for (const t of ['let', 'if', 'match'])
    add(`Dispatch ${t} -> Eval`, 'dispatch_rules: push frame, enter first expression non-tail');
  for (const t of COLLECTING)
    add(`Dispatch ${t} -> Eval`, 'dispatch_rules: collect operands left-to-right');
  add('Dispatch construct -> Ready', 'dispatch_rules: a nullary construct enters Ready directly');
  for (const t of COLLECTING) {
    const n = t.startsWith('prim.')
      ? arity(t.slice(5))
      : t === 'tuple'
        ? 2
        : t === 'construct'
          ? 2
          : t === 'apply'
            ? 2
            : 1;
    add(`CollectReturn ${t} -> Ready`, 'frames.Collect: Ready after the last value');
    if (n > 1) add(`CollectReturn ${t} -> Eval`, 'frames.Collect: enter the next operand');
  }
  for (const p of PRIMS) add(`Ready prim.${p} -> Value`, 'ready_rules: exact primitive Value');
  for (const [p, codes] of Object.entries(TRAPS))
    for (const c of codes) add(`Ready prim.${p} -> Unwind ${c}`, 'ready_rules: trap routing');
  for (const t of ['tuple', 'construct', 'project'])
    add(`Ready ${t} -> Value`, 'ready_rules: build or select a value');
  add('Ready emit -> Value [Invoke,Emit,Commit]', 'ready_rules: emit event sequence');
  for (const t of ['call', 'apply'])
    for (const k of ['tail', 'non-tail'])
      add(`Ready ${t} -> Eval ${k}`, 'ready_rules: enter body; Return frame only when non-tail');
  add('LetReturn -> Eval', 'frames.Let');
  add('IfReturn -> Eval then', 'frames.If: selected branch');
  add('IfReturn -> Eval else', 'frames.If: selected branch');
  add('MatchReturn -> Eval', 'frames.Match: selected arm');
  add('ReturnReturn -> Value', 'frames.Return');
  for (const f of ['let', 'if', 'match', 'collect', 'return'])
    add(`UnwindFrame ${f}`, 'root_rules: Unwind discards one frame per step');
  for (const p of ['function body', 'let body', 'if branch', 'match arm'])
    add(`Tail call in ${p}`, 'tail_positions');
  add('Tail call in lambda body', 'tail_positions');
  add('RootJoinEntry Value -> Join', 'root_rules');
  add('RootJoinEntry Unwind -> Join', 'root_rules');
  add('Join -> Terminate [ScopeExit]', 'root_rules');
  add('Terminate -> Terminal [TaskTermination]', 'root_rules');
  return keys;
}
// Keys exercised by one run (steps as produced by PureCallMachine.run or the model).
export function coveredKeys(program, steps) {
  const nodes = new Map(),
    parents = new Map(),
    bodies = new Map();
  const walk = (e, parent) => {
    if (!Array.isArray(e) || typeof e[1] !== 'string') return;
    nodes.set(e[1], e);
    if (parent) parents.set(e[1], parent);
    const kids =
      e[0] === 'let'
        ? [e[3], e[4]]
        : e[0] === 'lambda'
          ? [e[7]]
          : e[0] === 'if' || e[0] === 'apply' || e[0] === 'tuple'
            ? e.slice(2)
            : e[0] === 'prim'
              ? e.slice(3)
              : e[0] === 'call' || e[0] === 'emit'
                ? [e[3]]
                : e[0] === 'project'
                  ? [e[2]]
                  : e[0] === 'construct'
                    ? e.slice(4)
                    : e[0] === 'match'
                      ? [e[2], ...e.slice(3).map(a => a[2])]
                      : [];
    for (const k of kids) walk(k, e);
  };
  for (const f of program.functions) {
    walk(f.body, null);
    bodies.set(f.body[1], 'function body');
  }
  const tag = e => (e[0] === 'prim' ? 'prim.' + e[2] : e[0]);
  // Tail context of a node: why its position is tail, or null.
  const context = id => {
    const e = nodes.get(id),
      p = parents.get(id);
    if (!p) return bodies.get(id) ?? null;
    if (p[0] === 'let' && p[4] === e) return context(p[1]) ? 'let body' : null;
    if (p[0] === 'if' && p[2] !== e) return context(p[1]) ? 'if branch' : null;
    if (p[0] === 'match' && p[2] !== e) return context(p[1]) ? 'match arm' : null;
    if (p[0] === 'lambda') return 'lambda body';
    return null;
  };
  const keys = new Set(),
    outcome = steps.at(-1)?.events?.[0]?.outcome,
    stack = [];
  // Frames are simulated from the step records alone and checked against each step's depth.
  steps.forEach((s, i) => {
    const e = s.site.node !== undefined ? nodes.get(s.site.node) : null,
      prev = steps[i - 1];
    switch (s.site.rule) {
      case 'Dispatch':
        keys.add(`Dispatch ${tag(e)} -> ${s.after}`);
        if (['let', 'if', 'match'].includes(e[0])) stack.push(e[0]);
        else if (s.after === 'Eval') stack.push('collect');
        break;
      case 'CollectReturn':
        keys.add(`CollectReturn ${tag(e)} -> ${s.after}`);
        if (s.after === 'Ready') stack.pop();
        break;
      case 'Ready':
        if (e[0] === 'call' || e[0] === 'apply') {
          const tail = Number(s.depth) === stack.length;
          if (!tail) stack.push('return');
          keys.add(`Ready ${e[0]} -> Eval ${tail ? 'tail' : 'non-tail'}`);
          if (tail) {
            const c = context(e[1]);
            if (c) keys.add(`Tail call in ${c}`);
          }
        } else if (e[0] === 'emit')
          keys.add(`Ready emit -> ${s.after} [${s.events.map(v => v.kind).join(',')}]`);
        else
          keys.add(`Ready ${tag(e)} -> ${s.after}${s.after === 'Unwind' ? ' ' + outcome[1] : ''}`);
        break;
      case 'LetReturn':
        keys.add(`LetReturn -> ${s.after}`);
        stack.pop();
        break;
      case 'IfReturn': {
        const next = steps[i + 1]?.site.node;
        keys.add(`IfReturn -> ${s.after} ${next === e[3][1] ? 'then' : 'else'}`);
        stack.pop();
        break;
      }
      case 'MatchReturn':
        keys.add(`MatchReturn -> ${s.after}`);
        stack.pop();
        break;
      case 'ReturnReturn':
        keys.add(`ReturnReturn -> ${s.after}`);
        stack.pop();
        break;
      case 'UnwindFrame':
        keys.add(`UnwindFrame ${stack.pop()}`);
        break;
      case 'Value':
        keys.add(`RootJoinEntry Value -> ${s.after}`);
        break;
      case 'Unwind':
        keys.add(`RootJoinEntry Unwind -> ${s.after}`);
        break;
      case 'Join':
        keys.add(`Join -> ${s.after} [${s.events.map(v => v.kind).join(',')}]`);
        break;
      case 'Terminate':
        keys.add(`Terminate -> ${s.after} [${s.events.map(v => v.kind).join(',')}]`);
        break;
    }
    if (stack.length !== Number(s.depth))
      throw new Error(`Frame simulation lost sync at epoch ${s.epoch}`);
  });
  return keys;
}
export function coverage(rows) {
  const catalog = catalogKeys(),
    covered = new Map();
  for (const { name, program, steps } of rows)
    for (const k of coveredKeys(program, steps)) if (!covered.has(k)) covered.set(k, name);
  const unknown = [...covered.keys()].filter(k => !catalog.has(k)).sort();
  const missing = [...catalog.keys()].filter(k => !covered.has(k)).sort();
  return {
    catalog_keys: String(catalog.size),
    covered: String(catalog.size - missing.length),
    missing,
    unknown_observed: unknown,
    first_witness: Object.fromEntries([...covered].filter(([k]) => catalog.has(k)).sort())
  };
}
