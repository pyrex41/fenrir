export class UnsupportedTupleSpecialization extends Error {}

// Scalar-replace explicit tuple arguments to non-recursive helpers. Bind
// every component once, even when it is unused or projected more than once.
export function specializeTupleArguments(artifact) {
  const helpers = new Map(artifact.functions.filter(f => f.argument_type[0] === 'Tuple')
    .map(f => [f.name, f]));
  if (!helpers.size) return artifact.functions;
  let budget = 20000;

  function rewrite(e, bindings, active) {
    if (--budget < 0) throw new UnsupportedTupleSpecialization('Native tuple specialization exceeds its size bound');
    const [tag, id, value] = e;
    if (tag === 'project' && value[0] === 'var' && bindings.has(value[2])) {
      return ['var', id, bindings.get(value[2])[Number(e[3])]];
    }
    if (tag === 'call' && helpers.has(value)) {
      const helper = helpers.get(value);
      if (active.has(value)) throw new UnsupportedTupleSpecialization('Recursive tuple arguments require native heap lowering');
      if (e[3][0] !== 'tuple') throw new UnsupportedTupleSpecialization('Native tuple specialization needs explicit tuple operands');
      const args = e[3].slice(2).map(child => rewrite(child, bindings, active));
      const slots = args.map(() => Symbol('component'));
      const body = rewrite(helper.body, new Map([[helper.parameter_id, slots]]), new Set([...active, value]));
      return args.reduceRight((rest, arg, i) => ['let', id, slots[i], arg, rest], body);
    }
    return e.map(item => Array.isArray(item) ? rewrite(item, bindings, active) : item);
  }
  return artifact.functions.filter(f => !helpers.has(f.name))
    .map(f => ({...f, body: rewrite(f.body, new Map(), new Set())}));
}
