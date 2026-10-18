// Generated schema /2 family, arm-by-position mutant, reduction rules and the
// same-mutant failure replay transport. Scripted peers are UNIT tests, NOT Shen evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { encode } from '../../tools/tc0/canonical.mjs';
import { validatePureCallArtifact } from '../../tools/tc0/pure-call-artifact.mjs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';
import { createMachine } from '../../tools/tc0/pure-call-mutants.mjs';
import { generatePureData } from '../../tools/tc0/pure-data-generate.mjs';
import { pureCallReductions, pureCallMetric } from '../../tools/tc0/pure-call-reduce.mjs';
const run = (program, options = {}) => createMachine(program, ['int', '0'], options).run(200);
const labels = r => r.events.filter(e => e.kind === 'Emit').map(e => e.label);
const firstDivergence = (a, b) =>
  a.steps.findIndex((s, i) => JSON.stringify(s) !== JSON.stringify(b.steps[i]));

test('finite 24-case data family is deterministic, typed, bounded and explicit about truncation', () => {
  const g = generatePureData();
  assert.equal(g.cases.length, 24);
  assert.equal(g.truncated, false);
  assert.deepEqual(generatePureData(), g);
  assert.equal(generatePureData(3).truncated, true);
  assert.throws(() => generatePureData(25));
  assert.throws(() => generatePureData(0));
  for (const c of g.cases) {
    const v = validatePureCallArtifact(encode(c.program), ['int', '0']);
    assert.ok(Number(v.node_count) <= 200);
    const r = run(v.artifact);
    assert.equal(r.execution, 'Completed');
    assert.ok(r.steps.length <= 200);
    assert.deepEqual(r.outcome, c.expected_outcome);
    assert.deepEqual(labels(r), ['left', 'right']);
    const tags = new Set(
      JSON.stringify(c.program.functions).match(/"(bytes|tuple|project|construct|match)"/g)
    );
    assert.equal(tags.size, 5);
    for (const op of ['bytes_concat', 'bytes_index', 'eq'])
      assert.ok(JSON.stringify(c.program).includes(`"${op}"`));
  }
});

test('arm-by-position mutant: equivalent on declared arm order, diverges after MatchReturn on rotated order', () => {
  for (const c of generatePureData().cases) {
    const r = run(c.program),
      m = run(c.program, { armByPosition: true });
    assert.equal(m.execution, 'Completed');
    assert.deepEqual(m.outcome, c.arm_by_position_outcome);
    if (c.parameters.order === 'declared') {
      assert.deepEqual(m.steps, r.steps);
      continue;
    }
    const k = firstDivergence(r, m);
    assert.ok(k > 0, c.name);
    assert.equal(r.steps[k - 1].site.rule, 'MatchReturn');
    assert.equal(r.steps[k].site.rule, 'Dispatch');
    assert.equal(m.steps[k].site.rule, 'Dispatch');
    assert.notEqual(r.steps[k].site.node, m.steps[k].site.node);
  }
  // Rotated Sq with equal fields: same outcome, yet the trace still names the wrong arm.
  const same = generatePureData().cases.find(
    c =>
      c.parameters.order === 'rotated' &&
      c.parameters.constructor === 'Sq' &&
      c.parameters.padding === '1'
  );
  assert.deepEqual(same.arm_by_position_outcome, same.expected_outcome);
  assert.ok(firstDivergence(run(same.program), run(same.program, { armByPosition: true })) > 0);
});

test('reverse-operands mutant reverses tuple-field emissions with the same outcome on every case', () => {
  for (const c of generatePureData().cases) {
    const m = run(c.program, { reverseOperands: true });
    assert.deepEqual(labels(m), ['right', 'left']);
    assert.deepEqual(m.outcome, c.expected_outcome);
  }
});

