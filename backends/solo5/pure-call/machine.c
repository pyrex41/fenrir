/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Independent TC0-A pure-call candidate. See machine.h. */
#include "machine.h"
#define PC_ARENA_BYTES (4u*1024u*1024u)
static _Alignas(16) unsigned char arena[PC_ARENA_BYTES];
static size_t arena_used;
static int arena_exhausted;
static void *take(size_t bytes) {
    size_t rounded=(bytes+15u)&~(size_t)15u;
    if(rounded<bytes || rounded>PC_ARENA_BYTES-arena_used){arena_exhausted=1;return 0;}
    void *p=arena+arena_used;arena_used+=rounded;return p;
}
static int same(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}
static struct pc_value *fresh(int tag) {
    struct pc_value *v=take(sizeof *v);if(!v)return 0;
    v->tag=tag;v->integer=0;v->text=0;v->constructor=0;v->count=0;v->fields=0;v->code=-1;v->captures=0;v->segment=0;
    return v;
}
static const struct pc_value *scalar(int tag,int64_t n) {
    struct pc_value *v=fresh(tag);if(v)v->integer=n;return v;
}
static const struct pc_env *bind(uint64_t id,const struct pc_value *value,const struct pc_env *parent) {
    struct pc_env *e=take(sizeof *e);if(!e)return 0;
    e->id=id;e->value=value;e->parent=parent;return e;
}
static const struct pc_value *lookup(const struct pc_env *e,uint64_t id) {
    for(;e;e=e->parent)if(e->id==id)return e->value;
    return 0;
}
static const struct pc_value *aggregate(int tag,const struct pc_value *const *values,unsigned count) {
    struct pc_value *v=fresh(tag);if(!v)return 0;
    if(count){
        const struct pc_value **fields=take(count*sizeof *fields);if(!fields)return 0;
        for(unsigned i=0;i<count;i++)fields[i]=values[i];
        v->fields=fields;
    }
    v->count=count;return v;
}
/* Structural equality on checked equality-compatible values (no closures). */
static int equal(const struct pc_value *a,const struct pc_value *b) {
    if(a->tag!=b->tag)return 0;
    switch(a->tag){
    case PV_UNIT:return 1;
    case PV_BOOL:case PV_INT:return a->integer==b->integer;
    case PV_BYTES:
        if(a->count!=b->count)return 0;
        for(unsigned i=0;i<a->count;i++)if(a->text[i]!=b->text[i])return 0;
        return 1;
    case PV_DATA:
        if(!same(a->text,b->text) || !same(a->constructor,b->constructor))return 0;
        /* fall through */
    case PV_TUPLE:
        if(a->count!=b->count)return 0;
        for(unsigned i=0;i<a->count;i++)if(!equal(a->fields[i],b->fields[i]))return 0;
        return 1;
    default:return 0;
    }
}
/* ---------- TC1-D1: canonical JSON values, checked against a type descriptor ----------
 * The value encoding of the artifact, in its one canonical spelling (no white space;
 * I64 a canonical decimal in range; bytes lowercase hex). Type-directed: a datatype
 * value must name the datatype of its descriptor and one of its constructors with
 * exactly that constructor's fields. Used for the entry input and for host replies. */
