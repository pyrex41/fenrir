// Hand-assembled UNQUALIFIED TC1 program for remote perform (spec/tc1/EFFECTS.md §12):
// the caller image's program. IDs and source-map rows are allocated mechanically.
//
//   handle Note { note(x) => x } in
//     let a = match perform(Ledger, add, (7, 5)) {
//               reply(r)  => if r.0 == 0 then (let _ = emit("got", r.1) in r.1)
//                                        else (let _ = emit("conflict", ()) in -3)
//               not_delivered => let _ = emit("undelivered", ()) in -1
//               timed_out => match perform(Ledger, add, (7, 5)) {      -- the retry: same key, same argument
//                              reply(r)  => ...                        -- as above
//                              not_delivered => let _ = emit("undelivered", ()) in -1
//                              timed_out => let _ = emit("unknown", ()) in -2 } } in
//     let b = match perform(Ledger, add, (8, 5)) { ... timed_out => let _ = emit("unknown", ()) in -2 } in
//     let c = match perform(Ledger, add, (7, 6)) { ... timed_out => let _ = emit("unknown", ()) in -2 } in
//     (a, b, c)
//
// The operation's result is (status, value): status 0 is ok, status 1 is conflict,
// the peer's refusal of a key it has applied with another argument (§12.3). The
// third perform reuses key 7 with another argument on purpose: it is answered
// conflict if key 7 was applied with 5, and is applied if key 7 never was.
// With datatypes on the wire the result would be a sum, ok(I64) | conflict.
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
const RemoteResult={name:'RemoteResult',constructors:[{name:'reply',fields:[['Tuple','I64','I64']]},{name:'not_delivered',fields:[]},{name:'timed_out',fields:[]}]};
const Ledger={name:'Ledger',operations:[{name:'add',argument_type:['Tuple','I64','I64'],result_type:['Data','RemoteResult']}]};
const Note={name:'Note',operations:[{name:'note',argument_type:'I64',result_type:'I64'}]};
const emitThen=(label,value,result)=>node('let',fresh(),node('emit',label,value),result);
const part=(v,index)=>node('project',node('var',v),String(index));
const attempt=(key,argument,onTimeout)=>{const v=fresh();return node('match',node('perform','Ledger','add',node('tuple',int(key),int(argument))),
  ['reply',[v],node('if',node('prim','eq',part(v,0),int(0)),emitThen('got',part(v,1),part(v,1)),emitThen('conflict',node('unit'),int(-3)))],
  ['not_delivered',[],emitThen('undelivered',node('unit'),int(-1))],
  ['timed_out',[],onTimeout()]);};
const unknown=()=>emitThen('unknown',node('unit'),int(-2));
const id=fresh(),parameter_id=fresh();locations.push(id);
const x=fresh(),a=fresh(),b=fresh(),c=fresh();
const body=node('handle','Note',[['note',x,node('var',x)]],
  node('let',a,attempt(7,5,()=>attempt(7,5,unknown)),
    node('let',b,attempt(8,5,unknown),
      node('let',c,attempt(7,6,unknown),
        node('tuple',node('var',a),node('var',b),node('var',c))))));
export const program={contract_version:'tc1-draft-1',schema_version:'tc1-handler-demo/1',slice:'TC1-H1',module:'remote-caller',
  datatypes:[RemoteResult],effects:[Ledger,Note],
  functions:[{id,name:'main',parameter_id,argument_type:'I64',result_type:['Tuple','I64','I64','I64'],effects:['Emit','Ledger'],body}],
  entry:'main',input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'remote-caller',line:'0',column:'0'}))};
// Build-time map from remote effects to members of the system.
export const bindings=[['Ledger','peer']];
export const input=['int','0'];
