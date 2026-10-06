// Closed, UNQUALIFIED arithmetic-demo sublanguage of TC0-A. Not the full A validator.
// Proposed field/binding/source-map shapes need review before becoming authority.
import { decode, encode, decimal } from './canonical.mjs';
export class InvalidArtifact extends Error {}
export class ValidationLimit extends Error {}
const types = new Set(['Unit', 'Bool', 'I64']);
const arities = {add:2, sub:2, mul:2, div:2, neg:1, lt:2, le:2, gt:2, ge:2, not:1};
function invalid(reason) { throw new InvalidArtifact(reason); }
function object(v, keys) {
  if (!v || Array.isArray(v) || typeof v !== 'object') invalid('Expected object');
  if (Object.keys(v).sort().join(',') !== [...keys].sort().join(',')) invalid('Closed object fields');
}
function unsigned(v) { try { return decimal(v, {unsigned:true}); } catch { invalid('Unsigned decimal'); } }
function type(v) { if (!types.has(v)) invalid('Unsupported demo type'); return v; }
function array(v) { if (!Array.isArray(v)) invalid('Expected array'); return v; }
function string(v) { if (typeof v !== 'string') invalid('Expected string'); return v; }
function checkInput(value, t) {
  array(value);
  if (t === 'Unit' && value.length === 1 && value[0] === 'unit') return;
  if (t === 'Bool' && value.length === 2 && value[0] === 'bool' && typeof value[1] === 'boolean') return;
  if (t === 'I64' && value.length === 2 && value[0] === 'int') {
    try {
      decimal(value[1]); const n = BigInt(value[1]);
      if (n >= -(1n << 63n) && n < (1n << 63n)) return;
    } catch {}
  }
  invalid('Input/literal type or range');
}
export function validateArtifact(bytes, input, {maxNodes=200, maxDepth=64} = {}) {
  for (const n of [maxNodes,maxDepth]) if (!Number.isSafeInteger(n) || n < 1) throw new TypeError('Invalid cap');
  const artifact = decode(bytes);
  object(artifact, ['contract_version','schema_version','slice','module','datatypes','effects','functions','entry','input_schema','source_map']);
  if (artifact.contract_version !== '0.2' || artifact.schema_version !== 'tc0-a-arithmetic-demo/1' || artifact.slice !== 'TC0-A') invalid('Version/slice');
  string(artifact.module); array(artifact.datatypes); array(artifact.effects);
  if (artifact.datatypes.length || artifact.effects.length) invalid('Declarations unsupported in demo');
  array(artifact.functions);
  if (artifact.functions.length !== 1) invalid('Demo requires exactly one function');
  const fn = artifact.functions[0];
  object(fn, ['id','name','parameter_id','argument_type','result_type','effects','body']);
  unsigned(fn.id); unsigned(fn.parameter_id); string(fn.name);
  if (artifact.entry !== fn.name) invalid('Entry name');
  type(fn.argument_type); type(fn.result_type); array(fn.effects);
  if (!(fn.effects.length === 0 || fn.effects.length === 1 && fn.effects[0] === 'Emit')) invalid('Declared effects');
  object(artifact.input_schema, ['type']);
  if (artifact.input_schema.type !== fn.argument_type) invalid('Entry input schema');
  checkInput(input, fn.argument_type);
  const ids = new Set(), locations = new Set(); let nodes = 0;
  function fresh(id, location=false) {
    unsigned(id); if (ids.has(id)) invalid('Duplicate artifact ID'); ids.add(id);
    if (location) locations.add(id);
  }
  fresh(fn.id, true); fresh(fn.parameter_id);
  function expression(e, env, depth) {
    if (++nodes > maxNodes || depth > maxDepth) throw new ValidationLimit('AST node/depth cap');
    array(e); if (e.length < 2) invalid('Expression shape'); fresh(e[1],true);
    const [tag, , ...args] = e;
    const arity = n => { if (args.length !== n) invalid('AST arity'); };
    const visit = x => expression(x, env, depth+1);
    const merge = results => new Set(results.flatMap(r => [...r.effects]));
    let result, effects = new Set();
    switch (tag) {
      case 'unit': arity(0); result='Unit'; break;
      case 'bool': arity(1); checkInput(['bool',args[0]],'Bool'); result='Bool'; break;
      case 'int': arity(1); checkInput(['int',args[0]],'I64'); result='I64'; break;
      case 'var': arity(1); unsigned(args[0]); result=env.get(args[0]); if (!result) invalid('Unknown binding'); break;
      case 'let': {
        arity(3); fresh(args[0]); const init=visit(args[1]);
        const inner=new Map(env); inner.set(args[0],init.type);
        const body=expression(args[2],inner,depth+1); result=body.type; effects=merge([init,body]); break;
      }
      case 'if': {
        arity(3); const rows=args.map(visit);
        if (rows[0].type !== 'Bool' || rows[1].type !== rows[2].type) invalid('If types');
        result=rows[1].type; effects=merge(rows); break;
      }
      case 'prim': {
        const [op,...operands]=args;
        if (!Object.hasOwn(arities,op) || operands.length !== arities[op]) invalid('Primitive/arity');
        const rows=operands.map(visit), argumentType=op === 'not' ? 'Bool' : 'I64';
        if (rows.some(r=>r.type !== argumentType)) invalid('Primitive types');
        result=['lt','le','gt','ge','not'].includes(op) ? 'Bool' : 'I64'; effects=merge(rows); break;
      }
      case 'emit': {
        arity(2); string(args[0]); const row=visit(args[1]); effects=merge([row]); effects.add('Emit'); result='Unit'; break;
      }
      default: invalid('Unsupported AST tag in arithmetic demo');
    }
    return {type:result,effects};
  }
  const checked=expression(fn.body,new Map([[fn.parameter_id,fn.argument_type]]),0);
  if (checked.type !== fn.result_type || [...checked.effects].some(e=>!fn.effects.includes(e))) invalid('Result/effect mismatch');
  array(artifact.source_map); const mapped=new Set();
  for (const row of artifact.source_map) {
    object(row,['id','file','line','column']); unsigned(row.id); string(row.file); unsigned(row.line); unsigned(row.column);
    if (!locations.has(row.id) || mapped.has(row.id)) invalid('Source map unknown/duplicate location'); mapped.add(row.id);
  }
  if (mapped.size !== locations.size) invalid('Source map incomplete');
  // Freeze a detached graph so callers cannot mutate a validated AST in-place.
  function freeze(v) { if (v && typeof v === 'object') { for (const x of Object.values(v)) freeze(x); Object.freeze(v); } return v; }
  return freeze({artifact, input:decode(encode(input)), node_count:String(nodes)});
}
