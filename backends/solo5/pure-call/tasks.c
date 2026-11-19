/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * TC1-C1 task layer (spec/tc1/CONCURRENCY.md, schema tc1-task-demo/1). See tasks.h.
 *
 * Each task is a local handler machine (struct pc_machine of machine.c, included below
 * so this file can use its helpers; machine.c itself is unchanged except for enum values
 * appended at the ends of its enums). Every step of a task that is not one of C1's is the
 * handler machine's own pc_step on that task's control, environment and frames; this file
 * adds the scheduling-point steps of CONCURRENCY.md sections 5-7, the scope frame, the
 * task table, scopes, channels and pending awaits, the step records of section 10, and
 * the FIFO production policy of section 9. Written from the contract. UNQUALIFIED.
 *
 * IDs: tasks, scopes and channels are allocated from 0 by three counters, so an ID is
 * also the index of its record here. */
#include "machine.c"
#include "tasks.h"

#define TK_TASKS 16u
#define TK_SCOPES 64u
#define TK_CHANNELS 16u
#define TK_AWAITS 64u
#define TK_EVENTS 96u
#define TK_QUEUE 9u /* capacity at most 8 (the validator's bound), plus the off-by-one defect */

enum { TS_RUNNABLE,TS_BLOCKED,TS_TERMINAL };
enum { TC_NONE,TC_REQUESTED,TC_DELIVERED };
enum { TW_NONE,TW_RECEIVE,TW_SEND,TW_AWAIT };
enum { TO_OK,TO_TRAP,TO_CANCELLED,TO_ABANDONED };
enum { SR_NONE,SR_NORMAL,SR_TRAP,SR_CANCELLED,SR_ABANDON };
enum { SP_OPEN,SP_JOINING,SP_EXITED };
enum { E_EMIT,E_SCOPE_ENTER,E_SCOPE_EXIT,E_SPAWN,E_AWAIT,E_AWAIT_WAIT,E_AWAIT_REMOVED,E_AWAITED,
       E_CANCEL_REQUEST,E_CANCEL_EFFECTIVE,E_YIELD,E_CHANNEL,E_SEND,E_SENT,E_SEND_CLOSED,E_SEND_WAIT,
       E_SEND_REMOVED,E_RECEIVE,E_RECEIVED,E_END,E_RECEIVE_WAIT,E_RECEIVE_REMOVED,E_CLOSE,
       E_SCOPE_FAILURE,E_TERMINATION };

struct tk_task {
    int status,cancel,wait,has_owner;  /* wait: what a Wait control waits for */
    uint64_t wait_on,owner;              /* the channel or task waited on; the owning scope */
    int outcome,code;                    /* when Terminal */
    const struct pc_value *result;
    struct pc_machine m;
};
struct tk_scope {
    uint64_t owner; int phase,reason,code; const struct pc_value *value;
    uint64_t children[TK_TASKS]; unsigned child_count;
    int failed; uint64_t failed_task[TK_TASKS]; int failed_code[TK_TASKS]; unsigned failure_count;
    int join_waiting;
};
struct tk_sender { uint64_t task; const struct pc_value *value; };
struct tk_channel {
    uint64_t capacity; const struct pc_value *queue[TK_QUEUE]; unsigned count; int closed;
    struct tk_sender senders[TK_TASKS]; unsigned sender_count;
    uint64_t receivers[TK_TASKS]; unsigned receiver_count;
};
struct tk_event { int kind; uint64_t task,a,b,c; const struct pc_value *value; int flag,outcome,code; const char *label; };

static const struct pc_program *program;
static struct tk_task tasks[TK_TASKS];
static struct tk_scope scopes[TK_SCOPES];
static struct tk_channel channels[TK_CHANNELS];
static uint64_t await_waiter[TK_AWAITS],await_target[TK_AWAITS];
static unsigned task_count,scope_count,channel_count,await_count;
static uint64_t epoch;
static int defect,fifo,limit;
static struct tk_event events[TK_EVENTS];
static unsigned event_count;
static uint64_t became[TK_TASKS*4u],queue[TK_TASKS*4u];
static unsigned became_count,queue_count;
static int switchable,has_current;
static uint64_t current;

static void event(struct tk_event e) {if(event_count>=TK_EVENTS){limit=1;return;}events[event_count++]=e;}
static struct tk_event ev(int kind,uint64_t task) {return (struct tk_event){kind,task,0,0,0,0,0,0,0,0};}
static void became_runnable(uint64_t id) {if(became_count<TK_TASKS*4u)became[became_count++]=id;else limit=1;}
static void make_runnable(uint64_t id) {tasks[id].status=TS_RUNNABLE;became_runnable(id);}

/* ---------- values ---------- */

static const struct pc_value *data(const char *type,const char *ctor,const struct pc_value *field) {
    const struct pc_value *fields[1]={field};
    struct pc_value *d=(struct pc_value *)aggregate(PV_DATA,fields,field?1:0);
    if(!d){limit=1;return 0;}
    d->text=type;d->constructor=ctor;return d;
}
static const struct pc_value *unit_value(void) {const struct pc_value *u=scalar(PV_UNIT,0);if(!u)limit=1;return u;}
static const struct pc_value *handle(int tag,uint64_t id) {const struct pc_value *h=scalar(tag,(int64_t)id);if(!h)limit=1;return h;}
static const char *trap_name(int code) {
    switch(code){case PC_OVERFLOW:return "Overflow";case PC_DIVZERO:return "DivZero";case PC_BOUNDS:return "Bounds";
                 case PC_CHILDFAILED:return "ChildFailed";default:limit=1;return "?";}
}
/* A task outcome as the Outcome value await returns. */
static const struct pc_value *outcome_value(const struct tk_task *t) {
    if(t->outcome==TO_OK)return data("Outcome","Ok",t->result);
    if(t->outcome==TO_CANCELLED)return data("Outcome","Cancelled",0);
    return data("Outcome","Failed",data("TrapCode",trap_name(t->code),0));
}

