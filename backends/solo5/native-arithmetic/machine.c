/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#include "machine.h"
int na_pure(int op,const struct na_value *v,unsigned count,struct na_value *out,int *trap) {
    if (!v || !out || !trap || op<NA_ADD || op>NA_NOT) return -1;
    unsigned arity=(op==NA_NEG || op==NA_NOT)?1:2;
    if(count!=arity) return -1;
    *trap=NA_NO_TRAP;
    if(op==NA_NOT) {
        if(v[0].tag!=1 || (v[0].integer!=0 && v[0].integer!=1)) return -1;
        *out=(struct na_value){1,!v[0].integer}; return 1;
    }
    for(unsigned i=0;i<count;i++) if(v[i].tag!=2) return -1;
    int64_t a=v[0].integer,b=count==2?v[1].integer:0;
    if(op>=NA_LT && op<=NA_GE) {
        int r=op==NA_LT?a<b:op==NA_LE?a<=b:op==NA_GT?a>b:a>=b;
        *out=(struct na_value){1,r}; return 1;
    }
    __int128 wide;
    switch(op) {
    case NA_ADD: wide=(__int128)a+b; break;
    case NA_SUB: wide=(__int128)a-b; break;
    case NA_MUL: wide=(__int128)a*b; break;
    case NA_NEG: wide=-(__int128)a; break;
    case NA_DIV:
        if(!b) { *trap=NA_DIVZERO; return 0; }
        if(a==INT64_MIN && b==-1) { *trap=NA_OVERFLOW; return 0; }
        wide=a/b; break;
    default: return -1;
    }
    if(wide<INT64_MIN || wide>INT64_MAX) { *trap=NA_OVERFLOW; return 0; }
    *out=(struct na_value){2,(int64_t)wide}; return 1;
}
static int valid_value(struct na_value v) {
    return v.tag==0 || v.tag==2 || (v.tag==1 && (v.integer==0 || v.integer==1));
}
int na_init(struct na_machine *m,const struct na_node *nodes,unsigned count,unsigned root,
            uint64_t parameter,struct na_value input,int reverse) {
    if(!m || !nodes || !count || count>NA_MAX_NODES || root>=count || !valid_value(input) ||
       (reverse!=0 && reverse!=1)) return -1;
    *m=(struct na_machine){0};
    m->nodes=nodes;m->node_count=count;m->node=(int)root;m->env=0;m->binding_count=1;
    m->bindings[0]=(struct na_binding){parameter,input,-1};m->reverse_operands=reverse;
    return 1;
}
static int push(struct na_machine *m,struct na_frame f) {
    if(m->depth>=NA_MAX_FRAMES) return -1;
    m->frames[m->depth++]=f;return 1;
}
static int lookup(struct na_machine *m,uint64_t id,struct na_value *out) {
    int at=m->env;
    for(unsigned n=0;n<NA_MAX_BINDINGS && at>=0;n++) {
        if((unsigned)at>=m->binding_count) return -1;
        const struct na_binding *b=&m->bindings[at];
        if(b->id==id){*out=b->value;return 1;}at=b->parent;
    }
    return -1;
}
static void event(struct na_sample *s,int kind,uint64_t node,const char *label,struct na_value v,int trap) {
    s->events[s->event_count++]=(struct na_event){kind,node,label,v,trap};
}
int na_site(const struct na_machine *m,struct na_sample *s) {
    if(!m || !s || m->control<NA_EVAL || m->control>NA_TERMINAL || m->depth>NA_MAX_FRAMES ||
       m->binding_count>NA_MAX_BINDINGS || m->epoch==UINT64_MAX) return -1;
    if(m->control==NA_TERMINAL) return 0;
    *s=(struct na_sample){0};s->epoch=m->epoch;s->machine_site=-1;
    const struct na_node *node=0;
    if(m->control==NA_EVAL || m->control==NA_READY) {
        if(m->node<0 || (unsigned)m->node>=m->node_count) return -1;
        node=&m->nodes[m->node];s->node=node->id;
        s->rule=m->control==NA_EVAL?NA_DISPATCH:NA_READY_RULE;
    } else if(m->depth) {
        const struct na_frame *f=&m->frames[m->depth-1];
        if(f->node<0 || (unsigned)f->node>=m->node_count) return -1;
        s->node=m->nodes[f->node].id;
        s->rule=m->control==NA_UNWIND?NA_UNWIND_FRAME:
                f->kind==NA_COLLECT?NA_COLLECT_RETURN:f->kind==NA_BIND?NA_LET_RETURN:NA_IF_RETURN;
    } else {
        s->machine_site=m->control==NA_JOIN?NA_JOIN_SITE:m->control==NA_TERMINATE?NA_TERMINATE_SITE:NA_ROOT_ENTRY;
        s->rule=m->control==NA_VALUE?NA_VALUE_RULE:m->control==NA_UNWIND?NA_UNWIND_RULE:
                m->control==NA_JOIN?NA_JOIN_RULE:NA_TERMINATE_RULE;
    }
    return 1;
}
int na_step(struct na_machine *m,struct na_sample *s) {
    int status=na_site(m,s);
    if(status!=1)return status;
    const struct na_node *node=(m->control==NA_EVAL || m->control==NA_READY)?&m->nodes[m->node]:0;
    if(m->control==NA_EVAL) {
        if(node->tag<NA_UNIT || node->tag>NA_EMIT || node->count>3) return -1;
        for(unsigned i=0;i<node->count;i++) if(node->child[i]<0 || (unsigned)node->child[i]>=m->node_count) return -1;
        switch(node->tag) {
        case NA_UNIT: m->value=(struct na_value){0,0};m->control=NA_VALUE;break;
        case NA_INT: case NA_BOOL:
            if(!valid_value(node->literal)) return -1;
            m->value=node->literal;m->control=NA_VALUE;break;
        case NA_VAR: if(lookup(m,node->binding,&m->value)<0) return -1;m->control=NA_VALUE;break;
        case NA_LET: case NA_IF: {
            if(node->count!=(node->tag==NA_LET?2u:3u)) return -1;
            struct na_frame f={0};f.kind=node->tag==NA_LET?NA_BIND:NA_BRANCH;
            f.node=m->node;f.env=m->env;
            if(push(m,f)<0) return -1;
            m->node=node->child[0];break;
        }
        case NA_PRIM: case NA_EMIT: {
            if(node->count<1 || node->count>2 || (node->tag==NA_EMIT && node->count!=1)) return -1;
            struct na_frame f={0};f.kind=NA_COLLECT;f.node=m->node;f.env=m->env;f.count=node->count;
            for(unsigned i=0;i<f.count;i++) f.children[i]=node->child[m->reverse_operands?f.count-1-i:i];
            if(push(m,f)<0) return -1;
            m->node=f.children[0];break;
        }
        default:return -1;
        }
    } else if(m->control==NA_VALUE) {
        if(!m->depth) m->control=NA_JOIN;
        else {
            struct na_frame f=m->frames[--m->depth];
            const struct na_node *owner=&m->nodes[f.node];m->env=f.env;
            if(f.kind==NA_BIND) {
                if(m->binding_count==NA_MAX_BINDINGS) return -1;
                unsigned index=m->binding_count++;
                m->bindings[index]=(struct na_binding){owner->binding,m->value,m->env};m->env=(int)index;
                m->node=owner->child[1];m->control=NA_EVAL;
            } else if(f.kind==NA_BRANCH) {
                if(m->value.tag!=1) return -1;
                m->node=owner->child[m->value.integer?1:2];m->control=NA_EVAL;
            } else if(f.kind==NA_COLLECT) {
                if(!f.count || f.count>2 || f.next>=f.count) return -1;
                f.values[f.next++]=m->value;
                if(f.next<f.count) {
                    if(push(m,f)<0) return -1;
                    m->node=f.children[f.next];m->control=NA_EVAL;
                } else {
                    m->node=f.node;m->control=NA_READY;m->value_count=f.count;
                    for(unsigned i=0;i<f.count;i++) m->values[i]=f.values[m->reverse_operands?f.count-1-i:i];
                }
            } else return -1;
        }
    } else if(m->control==NA_READY) {
        if(node->tag==NA_EMIT) {
            if(m->value_count!=1 || !node->label) return -1;
            event(s,NA_INVOKE,node->id,node->label,m->values[0],0);
            event(s,NA_EMISSION,node->id,node->label,m->values[0],0);
            m->value=(struct na_value){0,0};event(s,NA_COMMIT,node->id,0,m->value,0);m->control=NA_VALUE;
        } else {
            int result=na_pure(node->op,m->values,m->value_count,&m->value,&m->trap);
            if(result<0) return -1;
            m->control=result?NA_VALUE:NA_UNWIND;
        }
    } else if(m->control==NA_UNWIND) {
        if(m->depth)m->env=m->frames[--m->depth].env;
        else m->control=NA_JOIN;
    } else if(m->control==NA_JOIN) {
        event(s,NA_SCOPE_EXIT,0,0,m->value,m->trap);m->control=NA_TERMINATE;
    } else if(m->control==NA_TERMINATE) {
        event(s,NA_TASK_TERMINATION,0,0,m->value,m->trap);m->control=NA_TERMINAL;
    } else return -1;
    m->epoch++;s->after=m->control;s->depth=m->depth;return 1;
}
