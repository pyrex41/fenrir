/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * See serve.h. */
#include "serve.h"
static int same(const char *a,const char *b) {while(*a && *a==*b){a++;b++;}return *a==*b;}
/* 1 get, 2 put, 0 neither: the store perform the machine is Ready at, when no
 * handler frame handles its effect. The search is the machine's own. */
static int store_perform(const struct pc_machine *m) {
    if(m->control!=PC_READY)return 0;
    const struct pc_node *n=&m->program->nodes[m->node];
    if(n->tag!=PC_PERFORM)return 0;
    int kind=same(n->text,"StoreRead") && same(n->text2,"get")?1:same(n->text,"StoreWrite") && same(n->text2,"put")?2:0;
    if(!kind)return 0;
    for(unsigned i=m->depth;i>0;i--)
        if(m->frames[i-1].kind==PF_HANDLE && same(m->program->nodes[m->frames[i-1].node].text,n->text))return 0;
    return kind;
}
int serve_request(struct pc_machine *m,const struct pc_program *p,unsigned function,const struct pc_value *input,
                  const struct serve_cell *cells,unsigned cell_count,int stale_reads,uint64_t fuel,
                  serve_observer *observe,void *context,struct serve_result *r) {
    r->completed=0;r->trap=PC_NO_TRAP;r->value=0;r->write_count=0;
    if(pc_start(m,p,function,input)!=1)return -1;
    while(m->control!=PC_TERMINAL && m->epoch<fuel){
        int kind=store_perform(m);
        if(!kind){
            struct pc_sample s;
            if(pc_step(m,&s)!=1)return -1;
            if(observe)observe(context,&s,0);
            continue;
        }
        const struct pc_value *argument=m->ready[0],*value;struct serve_event e;
        if(kind==1){
            if(!argument || argument->tag!=PV_INT)return -1;
            int found=0;
            e.put=0;e.key=argument->integer;e.value=0;
            for(unsigned i=0;i<r->write_count && !stale_reads && !found;i++)
                if(r->writes[i].key==e.key){e.value=r->writes[i].value;found=1;}
            for(unsigned i=0;i<cell_count && !found;i++)
                if(cells[i].key==e.key){e.value=cells[i].value;found=1;}
            value=pc_scalar(PV_INT,e.value);
        } else {
            if(!argument || argument->tag!=PV_TUPLE || argument->count!=2 ||
               argument->fields[0]->tag!=PV_INT || argument->fields[1]->tag!=PV_INT)return -1;
            unsigned at=0;
            e.put=1;e.key=argument->fields[0]->integer;e.value=argument->fields[1]->integer;
            while(at<r->write_count && r->writes[at].key!=e.key)at++;
            if(at==r->write_count){
                if(r->write_count>=SERVE_MAX_WRITES)return -1;
                r->write_count++;
            }
            r->writes[at].key=e.key;r->writes[at].value=e.value;
            value=pc_scalar(PV_UNIT,0);
        }
        if(!value)return -1;
        if(observe)observe(context,0,&e);
        /* The perform returns with that value; environment and frames are untouched. */
        m->control=PC_VALUE;m->value=value;
    }
    for(unsigned i=1;i<r->write_count;i++){
        struct serve_cell c=r->writes[i];unsigned k=i;
        while(k>0 && r->writes[k-1].key>c.key){r->writes[k]=r->writes[k-1];k--;}
        r->writes[k]=c;
    }
    r->completed=m->control==PC_TERMINAL;r->trap=m->trap;
    r->value=r->completed && !m->trap?m->value:0;
    return 1;
}
