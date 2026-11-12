/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Independent TC0-A pure-call candidate. See machine.h. */
#include "machine.h"
#define PC_ARENA_BYTES (4u*1024u*1024u)
static _Alignas(16) unsigned char arena[PC_ARENA_BYTES];
static size_t arena_used;
static void *take(size_t bytes) {
    size_t rounded=(bytes+15u)&~(size_t)15u;
    if(rounded<bytes || rounded>PC_ARENA_BYTES-arena_used)return 0;
    void *p=arena+arena_used;arena_used+=rounded;return p;
}
static int same(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}
static struct pc_value *fresh(int tag) {
    struct pc_value *v=take(sizeof *v);if(!v)return 0;
    v->tag=tag;v->integer=0;v->text=0;v->constructor=0;v->count=0;v->fields=0;v->code=-1;v->captures=0;
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
int pc_init(struct pc_machine *m,const struct pc_program *p,int reverse,int wrap) {
    if(!m || !p || !p->node_count || p->entry>=p->function_count)return -1;
    arena_used=0;
    const struct pc_function *entry=&p->functions[p->entry];
    if(entry->body<0 || (unsigned)entry->body>=p->node_count)return -1;
    if(p->input_tag!=PV_UNIT && p->input_tag!=PV_BOOL && p->input_tag!=PV_INT)return -1;
    const struct pc_value *input=scalar(p->input_tag,p->input_integer);if(!input)return -1;
    m->program=p;m->control=PC_EVAL;m->node=entry->body;m->tail=1;m->trap=PC_NO_TRAP;
    m->reverse_operands=reverse;m->wrap_overflow=wrap;m->value=0;m->depth=0;m->epoch=0;
    m->env=bind(entry->parameter,input,0);
    return m->env?1:-1;
}
static void site(const struct pc_machine *m,struct pc_sample *s) {
    static const int returns[]={PR_LET_RETURN,PR_IF_RETURN,PR_MATCH_RETURN,PR_RETURN_RETURN,PR_COLLECT_RETURN};
    const struct pc_node *nodes=m->program->nodes;
    s->machine_site=-1;s->node=0;
    if(m->control==PC_EVAL){s->node=nodes[m->node].id;s->rule=PR_DISPATCH;}
    else if(m->control==PC_READY){s->node=nodes[m->node].id;s->rule=PR_READY;}
    else if((m->control==PC_VALUE || m->control==PC_UNWIND) && m->depth){
        const struct pc_frame *f=&m->frames[m->depth-1];
        s->node=nodes[f->node].id;s->rule=m->control==PC_VALUE?returns[f->kind]:PR_UNWIND_FRAME;
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
    f->kind=kind;f->node=node;f->tail=tail;f->env=m->env;f->next=0;return f;
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
    switch(n->tag){
    case PC_EMIT: {
        const struct pc_value *unit=scalar(PV_UNIT,0);if(!unit)return -1;
        s->events[0]=(struct pc_event){PE_INVOKE,n->id,n->text,v[0],0};
        s->events[1]=(struct pc_event){PE_EMIT,n->id,n->text,v[0],0};
        s->events[2]=(struct pc_event){PE_COMMIT,n->id,n->text,unit,0};
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
    if(!m || !s || m->control==PC_TERMINAL)return -1;
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
            } /* PF_RETURN: caller environment restored; the value propagates. */
        }
    } else if(m->control==PC_READY){
        if(ready(m,s)!=1)return -1;
    } else if(m->control==PC_UNWIND){
        if(m->depth)m->env=m->frames[--m->depth].env;
        else m->control=PC_JOIN;
    } else if(m->control==PC_JOIN){
        s->events[0]=(struct pc_event){PE_SCOPE_EXIT,0,0,m->trap?0:m->value,m->trap};
        s->event_count=1;m->control=PC_TERMINATE;
    } else {
        s->events[0]=(struct pc_event){PE_TASK_TERMINATION,0,0,m->trap?0:m->value,m->trap};
        s->event_count=1;m->control=PC_TERMINAL;
    }
    s->after=m->control;s->depth=m->depth;m->epoch++;
    return 1;
}
