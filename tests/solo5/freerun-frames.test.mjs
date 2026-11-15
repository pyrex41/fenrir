import test from 'node:test';
import assert from 'node:assert/strict';
import {frames} from '../../tools/solo5/freerun.mjs';

test('tender banner lines are ignored and frames decode in order', () => {
  assert.deepEqual(frames('Solo5: banner\nFGRUN/1 7\n{"a":1}\nnoise\nFGRUN/1 2\n{}\n'), [{a: 1}, {}]);
});
test('a wrong length is rejected', () => {
  assert.throws(() => frames('FGRUN/1 8\n{"a":1}\n'), /length mismatch/);
});
test('an unknown FG prefix or malformed header is rejected', () => {
  assert.throws(() => frames('FGCTL/1 2\n{}\n'), /Invalid frame header/);
  assert.throws(() => frames('FGRUN/1 02\n{}\n'), /Invalid frame header/);
});
test('a header without a payload line is rejected', () => {
  assert.throws(() => frames('FGRUN/1 2'), /Invalid frame header/);
});
