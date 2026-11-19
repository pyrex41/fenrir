#!/usr/bin/env node
// Transport only, for `fenrir.sh run` on a TC1-C1 program (spec/tc1/SURFACE.md section
// 2, "Tasks"): turn a schedule policy into the explicit list of choices, one task ID per
// step, that the Shen model then replays (tools/tc1/task-schedule.mjs, the same policies
// harness/tc1-tasks.shen uses). The model checks every choice against its own Runnable
// set and, for a production policy, that every switch follows a scheduling point; no
// rule about tasks lives here.
//
//   node frontend/schedule.mjs ARTIFACT.json POLICY FUEL
// POLICY: fifo | lowest | highest | random:N | prandom:N. Prints {"choices":[...]}.
import {readFileSync} from 'node:fs';
import {scheduleFor} from '../tools/tc1/task-schedule.mjs';
import {validatePureCallArtifact} from '../tools/tc0/pure-call-artifact.mjs';

const [path,policy,fuel]=process.argv.slice(2);
if(!path||!/^(fifo|lowest|highest|(random|prandom):[0-9]{1,9})$/.test(policy??'')||!/^[0-9]{1,9}$/.test(fuel??'')||process.argv.length!==5){
  console.error('usage: node frontend/schedule.mjs ARTIFACT.json fifo|lowest|highest|random:N|prandom:N FUEL');process.exit(2);
}
const {artifact,input}=validatePureCallArtifact(readFileSync(path),['int','0']);
console.log(JSON.stringify({choices:scheduleFor(artifact,input,{name:policy,policy},Number(fuel)).choices}));