/* ---------- cancellation requests (section 6) ---------- */

static void stabilize(uint64_t ch);
static void remove_task(uint64_t *list,unsigned *count,uint64_t id) {
    unsigned k=0;for(unsigned i=0;i<*count;i++)if(list[i]!=id)list[k++]=list[i];
    *count=k;
}
static void request(uint64_t requester,uint64_t x) {
    struct tk_task *t=&tasks[x];
    struct tk_event e=ev(E_CANCEL_REQUEST,requester);e.a=x;
    if(t->status==TS_TERMINAL || t->cancel!=TC_NONE){e.flag=0;event(e);return;}
    t->cancel=TC_REQUESTED;e.flag=1;event(e);
    if(t->status!=TS_BLOCKED)return;
    /* Its registration is removed (a channel then stabilizes), then it becomes Runnable. */
    t->status=TS_RUNNABLE;
    if(t->m.control==PC_WAIT){
        if(t->wait==TW_AWAIT){
            unsigned k=0;
            for(unsigned i=0;i<await_count;i++)if(!(await_waiter[i]==x && await_target[i]==t->wait_on)){await_waiter[k]=await_waiter[i];await_target[k]=await_target[i];k++;}
            await_count=k;
            struct tk_event r=ev(E_AWAIT_REMOVED,x);r.a=t->wait_on;event(r);
        } else {
            struct tk_channel *c=&channels[t->wait_on];
            if(t->wait==TW_RECEIVE)remove_task(c->receivers,&c->receiver_count,x);
            else {unsigned k=0;for(unsigned i=0;i<c->sender_count;i++)if(c->senders[i].task!=x)c->senders[k++]=c->senders[i];c->sender_count=k;}
            struct tk_event r=ev(t->wait==TW_RECEIVE?E_RECEIVE_REMOVED:E_SEND_REMOVED,x);r.a=t->wait_on;event(r);
            stabilize(t->wait_on);
        }
    } else if(t->m.control==PC_JOIN && t->m.depth){
        scopes[t->m.frames[t->m.depth-1].next].join_waiting=0;
    } else limit=1;
    became_runnable(x);
}
/* Request cancellation of every nonterminal child in Children, in order. */
static void request_all(uint64_t requester,const struct tk_scope *s) {
    for(unsigned i=0;i<s->child_count;i++)if(tasks[s->children[i]].status!=TS_TERMINAL)request(requester,s->children[i]);
}
static void deliver(uint64_t id) {
    struct tk_task *t=&tasks[id];
    t->cancel=TC_DELIVERED;event(ev(E_CANCEL_EFFECTIVE,id));
    t->m.control=PC_UNWIND;t->m.trap=PC_CANCELLED;
}

/* ---------- channels (section 5) ---------- */

static void commit(uint64_t w,const struct pc_value *v) {
    struct tk_task *t=&tasks[w];
    if(t->status!=TS_BLOCKED || t->m.control!=PC_WAIT){limit=1;return;}
    t->m.control=PC_PENDING;t->m.value=v;t->wait=TW_NONE;make_runnable(w);
}
static uint64_t room(const struct tk_channel *c) {return c->capacity+(defect==TK_CAPACITY_OFF_BY_ONE?1u:0u);}
static const struct pc_value *take_oldest(struct tk_channel *c) {
    const struct pc_value *v=c->queue[0];
    for(unsigned i=1;i<c->count;i++)c->queue[i-1]=c->queue[i];
    c->count--;return v;
}
static void enqueue(struct tk_channel *c,const struct pc_value *v) {if(c->count>=TK_QUEUE){limit=1;return;}c->queue[c->count++]=v;}
static void stabilize(uint64_t ch) {
    struct tk_channel *c=&channels[ch];
    for(;!limit;){
        if(c->receiver_count && c->count){
            uint64_t r=c->receivers[0];remove_task(c->receivers,&c->receiver_count,r);
            const struct pc_value *v=take_oldest(c);
            commit(r,data("ReceiveResult","Item",v));
            struct tk_event e=ev(E_RECEIVED,r);e.a=ch;e.value=v;event(e);continue;
        }
        if(!c->closed && c->sender_count && c->count<room(c)){
            struct tk_sender s=c->senders[0];
            for(unsigned i=1;i<c->sender_count;i++)c->senders[i-1]=c->senders[i];
            c->sender_count--;enqueue(c,s.value);
            commit(s.task,data("SendResult","Sent",0));
            struct tk_event e=ev(E_SENT,s.task);e.a=ch;event(e);continue;
        }
        return;
    }
}

/* ---------- operations: the Ready step of section 5 ---------- */