test('runner accepts each mutant flag once and rejects unknown flags', () => {
  const parent = resolve('build/tc0');
  mkdirSync(parent, { recursive: true });
  const dir = mkdtempSync(resolve(parent, 'pure-data-runner-'));
  try {
    const c = generatePureData().cases[12],
      file = resolve(dir, 'p.json');
    writeFileSync(file, JSON.stringify(c.program));
    const go = (...flags) =>
      spawnSync(process.execPath, ['tools/tc0/run-pure-call.mjs', file, ...flags], {
        encoding: 'utf8',
        timeout: 10000
      });
    assert.deepEqual(JSON.parse(go().stdout).outcome, c.expected_outcome);
    assert.deepEqual(JSON.parse(go('--arm-by-position').stdout).outcome, c.arm_by_position_outcome);
    for (const flags of [['--bogus'], ['--arm-by-position', '--arm-by-position']])
      assert.notEqual(go(...flags).status, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('data reduction rules are typed, smaller, largest-first, and prune unused datatypes', () => {
  const p = generatePureData().cases[12].program,
    n = pureCallMetric(p).nodes,
    proposals = pureCallReductions(p);
  for (const row of proposals) {
    const v = validatePureCallArtifact(encode(row.program), ['int', '0']);
    assert.ok(Number(v.node_count) < n);
  }
  assert.deepEqual(
    proposals.map(r => r.metric.nodes),
    [...proposals.map(r => r.metric.nodes)].sort((a, b) => a - b)
  );
  // Every arm here uses its binders, so match-to-arm proposals are all ill-typed and dropped.
  assert.ok(!proposals.some(r => r.rule === 'match-to-arm'));
  for (const rule of [
    'if-to-branch',
    'prim-to-operand',
    'call-to-argument',
    'constant-if',
    'drop-let-if-still-typed'
  ])
    assert.ok(
      proposals.some(r => r.rule === rule),
      rule
    );
  // Once nothing constructs or names Shape, its declaration goes too.
  const pruned = proposals.find(r => !JSON.stringify(r.program.functions).includes('"Shape"'));
  if (pruned) assert.deepEqual(pruned.program.datatypes, []);
  const kept = proposals.filter(r => JSON.stringify(r.program.functions).includes('"Shape"'));
  assert.ok(kept.every(r => r.program.datatypes.length === 1));
});

test('match-to-arm keeps a binder-free arm body', () => {
  const program = {
    contract_version: '0.2',
    schema_version: 'tc0-a-pure-call-demo/2',
    slice: 'TC0-A',
    module: 'unit',
    datatypes: [
      {
        name: 'Opt',
        constructors: [
          { name: 'None', fields: [] },
          { name: 'Some', fields: ['I64'] }
        ]
      }
    ],
    effects: [],
    functions: [
      {
        id: '0',
        name: 'main',
        parameter_id: '1',
        argument_type: 'I64',
        result_type: 'I64',
        effects: [],
        body: [
          'match',
          '2',
          ['construct', '3', 'Opt', 'None'],
          ['None', [], ['int', '4', '5']],
          ['Some', ['5'], ['var', '6', '5']]
        ]
      }
    ],
    entry: 'main',
    input_schema: { type: 'I64' },
    source_map: ['0', '2', '3', '4', '6'].map(id => ({ id, file: 'unit', line: '0', column: '0' }))
  };
  const rows = pureCallReductions(program).filter(r => r.rule === 'match-to-arm');
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].program.functions[0].body, ['int', '4', '5']);
  assert.deepEqual(rows[0].program.datatypes, []);
});

test('project-tuple-literal selects the projected element', () => {
  const program = {
    contract_version: '0.2',
    schema_version: 'tc0-a-pure-call-demo/2',
    slice: 'TC0-A',
    module: 'unit',
    datatypes: [],
    effects: [],
    functions: [
      {
        id: '0',
        name: 'main',
        parameter_id: '1',
        argument_type: 'I64',
        result_type: 'I64',
        effects: [],
        body: ['project', '2', ['tuple', '3', ['int', '4', '7'], ['int', '5', '9']], '1']
      }
    ],
    entry: 'main',
    input_schema: { type: 'I64' },
    source_map: ['0', '2', '3', '4', '5'].map(id => ({ id, file: 'unit', line: '0', column: '0' }))
  };
  // Either drop leaves index 1 out of range, so revalidation discards both.
  assert.ok(!pureCallReductions(program).some(r => r.rule === 'drop-tuple-element'));
  const unused = structuredClone(program);
  unused.functions[0].body = [
    'let',
    '6',
    '7',
    ['tuple', '3', ['int', '4', '7'], ['int', '5', '9']],
    ['int', '2', '0']
  ];
  unused.source_map = ['0', '2', '3', '4', '5', '6'].map(id => ({
    id,
    file: 'unit',
    line: '0',
    column: '0'
  }));
  assert.deepEqual(
    pureCallReductions(unused)
      .filter(r => r.rule === 'drop-tuple-element')
      .map(r => r.program.functions[0].body[3]),
    [
      ['tuple', '3', ['int', '5', '9']],
      ['tuple', '3', ['int', '4', '7']]
    ]
  );
  const row = pureCallReductions(program).find(r => r.rule === 'project-tuple-literal');
  assert.deepEqual(row.program.functions[0].body, ['int', '5', '9']);
  assert.deepEqual(
    row.program.source_map.map(r => r.id),
    ['0', '5']
  );
});

test('schema /2 same-mutant failure replay rechecks wrong-match-arm and fails closed on drift', () => {
  const digest = p => createHash('sha256').update(readFileSync(p)).digest('hex');
  const parent = resolve('build/tc0');
  mkdirSync(parent, { recursive: true });
  const dir = mkdtempSync(resolve(parent, 'pure-data-failure-unit-'));
  try {
    mkdirSync(resolve(dir, 'bin'));
    const shen = resolve(dir, 'bin/shen-scheme'),
      boot = resolve(dir, 'shen.boot');
    writeFileSync(shen, 'mock unit only');
    writeFileSync(boot, 'mock boot');
    const paths = [
      'tools/check-tc0-pure-call-reduction.py',
      'tools/check-tc0-pure-call.py',
      'tools/check-tc0-expression.py',
      'tools/tc0/pure-call-generate.mjs',
      'tools/tc0/pure-data-generate.mjs',
      'tools/tc0/pure-call-reduce.mjs',
      'tools/tc0/pure-call-campaign-bridge.mjs',
      'tools/tc0/run-pure-call.mjs',
      'tools/tc0/pure-call-artifact.mjs',
      'tools/tc0/canonical.mjs',
      'models/tc0/pure-call-machine.shen',
      'models/tc0/arithmetic.shen',
      'runtime/tc0/pure-call-machine.mjs',
      'spec/tc0/pure-call-demo.json'
    ].map(p => resolve(p));
    const sources = Object.fromEntries(
      [...paths, process.execPath, shen, boot].map(p => [p, digest(p)])
    );
    const program = generatePureData().cases[12].program,
      input = ['int', '0'],
      candidate = run(program),
      mutant = run(program, { armByPosition: true });
    const row = {
      name: 'mock-unit-only',
      program,
      input,
      candidate,
      equivalent_control: candidate,
      mutant,
      model_steps: candidate.steps,
      hand_outcome: candidate.outcome,
      discrepancy: 'wrong-match-arm'
    };
    const report = {
      schema: 'pure-call-reduction-development/2',
      family: 'pure-data',
      mutant: 'arm-by-position',
      expected_discrepancy: 'wrong-match-arm',
      qualification: 'UNKNOWN',
      cleanup: 'confirmed',
      sources,
      sources_after: sources,
      observations: [row],
      original: row,
      minimized: row
    };
    const file = resolve(dir, 'input.json');
    let serial = 0;
    const go = r => {
      const out = resolve(dir, 'output-' + serial++ + '.json');
      writeFileSync(file, JSON.stringify(r));
      const result = spawnSync(
        process.execPath,
        ['tools/tc0/check-pure-call-failure-replay.mjs', file, out],
        { timeout: 10000, encoding: 'utf8' }
      );
      assert.ifError(result.error);
      return { result, out };
    };
    const { result, out } = go(report);
    assert.equal(result.status, 0, result.stderr);
    const bundle = JSON.parse(readFileSync(out));
    assert.equal(bundle.mutant, 'arm-by-position');
    assert.equal(bundle.family, 'pure-data');
    for (const c of bundle.cases) {
      assert.equal(c.result.replay, 'Exact');
      assert.equal(c.result.conformance, 'Diverged');
      assert.equal(c.bundle.footer.kind, 'Divergence');
    }
    // A declared-order case is an equivalent mutant: no retained discrepancy can be claimed for it.
    const equivalent = generatePureData().cases[0].program,
      eq = run(equivalent);
    for (const mutate of [
      x => {
        x.mutant = 'reverse-operands';
      },
      x => {
        x.expected_discrepancy = 'reversed-emissions-same-outcome';
      },
      x => {
        x.family = 'other';
      },
      x => delete x.sources[resolve('tools/tc0/pure-data-generate.mjs')],
      x => {
        x.original.discrepancy = 'reversed-emissions-same-outcome';
      },
      x => {
        x.original.mutant = x.original.candidate;
      },
      x => {
        const r = {
          ...x.original,
          program: equivalent,
          candidate: eq,
          equivalent_control: eq,
          mutant: run(equivalent, { armByPosition: true }),
          model_steps: eq.steps,
          hand_outcome: eq.outcome
        };
        x.original = r;
        x.observations.push(r);
      }
    ]) {
      const bad = structuredClone(report);
      mutate(bad);
      const r = go(bad);
      assert.notEqual(r.result.status, 0);
      assert.equal(existsSync(r.out), false);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('invalid family: each named mutation is rejected with its expected class and never executes', async () => {
  const { generateInvalidPureData } = await import('../../tools/tc0/pure-data-invalid.mjs');
  const { InvalidPureCallArtifact } = await import('../../tools/tc0/pure-call-artifact.mjs');
  const family = generateInvalidPureData();
  assert.deepEqual(generateInvalidPureData(), family);
  assert.equal(Number(family.count), family.cases.length);
  const parent = resolve('build/tc0');
  mkdirSync(parent, { recursive: true });
  const dir = mkdtempSync(resolve(parent, 'pure-data-invalid-'));
  try {
    for (const c of family.cases) {
      assert.throws(
        () => validatePureCallArtifact(encode(c.program), ['int', '0']),
        e => e instanceof InvalidPureCallArtifact && e.message === c.expected_rejection,
        c.name
      );
      const file = resolve(dir, c.name + '.json');
      writeFileSync(file, JSON.stringify(c.program));
      const r = spawnSync(process.execPath, ['tools/tc0/run-pure-call.mjs', file], {
        encoding: 'utf8',
        timeout: 10000
      });
      assert.notEqual(r.status, 0, c.name);
      assert.equal(r.stdout, '', c.name);
      assert.match(r.stderr, /InvalidPureCallArtifact/, c.name);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('exhaustive-small enumeration: exact counts, deterministic, valid, completing, cap fails closed', async () => {
  const { enumeratePureData } = await import('../../tools/tc0/pure-data-enumerate.mjs');
  // Hand-derived: size 1 = 4 I64 leaves + true + 3 bytes + None + A/B/C = 12; size 2 adds
  // tap(4) + bytes_length(3) + not(1) + Some(4) = 12; size 3 adds I64 51 (tap 7, add/div 32,
  // bytes_index 12), Bool 52 (not 1, lt 16, eq 16+9+1+9), Bytes 9, Opt 7, Pair 16 = 135.
  assert.deepEqual(
    [1, 2, 3].map(n => enumeratePureData(n).count),
    ['12', '24', '159']
  );
  assert.deepEqual(enumeratePureData(3).counts_by_result_and_nodes, {
    'I64/1': '4',
    'Bool/1': '1',
    'Bytes/1': '3',
    'Opt/1': '1',
    'Tri/1': '3',
    'I64/2': '7',
    'Bool/2': '1',
    'Opt/2': '4',
    'I64/3': '51',
    'Bool/3': '52',
    'Bytes/3': '9',
    'Opt/3': '7',
    'Pair/3': '16'
  });
  // The smallest Tri match is 5 nodes: 3 scrutinees x 4^3 leaf bodies x 6 arm orders.
  const tri = enumeratePureData(5).cases.filter(
    c => c.program.functions[0].body[0] === 'match' && c.program.functions[0].body[2][2] === 'Tri'
  );
  assert.equal(tri.length, 3 * 64 * 6);
  const e = enumeratePureData(3);
  assert.deepEqual(enumeratePureData(3), e);
  assert.equal(e.truncated, false);
  const bodies = new Set(e.cases.map(c => c.result + JSON.stringify(c.program.functions[0].body)));
  assert.equal(bodies.size, e.cases.length);
  for (const c of e.cases) {
    const r = run(c.program);
    assert.equal(r.execution, 'Completed', c.name);
  }
  assert.throws(() => enumeratePureData(5, { maxCases: 100 }), RangeError);
  assert.throws(() => enumeratePureData(7), TypeError);
});
