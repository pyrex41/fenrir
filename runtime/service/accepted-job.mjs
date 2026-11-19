// Accepted-job contract: a second, independently structured implementation,
// written from the contract text spec/service/ACCEPTED_JOB.md (sections 1-3),
// not from the Shen model. It is the candidate that stages A2/A3 replace; it is
// UNQUALIFIED and makes no claim beyond agreeing with the model where
// harness/service-explore.shen compares them.
//
// Structure (deliberately unlike the model's lists): each tenant store holds Maps
// keyed by id or key; the outbox is a Map from an event's canonical text to the
// event; the clients' trace is an append-only array, oldest first. Events and
// receipts are plain objects. The canonical observation of section 3 is produced
// only by observe().

export class Disabled extends Error {}

const STATUS=Object.freeze({pending:'pending',done:'done',failed:'failed'});

function emptyStore(){return {reports:new Map(),jobs:new Map(),keys:new Map(),next:0};}

function copyStore(s){
  return {reports:new Map(s.reports),
    jobs:new Map([...s.jobs].map(([id,job])=>[id,{...job}])),
    keys:new Map(s.keys),next:s.next};
}

// Receipts and events are immutable once made, so copies may share them.
const receiptArray=r=>[r.tenant,r.key,r.digest,r.report,r.job];
export function eventArray(e){
  return e.kind==='accepted'?['accepted',receiptArray(e.receipt)]:['conflict',e.tenant,e.key];
}
function eventFromArray(a){
  if(!Array.isArray(a))throw new TypeError('event must be an array');
  if(a[0]==='accepted'&&Array.isArray(a[1])&&a[1].length===5){
    const [tenant,key,digest,report,job]=a[1];
    return Object.freeze({kind:'accepted',receipt:Object.freeze({tenant,key,digest,report,job})});
  }
  if(a[0]==='conflict'&&a.length===3)return Object.freeze({kind:'conflict',tenant:a[1],key:a[2]});
  throw new TypeError('not an event: '+JSON.stringify(a));
}
const eventText=e=>JSON.stringify(eventArray(e));

// Section 3 order: accepted before conflict; then field by field.
function compareEvents(a,b){
  const x=eventArray(a),y=eventArray(b);
  if(x[0]!==y[0])return x[0]==='accepted'?-1:1;
  const fx=x[0]==='accepted'?x[1]:x.slice(1),fy=y[0]==='accepted'?y[1]:y.slice(1);
  for(let i=0;i<fx.length;i++)if(fx[i]!==fy[i])return fx[i]-fy[i];
  return 0;
}

export class AcceptedJobService {
  constructor(tenants){
    if(!Number.isInteger(tenants)||tenants<1)throw new TypeError('tenants must be a positive integer');
    this.stores=Array.from({length:tenants},emptyStore);
    this.outbox=new Map();
    this.told=[];
  }

  clone(){
    const c=Object.create(AcceptedJobService.prototype);
    c.stores=this.stores.map(copyStore);
    c.outbox=new Map(this.outbox);
    c.told=this.told.slice();
    return c;
  }

  store(t){
    if(!Number.isInteger(t)||t<0||t>=this.stores.length)throw new Disabled('no such tenant '+t);
    return this.stores[t];
  }

  // The request transaction, installed at once; its response goes to the outbox.
  submit(t,k,d){
    const s=this.store(t),entry=s.keys.get(k);
    let event;
    if(entry===undefined){
      const id=s.next;
      const receipt=Object.freeze({tenant:t,key:k,digest:d,report:id,job:id});
      s.reports.set(id,d);
      s.jobs.set(id,{report:id,status:STATUS.pending});
      s.keys.set(k,{digest:d,receipt});
      s.next=id+1;
      event=Object.freeze({kind:'accepted',receipt});
    }else if(entry.digest===d){
      event=Object.freeze({kind:'accepted',receipt:entry.receipt});
    }else{
      event=Object.freeze({kind:'conflict',tenant:t,key:k});
    }
    this.outbox.set(eventText(event),event);
    return event;
  }

  // Worker delivery: only a pending job moves; an unknown id changes nothing.
  complete(t,j,ok){
    const job=this.store(t).jobs.get(j);
    if(job!==undefined&&job.status===STATUS.pending)job.status=ok?STATUS.done:STATUS.failed;
    return null;
  }

  respond(event){
    const text=eventText(event);
    if(!this.outbox.has(text))throw new Disabled('response not in the outbox');
    const e=this.outbox.get(text);
    this.told.push(e);
    return e;
  }

  crash(){this.outbox.clear();return null;}

  // Apply a label in its canonical array form; returns the response in canonical form or null.
  apply(label){
    if(!Array.isArray(label))throw new TypeError('label must be an array');
    switch(label[0]){
      case 'submit':{const [,t,k,d]=label;return eventArray(this.submit(t,k,d));}
      case 'complete':{const [,t,j,ok]=label;if(typeof ok!=='boolean')throw new TypeError('outcome must be boolean');return this.complete(t,j,ok);}
      case 'respond':return eventArray(this.respond(eventFromArray(label[1])));
      case 'crash':return this.crash();
      default:throw new Disabled('not in the alphabet: '+JSON.stringify(label));
    }
  }

  // Section 2: every submit; deliveries of each id in use and the next unused id,
  // with both outcomes; every response in the outbox; crash.
  alphabet({keys,digests}){
    const labels=[];
    this.stores.forEach((_,t)=>{for(let k=0;k<keys;k++)for(let d=0;d<digests;d++)labels.push(['submit',t,k,d]);});
    this.stores.forEach((s,t)=>{for(let j=0;j<=s.next;j++)labels.push(['complete',t,j,true],['complete',t,j,false]);});
    for(const e of this.outbox.values())labels.push(['respond',eventArray(e)]);
    labels.push(['crash']);
    return labels;
  }

  observe(){
    const byNumber=(a,b)=>a-b;
    const tenants=this.stores.map(s=>[
      [...s.reports.keys()].sort(byNumber).map(id=>[id,s.reports.get(id)]),
      [...s.jobs.keys()].sort(byNumber).map(id=>{const j=s.jobs.get(id);return [id,j.report,j.status];}),
      [...s.keys.keys()].sort(byNumber).map(k=>{const e=s.keys.get(k);return [k,e.digest,receiptArray(e.receipt)];}),
      s.next]);
    const outbox=[...this.outbox.values()].sort(compareEvents).map(eventArray);
    return [tenants,outbox,this.told.map(eventArray)];
  }
}
