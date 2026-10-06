// Data-only admission endpoint. Never imports candidate/oracle transitions.
import {decode} from '../../tc0/canonical.mjs';
import {lower,dataHeader,readAdmissionFile} from './lower.mjs';
const [artifact,input]=process.argv.slice(2);
if(!artifact || !input || process.argv.length!==4)throw new Error('Usage: admit.mjs artifact input');
const data=lower(readAdmissionFile(artifact),decode(readAdmissionFile(input)));
console.log(JSON.stringify({data,header:dataHeader(data)}));
