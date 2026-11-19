// Programs of profile fenrir-aarch64-checked-call/1 as TC0-A pure-call
// artifacts (schema /2). Surface as in expr-fixtures.mjs plus
// ['call', 'name', arg]; each function is [name, argType, resultType, body]
// with parameter 'x'. The first function is the entry.
export function program(functions, module = 'arm-call') {
  let id = 0; const locations = [];
  const fresh = (loc = true) => { const s = String(id++); if (loc) locations.push(s); return s; };
  function build(t, scope) {
    if (typeof t === 'bigint') return ['int', fresh(), String(t)];
    if (typeof t === 'boolean') return ['bool', fresh(), t];
    if (typeof t === 'string') { if (!(t in scope)) throw new Error(`unbound ${t}`); return ['var', fresh(), scope[t]]; }
    const [op, ...args] = t;
    if (op === 'let') { const node = fresh(), binder = fresh(false), init = build(args[1], scope); return ['let', node, binder, init, build(args[2], {...scope, [args[0]]: binder})]; }
    if (op === 'if') { const node = fresh(); return ['if', node, ...args.map(a => build(a, scope))]; }
    if (op === 'call') { const node = fresh(); return ['call', node, args[0], build(args[1], scope)]; }
    const node = fresh();
    return ['prim', node, op, ...args.map(a => build(a, scope))];
  }
  const fns = functions.map(([name, argument_type, result_type, body]) => {
    const fid = fresh(), param = fresh(false);
    return {id: fid, name, parameter_id: param, argument_type, result_type, effects: [], body: build(body, {x: param})};
  });
  return {contract_version: '0.2', schema_version: 'tc0-a-pure-call-demo/2', slice: 'TC0-A', module, datatypes: [], effects: [],
    functions: fns, entry: functions[0][0], input_schema: {type: 'I64'},
    source_map: locations.map(i => ({id: i, file: module, line: '0', column: '0'}))};
}

const MAX = (1n << 63n) - 1n;
// Clamp x into lo..hi (in-language), so call depth is bounded on every input.
const clamp = (lo, hi) => ['if', ['lt', 'x', lo], lo, ['if', ['gt', 'x', hi], hi, 'x']];

export const CALL_HAND = [
  ['sum-recursive', [['main', 'I64', 'I64', ['call', 'sum', clamp(0n, 500n)]],
    ['sum', 'I64', 'I64', ['if', ['le', 'x', 0n], 0n, ['let', 'r', ['call', 'sum', ['sub', 'x', 1n]], ['add', 'x', 'r']]]]]],
  ['count-down-tail', [['main', 'I64', 'I64', ['call', 'count', clamp(-5n, 3000n)]],
    ['count', 'I64', 'I64', ['if', ['le', 'x', 0n], 'x', ['call', 'count', ['sub', 'x', 1n]]]]]],
  ['even-odd-mutual-tail', [['main', 'I64', 'Bool', ['call', 'even', clamp(0n, 1000n)]],
    ['even', 'I64', 'Bool', ['if', ['eq', 'x', 0n], true, ['call', 'odd', ['sub', 'x', 1n]]]],
    ['odd', 'I64', 'Bool', ['if', ['eq', 'x', 0n], false, ['call', 'even', ['sub', 'x', 1n]]]]]],
  ['callee-overflow', [['main', 'I64', 'I64', ['let', 'r', ['call', 'square', 'x'], ['add', 'r', 1n]]],
    ['square', 'I64', 'I64', ['mul', 'x', 'x']]]],
  ['callee-divzero', [['main', 'I64', 'I64', ['let', 'r', ['call', 'inv', 'x'], ['sub', 'r', 'x']]],
    ['inv', 'I64', 'I64', ['div', 100n, 'x']]]],
  ['chain', [['main', 'I64', 'I64', ['let', 'a', ['call', 'f1', 'x'], ['let', 'b', ['call', 'f2', 'a'], ['sub', 'a', 'b']]]],
    ['f1', 'I64', 'I64', ['add', 'x', 7n]], ['f2', 'I64', 'I64', ['let', 'y', ['call', 'f1', 'x'], ['mul', 'y', 2n]]]]],
  ['bool-parameter', [['main', 'I64', 'I64', ['let', 'r', ['call', 'pick', ['lt', 'x', 0n]], ['mul', 'r', 'x']]],
    ['pick', 'Bool', 'I64', ['if', 'x', -1n, 1n]]]],
  ['call-in-branch', [['main', 'I64', 'I64', ['if', ['gt', 'x', 0n], ['call', 'half', 'x'], ['sub', 0n, 'x']]],
    ['half', 'I64', 'I64', ['div', 'x', 2n]]]],
  ['collatz-tail', [['main', 'I64', 'I64', ['call', 'c', ['if', ['lt', 'x', 1n], 1n, 'x']]],
    ['c', 'I64', 'I64', ['if', ['le', 'x', 1n], 'x',
      ['if', ['eq', ['sub', 'x', ['mul', ['div', 'x', 2n], 2n]], 0n], ['call', 'c', ['div', 'x', 2n]],
        ['call', 'c', ['add', ['mul', 'x', 3n], 1n]]]]]]],
  ['let-before-call', [['main', 'I64', 'I64', ['let', 'y', ['sub', 'x', 1n], ['let', 'z', ['call', 'id', 'y'], ['add', 'z', 1n]]]],
    ['id', 'I64', 'I64', 'x']]],
  ['entry-not-first-in-callee-order', [['main', 'I64', 'I64', ['let', 'r', ['call', 'g', 'x'], ['call', 'h', 'r']]],
    ['g', 'I64', 'I64', ['add', 'x', MAX]], ['h', 'I64', 'I64', ['neg', 'x']]]],
  ['fib-recursive', [['main', 'I64', 'I64', ['call', 'fib', clamp(0n, 16n)]],
    ['fib', 'I64', 'I64', ['if', ['lt', 'x', 2n], 'x',
      ['let', 'a', ['call', 'fib', ['sub', 'x', 1n]], ['let', 'b', ['call', 'fib', ['sub', 'x', 2n]], ['add', 'a', 'b']]]]]]],
];

// Deep recursion and a long tail loop, run natively on extra inputs only.
export const CALL_DEEP = [
  ['deep-recursion', [['main', 'I64', 'I64', ['call', 'sum', clamp(0n, 60000n)]],
    ['sum', 'I64', 'I64', ['if', ['le', 'x', 0n], 0n, ['let', 'r', ['call', 'sum', ['sub', 'x', 1n]], ['add', 'x', 'r']]]]], [60000n, 59999n]],
  ['long-tail-loop', [['main', 'I64', 'I64', ['call', 'count', clamp(-5n, 200000n)]],
    ['count', 'I64', 'I64', ['if', ['le', 'x', 0n], 'x', ['call', 'count', ['sub', 'x', 1n]]]]], [200000n, 199999n]],
];

export function callCases() { return CALL_HAND.map(([name, fns]) => ({name, artifact: program(fns)})); }
export function deepCases() { return CALL_DEEP.map(([name, fns, inputs]) => ({name, artifact: program(fns), inputs})); }
