// Programs of profile fenrir-aarch64-checked-expr/1 as existing-format
// TC0-A pure-call artifacts (schema /2, which admits eq). A tiny surface:
//   'x' | n (bigint) | true | false | [op, a, b?] | ['let', name, init, body] | ['if', c, t, f]
// Variable names are resolved to binding IDs here; the artifact is what the
// compiler, the JavaScript candidate and the Shen model all consume.
export function artifact(surface, resultType = 'I64', module = 'arm-expr') {
  let id = 2; const locations = ['0'];
  const fresh = (loc = true) => { const s = String(id++); if (loc) locations.push(s); return s; };
  function build(t, scope) {
    if (typeof t === 'bigint') return ['int', fresh(), String(t)];
    if (typeof t === 'boolean') return ['bool', fresh(), t];
    if (typeof t === 'string') { if (!(t in scope)) throw new Error(`unbound ${t}`); return ['var', fresh(), scope[t]]; }
    const [op, ...args] = t;
    if (op === 'let') {
      const node = fresh(), binder = fresh(false), init = build(args[1], scope);
      return ['let', node, binder, init, build(args[2], {...scope, [args[0]]: binder})];
    }
    if (op === 'if') { const node = fresh(); return ['if', node, ...args.map(a => build(a, scope))]; }
    const node = fresh();
    return ['prim', node, op, ...args.map(a => build(a, scope))];
  }
  const body = build(surface, {x: '1'});
  return {contract_version: '0.2', schema_version: 'tc0-a-pure-call-demo/2', slice: 'TC0-A', module, datatypes: [], effects: [],
    functions: [{id: '0', name: 'main', parameter_id: '1', argument_type: 'I64', result_type: resultType, effects: [], body}],
    entry: 'main', input_schema: {type: 'I64'},
    source_map: locations.map(i => ({id: i, file: module, line: '0', column: '0'}))};
}

const MIN = -(1n << 63n), MAX = (1n << 63n) - 1n;
// Hand cases: every construct, every trap, intermediate and branch-local traps.
export const HAND = [
  ['add-sub-intermediate', ['sub', ['add', 'x', 1n], 1n]],
  ['sub-add-intermediate', ['add', ['sub', 'x', 1n], 1n]],
  ['mul-square', ['mul', 'x', 'x']],
  ['mul-by-three-then-div', ['div', ['mul', 'x', 3n], 3n]],
  ['div-by-x', ['div', 7n, 'x']],
  ['div-by-minus-one', ['div', 'x', -1n]],
  ['min-div-x', ['div', MIN, 'x']],
  ['neg', ['neg', 'x']],
  ['abs', ['if', ['lt', 'x', 0n], ['neg', 'x'], 'x']],
  ['let-chain', ['let', 'y', ['add', 'x', 1n], ['let', 'z', ['mul', 'y', 'y'], ['sub', 'z', 'x']]]],
  ['let-shadow', ['let', 'x', ['add', 'x', 1n], ['let', 'x', ['mul', 'x', 2n], 'x']]],
  ['nested-operands', ['sub', ['mul', ['add', 'x', 1n], ['add', 'x', 2n]], ['mul', ['add', 'x', 3n], ['add', 'x', 4n]]]],
  ['guarded-div', ['if', ['eq', 'x', 0n], 0n, ['div', 100n, 'x']]],
  ['branch-local-trap', ['if', ['gt', 'x', 0n], ['add', 'x', MAX], ['sub', 'x', MAX]]],
  ['big-literals', ['add', ['sub', 'x', MIN], MIN]],
  ['max-plus-x', ['add', MAX, 'x']],
  ['div-chain', ['div', ['div', 'x', 2n], ['sub', 'x', 'x']]],
  ['mixed-let-if', ['let', 'a', ['div', 'x', 3n], ['if', ['eq', 'a', 0n], 100n, ['if', ['lt', 'a', 0n], ['mul', 'a', 'a'], ['sub', 'a', 1n]]]]],
  ['cmp-le', ['le', 'x', 5n], 'Bool'],
  ['cmp-ge-self', ['ge', 'x', 'x'], 'Bool'],
  ['cmp-gt', ['gt', 'x', -3n], 'Bool'],
  ['eq-literal', ['eq', 'x', 7n], 'Bool'],
  ['not-eq-zero', ['not', ['eq', 'x', 0n]], 'Bool'],
  ['eq-bools', ['eq', ['lt', 'x', 0n], ['gt', 'x', 0n]], 'Bool'],
  ['bool-if', ['if', ['gt', 'x', 0n], true, false], 'Bool'],
  ['cmp-traps-first', ['lt', ['add', 'x', 1n], 0n], 'Bool'],
  ['let-bool', ['let', 'p', ['le', 'x', 0n], ['if', 'p', ['neg', 'x'], ['sub', 'x', 1n]]]],
  ['deep-left', ['add', ['add', ['add', ['add', ['add', 'x', 1n], 2n], 3n], 4n], 5n]],
  ['deep-right', ['add', 1n, ['add', 2n, ['add', 3n, ['add', 4n, ['add', 5n, 'x']]]]]],
  ['eval-order', ['add', ['div', 1n, 'x'], ['mul', 'x', 'x']]],
];

// Deterministic generated programs over the profile grammar (typed).
export function generated(count = 40, seed = 0x5eed1234n) {
  let s = seed;
  const next = () => { s = BigInt.asUintN(64, s * 6364136223846793005n + 1442695040888963407n); return Number(s >> 33n); };
  const pick = a => a[next() % a.length];
  const lits = [0n, 1n, -1n, 2n, 3n, 7n, 100n, MAX, MIN, MAX - 1n, MIN + 1n, 4294967296n, 3037000500n];
  function int(depth, vars) {
    const r = next() % (depth <= 0 ? 2 : 9);
    if (r === 0) return pick(vars);
    if (r === 1) return pick(lits);
    if (r === 2) return ['neg', int(depth - 1, vars)];
    if (r <= 5) return [pick(['add', 'sub', 'mul', 'div']), int(depth - 1, vars), int(depth - 1, vars)];
    if (r === 6) return ['if', bool(depth - 1, vars), int(depth - 1, vars), int(depth - 1, vars)];
    const v = `v${vars.length}`;
    return ['let', v, int(depth - 1, vars), int(depth - 1, [...vars, v])];
  }
  function bool(depth, vars) {
    const r = next() % (depth <= 0 ? 1 : 4);
    if (r === 0) return [pick(['lt', 'le', 'gt', 'ge', 'eq']), int(depth - 1, vars), int(depth - 1, vars)];
    if (r === 1) return ['not', bool(depth - 1, vars)];
    if (r === 2) return pick([true, false]);
    return ['eq', bool(depth - 1, vars), bool(depth - 1, vars)];
  }
  return Array.from({length: count}, (_, i) => i % 5 === 4 ? [`gen-${i}`, bool(4, ['x']), 'Bool'] : [`gen-${i}`, int(4, ['x'])]);
}

export function cases() {
  return [...HAND, ...generated()].map(([name, surface, type = 'I64']) => ({name, artifact: artifact(surface, type)}));
}
