// Admit the validated artifact before lowering and prepare the link metadata.
import {readFileSync, writeFileSync} from 'node:fs';
import {NativeProfileError, requireStandaloneProfile, runtimeConfigHeader} from './native-profile.mjs';
import {nativeProfile, profileBytes} from '../tc1/native-profile.mjs';
import {stampNativeImage} from './native-profile-stamp.mjs';

const [target, artifact, stamp, header] = process.argv.slice(2);
try {
  requireStandaloneProfile(JSON.parse(readFileSync(artifact)));
  writeFileSync(header, runtimeConfigHeader(nativeProfile.limits), {flag: 'wx'});
  writeFileSync(stamp, stampNativeImage('', target, profileBytes));
} catch (error) {
  if (!(error instanceof NativeProfileError)) throw error;
  console.error(error.message);
  process.exitCode = 1;
}
