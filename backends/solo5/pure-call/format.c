/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Sample JSON for the pure-call guest. Names and labels are restricted by the
 * lowering to [A-Za-z_][A-Za-z0-9_-]* so no string escaping is required. */
#include "machine.h"
struct writer { char *out; size_t at,cap; int bad; };
static void text(struct writer *w,const char *s) {
    while(*s){if(w->at+1>=w->cap){w->bad=1;return;}w->out[w->at++]=*s++;}
}
static void span(struct writer *w,const char *s,unsigned n) {
    for(unsigned i=0;i<n;i++){if(w->at+1>=w->cap){w->bad=1;return;}w->out[w->at++]=s[i];}
}
static void quote(struct writer *w,const char *s) {text(w,"\"");text(w,s);text(w,"\"");}
static void natural(struct writer *w,uint64_t n) {
    char digits[21];unsigned at=20;digits[20]=0;
    do{digits[--at]=(char)('0'+n%10);n/=10;}while(n);
    text(w,digits+at);
}
static void integer(struct writer *w,int64_t n) {
    if(n<0){text(w,"-");natural(w,(uint64_t)0-(uint64_t)n);} else natural(w,(uint64_t)n);
}
static void value(struct writer *w,const struct pc_value *v,unsigned depth) {
    if(!v || depth>256){w->bad=1;return;}
    switch(v->tag){
    case PV_UNIT:text(w,"[\"unit\"]");return;
    case PV_BOOL:text(w,v->integer?"[\"bool\",true]":"[\"bool\",false]");return;
    case PV_INT:text(w,"[\"int\",\"");integer(w,v->integer);text(w,"\"]");return;
    case PV_BYTES:text(w,"[\"bytes\",\"");span(w,v->text,v->count);text(w,"\"]");return;
    case PV_TUPLE:text(w,"[\"tuple\"");break;
    case PV_DATA:text(w,"[\"data\",");quote(w,v->text);text(w,",");quote(w,v->constructor);break;
    default:w->bad=1;return; /* closures are not serializable observations */
    }
    for(unsigned i=0;i<v->count;i++){text(w,",");value(w,v->fields[i],depth+1);}
    text(w,"]");
}
static void outcome(struct writer *w,const struct pc_event *e) {
    static const char *traps[]={0,"Overflow","DivZero","Bounds"};
    if(e->trap<0 || e->trap>PC_BOUNDS){w->bad=1;return;}
    if(e->trap){text(w,"[\"Trap\",");quote(w,traps[e->trap]);text(w,"]");}
    else {text(w,"[\"Ok\",");value(w,e->value,0);text(w,"]");}
}
static void event(struct writer *w,const struct pc_event *e) {
    static const char *kinds[]={"Invoke","Emit","Commit","ScopeExit","TaskTermination"};
    if(e->kind<0 || e->kind>PE_TASK_TERMINATION){w->bad=1;return;}
    text(w,"{\"kind\":");quote(w,kinds[e->kind]);text(w,",\"task\":\"0\"");
    if(e->kind<=PE_COMMIT){
        text(w,",\"node\":\"");natural(w,e->node);text(w,"\"");
        if(e->kind!=PE_EMIT)text(w,",\"operation\":\"emit\"");
        if(e->kind!=PE_COMMIT){text(w,",\"label\":");quote(w,e->label);}
        text(w,",\"value\":");value(w,e->value,0);
    } else {
        if(e->kind==PE_SCOPE_EXIT)text(w,",\"scope\":\"0\"");
        text(w,",\"outcome\":");outcome(w,e);
    }
    text(w,"}");
}
size_t pc_format_sample(const struct pc_sample *s,char *out,size_t cap) {
    static const char *controls[]={"Eval","Value","Ready","Unwind","Join","Terminate","Terminal"};
    static const char *rules[]={"Dispatch","Ready","LetReturn","IfReturn","MatchReturn","ReturnReturn",
                                "CollectReturn","UnwindFrame","Value","Unwind","Join","Terminate"};
    static const char *sites[]={"RootJoinEntry","Join","Terminate"};
    if(!s || !out || !cap || s->after<0 || s->after>PC_TERMINAL || s->rule<0 || s->rule>PR_TERMINATE ||
       s->machine_site< -1 || s->machine_site>PS_TERMINATE || s->event_count>3)return 0;
    struct writer w={out,0,cap,0};
    text(&w,"{\"after\":");quote(&w,controls[s->after]);
    text(&w,",\"depth\":\"");natural(&w,s->depth);text(&w,"\",\"epoch\":\"");natural(&w,s->epoch);
    text(&w,"\",\"events\":[");
    for(unsigned i=0;i<s->event_count;i++){if(i)text(&w,",");event(&w,&s->events[i]);}
    text(&w,"],\"site\":{");
    if(s->machine_site<0){text(&w,"\"node\":\"");natural(&w,s->node);text(&w,"\"");}
    else {text(&w,"\"machine\":");quote(&w,sites[s->machine_site]);}
    text(&w,",\"rule\":");quote(&w,rules[s->rule]);text(&w,"}}");
    if(w.bad)return 0;
    out[w.at]=0;return w.at;
}
