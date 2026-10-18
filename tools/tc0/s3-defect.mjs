// The S3 defective original: the arm-by-position mutant (match selects the arm at the
// constructor's declared position instead of by name) applied to the reference candidate
// source. Refuses if the source moved or the result names the injected defect.
import { mutantSource } from './pure-call-mutants.mjs';
export function makeDefective(source) {
  const out = mutantSource(source, 'armByPosition');
  if (/armByPosition|arm_by_position|[Mm]utant/.test(out))
    throw new Error('Defective source still names the injected defect');
  return out;
}