static void block(struct tk_task *t,int wait,uint64_t on) {t->status=TS_BLOCKED;t->m.control=PC_WAIT;t->wait=wait;t->wait_on=on;}
static int innermost_scope(const struct pc_machine *m,uint64_t *s) {
    for(unsigned i=m->depth;i>0;i--)if(m->frames[i-1].kind==PF_SCOPE){*s=m->frames[i-1].next;return 1;}
    return 0;
}
static uint64_t new_scope(uint64_t owner) {
    if(scope_count>=TK_SCOPES){limit=1;return 0;}
    struct tk_scope *s=&scopes[scope_count];
    s->owner=owner;s->phase=SP_OPEN;s->reason=SR_NONE;s->code=0;s->value=0;s->child_count=0;s->failed=0;s->failure_count=0;s->join_waiting=0;
    return scope_count++;
}
static void spawn(uint64_t id,const struct pc_value *closure) {
    struct tk_task *t=&tasks[id];uint64_t owning;
    if(!innermost_scope(&t->m,&owning)){limit=1;return;}
    if(scopes[owning].failed){trap(&t->m,PC_CHILDFAILED);return;}
    if(task_count>=TK_TASKS || scopes[owning].child_count>=TK_TASKS){limit=1;return;}
    uint64_t child=task_count++,implicit=new_scope(child);
    if(limit)return;
    scopes[owning].children[scopes[owning].child_count++]=child;
    struct tk_task *c=&tasks[child];
    c->status=TS_RUNNABLE;c->cancel=TC_NONE;c->wait=TW_NONE;c->has_owner=1;c->owner=owning;c->outcome=0;c->code=0;c->result=0;
    struct pc_machine *cm=&c->m;
    cm->program=program;cm->control=PC_START;cm->node=0;cm->tail=1;cm->trap=PC_NO_TRAP;cm->reverse_operands=0;cm->wrap_overflow=0;
    cm->value=closure;cm->env=0;cm->depth=0;cm->epoch=0;cm->requests=0;
    struct pc_frame *f=push(cm,PF_SCOPE,-1,0);if(!f){limit=1;return;}
    f->next=(unsigned)implicit;
    /* Copies of the active handler frames, in order, above the implicit scope. */
    for(unsigned i=0;i<t->m.depth;i++)if(t->m.frames[i].kind==PF_HANDLE){
        if(cm->depth>=PC_MAX_FRAMES){limit=1;return;}
        cm->frames[cm->depth++]=t->m.frames[i];
    }
    became_runnable(child);
    struct tk_event e=ev(E_SPAWN,id);e.a=child;e.b=owning;e.c=implicit;event(e);
    produce(&t->m,handle(PV_TASK,child));
}
static void operation(uint64_t id) {
    struct tk_task *t=&tasks[id];struct pc_machine *m=&t->m;
    const struct pc_node *n=&program->nodes[m->node];const struct pc_value *const *v=m->ready;
    switch(n->tag){
    case PC_SPAWN:
        if(v[0]->tag!=PV_CLOSURE){limit=1;return;}
        spawn(id,v[0]);return;
    case PC_AWAIT: {
        if(v[0]->tag!=PV_TASK || (uint64_t)v[0]->integer>=task_count){limit=1;return;}
        uint64_t x=(uint64_t)v[0]->integer;
        struct tk_event e=ev(E_AWAIT,id);e.a=x;event(e);
        if(tasks[x].status==TS_TERMINAL){
            const struct pc_value *o=outcome_value(&tasks[x]);
            struct tk_event a=ev(E_AWAITED,id);a.a=x;a.outcome=tasks[x].outcome;a.code=tasks[x].code;a.value=tasks[x].result;event(a);
            produce(m,o);return;
        }
        if(await_count>=TK_AWAITS){limit=1;return;}
        await_waiter[await_count]=id;await_target[await_count]=x;await_count++;
        struct tk_event w=ev(E_AWAIT_WAIT,id);w.a=x;event(w);
        block(t,TW_AWAIT,x);return; }
    case PC_CANCEL:
        if(v[0]->tag!=PV_TASK || (uint64_t)v[0]->integer>=task_count){limit=1;return;}
        request(id,(uint64_t)v[0]->integer);produce(m,unit_value());return;
    case PC_YIELD:
        event(ev(E_YIELD,id));produce(m,unit_value());return;
    case PC_CHANNEL: {
        if(channel_count>=TK_CHANNELS || n->integer<1 || n->integer>8){limit=1;return;}
        uint64_t ch=channel_count++;struct tk_channel *c=&channels[ch];
        c->capacity=(uint64_t)n->integer;c->count=0;c->closed=0;c->sender_count=0;c->receiver_count=0;
        struct tk_event e=ev(E_CHANNEL,id);e.a=ch;e.b=c->capacity;event(e);
        produce(m,handle(PV_CHANNEL,ch));return; }
    default:break;
    }
    if(v[0]->tag!=PV_CHANNEL || (uint64_t)v[0]->integer>=channel_count){limit=1;return;}
    uint64_t ch=(uint64_t)v[0]->integer;struct tk_channel *c=&channels[ch];
    if(n->tag==PC_SEND){
        struct tk_event e=ev(E_SEND,id);e.a=ch;e.value=v[1];event(e);
        if(c->closed){struct tk_event x=ev(E_SEND_CLOSED,id);x.a=ch;event(x);produce(m,data("SendResult","Closed",0));return;}
        if(c->count<room(c)){
            enqueue(c,v[1]);struct tk_event x=ev(E_SENT,id);x.a=ch;event(x);
            stabilize(ch);produce(m,data("SendResult","Sent",0));return;
        }
        if(c->sender_count>=TK_TASKS){limit=1;return;}
        c->senders[c->sender_count++]=(struct tk_sender){id,v[1]};
        struct tk_event x=ev(E_SEND_WAIT,id);x.a=ch;event(x);
        block(t,TW_SEND,ch);return;
    }
    if(n->tag==PC_RECEIVE){
        struct tk_event e=ev(E_RECEIVE,id);e.a=ch;event(e);
        if(c->count){
            const struct pc_value *x=take_oldest(c);
            struct tk_event r=ev(E_RECEIVED,id);r.a=ch;r.value=x;event(r);
            stabilize(ch);produce(m,data("ReceiveResult","Item",x));return;
        }
        if(c->closed){struct tk_event r=ev(E_END,id);r.a=ch;event(r);produce(m,data("ReceiveResult","End",0));return;}
        if(c->receiver_count>=TK_TASKS){limit=1;return;}
        c->receivers[c->receiver_count++]=id;
        struct tk_event r=ev(E_RECEIVE_WAIT,id);r.a=ch;event(r);
        block(t,TW_RECEIVE,ch);return;
    }
    if(n->tag!=PC_CLOSE){limit=1;return;}
    struct tk_event e=ev(E_CLOSE,id);e.a=ch;e.flag=!c->closed;event(e);
    if(!c->closed){
        c->closed=1;
        struct tk_sender waiting[TK_TASKS];unsigned k=c->sender_count;
        for(unsigned i=0;i<k;i++)waiting[i]=c->senders[i];
        c->sender_count=0;
        for(unsigned i=0;i<k;i++){
            commit(waiting[i].task,data("SendResult","Closed",0));
            struct tk_event x=ev(E_SEND_CLOSED,waiting[i].task);x.a=ch;event(x);
        }
        stabilize(ch);
        if(!c->count){
            uint64_t ending[TK_TASKS];unsigned r=c->receiver_count;
            for(unsigned i=0;i<r;i++)ending[i]=c->receivers[i];
            c->receiver_count=0;
            for(unsigned i=0;i<r;i++){
                commit(ending[i],data("ReceiveResult","End",0));
                struct tk_event x=ev(E_END,ending[i]);x.a=ch;event(x);
            }
        }
    }
    produce(m,unit_value());
}

