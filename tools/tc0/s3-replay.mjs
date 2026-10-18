// S3 retained-failure replay, development tier, NOT qualification.
// Usage: node tools/tc0/s3-replay.mjs BUNDLE CANDIDATE_FILE original|repaired OUTPUT
//   original  CANDIDATE_FILE must be the bundle's preserved defective original; each
//             retained failure must replay Exact and stop at its recorded first divergence.
//   repaired  CANDIDATE_FILE must differ from it; each retained failure must replay
//             Exact and be Admitted (complete agreement with the model trace).
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { encode } from './canonical.mjs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
import { pureCallHeader } from './pure-call-replay-header.mjs';
import { recordPureCall, replayPureCall } from './pure-call-replay.mjs';
const sha = b => createHash('sha256').update(b).digest('hex');
const [bundlePath, candidatePath, mode, output] = process.argv.slice(2);
if (
  !bundlePath ||
  !candidatePath ||
  !['original', 'repaired'].includes(mode) ||
  !output?.endsWith('.json') ||
  existsSync(output)
)
  throw new Error('Usage: s3-replay.mjs BUNDLE CANDIDATE_FILE original|repaired FRESH_OUTPUT.json');
const bundleBytes = readFileSync(bundlePath),
  bundle = JSON.parse(bundleBytes),
  candidate = resolve(candidatePath),
  candidateHash = sha(readFileSync(candidate));
if (bundle.schema !== 'tc0-s3-failure-bundle/1') throw new Error('Expected an S3 failure bundle');
if ((mode === 'original') !== (candidateHash === bundle.defective_candidate_sha256))
  throw new Error(
    mode === 'original'
      ? 'Not the preserved defective original'
      : 'Candidate is still the defective original'
  );
const { PureCallMachine } = await import(pathToFileURL(candidate).href + '?sha=' + candidateHash);
const cases = bundle.failures.map(f => {
  const checked = validatePureCallArtifact(encode(f.program), f.input),
    machine = () => new PureCallMachine(checked.artifact, checked.input);
  const header = pureCallHeader(
    machine(),
    checked.artifact,
    checked.input,
    f.model_steps,
    { bundle_sha256: sha(bundleBytes) },
    { run_id: 's3-' + mode + '-' + f.label, candidate_path: candidate }
  );
  const tape = recordPureCall(machine(), f.model_steps, header),
    result = replayPureCall(machine(), f.model_steps, header, tape);
  const ok =
    mode === 'original'
      ? result.replay === 'Exact' &&
        result.conformance === 'Diverged' &&
        tape.footer.kind === 'Divergence' &&
        tape.footer.epoch === f.first_divergence_epoch
      : result.replay === 'Exact' &&
        result.conformance === 'Admitted' &&
        encode(tape.footer.outcome).equals(encode(f.model_outcome));
  if (!ok)
    throw new Error(
      `${mode} replay failed for ${f.label}: ${JSON.stringify(result)} footer ${JSON.stringify(tape.footer)}`
    );
  return { label: f.label, result, footer: tape.footer, header };
});
writeFileSync(
  output,
  encode({
    qualification: 'UNKNOWN',
    mode,
    candidate_sha256: candidateHash,
    bundle_sha256: sha(bundleBytes),
    cases
  }),
  { flag: 'wx' }
);
console.log(
  JSON.stringify({
    qualification: 'UNKNOWN',
    mode,
    cases: cases.map(c => ({
      label: c.label,
      conformance: c.result.conformance,
      footer: c.footer.kind,
      epoch: c.footer.epoch
    }))
  })
);