struct reader { const char *at,*end; const struct pc_program *program; unsigned depth; };
static int expect(struct reader *r,const char *s) {
    const char *p=r->at;
    while(*s){if(p>=r->end || *p!=*s)return 0;p++;s++;}
    r->at=p;return 1;
}
static int hex_digit(char c) {return (c>='0'&&c<='9')||(c>='a'&&c<='f');}
static int quoted(struct reader *r,const char *want) {
    return expect(r,"\"") && expect(r,want) && expect(r,"\"");
}
static int read_i64(struct reader *r,int64_t *out) {
    const char *p=r->at;int negative=0;uint64_t n=0;unsigned digits=0;
    if(p<r->end && *p=='-'){negative=1;p++;}
    if(p>=r->end || *p<'0' || *p>'9')return 0;
    if(*p=='0' && (negative || (p+1<r->end && p[1]>='0' && p[1]<='9')))return 0; /* -0, leading zero */
    while(p<r->end && *p>='0' && *p<='9'){
        if(++digits>19)return 0;
        uint64_t d=(uint64_t)(*p-'0');
        if(n>(UINT64_MAX-d)/10)return 0;
        n=n*10+d;p++;
    }
    if(negative?n>((uint64_t)1<<63):n>((uint64_t)1<<63)-1)return 0;
    *out=negative?(n==((uint64_t)1<<63)?INT64_MIN:-(int64_t)n):(int64_t)n;
    r->at=p;return 1;
}
static const char *const trap_names[]={"Overflow","DivZero","Bounds","InvalidDuration","TaskLimit","ChildFailed"};
static const struct pc_value *read_value(struct reader *r,const char **type) {
    const char *t=*type;
    if(++r->depth>65 || !*t)return 0; /* validator depth 0..64, counting from the root */
    const struct pc_value *result=0;
    switch(*t){
    case 'U':*type=t+1;if(expect(r,"[\"unit\"]"))result=scalar(PV_UNIT,0);break;
    case 'B':*type=t+1;
        if(expect(r,"[\"bool\",true]"))result=scalar(PV_BOOL,1);
        else if(expect(r,"[\"bool\",false]"))result=scalar(PV_BOOL,0);
        break;
    case 'I': {
        int64_t n;*type=t+1;
        if(expect(r,"[\"int\",\"") && read_i64(r,&n) && expect(r,"\"]"))result=scalar(PV_INT,n);
        break; }
    case 'Y': {
        *type=t+1;
        if(!expect(r,"[\"bytes\",\""))break;
        const char *start=r->at;unsigned count=0;
        while(r->at<r->end && hex_digit(*r->at)){r->at++;count++;}
        if(count%2 || !expect(r,"\"]"))break;
        struct pc_value *b=fresh(PV_BYTES);char *text=take(count?count:1);if(!b || !text)break;
        for(unsigned i=0;i<count;i++)text[i]=start[i];
        b->text=text;b->count=count;result=b;break; }
    case 'K': {
        *type=t+1;
        if(!expect(r,"[\"data\",\"TrapCode\",\""))break;
        for(unsigned i=0;i<6 && !result;i++){
            struct reader saved=*r;
            if(expect(r,trap_names[i]) && expect(r,"\"]")){
                struct pc_value *d=(struct pc_value *)aggregate(PV_DATA,0,0);
                if(d){d->text="TrapCode";d->constructor=trap_names[i];}
                result=d;
            } else *r=saved;
        }
        break; }
    case 'T': {
        unsigned n=(unsigned)(t[1]-'0');*type=t+2;
        if(n<1 || n>8 || !expect(r,"[\"tuple\""))break;
        const struct pc_value *fields[8];unsigned k=0;
        for(;k<n;k++){if(!expect(r,",") || !(fields[k]=read_value(r,type)))break;}
        if(k==n && expect(r,"]"))result=aggregate(PV_TUPLE,fields,n);
        break; }
    case 'D': {
        unsigned index=0;t++;
        while(*t>='0' && *t<='9')index=index*10+(unsigned)(*t++-'0');
        if(*t!=';')break;
        *type=t+1;
        const struct pc_program *p=r->program;
        if(index>=p->datatype_count)break;
        const struct pc_datatype *d=&p->datatypes[index];
        if(!expect(r,"[\"data\",") || !quoted(r,d->name) || !expect(r,",\""))break;
        const struct pc_constructor *c=0;
        for(unsigned i=0;i<d->constructor_count && !c;i++){
            struct reader saved=*r;
            if(expect(r,d->constructors[i].name) && expect(r,"\""))c=&d->constructors[i];
            else *r=saved;
        }
        if(!c || c->field_count>PC_MAX_OPERANDS)break;
        const struct pc_value *fields[PC_MAX_OPERANDS];unsigned k=0;
        for(;k<c->field_count;k++){
            const char *ft=c->fields[k];
            if(!expect(r,",") || !(fields[k]=read_value(r,&ft)) || *ft)break;
        }
        if(k!=c->field_count || !expect(r,"]"))break;
        struct pc_value *v=(struct pc_value *)aggregate(PV_DATA,fields,k);
        if(v){v->text=d->name;v->constructor=c->name;}
        result=v;break; }
    default:break;
    }
    r->depth--;
    return result;
}
/* The whole of text[0..n) as one value of the descriptor's type, or 0. */
static const struct pc_value *parse_value(const struct pc_program *p,const char *text,size_t n,const char *type) {
    struct reader r={text,text+n,p,0};const char *t=type;
    if(!type)return 0;
    const struct pc_value *v=read_value(&r,&t);
    return v && !*t && r.at==r.end?v:0;
}
int pc_host_wait(const struct pc_machine *m) {return m && m->control==PC_HOSTWAIT;}
int pc_init(struct pc_machine *m,const struct pc_program *p,int reverse,int wrap) {
    if(!m || !p || !p->node_count || p->entry>=p->function_count)return -1;
    arena_used=0;arena_exhausted=0;
    const struct pc_function *entry=&p->functions[p->entry];
    if(entry->body<0 || (unsigned)entry->body>=p->node_count)return -1;
    const struct pc_value *input=0;
    if(p->input_tag==PC_INPUT_VALUE){
        unsigned n=0;
        if(!p->input_value)return -1;
        while(p->input_value[n])n++;
        input=parse_value(p,p->input_value,n,p->input_type);
    } else {
        if(p->input_tag!=PV_UNIT && p->input_tag!=PV_BOOL && p->input_tag!=PV_INT)return -1;
        input=scalar(p->input_tag,p->input_integer);
    }
    if(!input)return -1;
    m->program=p;m->control=PC_EVAL;m->node=entry->body;m->tail=1;m->trap=PC_NO_TRAP;m->requests=0;
    m->reverse_operands=reverse;m->wrap_overflow=wrap;m->value=0;m->depth=0;m->epoch=0;
    m->env=bind(entry->parameter,input,0);
    return m->env?1:-1;
}
int pc_start(struct pc_machine *m,const struct pc_program *p,unsigned function,const struct pc_value *input) {
    if(!m || !p || !p->node_count || function>=p->function_count || !input)return -1;
    arena_used=0;arena_exhausted=0;
    const struct pc_function *entry=&p->functions[function];
    if(entry->body<0 || (unsigned)entry->body>=p->node_count)return -1;
    m->program=p;m->control=PC_EVAL;m->node=entry->body;m->tail=1;m->trap=PC_NO_TRAP;m->requests=0;
    m->reverse_operands=0;m->wrap_overflow=0;m->value=0;m->depth=0;m->epoch=0;
    m->env=bind(entry->parameter,input,0);
    return m->env?1:-1;
}
const struct pc_value *pc_scalar(int tag,int64_t integer) {
    if(tag!=PV_UNIT && tag!=PV_BOOL && tag!=PV_INT)return 0;
    return scalar(tag,integer);
}
static void site(const struct pc_machine *m,struct pc_sample *s) {
    static const int returns[]={PR_LET_RETURN,PR_IF_RETURN,PR_MATCH_RETURN,PR_RETURN_RETURN,PR_COLLECT_RETURN,
                                PR_HANDLE_RETURN,PR_CLAUSE_RETURN,PR_CLAUSE_EXIT_RETURN,PR_RESUME_RETURN,PR_DISCONTINUE_RETURN};
    const struct pc_node *nodes=m->program->nodes;
    s->machine_site=-1;s->node=0;
    if(m->control==PC_EVAL){s->node=nodes[m->node].id;s->rule=PR_DISPATCH;}
    else if(m->control==PC_READY){s->node=nodes[m->node].id;s->rule=PR_READY;}
    else if((m->control==PC_VALUE || m->control==PC_UNWIND) && m->depth){
        const struct pc_frame *f=&m->frames[m->depth-1];
        s->node=nodes[f->node].id;s->rule=m->control==PC_VALUE?returns[f->kind]:PR_UNWIND_FRAME;
    } else if(m->control==PC_ABANDON && m->depth){
        const struct pc_frame *f=&m->frames[m->depth-1];
        s->node=nodes[f->node].id;s->rule=f->kind==PF_DISCONTINUE?PR_DISCONTINUE_RETURN:PR_ABANDON_FRAME;
    } else if(m->control==PC_VALUE){s->machine_site=PS_ROOT_JOIN_ENTRY;s->rule=PR_VALUE;}
    else if(m->control==PC_UNWIND){s->machine_site=PS_ROOT_JOIN_ENTRY;s->rule=PR_UNWIND;}
    else if(m->control==PC_JOIN){s->machine_site=PS_JOIN;s->rule=PR_JOIN;}
    else {s->machine_site=PS_TERMINATE;s->rule=PR_TERMINATE;}
}
static void produce(struct pc_machine *m,const struct pc_value *v) {m->control=PC_VALUE;m->value=v;}
static void enter(struct pc_machine *m,int node,int tail) {m->control=PC_EVAL;m->node=node;m->tail=tail;}
static void trap(struct pc_machine *m,int code) {m->control=PC_UNWIND;m->trap=code;}
static struct pc_frame *push(struct pc_machine *m,int kind,int node,int tail) {
    if(m->depth>=PC_MAX_FRAMES)return 0;
    struct pc_frame *f=&m->frames[m->depth++];
    f->kind=kind;f->node=node;f->tail=tail;f->env=m->env;f->next=0;f->segment=0;return f;
}
/* TC1: copy the frames from index `at` to the top into the arena and remove them. */
static const struct pc_segment *suspend(struct pc_machine *m,unsigned at) {
    struct pc_segment *seg=take(sizeof *seg);if(!seg)return 0;
    unsigned count=m->depth-at;
    struct pc_frame *frames=take(count*sizeof *frames);if(!frames)return 0;
    for(unsigned i=0;i<count;i++)frames[i]=m->frames[at+i];
    seg->count=count;seg->frames=frames;m->depth=at;return seg;
}
/* TC1: put a suspended segment back on top of the frames. */
static int restore(struct pc_machine *m,const struct pc_segment *seg) {
    if(!seg || seg->count>PC_MAX_FRAMES-m->depth)return 0;
    for(unsigned i=0;i<seg->count;i++)m->frames[m->depth++]=seg->frames[i];
    return 1;
}
/* TC1: select the innermost active handler for the effect and enter its clause. */
static int perform(struct pc_machine *m,const struct pc_node *n,const struct pc_value *argument,struct pc_sample *s) {
    const struct pc_program *p=m->program;int at=-1;
    for(int i=(int)m->depth-1;i>=0 && at<0;i--)
        if(m->frames[i].kind==PF_HANDLE && same(p->nodes[m->frames[i].node].text,n->text))at=i;
    if(at<0 && n->integer==1){
        /* TC1-D1: a durable effect with no active handler is a host request. The machine
         * stops in HostWait with everything else unchanged; the argument stays live. */
        s->events[0]=(struct pc_event){PE_HOST_REQUEST,n->id,n->text,argument,0,n->text2,m->requests};
        s->event_count=1;m->requests++;m->value=argument;m->control=PC_HOSTWAIT;return 1;
    }
    if(at<0)return -1; /* an unhandled effect in a validated program is a defect, not a trap */
    const struct pc_node *handler=&p->nodes[m->frames[at].node];const struct pc_env *definition=m->frames[at].env;
    const struct pc_arm *clause=0;
    for(unsigned i=0;i<handler->arm_count && !clause;i++)if(same(handler->arms[i].constructor,n->text2))clause=&handler->arms[i];
    if(!clause || clause->binder_count<1 || clause->binder_count>2)return -1;
    const struct pc_env *site=m->env;
    const struct pc_segment *segment=suspend(m,(unsigned)at);if(!segment)return -1;
    const struct pc_env *env=bind(clause->binders[0],argument,definition);if(!env)return -1;
    if(clause->binder_count==2){
        /* Explicit resumption: the clause owns the segment as the value of k, and its own
         * value becomes the value of the handle. */
        struct pc_value *k=fresh(PV_RESUMPTION);if(!k)return -1;
        k->segment=segment;k->captures=site;
        struct pc_frame *f=push(m,PF_CLAUSE_EXIT,m->node,0);if(!f)return -1;
        f->env=definition;
        env=bind(clause->binders[1],k,env);if(!env)return -1;
    } else {
        struct pc_frame *f=push(m,PF_CLAUSE,m->node,0);if(!f)return -1;
        f->segment=segment; /* f->env is the perform site's environment, restored on resume */
    }
    m->env=env;enter(m,clause->body,1);return 1;
}
/* k-th operand to evaluate: grammar order, or reversed for the injected defect. */
static unsigned operand(const struct pc_machine *m,const struct pc_node *n,unsigned k) {
    return m->reverse_operands?n->child_count-1-k:k;
}
static int hex(char c) {return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;}
static int arithmetic(struct pc_machine *m,int op,int64_t a,int64_t b) {
    int64_t n=0;int overflow=0;
    switch(op){
    case PC_ADD:overflow=__builtin_add_overflow(a,b,&n);break;
    case PC_SUB:overflow=__builtin_sub_overflow(a,b,&n);break;
    case PC_MUL:overflow=__builtin_mul_overflow(a,b,&n);break;
    case PC_NEG:overflow=__builtin_sub_overflow((int64_t)0,a,&n);break;
    case PC_DIV:
        if(b==0){trap(m,PC_DIVZERO);return 1;}
        if(a==INT64_MIN && b==-1){overflow=1;n=INT64_MIN;} else n=a/b; /* C99: toward zero */
        break;
    case PC_LT:case PC_LE:case PC_GT:case PC_GE: {
        int r=op==PC_LT?a<b:op==PC_LE?a<=b:op==PC_GT?a>b:a>=b;
        const struct pc_value *v=scalar(PV_BOOL,r);if(!v)return -1;
        produce(m,v);return 1; }
    default:return -1;
    }
    if(overflow && !m->wrap_overflow){trap(m,PC_OVERFLOW);return 1;}
    const struct pc_value *v=scalar(PV_INT,n);if(!v)return -1;
    produce(m,v);return 1;
}
static int ready(struct pc_machine *m,struct pc_sample *s) {
    const struct pc_program *p=m->program;const struct pc_node *n=&p->nodes[m->node];
    const struct pc_value *const *v=m->ready;const struct pc_value *r=0;
    if(n->tag==PC_CALL || n->tag==PC_APPLY){
        uint64_t parameter;int body;const struct pc_env *captures=0;const struct pc_value *argument;
        if(n->tag==PC_CALL){
            if(n->index>=p->function_count)return -1;
            parameter=p->functions[n->index].parameter;body=p->functions[n->index].body;argument=v[0];
        } else {
            if(v[0]->tag!=PV_CLOSURE || v[0]->code<0 || (unsigned)v[0]->code>=p->node_count)return -1;
            const struct pc_node *code=&p->nodes[v[0]->code];
            if(code->tag!=PC_LAMBDA || code->child_count!=1)return -1;
            parameter=code->binding;body=code->children[0];captures=v[0]->captures;argument=v[1];
        }
        if(!m->tail && !push(m,PF_RETURN,m->node,0))return -1;
        m->env=bind(parameter,argument,captures);if(!m->env)return -1;
        enter(m,body,1);return 1;
    }
    if(n->tag==PC_PERFORM)return perform(m,n,v[0],s);
    if(n->tag==PC_RESUME || n->tag==PC_DISCONTINUE){
        const struct pc_value *k=lookup(m->env,n->binding);
        if(!k || k->tag!=PV_RESUMPTION)return -1;
        if(n->tag==PC_RESUME){
            /* In tail position the resumed body's value goes straight to the frame below. */
            if(!m->tail && !push(m,PF_RESUME,m->node,0))return -1;
            if(!restore(m,k->segment))return -1;
            m->env=k->captures;produce(m,v[0]);return 1;
        }
        /* Expose the segment above a marker; the abandon phase discards it frame by frame. */
        if(!push(m,PF_DISCONTINUE,m->node,0) || !restore(m,k->segment))return -1;
        m->control=PC_ABANDON;return 1;
    }
    switch(n->tag){
    case PC_EMIT: {
        const struct pc_value *unit=scalar(PV_UNIT,0);if(!unit)return -1;
        s->events[0]=(struct pc_event){PE_INVOKE,n->id,n->text,v[0],0,0,0};
        s->events[1]=(struct pc_event){PE_EMIT,n->id,n->text,v[0],0,0,0};
        s->events[2]=(struct pc_event){PE_COMMIT,n->id,n->text,unit,0,0,0};
        s->event_count=3;produce(m,unit);return 1; }
    case PC_TUPLE:r=aggregate(PV_TUPLE,v,n->child_count);break;
    case PC_CONSTRUCT: {
        struct pc_value *d=(struct pc_value *)aggregate(PV_DATA,v,n->child_count);
        if(d){d->text=n->text;d->constructor=n->text2;}
        r=d;break; }
    case PC_PROJECT:
        if(v[0]->tag!=PV_TUPLE || n->index>=v[0]->count)return -1;
        r=v[0]->fields[n->index];break;
    case PC_PRIM:
        switch(n->op){
        case PC_NOT:r=scalar(PV_BOOL,!v[0]->integer);break;
        case PC_EQ:r=scalar(PV_BOOL,equal(v[0],v[1]));break;
        case PC_BYTES_LENGTH:r=scalar(PV_INT,(int64_t)(v[0]->count/2));break;
        case PC_BYTES_CONCAT: {
            struct pc_value *b=fresh(PV_BYTES);if(!b)return -1;
            unsigned total=v[0]->count+v[1]->count;
            char *text=take(total?total:1);if(!text)return -1;
            for(unsigned i=0;i<v[0]->count;i++)text[i]=v[0]->text[i];
            for(unsigned i=0;i<v[1]->count;i++)text[v[0]->count+i]=v[1]->text[i];
            b->text=text;b->count=total;r=b;break; }
        case PC_BYTES_INDEX: {
            int64_t i=v[1]->integer;
            if(i<0 || (uint64_t)i>=(uint64_t)(v[0]->count/2)){trap(m,PC_BOUNDS);return 1;}
            int high=hex(v[0]->text[2*i]),low=hex(v[0]->text[2*i+1]);
            if(high<0 || low<0)return -1;
            r=scalar(PV_INT,high*16+low);break; }
        case PC_NEG:return arithmetic(m,n->op,v[0]->integer,0);
        default:return arithmetic(m,n->op,v[0]->integer,v[1]->integer);
        }
        break;
    default:return -1;
    }
    if(!r)return -1;
    produce(m,r);return 1;
}
int pc_step(struct pc_machine *m,struct pc_sample *s) {
    if(!m || !s || m->control==PC_TERMINAL || m->control==PC_HOSTWAIT)return -1;
    const struct pc_program *p=m->program;
    s->epoch=m->epoch;s->event_count=0;site(m,s);
    if(m->control==PC_EVAL){
        if(m->node<0 || (unsigned)m->node>=p->node_count)return -1;
        const struct pc_node *n=&p->nodes[m->node];const struct pc_value *v=0;
        switch(n->tag){
        case PC_UNIT:v=scalar(PV_UNIT,0);break;
        case PC_BOOL:v=scalar(PV_BOOL,n->integer);break;
        case PC_INT:v=scalar(PV_INT,n->integer);break;
        case PC_BYTES: {
            struct pc_value *b=fresh(PV_BYTES);
            if(b){b->text=n->text;while(n->text[b->count])b->count++;}
            v=b;break; }
        case PC_VAR:v=lookup(m->env,n->binding);break;
        case PC_LAMBDA: {
            struct pc_value *c=fresh(PV_CLOSURE);if(!c)return -1;
            c->code=m->node;
            for(unsigned i=0;i<n->free_count;i++){
                const struct pc_value *captured=lookup(m->env,n->free[i]);if(!captured)return -1;
                c->captures=bind(n->free[i],captured,c->captures);if(!c->captures)return -1;
            }
            v=c;break; }
        case PC_HANDLE:
            /* The handler frame is the body's return destination. */
            if(n->child_count!=1 || !push(m,PF_HANDLE,m->node,0))return -1;
            enter(m,n->children[0],1);break;
        case PC_LET:case PC_IF:case PC_MATCH:
            if(!n->child_count || !push(m,n->tag==PC_LET?PF_LET:n->tag==PC_IF?PF_IF:PF_MATCH,m->node,m->tail))return -1;
            enter(m,n->children[0],0);break;
        default:
            if(n->child_count>PC_MAX_OPERANDS)return -1;
            if(n->child_count){
                int node=m->node;
                if(!push(m,PF_COLLECT,node,m->tail))return -1;
                enter(m,n->children[operand(m,n,0)],0);
            } else m->control=PC_READY;
        }
        if(n->tag<=PC_VAR || n->tag==PC_LAMBDA){if(!v)return -1;produce(m,v);}
    } else if(m->control==PC_VALUE){
        if(!m->depth)m->control=PC_JOIN;
        else {
            struct pc_frame *f=&m->frames[--m->depth];const struct pc_node *n=&p->nodes[f->node];
            m->env=f->env;
            if(f->kind==PF_LET){
                m->env=bind(n->binding,m->value,m->env);if(!m->env)return -1;
                enter(m,n->children[1],f->tail);
            } else if(f->kind==PF_IF)enter(m,n->children[m->value->integer?1:2],f->tail);
            else if(f->kind==PF_MATCH){
                const struct pc_arm *arm=0;
                if(m->value->tag!=PV_DATA)return -1;
                for(unsigned i=0;i<n->arm_count && !arm;i++)if(same(n->arms[i].constructor,m->value->constructor))arm=&n->arms[i];
                if(!arm || arm->binder_count!=m->value->count)return -1;
                for(unsigned i=0;i<arm->binder_count;i++){
                    m->env=bind(arm->binders[i],m->value->fields[i],m->env);if(!m->env)return -1;
                }
                enter(m,arm->body,f->tail);
            } else if(f->kind==PF_COLLECT){
                f->values[operand(m,n,f->next)]=m->value;f->next++;
                if(f->next<n->child_count){m->depth++;enter(m,n->children[operand(m,n,f->next)],0);}
                else {
                    for(unsigned i=0;i<n->child_count;i++)m->ready[i]=f->values[i];
                    m->control=PC_READY;m->node=f->node;m->tail=f->tail;
                }
            } else if(f->kind==PF_CLAUSE){
                /* The clause returned: restore the suspended segment; the perform site gets the value. */
                const struct pc_segment *segment=f->segment;
                if(!restore(m,segment))return -1;
            } /* PF_RETURN, PF_HANDLE, PF_CLAUSE_EXIT, PF_RESUME: environment restored; the value propagates. */
        }
    } else if(m->control==PC_READY){
        if(ready(m,s)!=1)return -1;
    } else if(m->control==PC_UNWIND){
        if(m->depth){
            /* One frame per step. A clause frame gives back its suspended segment to be unwound next. */
            const struct pc_frame f=m->frames[--m->depth];
            if(f.kind==PF_CLAUSE && !restore(m,f.segment))return -1;
            m->env=f.env;
        } else m->control=PC_JOIN;
    } else if(m->control==PC_ABANDON){
        if(!m->depth)return -1;
        const struct pc_frame f=m->frames[--m->depth];
        if(f.kind==PF_CLAUSE && !restore(m,f.segment))return -1;
        m->env=f.env;
        if(f.kind==PF_DISCONTINUE){
            const struct pc_value *unit=scalar(PV_UNIT,0);if(!unit)return -1;
            produce(m,unit);
        }
    } else if(m->control==PC_JOIN){
        s->events[0]=(struct pc_event){PE_SCOPE_EXIT,0,0,m->trap?0:m->value,m->trap,0,0};
        s->event_count=1;m->control=PC_TERMINATE;
    } else {
        s->events[0]=(struct pc_event){PE_TASK_TERMINATION,0,0,m->trap?0:m->value,m->trap,0,0};
        s->event_count=1;m->control=PC_TERMINAL;
    }
    s->after=m->control;s->depth=m->depth;m->epoch++;
    return 1;
}
/* TC1-D1: the host's reply to the pending request (DURABLE.md section 4). */
int pc_reply(struct pc_machine *m,const char *text,size_t n,struct pc_sample *s) {
    if(!m || !s || m->control!=PC_HOSTWAIT)return -1;
    const struct pc_node *node=&m->program->nodes[m->node];
    size_t used=arena_used;arena_exhausted=0;
    const struct pc_value *v=parse_value(m->program,text,n,node->type);
    if(!v){arena_used=used;return arena_exhausted?-1:0;}
    s->epoch=m->epoch;s->machine_site=-1;s->node=node->id;s->rule=PR_HOST_REPLY;
    s->events[0]=(struct pc_event){PE_HOST_REPLY,node->id,0,v,0,0,m->requests-1};
    s->event_count=1;produce(m,v);
    s->after=m->control;s->depth=m->depth;m->epoch++;
    return 1;
}