/* ---------- scopes, joins and termination (section 7) ---------- */

static int all_terminal(const struct tk_scope *s) {
    for(unsigned i=0;i<s->child_count;i++)if(tasks[s->children[i]].status!=TS_TERMINAL)return 0;
    return 1;
}
static void join(uint64_t id) {
    struct tk_task *t=&tasks[id];struct pc_machine *m=&t->m;
    struct tk_scope *s=&scopes[m->frames[m->depth-1].next];
    if(t->cancel==TC_REQUESTED && s->reason==SR_NORMAL){
        t->cancel=TC_DELIVERED;s->reason=SR_CANCELLED;
        event(ev(E_CANCEL_EFFECTIVE,id));request_all(id,s);return;
    }
    if(!all_terminal(s)){s->join_waiting=1;t->status=TS_BLOCKED;return;}
    m->depth--;s->phase=SP_EXITED;s->join_waiting=0;
    struct tk_event e=ev(E_SCOPE_EXIT,id);e.a=(uint64_t)(s-scopes);
    if(s->reason==SR_NORMAL && !s->failed){e.outcome=TO_OK;e.value=s->value;m->trap=PC_NO_TRAP;produce(m,s->value);}
    else if(s->reason==SR_NORMAL){e.outcome=TO_TRAP;e.code=PC_CHILDFAILED;trap(m,PC_CHILDFAILED);}
    else if(s->reason==SR_TRAP){e.outcome=TO_TRAP;e.code=s->code;trap(m,s->code);}
    else if(s->reason==SR_CANCELLED){e.outcome=TO_CANCELLED;trap(m,PC_CANCELLED);}
    else {e.outcome=TO_ABANDONED;m->control=PC_ABANDON;}
    event(e);
}
static void insert_failure(struct tk_scope *s,uint64_t task,int code) {
    if(s->failure_count>=TK_TASKS){limit=1;return;}
    unsigned at=s->failure_count;
    while(at>0 && s->failed_task[at-1]>task){s->failed_task[at]=s->failed_task[at-1];s->failed_code[at]=s->failed_code[at-1];at--;}
    s->failed_task[at]=task;s->failed_code[at]=code;s->failure_count++;
}
static void terminate(uint64_t id,int outcome,int code,const struct pc_value *result) {
    struct tk_task *t=&tasks[id];
    t->status=TS_TERMINAL;t->outcome=outcome;t->code=code;t->result=result;t->m.control=PC_TERMINAL;
    struct tk_event e=ev(E_TERMINATION,id);e.outcome=outcome;e.code=code;e.value=result;event(e);
    struct tk_scope *s=t->has_owner?&scopes[t->owner]:0;
    if(s && outcome==TO_TRAP){
        s->failed=1;insert_failure(s,id,code);
        struct tk_event f=ev(E_SCOPE_FAILURE,id);f.a=t->owner;f.code=code;event(f);
        request_all(id,s);
    }
    if(defect!=TK_LOST_WAKEUP){
        unsigned k=0;
        for(unsigned i=0;i<await_count;i++){
            if(await_target[i]==id){
                commit(await_waiter[i],outcome_value(t));
                struct tk_event a=ev(E_AWAITED,await_waiter[i]);a.a=id;a.outcome=outcome;a.code=code;a.value=result;event(a);
            } else {await_waiter[k]=await_waiter[i];await_target[k]=await_target[i];k++;}
        }
        await_count=k;
    }
    if(s && s->join_waiting && all_terminal(s)){s->join_waiting=0;make_runnable(s->owner);}
}

/* ---------- one step ---------- */

