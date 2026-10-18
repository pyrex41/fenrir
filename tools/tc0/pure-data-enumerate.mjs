// Exhaustive-small schema /2 scope, UNQUALIFIED development enumeration.
// Enumerates EVERY expression of grammar G below with at most `maxNodes` AST nodes,
// as the body of `main : I64 -> T` for each result type T, in a fixed order.
// The scope claim is exactly "all of G up to the bound", nothing wider.
//
// G (sizes count AST nodes; arms and binders are not nodes):
//   I64   ::= 0 | 1 | 9223372036854775807 | p | x (match binder in scope)
//           | tap(I64) | add(I64,I64) | div(I64,I64) | bytes_length(Bytes)
//           | bytes_index(Bytes,I64) | project(Pair,0|1) | if(Bool,I64,I64)
//           | match Opt {None => I64; Some x => I64}   (both arm orders)
//           | match Tri {A => I64; B => I64; C => I64}  (all six arm orders)
//   Bool  ::= true | not(Bool) | lt(I64,I64) | eq(T,T) for T in I64, Bytes, Opt, Pair, Tri
//   Bytes ::= "" | ff | 01 | bytes_concat(Bytes,Bytes)   (two distinct nonempty literals
//                                                     make concatenation order observable)
//   Opt   ::= None | Some(I64)
//   Pair  ::= tuple(I64,I64)
//   Tri   ::= A | B | C                     (a nullary three-constructor datatype)
// `tap` is a named I64 -> I64 function that emits its argument and returns it, so
// evaluation order is observable. p is main's parameter (input 0).
import { encode } from './canonical.mjs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
const Opt = {
  name: 'Opt',
  constructors: [
    { name: 'None', fields: [] },
    { name: 'Some', fields: ['I64'] }
  ]
};
const Tri = { name: 'Tri', constructors: ['A', 'B', 'C'].map(name => ({ name, fields: [] })) };
const TYPES = {
  I64: 'I64',
  Bool: 'Bool',
  Bytes: 'Bytes',
  Opt: ['Data', 'Opt'],
  Pair: ['Tuple', 'I64', 'I64'],
  Tri: ['Data', 'Tri']
};
const ORDERS = [
  ['A', 'B', 'C'],
  ['A', 'C', 'B'],
  ['B', 'A', 'C'],
  ['B', 'C', 'A'],
  ['C', 'A', 'B'],
  ['C', 'B', 'A']
];
const MAX = '9223372036854775807';
// Templates: [tag,...operands] without node IDs; binders are '$p' or '$v<depth>'.
function enumerate(maxNodes) {
  const memo = new Map();
  // All templates of type t with exactly n nodes, binders $v0..$v<depth-1> in scope.
  function gen(t, n, depth) {
    const key = t + '/' + n + '/' + depth;
    if (memo.has(key)) return memo.get(key);
    const out = [];
    memo.set(key, out);
    if (n < 1) return out;
    const splits = (k, parts) => {
      if (parts === 1) return k >= 1 ? [[k]] : [];
      const r = [];
      for (let i = 1; i <= k - parts + 1; i++)
        for (const rest of splits(k - i, parts - 1)) r.push([i, ...rest]);
      return r;
    };
    // Products of child generators whose sizes sum to n-1.
    const product = (kinds, build) => {
      for (const sizes of splits(n - 1, kinds.length)) {
        let rows = [[]];
        kinds.forEach(([ty, d], i) => {
          const next = [];
          for (const r of rows) for (const c of gen(ty, sizes[i], d)) next.push([...r, c]);
          rows = next;
        });
        for (const r of rows) out.push(build(...r));
      }
    };
    if (t === 'I64') {
      if (n === 1) {
        out.push(['int', '0'], ['int', '1'], ['int', MAX], ['var', '$p']);
        for (let d = 0; d < depth; d++) out.push(['var', '$v' + d]);
      }
      product([['I64', depth]], a => ['call', 'tap', a]);
      for (const op of ['add', 'div'])
        product(
          [
            ['I64', depth],
            ['I64', depth]
          ],
          (a, b) => ['prim', op, a, b]
        );
      product([['Bytes', depth]], b => ['prim', 'bytes_length', b]);
      product(
        [
          ['Bytes', depth],
          ['I64', depth]
        ],
        (b, i) => ['prim', 'bytes_index', b, i]
      );
      for (const i of ['0', '1']) product([['Pair', depth]], p => ['project', p, i]);
      product(
        [
          ['Bool', depth],
          ['I64', depth],
          ['I64', depth]
        ],
        (c, a, b) => ['if', c, a, b]
      );
      product(
        [
          ['Opt', depth],
          ['I64', depth],
          ['I64', depth + 1]
        ],
        (o, none, some) => {
          const x = '$v' + depth;
          return ['match', o, ['None', [], none], ['Some', [x], some]];
        }
      );
      product(
        [
          ['Opt', depth],
          ['I64', depth],
          ['I64', depth + 1]
        ],
        (o, none, some) => {
          const x = '$v' + depth;
          return ['match', o, ['Some', [x], some], ['None', [], none]];
        }
      );
      // Arm bodies are paired with constructors A, B, C; each order lists the same arms.
      for (const order of ORDERS)
        product(
          [
            ['Tri', depth],
            ['I64', depth],
            ['I64', depth],
            ['I64', depth]
          ],
          (t, a, b, c) => {
            const body = { A: a, B: b, C: c };
            return ['match', t, ...order.map(k => [k, [], body[k]])];
          }
        );
    } else if (t === 'Bool') {
      if (n === 1) out.push(['bool', true]);
      product([['Bool', depth]], b => ['prim', 'not', b]);
      product(
        [
          ['I64', depth],
          ['I64', depth]
        ],
        (a, b) => ['prim', 'lt', a, b]
      );
      for (const ty of ['I64', 'Bytes', 'Opt', 'Pair', 'Tri'])
        product(
          [
            [ty, depth],
            [ty, depth]
          ],
          (a, b) => ['prim', 'eq', a, b]
        );
    } else if (t === 'Bytes') {
      if (n === 1) out.push(['bytes', ''], ['bytes', 'ff'], ['bytes', '01']);
      product(
        [
          ['Bytes', depth],
          ['Bytes', depth]
        ],
        (a, b) => ['prim', 'bytes_concat', a, b]
      );
    } else if (t === 'Opt') {
      if (n === 1) out.push(['construct', 'Opt', 'None']);
      product([['I64', depth]], a => ['construct', 'Opt', 'Some', a]);
    } else if (t === 'Pair')
      product(
        [
          ['I64', depth],
          ['I64', depth]
        ],
        (a, b) => ['tuple', a, b]
      );
    else if (t === 'Tri' && n === 1) out.push(...['A', 'B', 'C'].map(k => ['construct', 'Tri', k]));
    return out;
  }
  const rows = [];
  for (let n = 1; n <= maxNodes; n++)
    for (const t of Object.keys(TYPES))
      for (const body of gen(t, n, 0)) rows.push({ result: t, nodes: n, body });
  return rows;
}
// Assign node IDs in preorder and binding IDs at binders; build the closed artifact.
function artifact(row, name) {
  let next = 0n;
  const fresh = () => String(next++),
    locations = [];
  const main = { id: fresh(), name: 'main', parameter_id: fresh() },
    binders = new Map([['$p', main.parameter_id]]);
  locations.push(main.id);
  const walk = e => {
    const id = fresh();
    locations.push(id);
    const [tag, ...x] = e;
    if (tag === 'var') return ['var', id, binders.get(x[0])];
    if (tag === 'int' || tag === 'bool' || tag === 'bytes') return [tag, id, ...x];
    if (tag === 'call' || tag === 'project')
      return tag === 'call' ? ['call', id, x[0], walk(x[1])] : ['project', id, walk(x[0]), x[1]];
    if (tag === 'construct') return ['construct', id, x[0], x[1], ...x.slice(2).map(walk)];
    if (tag === 'prim') return ['prim', id, x[0], ...x.slice(1).map(walk)];
    if (tag === 'match') {
      const scrutinee = walk(x[0]);
      return [
        'match',
        id,
        scrutinee,
        ...x.slice(1).map(([c, bs, body]) => {
          const ids = bs.map(b => {
            const k = fresh();
            binders.set(b, k);
            return k;
          });
          return [c, ids, walk(body)];
        })
      ];
    }
    return [tag, id, ...x.map(walk)];
  };
  const body = walk(row.body);
  const tapId = fresh(),
    tapParam = fresh(),
    letId = fresh(),
    bind = fresh(),
    emitId = fresh(),
    v1 = fresh(),
    v2 = fresh();
  locations.push(tapId, letId, emitId, v1, v2);
  const tap = {
    id: tapId,
    name: 'tap',
    parameter_id: tapParam,
    argument_type: 'I64',
    result_type: 'I64',
    effects: ['Emit'],
    body: [
      'let',
      letId,
      bind,
      ['emit', emitId, 'tap', ['var', v1, tapParam]],
      ['var', v2, tapParam]
    ]
  };
  const uses = s => JSON.stringify(row.body).includes(s);
  return {
    contract_version: '0.2',
    schema_version: 'tc0-a-pure-call-demo/2',
    slice: 'TC0-A',
    module: name,
    datatypes: [...(uses('"Opt"') ? [Opt] : []), ...(uses('"Tri"') ? [Tri] : [])],
    effects: [],
    functions: [
      { ...main, argument_type: 'I64', result_type: TYPES[row.result], effects: ['Emit'], body },
      tap
    ],
    entry: 'main',
    input_schema: { type: 'I64' },
    source_map: locations.map(id => ({ id, file: 'exhaustive-small', line: '0', column: '0' }))
  };
}
export function enumeratePureData(maxNodes = 4, { maxCases = 8000 } = {}) {
  if (!Number.isSafeInteger(maxNodes) || maxNodes < 1 || maxNodes > 6)
    throw new TypeError('Node bound 1..6');
  const rows = enumerate(maxNodes);
  if (rows.length > maxCases)
    throw new RangeError(
      `Exhaustive scope has ${rows.length} programs, above the ${maxCases} cap; lower the node bound rather than truncating`
    );
  const cases = rows.map((row, i) => {
    const name = 'small-' + i,
      program = artifact(row, name);
    validatePureCallArtifact(encode(program), ['int', '0']);
    return { name, program, nodes: String(row.nodes), result: row.result };
  });
  const by = {};
  for (const c of cases)
    by[c.result + '/' + c.nodes] = String(1 + Number(by[c.result + '/' + c.nodes] ?? 0));
  return {
    schema: 'pure-data-exhaustive-small/1',
    grammar: 'tools/tc0/pure-data-enumerate.mjs header grammar G',
    max_nodes: String(maxNodes),
    count: String(cases.length),
    counts_by_result_and_nodes: by,
    truncated: false,
    cases
  };
}
