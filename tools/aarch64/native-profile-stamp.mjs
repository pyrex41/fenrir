// Keep the executable's profile identity available after linking and stripping.
import {createHash} from 'node:crypto';

export function stampNativeImage(assembly, target, profileBytes) {
  const profile = JSON.parse(profileBytes);
  if (!profile.targets.includes(target) || !/^[a-z0-9/-]+$/.test(profile.id)) {
    throw new Error('invalid standalone image profile');
  }
  const digest = createHash('sha256').update(profileBytes).digest('hex');
  const section = target === 'macos-arm64'
    ? '.section __TEXT,__fenrir_profile,regular,no_dead_strip'
    : '.section .fenrir.profile,"aR",%progbits';
  const stamp = Buffer.from(`\0FENRIR-EXEC-PROFILE\0${profile.id}\0${target}\0${digest}\0`);
  return assembly + '\n' + section + '\n.byte ' + [...stamp].join(',') + '\n';
}
