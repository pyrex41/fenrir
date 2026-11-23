import {readFileSync} from 'node:fs';

export const profileBytes = readFileSync(new URL('../../spec/native/standalone-v1.json', import.meta.url));
export const nativeProfile = JSON.parse(profileBytes);
export const NATIVE_PROFILE = nativeProfile.id;
export const nativeLimits = nativeProfile.limits;
