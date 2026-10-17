// Independent candidate for the arithmetic component, not a TC0 AST machine.
// No imports from the Shen kernel or reference adapter.
const min = -(1n << 63n), max = (1n << 63n) - 1n;
const argv = process.argv.slice(2);
const mutant = argv.at(-1) === '--mutant=rounded-add';
if (mutant) argv.pop();
const [op, ...args] = argv;
const arities = { add: 2, sub: 2, mul: 2, div: 2, neg: 1 };
try {
  if (!Object.hasOwn(arities, op) || args.length !== arities[op]) throw new Error('operation/arity');
  const numbers = args.map(text => {
    if (!/^(0|-[1-9][0-9]*|[1-9][0-9]*)$/.test(text)) throw new Error('noncanonical integer');
    const value = BigInt(text);
    if (value < min || value > max) throw new Error('literal out of I64 range');
    return value;
  });
  const [a, b] = numbers;
  let value;
  if (op === 'div' && b === 0n) {
    console.log(JSON.stringify({ status: 'Trap', code: 'DivZero' }));
  } else {
    switch (op) {
      case 'add': value = mutant ? BigInt(Number(a) + Number(b)) : a + b; break;
      case 'sub': value = a - b; break;
      case 'mul': value = a * b; break;
      case 'div': value = a / b; break;
      case 'neg': value = -a; break;
    }
    console.log(JSON.stringify(value < min || value > max
      ? { status: 'Trap', code: 'Overflow' }
      : { status: 'Ok', value: value.toString() }));
  }
} catch (error) {
  console.error(JSON.stringify({ status: 'InvalidInput', reason: error.message }));
  process.exitCode = 2;
}