struct site { int machine; uint64_t node; const char *rule; }; /* machine: -1 node, 0 TaskStart, 1 TaskScope, 2 Terminate */
static const char *const machine_sites[]={"TaskStart","TaskScope","Terminate"};
static int runtime_op(int tag) {return tag>=PC_SPAWN && tag<=PC_CLOSE;}
static const char *pure_rule(int rule) {
    static const char *rules[]={"Dispatch","Ready","LetReturn","IfReturn","MatchReturn","ReturnReturn",
                                "CollectReturn","UnwindFrame","Value","Unwind","Join","Terminate",
                                "HandleReturn","ClauseReturn","ClauseExitReturn","ResumeReturn","DiscontinueReturn","AbandonFrame","HostReply"};
    if(rule<0 || rule>PR_HOST_REPLY){limit=1;return "?";}
    return rules[rule];
}
static struct site node_site(const struct pc_machine *m,const char *rule) {return (struct site){-1,program->nodes[m->node].id,rule};}
static struct site scope_site(const struct pc_machine *m,const char *rule) {
    int node=m->frames[m->depth-1].node;
    return node<0?(struct site){1,0,rule}:(struct site){-1,program->nodes[node].id,rule};
}
/* The site of the pure step the handler machine would take now. */
static struct site pure_site(const struct pc_machine *m) {
    struct pc_sample s;site(m,&s);
    if(s.machine_site!=-1)limit=1;
    return (struct site){-1,s.node,pure_rule(s.rule)};
}
static int due(const struct tk_task *t) {return t->cancel==TC_REQUESTED;}
/* A step at which the contract delivers a pending cancellation (section 6). */
static int delivery_point(const struct pc_machine *m) {
    const struct pc_node *n=&program->nodes[m->node];
    return m->control==PC_START || m->control==PC_PENDING || m->control==PC_WAIT ||
           (m->control==PC_EVAL && n->tag==PC_SCOPE) || (m->control==PC_READY && runtime_op(n->tag));
}
static int step_task(uint64_t id,struct site *where,int *point) {
    struct tk_task *t=&tasks[id];struct pc_machine *m=&t->m;
    const struct pc_node *nodes=program->nodes;
    int top=m->depth?m->frames[m->depth-1].kind:-1;
    *point=1;
    if(defect==TK_CANCEL_OFF_POINT && due(t) && !delivery_point(m) &&
       (m->control==PC_EVAL || m->control==PC_READY || (m->control==PC_VALUE && top!=PF_SCOPE && m->depth))){
        /* The injected defect: delivery at a pure step, which is not a scheduling point. */
        *where=pure_site(m);deliver(id);*point=0;return 1;
    }
    if(m->control==PC_START){
        *where=(struct site){0,0,"TaskStart"};
        if(due(t)){deliver(id);return 1;}
        const struct pc_value *c=m->value;
        if(!c || c->tag!=PV_CLOSURE || c->code<0 || (unsigned)c->code>=program->node_count)return -1;
        const struct pc_node *code=&nodes[c->code];
        if(code->tag!=PC_LAMBDA || code->child_count!=1)return -1;
        const struct pc_value *u=unit_value();if(!u)return -1;
        m->env=bind(code->binding,u,c->captures);if(!m->env)return -1;
        enter(m,code->children[0],1);m->value=0;return 1;
    }
    if(m->control==PC_EVAL && nodes[m->node].tag==PC_SCOPE){
        *where=node_site(m,"Dispatch");
        if(due(t)){deliver(id);return 1;}
        uint64_t s=new_scope(id);if(limit)return -1;
        int node=m->node;
        struct pc_frame *f=push(m,PF_SCOPE,node,0);if(!f)return -1;
        f->next=(unsigned)s;
        enter(m,nodes[node].children[0],1);
        struct tk_event e=ev(E_SCOPE_ENTER,id);e.a=s;event(e);
        return 1;
    }
    if(m->control==PC_READY && runtime_op(nodes[m->node].tag)){
        *where=node_site(m,"Ready");
        if(due(t)){deliver(id);return 1;}
        operation(id);return 1;
    }
    if(m->control==PC_PENDING || m->control==PC_WAIT){
        *where=node_site(m,"Wake");
        if(due(t)){deliver(id);return 1;}
        if(m->control==PC_WAIT)return -1; /* Wait without a cancellation request */
        produce(m,m->value);return 1;
    }
    if(top==PF_SCOPE && m->control==PC_VALUE){
        *where=scope_site(m,"ScopeClose");*point=0;
        struct tk_scope *s=&scopes[m->frames[m->depth-1].next];
        s->phase=SP_JOINING;s->reason=SR_NORMAL;s->value=m->value;m->control=PC_JOIN;return 1;
    }
    if(top==PF_SCOPE && (m->control==PC_UNWIND || m->control==PC_ABANDON)){
        *where=scope_site(m,"ScopeAbort");
        struct tk_scope *s=&scopes[m->frames[m->depth-1].next];
        s->phase=SP_JOINING;
        if(m->control==PC_ABANDON)s->reason=SR_ABANDON;
        else if(m->trap==PC_CANCELLED)s->reason=SR_CANCELLED;
        else {s->reason=SR_TRAP;s->code=m->trap;}
        request_all(id,s);m->control=PC_JOIN;return 1;
    }
    if(m->control==PC_JOIN){
        if(top!=PF_SCOPE)return -1;
        *where=scope_site(m,"Join");join(id);return 1;
    }
    if(!m->depth && (m->control==PC_VALUE || m->control==PC_UNWIND)){
        *where=(struct site){2,0,"Terminate"};
        if(m->control==PC_VALUE)terminate(id,TO_OK,0,m->value);
        else if(m->trap==PC_CANCELLED)terminate(id,TO_CANCELLED,0,0);
        else terminate(id,TO_TRAP,m->trap,0);
        return 1;
    }
    /* A step of the handler machine on this task. Only emit has events there; C1 keeps
     * its Emit event alone. */
    *point=0;
    struct pc_sample s;
    if(pc_step(m,&s)!=1)return -1;
    if(s.machine_site!=-1)return -1;
    *where=(struct site){-1,s.node,pure_rule(s.rule)};
    for(unsigned i=0;i<s.event_count;i++)if(s.events[i].kind==PE_EMIT){
        struct tk_event e=ev(E_EMIT,id);e.label=s.events[i].label;e.value=s.events[i].value;event(e);
    }
    return 1;
}

/* ---------- records (section 10) ---------- */

