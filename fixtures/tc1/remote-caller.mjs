// Hand-assembled UNQUALIFIED TC1 program for remote perform (spec/tc1/EFFECTS.md §12):
// the caller image's program. IDs and source-map rows are allocated mechanically.
//
//   handle Note { note(x) => x } in
//     let a = match perform(Ledger, add, (7, 5)) {
//               reply(v)  => let _ = emit("got", v) in v
//               peer_down => let _ = emit("down", ()) in -1
//               timed_out => match perform(Ledger, add, (7, 5)) {      -- the retry: same key
//                              reply(v)  => let _ = emit("got", v) in v
//                              peer_down => let _ = emit("down", ()) in -1
//                              timed_out => let _ = emit("unknown", ()) in -2 } } in
//     let b = match perform(Ledger, add, (8, 5)) { ... timed_out => let _ = emit("unknown", ()) in -2 } in
//     (a, b)
//
// Ledger is not handled by the program: the image's build binds it to a member
// (`bindings`), which makes its operations remote. Note is an ordinary user effect
// with a handler in scope, so the remote performs happen under a handler frame.
// The entry function's effect set names Ledger, which TC1 itself does not allow
// yet (§12.9); tools/solo5/remote-build.mjs admits it with the validator's
// remoteEffects option.
let next=0n;const locations=[];
const fresh=()=>String(next++);
const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
const int=n=>node('int',String(n));
const RemoteResult={name:'RemoteResult',constructors:[{name:'reply',fields:['I64']},{name:'peer_down',fields:[]},{name:'timed_out',fields:[]}]};
const Ledger={name:'Ledger',operations:[{name:'add',argument_type:['Tuple','I64','I64'],result_type:['Data','RemoteResult']}]};
const Note={name:'Note',operations:[{name:'note',argument_type:'I64',result_type:'I64'}]};
const emitThen=(label,value,result)=>node('let',fresh(),node('emit',label,value),result);
const attempt=(key,argument,onTimeout)=>{const v=fresh();return node('match',node('perform','Ledger','add',node('tuple',int(key),int(argument))),
  ['reply',[v],emitThen('got',node('var',v),node('var',v))],
  ['peer_down',[],emitThen('down',node('unit'),int(-1))],
  ['timed_out',[],onTimeout()]);};
const unknown=()=>emitThen('unknown',node('unit'),int(-2));
const id=fresh(),parameter_id=fresh();locations.push(id);
const x=fresh(),a=fresh(),b=fresh();
const body=node('handle','Note',[['note',x,node('var',x)]],
  node('let',a,attempt(7,5,()=>attempt(7,5,unknown)),
    node('let',b,attempt(8,5,unknown),
      node('tuple',node('var',a),node('var',b)))));
export const program={contract_version:'tc1-draft-1',schema_version:'tc1-handler-demo/1',slice:'TC1-H1',module:'remote-caller',
  datatypes:[RemoteResult],effects:[Ledger,Note],
  functions:[{id,name:'main',parameter_id,argument_type:'I64',result_type:['Tuple','I64','I64'],effects:['Emit','Ledger'],body}],
  entry:'main',input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'remote-caller',line:'0',column:'0'}))};
// Build-time map from remote effects to members of the system.
export const bindings=[['Ledger','peer']];
export const input=['int','0'];
