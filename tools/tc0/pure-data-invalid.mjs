// Finite deterministic INVALID schema /2 family, UNQUALIFIED development scope.
// Each case applies one named mutation to a valid generated seed and records the
// rejection it must produce. The expectation comes from the mutation, not from
// running the validator. Invalid artifacts must never execute.
import { generatePureData } from './pure-data-generate.mjs';
const clone = x => JSON.parse(JSON.stringify(x));
// Every expression array in the program with its parent container and key.
function nodes(program) {
  const out = [];
  const walk = (e, parent, key) => {
    if (!Array.isArray(e) || typeof e[0] !== 'string' || !/^\d+$/.test(e[1] ?? '')) return;
    out.push({ e, parent, key });
    e.forEach((x, i) => {
      if (Array.isArray(x)) {
        if (e[0] === 'match' && i >= 3) walk(x[2], x, 2);
        else walk(x, e, i);
      }
    });
  };
  program.functions.forEach(f => walk(f.body, f, 'body'));
  return out;
}
const first = (p, tag, where = () => true) => {
  const n = nodes(p).find(n => n.e[0] === tag && where(n.e));
  if (!n) throw new Error('Seed lacks ' + tag);
  return n;
};
const MUTATIONS = [
  [
    'duplicate-node-id',
    'Duplicate ID',
    p => {
      const [a, b] = nodes(p);
      b.e[1] = a.e[1];
    }
  ],
  [
    'unknown-tag',
    'Unsupported tag',
    p => {
      first(p, 'tuple').e[0] = 'record';
    }
  ],
  // Under /1 the Data type in area's signature is rejected before any body tag is visited.
  [
    'schema-1-data-type',
    'Type',
    p => {
      p.schema_version = 'tc0-a-pure-call-demo/1';
      p.datatypes = [];
    }
  ],
  [
    'bytes-uppercase-hex',
    'Bytes hex',
    p => {
      first(p, 'bytes').e[2] = 'FF';
    }
  ],
  [
    'bytes-odd-hex',
    'Bytes hex',
    p => {
      first(p, 'bytes').e[2] = '0';
    }
  ],
  [
    'tuple-arity-nine',
    'Tuple arity',
    p => {
      const t = first(p, 'tuple').e;
      let id = 1000;
      while (t.length < 11) t.push(['int', String(id++), '0']);
      p.source_map.push(
        ...t.slice(5).map(x => ({ id: x[1], file: 'invalid', line: '0', column: '0' }))
      );
    }
  ],
  [
    'project-out-of-range',
    'Projection',
    p => {
      first(p, 'project').e[3] = '3';
    }
  ],
  [
    'project-negative-index',
    'Unsigned ID',
    p => {
      first(p, 'project').e[3] = '-1';
    }
  ],
  [
    'construct-unknown-constructor',
    'Constructor',
    p => {
      first(p, 'construct').e[3] = 'Hexagon';
    }
  ],
  [
    'construct-unknown-datatype',
    'Unknown datatype',
    p => {
      first(p, 'construct').e[2] = 'Polygon';
    }
  ],
  [
    'construct-field-count',
    'Constructor',
    p => {
      const c = first(p, 'construct');
      c.parent[c.key] = c.e.slice(0, 5);
    }
  ],
  [
    'construct-field-type',
    'Constructor field type',
    p => {
      first(p, 'construct').e[4] = ['bool', first(p, 'construct').e[4][1], true];
    }
  ],
  [
    'match-missing-arm',
    'Non-exhaustive or duplicate match arms',
    p => {
      first(p, 'match').e.pop();
    }
  ],
  [
    'match-duplicate-arm',
    'Non-exhaustive or duplicate match arms',
    p => {
      const m = first(p, 'match').e;
      m[m.length - 1] = [m[3][0], [...m.at(-1)[1]], m.at(-1)[2]];
    }
  ],
  [
    'match-binder-count',
    'Match binders',
    p => {
      first(p, 'match').e[3][1].pop();
    }
  ],
  [
    'match-binder-out-of-scope',
    'Unknown binding',
    p => {
      const m = first(p, 'match').e,
        b = m[3][1][0];
      m[4][2] = ['var', m[4][2][1], b];
    }
  ],
  [
    'match-scrutinee-not-data',
    'Match scrutinee type',
    p => {
      const m = first(p, 'match').e;
      m[2] = ['int', m[2][1], '0'];
    }
  ],
  [
    'eq-mixed-types',
    'Equality type',
    p => {
      const q = first(p, 'prim', e => e[2] === 'eq').e;
      q[4] = ['int', q[4][1], '0'];
    }
  ],
  [
    'bytes-index-bytes-index',
    'Primitive type',
    p => {
      const q = first(p, 'prim', e => e[2] === 'bytes_index').e;
      q[4] = ['bytes', q[4][1], '00'];
    }
  ],
  [
    'bytes-concat-arity',
    'Primitive',
    p => {
      const q = first(p, 'prim', e => e[2] === 'bytes_concat');
      q.parent[q.key] = q.e.slice(0, 4);
    }
  ],
  [
    'if-branch-types',
    'If types',
    p => {
      const i = first(p, 'if').e;
      i[4] = ['bytes', i[4][1], ''];
    }
  ],
  [
    'datatype-duplicate-constructor',
    'Duplicate constructor',
    p => {
      p.datatypes[0].constructors[1].name = 'Sq';
    }
  ],
  [
    'datatype-builtin-name',
    'Datatype name',
    p => {
      p.datatypes.push({ name: 'Bytes', constructors: [{ name: 'B', fields: [] }] });
    }
  ],
  [
    'datatype-unknown-field-type',
    'Type',
    p => {
      p.datatypes[0].constructors[0].fields[0] = ['Data', 'Missing'];
    }
  ],
  [
    'datatype-extra-field',
    'Closed object fields',
    p => {
      p.datatypes[0].extra = '1';
    }
  ],
  [
    'entry-result-function',
    'Serializable entry',
    p => {
      p.functions[0].result_type = ['Tuple', ['Arrow', 'I64', 'I64', []]];
    }
  ],
  [
    'source-map-missing-row',
    'Source map incomplete',
    p => {
      p.source_map.pop();
    }
  ]
];
export function generateInvalidPureData() {
  const seed = generatePureData().cases[12].program;
  const cases = MUTATIONS.map(([name, rejection, mutate]) => {
    const program = clone(seed);
    program.module = 'invalid-' + name;
    mutate(program);
    return { name: 'invalid-' + name, program, expected_rejection: rejection };
  });
  return {
    schema: 'pure-data-invalid-family/1',
    scope:
      String(cases.length) +
      ' single named mutations of generated case 12, NOT exhaustive invalid-program exploration',
    seed: 'generated-data-12',
    count: String(cases.length),
    cases
  };
}