struct out { char *at; size_t used,cap; int bad; };
static void put(struct out *o,const char *s) {while(*s){if(o->used+1>=o->cap){o->bad=1;return;}o->at[o->used++]=*s++;}}
static void put_n(struct out *o,const char *s,unsigned n) {for(unsigned i=0;i<n;i++){if(o->used+1>=o->cap){o->bad=1;return;}o->at[o->used++]=s[i];}}
static void put_natural(struct out *o,uint64_t n) {
    char d[21];unsigned at=20;d[20]=0;
    do{d[--at]=(char)('0'+n%10);n/=10;}while(n);
    put(o,d+at);
}
static void put_id(struct out *o,const char *key,uint64_t n) {put(o,"\"");put(o,key);put(o,"\":\"");put_natural(o,n);put(o,"\"");}
static void put_value(struct out *o,const struct pc_value *v,unsigned depth) {
    if(!v || depth>256){o->bad=1;return;}
    switch(v->tag){
    case PV_UNIT:put(o,"[\"unit\"]");return;
    case PV_BOOL:put(o,v->integer?"[\"bool\",true]":"[\"bool\",false]");return;
    case PV_INT:
        put(o,"[\"int\",\"");
        if(v->integer<0){put(o,"-");put_natural(o,(uint64_t)0-(uint64_t)v->integer);} else put_natural(o,(uint64_t)v->integer);
        put(o,"\"]");return;
    case PV_BYTES:put(o,"[\"bytes\",\"");put_n(o,v->text,v->count);put(o,"\"]");return;
    case PV_TUPLE:put(o,"[\"tuple\"");break;
    case PV_DATA:put(o,"[\"data\",\"");put(o,v->text);put(o,"\",\"");put(o,v->constructor);put(o,"\"");break;
    default:o->bad=1;return; /* handles, closures and resumptions are not observations */
    }
    for(unsigned i=0;i<v->count;i++){put(o,",");put_value(o,v->fields[i],depth+1);}
    put(o,"]");
}
static void put_outcome(struct out *o,int outcome,int code,const struct pc_value *v) {
    if(outcome==TO_OK){put(o,"[\"Ok\",");put_value(o,v,0);put(o,"]");}
    else if(outcome==TO_TRAP){put(o,"[\"Trap\",\"");put(o,trap_name(code));put(o,"\"]");}
    else if(outcome==TO_CANCELLED)put(o,"[\"Cancelled\"]");
    else put(o,"[\"Abandoned\"]");
}
static void put_awaited_outcome(struct out *o,const struct tk_event *e) {
    if(e->outcome==TO_OK){put(o,"[\"data\",\"Outcome\",\"Ok\",");put_value(o,e->value,0);put(o,"]");}
    else if(e->outcome==TO_CANCELLED)put(o,"[\"data\",\"Outcome\",\"Cancelled\"]");
    else {put(o,"[\"data\",\"Outcome\",\"Failed\",[\"data\",\"TrapCode\",\"");put(o,trap_name(e->code));put(o,"\"]]");}
}
static void put_kind(struct out *o,const char *k) {put(o,"\"kind\":\"");put(o,k);put(o,"\"");}
static void put_task(struct out *o,const struct tk_event *e) {put(o,",");put_id(o,"task",e->task);}
/* One event, keys sorted. */
static void put_event(struct out *o,const struct tk_event *e) {
    static const char *const channel_kinds[]={"Sent","SendClosed","SendWait","SendRemoved","Receive","Received","End","ReceiveWait","ReceiveRemoved"};
    put(o,"{");
    switch(e->kind){
    case E_EMIT:put_kind(o,"Emit");put(o,",\"label\":\"");put(o,e->label);put(o,"\"");put_task(o,e);put(o,",\"value\":");put_value(o,e->value,0);break;
    case E_SCOPE_ENTER:put_kind(o,"ScopeEnter");put(o,",");put_id(o,"scope",e->a);put_task(o,e);break;
    case E_SCOPE_EXIT:put_kind(o,"ScopeExit");put(o,",\"outcome\":");put_outcome(o,e->outcome,e->code,e->value);put(o,",");put_id(o,"scope",e->a);put_task(o,e);break;
    case E_SPAWN:put_id(o,"child",e->a);put(o,",");put_id(o,"child_scope",e->c);put(o,",");put_kind(o,"Spawn");put(o,",");put_id(o,"scope",e->b);put_task(o,e);break;
    case E_AWAIT:case E_AWAIT_WAIT:case E_AWAIT_REMOVED:
        put_kind(o,e->kind==E_AWAIT?"Await":e->kind==E_AWAIT_WAIT?"AwaitWait":"AwaitRemoved");put(o,",");put_id(o,"target",e->a);put_task(o,e);break;
    case E_AWAITED:put_kind(o,"Awaited");put(o,",\"outcome\":");put_awaited_outcome(o,e);put(o,",");put_id(o,"target",e->a);put_task(o,e);break;
    case E_CANCEL_REQUEST:put_kind(o,"CancelRequest");put(o,e->flag?",\"new_request\":true,":",\"new_request\":false,");put_id(o,"target",e->a);put_task(o,e);break;
    case E_CANCEL_EFFECTIVE:put_kind(o,"CancelEffective");put_task(o,e);break;
    case E_YIELD:put_kind(o,"Yield");put_task(o,e);break;
    case E_CHANNEL:put_id(o,"capacity",e->b);put(o,",");put_id(o,"channel",e->a);put(o,",");put_kind(o,"Channel");put_task(o,e);break;
    case E_SEND:put_id(o,"channel",e->a);put(o,",");put_kind(o,"Send");put_task(o,e);put(o,",\"value\":");put_value(o,e->value,0);break;
    case E_CLOSE:put_id(o,"channel",e->a);put(o,e->flag?",\"first\":true,":",\"first\":false,");put_kind(o,"Close");put_task(o,e);break;
    case E_SCOPE_FAILURE:put(o,"\"code\":\"");put(o,trap_name(e->code));put(o,"\",");put_kind(o,"ScopeFailure");put(o,",");put_id(o,"scope",e->a);put_task(o,e);break;
    case E_TERMINATION:put_kind(o,"Termination");put(o,",\"outcome\":");put_outcome(o,e->outcome,e->code,e->value);put_task(o,e);break;
    default:
        if(e->kind<E_SENT || e->kind>E_RECEIVE_REMOVED){o->bad=1;break;}
        put_id(o,"channel",e->a);put(o,",");put_kind(o,channel_kinds[e->kind-E_SENT]);put_task(o,e);
        if(e->kind==E_RECEIVED){put(o,",\"value\":");put_value(o,e->value,0);}
        break;
    }
    put(o,"}");
}
static const char *after_name(int control) {
    switch(control){
    case PC_EVAL:return "Eval";case PC_VALUE:return "Value";case PC_READY:return "Ready";case PC_UNWIND:return "Unwind";
    case PC_ABANDON:return "Abandon";case PC_WAIT:return "Wait";case PC_JOIN:return "Join";case PC_TERMINAL:return "Terminal";
    default:limit=1;return "?";
    }
}

