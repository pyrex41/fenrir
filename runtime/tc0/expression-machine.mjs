// Independent candidate for the UNQUALIFIED arithmetic-demo frame proposal.
// Accepts only host-validated graphs; no oracle/validator/transition imports.
const minimum=-(1n<<63n), maximum=(1n<<63n)-1n;
export class ExpressionMachine {
  constructor(body, parameter, input, {reverseOperands=false}={}) {
    this.control={kind:'Eval',expr:body}; this.env=new Map([[parameter,input]]);
    this.frames=[]; this.epoch=0n; this.terminal=null; this.events=[];
    this.reverseOperands=reverseOperands;
  }
  site() {
    const c=this.control;
    if (c.kind === 'Eval') return {node:c.expr[1],rule:'Dispatch'};
    if (c.kind === 'Ready') return {node:c.node,rule:'Ready'};
    if (c.kind === 'Value' && this.frames.length) {
      const f=this.frames.at(-1); return {node:f.node,rule:f.kind+'Return'};
    }
    if (c.kind === 'Unwind' && this.frames.length) return {node:this.frames.at(-1).node,rule:'UnwindFrame'};
    return {machine:c.kind === 'Value' || c.kind === 'Unwind' ? 'RootJoinEntry' : c.kind,rule:c.kind};
  }
  step() {
    if (this.terminal) throw new Error('No transition after termination');
    const site=this.site(), c=this.control, events=[];
    const value=v=>{this.control={kind:'Value',value:v};};
    const enter=e=>{this.control={kind:'Eval',expr:e};};
    if (c.kind === 'Eval') {
      const [tag,node,...args]=c.expr;
      switch(tag) {
        case 'int': value(['int',args[0]]); break;
        case 'bool': value(['bool',args[0]]); break;
        case 'unit': value(['unit']); break;
        case 'var': if (!this.env.has(args[0])) throw new Error('Unknown binding'); value(this.env.get(args[0])); break;
        case 'let': this.frames.push({kind:'Let',node,binding:args[0],body:args[2],env:this.env}); enter(args[1]); break;
        case 'if': this.frames.push({kind:'If',node,yes:args[1],no:args[2],env:this.env}); enter(args[0]); break;
        case 'prim': case 'emit': {
          let operands=tag === 'prim' ? args.slice(1) : [args[1]];
          if (this.reverseOperands) operands=[...operands].reverse();
          const frame={kind:'Collect',node,op:tag === 'prim' ? args[0] : 'emit',label:tag === 'emit' ? args[0] : null,operands,index:0,values:[],env:this.env};
          if (operands.length) {this.frames.push(frame);enter(operands[0]);}
          else this.control={kind:'Ready',node,op:frame.op,label:frame.label,values:[]};
          break;
        }
        default: throw new Error('Unsupported candidate expression');
      }
    } else if (c.kind === 'Value') {
      if (!this.frames.length) this.control={kind:'Join',outcome:['Ok',c.value]};
      else {
        const f=this.frames.pop(); this.env=f.env;
        if (f.kind === 'Let') {this.env=new Map(f.env);this.env.set(f.binding,c.value);enter(f.body);}
        else if (f.kind === 'If') enter(c.value[1] ? f.yes : f.no);
        else {
          f.values.push(c.value); f.index++;
          if (f.index < f.operands.length) {this.frames.push(f);enter(f.operands[f.index]);}
          else this.control={kind:'Ready',node:f.node,op:f.op,label:f.label,values:this.reverseOperands ? f.values.reverse() : f.values};
        }
      }
    } else if (c.kind === 'Ready') {
      if (c.op === 'emit') {
        const identity={task:'0',node:c.node};
        events.push({kind:'Invoke',...identity,operation:'emit',label:c.label,value:c.values[0]},
          {kind:'Emit',...identity,label:c.label,value:c.values[0]},
          {kind:'Commit',...identity,operation:'emit',value:['unit']}); value(['unit']);
      } else if (c.op === 'not') value(['bool',!c.values[0][1]]);
      else {
        const [a,b]=c.values.map(v=>BigInt(v[1])); let result;
        if (c.op === 'div' && b === 0n) this.control={kind:'Unwind',code:'DivZero'};
        else {
          switch(c.op) {
            case 'add': result=a+b;break; case 'sub':result=a-b;break;case 'mul':result=a*b;break;
            case 'div':result=a/b;break;case 'neg':result=-a;break;
            case 'lt':result=a<b;break;case 'le':result=a<=b;break;case 'gt':result=a>b;break;case 'ge':result=a>=b;break;
            default:throw new Error('Unsupported primitive');
          }
          if (typeof result === 'boolean') value(['bool',result]);
          else if (result < minimum || result > maximum) this.control={kind:'Unwind',code:'Overflow'};
          else value(['int',String(result)]);
        }
      }
    } else if (c.kind === 'Unwind') {
      if (this.frames.length) {const f=this.frames.pop();this.env=f.env;}
      else this.control={kind:'Join',outcome:['Trap',c.code]};
    } else if (c.kind === 'Join') {
      events.push({kind:'ScopeExit',task:'0',scope:'0',outcome:c.outcome});this.control={kind:'Terminate',outcome:c.outcome};
    } else if (c.kind === 'Terminate') {
      this.terminal=c.outcome;events.push({kind:'TaskTermination',task:'0',outcome:c.outcome});this.control={kind:'Terminal'};
    } else throw new Error('Invalid control');
    const record={epoch:String(this.epoch++),site,after:this.control.kind,depth:String(this.frames.length),events};
    this.events.push(...events); return record;
  }
  run(fuel) {
    if (!Number.isSafeInteger(fuel) || fuel < 0) throw new TypeError('Invalid fuel');
    const steps=[];
    while (!this.terminal && steps.length < fuel) steps.push(this.step());
    return {execution:this.terminal ? 'Completed' : 'BudgetExhausted',outcome:this.terminal,steps,events:[...this.events]};
  }
}
