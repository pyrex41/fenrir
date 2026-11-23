// Usage: node tests/native/check-clock-traces.mjs NEW_OUTPUT_DIRECTORY
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {scheduleFor} from '../../tools/tc1/task-schedule.mjs';
import {runSchedule} from '../../runtime/tc1/task-machine.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const out = resolve(process.argv[2]);
mkdirSync(out);
const policies = ['fifo', 'lowest', 'highest', 'random:17', 'prandom:17'];
const fixtures = ['virtual-clock', 'clock-child', 'clock-cancel', 'clock-invalid-duration', 'clock-overflow',
                  'clock-child-trap', 'clock-tied-cancel', 'clock-close-full'];
let steps = 0;
for (const fixture of fixtures) {
  const dir = join(out, fixture);
  mkdirSync(dir);
  const run = (cmd, args) => execFileSync(cmd, args, {cwd: root, timeout: 30000, stdio: 'pipe'});
  run('sh', ['frontend/fenrir.sh', 'emit', 'tests/native/' + fixture + '.fen', join(dir, 'artifact.json')]);
  const artifact = JSON.parse(readFileSync(join(dir, 'artifact.json')));
  const input = ['int', '0'];
  const schedules = policies.map(policy => ({
    policy, choices: scheduleFor(artifact, input, {name: policy, policy}, 1000).choices
  }));
  writeFileSync(join(dir, 'input.json'), JSON.stringify({artifact, schedules}));
  const js = schedules.map(({policy, choices}) => {
    const result = runSchedule(artifact, input, choices);
    assert.equal(result.execution, 'Completed');
    assert.equal(result.steps.length, choices.length);
    if (fixture === 'clock-close-full') {
      const channelEvents = result.steps.flatMap(step => step.events)
        .filter(event => ['Sent', 'SendWait', 'Close', 'SendClosed', 'Received', 'End'].includes(event.kind));
      assert.deepEqual(channelEvents.map(event => event.kind),
        ['Sent', 'SendWait', 'Close', 'SendClosed', 'Received', 'End']);
      assert.deepEqual(channelEvents[4].value, ['int', '7']);
      assert.deepEqual(result.outcome, ['Ok', ['int', '7']]);
    }
    steps += choices.length;
    return {policy, ...result};
  });
  writeFileSync(join(dir, 'javascript.json'), JSON.stringify(js));
  run('sh', ['-ec', '. ./harness/jit.sh; exec "$jit/bin/shen-jit" script tests/native/clock-traces.shen "$jit/lib" "$root" "$1" "$2"',
             'harness/jit.sh', join(dir, 'input.json'), join(dir, 'shen.json')]);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'shen.json'))), js, fixture);
}
console.log(fixtures.length * policies.length, 'matching full traces,', steps, 'steps');