/* ---------- the machine ---------- */

int tk_runnable(uint64_t id) {return id<task_count && tasks[id].status==TS_RUNNABLE;}
uint64_t tk_epoch(void) {return epoch;}
static int any_runnable(void) {for(unsigned i=0;i<task_count;i++)if(tasks[i].status==TS_RUNNABLE)return 1;return 0;}
const char *tk_execution(uint64_t fuel) {
    if(tasks[0].status==TS_TERMINAL)return "Completed";
    if(!any_runnable())return "Deadlock";
    if(epoch>=fuel)return "BudgetExhausted";
    return "Running";
}
int tk_init(const struct pc_program *p,int d,int f) {
    if(pc_init(&tasks[0].m,p,0,0)!=1)return -1;
    program=p;defect=d;fifo=f;limit=0;epoch=0;
    task_count=1;scope_count=0;channel_count=0;await_count=0;
    struct tk_task *root=&tasks[0];
    root->status=TS_RUNNABLE;root->cancel=TC_NONE;root->wait=TW_NONE;root->has_owner=0;root->owner=0;root->outcome=0;root->code=0;root->result=0;
    new_scope(0);
    /* The root's implicit scope 0 is the bottom frame of its continuation. */
    struct pc_machine *m=&root->m;
    const struct pc_env *env=m->env;m->env=0;
    struct pc_frame *fr=push(m,PF_SCOPE,-1,0);if(!fr)return -1;
    fr->next=0;m->env=env;
    queue[0]=0;queue_count=1;switchable=1;has_current=0;current=0;
    return limit?-1:1;
}
static int queued(uint64_t id) {for(unsigned i=0;i<queue_count;i++)if(queue[i]==id)return 1;return 0;}
/* The FIFO production policy's next choice (section 9). */
static int fifo_choice(uint64_t *id) {
    if(!switchable && has_current && tk_runnable(current)){*id=current;return 1;}
    if(!queue_count)return 0;
    if(defect==TK_FIFO_REVERSED){*id=queue[--queue_count];return 1;}
    *id=queue[0];
    for(unsigned i=1;i<queue_count;i++)queue[i-1]=queue[i];
    queue_count--;return 1;
}
/* FIFO bookkeeping after the step of task id. */
static void fifo_after(uint64_t id,int point) {
    unsigned before=queue_count;
    for(unsigned i=0;i<became_count;i++){
        int seen=0;for(unsigned k=0;k<before;k++)if(queue[k]==became[i])seen=1;
        if(!seen){if(queue_count>=TK_TASKS*4u){limit=1;return;}queue[queue_count++]=became[i];}
    }
    switchable=point || !tk_runnable(id);current=id;has_current=1;
    if(switchable && tk_runnable(id) && !queued(id)){if(queue_count>=TK_TASKS*4u){limit=1;return;}queue[queue_count++]=id;}
    unsigned k=0;for(unsigned i=0;i<queue_count;i++)if(tk_runnable(queue[i]))queue[k++]=queue[i];
    queue_count=k;
}
int tk_step(uint64_t id,char *out,size_t cap,size_t *n) {
    if(fifo && !fifo_choice(&id))return -1;
    if(!tk_runnable(id))return fifo?-1:0;
    event_count=0;became_count=0;
    struct site where={-1,0,"?"};int point=1;
    if(step_task(id,&where,&point)!=1 || limit)return -1;
    if(fifo)fifo_after(id,point);
    if(limit)return -1;
    struct out o={out,0,cap,0};
    put(&o,"{\"after\":\"");put(&o,after_name(tasks[id].m.control));put(&o,"\",");
    put_id(&o,"depth",tasks[id].m.depth);put(&o,",");put_id(&o,"epoch",epoch);put(&o,",\"events\":[");
    for(unsigned i=0;i<event_count;i++){if(i)put(&o,",");put_event(&o,&events[i]);}
    put(&o,point?"],\"point\":true,\"runnable\":[":"],\"point\":false,\"runnable\":[");
    int first=1;
    for(unsigned i=0;i<task_count;i++)if(tasks[i].status==TS_RUNNABLE){if(!first)put(&o,",");first=0;put(&o,"\"");put_natural(&o,i);put(&o,"\"");}
    put(&o,"],\"site\":{");
    if(where.machine<0){put_id(&o,"node",where.node);}
    else {put(&o,"\"machine\":\"");put(&o,machine_sites[where.machine]);put(&o,"\"");}
    put(&o,",\"rule\":\"");put(&o,where.rule);put(&o,"\"},");put_id(&o,"task",id);put(&o,"}");
    epoch++;
    if(o.bad || limit)return -1;
    out[o.used]=0;*n=o.used;return 1;
}
size_t tk_wait_graph(char *out,size_t cap) {
    struct out o={out,0,cap,0};
    put(&o,"[");int first=1;
    for(unsigned i=0;i<task_count;i++){
        const struct tk_task *t=&tasks[i];
        if(t->status==TS_TERMINAL)continue;
        if(!first)put(&o,",");
        first=0;put(&o,"{");
        if(t->m.control==PC_WAIT){
            put_id(&o,t->wait==TW_RECEIVE?"receive":t->wait==TW_SEND?"send":"await",t->wait_on);
        } else if(t->m.control==PC_JOIN && t->m.depth){
            put_id(&o,"join",t->m.frames[t->m.depth-1].next);
        } else put(&o,"\"running\":true");
        put(&o,",");put_id(&o,"task",i);put(&o,"}");
    }
    put(&o,"]");
    if(o.bad)return 0;
    out[o.used]=0;return o.used;
}

/* ---------- state digest: FNV-1a 64 over the whole task machine ---------- */

struct digest { uint64_t h; unsigned long budget; };
static void mix(struct digest *d,uint64_t x) {for(int i=0;i<8;i++){d->h^=(uint8_t)(x>>(8*i));d->h*=1099511628211ULL;}}
static void mix_text(struct digest *d,const char *s,unsigned n) {mix(d,n);for(unsigned i=0;i<n;i++){d->h^=(uint8_t)s[i];d->h*=1099511628211ULL;}}
static unsigned text_length(const char *s) {unsigned n=0;while(s && s[n])n++;return n;}
static void mix_env(struct digest *,const struct pc_env *);
static void mix_frames(struct digest *,const struct pc_frame *,unsigned);
static void mix_value(struct digest *d,const struct pc_value *v) {
    if(!d->budget){mix(d,0xbadULL);return;}
    d->budget--;
    if(!v){mix(d,0xffffULL);return;}
    mix(d,(uint64_t)v->tag);mix(d,(uint64_t)v->integer);
    if(v->tag==PV_BYTES)mix_text(d,v->text,v->count);
    if(v->tag==PV_DATA){mix_text(d,v->text,text_length(v->text));mix_text(d,v->constructor,text_length(v->constructor));}
    if(v->tag==PV_TUPLE || v->tag==PV_DATA){mix(d,v->count);for(unsigned i=0;i<v->count;i++)mix_value(d,v->fields[i]);}
    if(v->tag==PV_CLOSURE){mix(d,(uint64_t)(int64_t)v->code);mix_env(d,v->captures);}
    if(v->tag==PV_RESUMPTION){mix_env(d,v->captures);mix(d,v->segment?v->segment->count:0);
        if(v->segment)mix_frames(d,v->segment->frames,v->segment->count);}
}
static void mix_env(struct digest *d,const struct pc_env *e) {
    for(;e && d->budget;e=e->parent){d->budget--;mix(d,e->id);mix_value(d,e->value);}
    mix(d,0xe0dULL);
}
static void mix_frames(struct digest *d,const struct pc_frame *f,unsigned count) {
    for(unsigned i=0;i<count && d->budget;i++){
        d->budget--;
        mix(d,(uint64_t)f[i].kind);mix(d,(uint64_t)(int64_t)f[i].node);mix(d,(uint64_t)f[i].tail);mix(d,f[i].next);
        mix_env(d,f[i].env);
        if(f[i].kind==PF_COLLECT){
            unsigned c=program->nodes[f[i].node].child_count;
            for(unsigned k=0;k<f[i].next && k<c;k++)mix_value(d,f[i].values[k]);
        }
        if(f[i].kind==PF_CLAUSE && f[i].segment){mix(d,f[i].segment->count);mix_frames(d,f[i].segment->frames,f[i].segment->count);}
    }
}
static void mix_machine(struct digest *d,const struct pc_machine *m) {
    mix(d,(uint64_t)m->control);mix(d,(uint64_t)(int64_t)m->node);mix(d,(uint64_t)m->tail);mix(d,(uint64_t)m->trap);mix(d,m->depth);
    if(m->control==PC_VALUE || m->control==PC_START || m->control==PC_PENDING)mix_value(d,m->value);
    if(m->control==PC_READY){unsigned c=program->nodes[m->node].child_count;mix(d,c);for(unsigned i=0;i<c;i++)mix_value(d,m->ready[i]);}
    mix_env(d,m->env);mix_frames(d,m->frames,m->depth);
}
void tk_digest(char *hex) {
    struct digest d={14695981039346656037ULL,1u<<20};
    mix(&d,epoch);mix(&d,task_count);mix(&d,scope_count);mix(&d,channel_count);
    for(unsigned i=0;i<task_count;i++){
        const struct tk_task *t=&tasks[i];
        mix(&d,(uint64_t)t->status);mix(&d,(uint64_t)t->cancel);mix(&d,(uint64_t)t->wait);mix(&d,t->wait_on);
        mix(&d,(uint64_t)t->has_owner);mix(&d,t->owner);
        if(t->status==TS_TERMINAL){mix(&d,(uint64_t)t->outcome);mix(&d,(uint64_t)t->code);mix_value(&d,t->result);}
        else mix_machine(&d,&t->m);
    }
    for(unsigned i=0;i<scope_count;i++){
        const struct tk_scope *s=&scopes[i];
        mix(&d,s->owner);mix(&d,(uint64_t)s->phase);mix(&d,(uint64_t)s->reason);mix(&d,(uint64_t)s->code);
        if(s->reason==SR_NORMAL)mix_value(&d,s->value);
        mix(&d,s->child_count);for(unsigned k=0;k<s->child_count;k++)mix(&d,s->children[k]);
        mix(&d,(uint64_t)s->failed);mix(&d,s->failure_count);
        for(unsigned k=0;k<s->failure_count;k++){mix(&d,s->failed_task[k]);mix(&d,(uint64_t)s->failed_code[k]);}
        mix(&d,(uint64_t)s->join_waiting);
    }
    for(unsigned i=0;i<channel_count;i++){
        const struct tk_channel *c=&channels[i];
        mix(&d,c->capacity);mix(&d,(uint64_t)c->closed);mix(&d,c->count);for(unsigned k=0;k<c->count;k++)mix_value(&d,c->queue[k]);
        mix(&d,c->sender_count);for(unsigned k=0;k<c->sender_count;k++){mix(&d,c->senders[k].task);mix_value(&d,c->senders[k].value);}
        mix(&d,c->receiver_count);for(unsigned k=0;k<c->receiver_count;k++)mix(&d,c->receivers[k]);
    }
    mix(&d,await_count);for(unsigned i=0;i<await_count;i++){mix(&d,await_waiter[i]);mix(&d,await_target[i]);}
    if(fifo){mix(&d,queue_count);for(unsigned i=0;i<queue_count;i++)mix(&d,queue[i]);mix(&d,(uint64_t)switchable);mix(&d,(uint64_t)has_current);mix(&d,current);}
    mix(&d,d.budget?1:0);
    for(int i=15;i>=0;i--){unsigned x=(unsigned)(d.h&15u);hex[i]=(char)(x<10?'0'+x:'a'+x-10);d.h>>=4;}
    hex[16]=0;
}
