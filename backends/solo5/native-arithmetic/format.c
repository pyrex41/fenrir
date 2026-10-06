/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability. */
#include "format.h"
struct writer { char *p; size_t at,cap; int bad; };
static void text(struct writer *w,const char *s) {
    if(!s){w->bad=1;return;}
    while(*s) { if(w->at+1>=w->cap){w->bad=1;return;}w->p[w->at++]=*s++; }
}
static void number(struct writer *w,uint64_t n) {
    char d[21];unsigned at=20;d[20]=0;
    do{d[--at]=(char)('0'+n%10);n/=10;}while(n);text(w,d+at);
}
static void quote(struct writer *w,const char *s) {
    /* Labels are admitted ASCII identifiers; enum strings are fixed. */
    text(w,"\"");
    if(!s){w->bad=1;return;}
    for(const char *p=s;*p;p++) if(!((*p>='A' && *p<='Z') || (*p>='a' && *p<='z') ||
         (*p>='0' && *p<='9') || *p=='_')){w->bad=1;return;}
    text(w,s);text(w,"\"");
}
static void value(struct writer *w,struct na_value v) {
    if(v.tag==0)text(w,"[\"unit\"]");
    else if(v.tag==1 && (v.integer==0 || v.integer==1))text(w,v.integer?"[\"bool\",true]":"[\"bool\",false]");
    else if(v.tag==2){
        text(w,"[\"int\",\"");
        if(v.integer<0){text(w,"-");number(w,(uint64_t)(-(v.integer+1))+1);}
        else number(w,(uint64_t)v.integer);
        text(w,"\"]");
    }else w->bad=1;
}
static void outcome(struct writer *w,const struct na_event *e) {
    if(e->trap==NA_NO_TRAP){text(w,"[\"Ok\",");value(w,e->value);text(w,"]");}
    else if(e->trap==NA_OVERFLOW)text(w,"[\"Trap\",\"Overflow\"]");
    else if(e->trap==NA_DIVZERO)text(w,"[\"Trap\",\"DivZero\"]");
    else w->bad=1;
}
static void event(struct writer *w,const struct na_event *e) {
    static const char *kinds[]={"Invoke","Emit","Commit","ScopeExit","TaskTermination"};
    if(e->kind<0 || e->kind>NA_TASK_TERMINATION){w->bad=1;return;}
    text(w,"{\"kind\":");quote(w,kinds[e->kind]);
    if(e->kind<=NA_EMISSION){text(w,",\"label\":");quote(w,e->label);}
    if(e->kind<=NA_COMMIT){
        text(w,",\"node\":\"");number(w,e->node);text(w,"\"");
        if(e->kind!=NA_EMISSION)text(w,",\"operation\":\"emit\"");
        text(w,",\"task\":\"0\",\"value\":");value(w,e->value);
    } else {
        text(w,",\"outcome\":");outcome(w,e);
        if(e->kind==NA_SCOPE_EXIT)text(w,",\"scope\":\"0\"");
        text(w,",\"task\":\"0\"");
    }
    text(w,"}");
}
size_t na_format_site(const struct na_sample *s,char *out,size_t cap) {
    static const char *rules[]={"Dispatch","Ready","CollectReturn","LetReturn","IfReturn","UnwindFrame","Value","Unwind","Join","Terminate"};
    static const char *sites[]={"RootJoinEntry","Join","Terminate"};
    if(!s || !out || !cap || s->rule<0 || s->rule>NA_TERMINATE_RULE ||
       s->machine_site < -1 || s->machine_site>NA_TERMINATE_SITE)return 0;
    struct writer w={out,0,cap,0};text(&w,"{");
    if(s->machine_site<0){text(&w,"\"node\":\"");number(&w,s->node);text(&w,"\"");}
    else {text(&w,"\"machine\":");quote(&w,sites[s->machine_site]);}
    text(&w,",\"rule\":");quote(&w,rules[s->rule]);text(&w,"}");
    if(w.bad)return 0;
    out[w.at]=0;return w.at;
}
size_t na_format_sample(const struct na_sample *s,char *out,size_t cap) {
    static const char *controls[]={"Eval","Value","Ready","Unwind","Join","Terminate","Terminal"};
    static const char *rules[]={"Dispatch","Ready","CollectReturn","LetReturn","IfReturn","UnwindFrame","Value","Unwind","Join","Terminate"};
    static const char *sites[]={"RootJoinEntry","Join","Terminate"};
    if(!s || !out || !cap || s->after<0 || s->after>NA_TERMINAL || s->rule<0 ||
       s->rule>NA_TERMINATE_RULE || s->machine_site < -1 || s->machine_site>NA_TERMINATE_SITE || s->event_count>3)return 0;
    struct writer w={out,0,cap,0};
    text(&w,"{\"after\":");quote(&w,controls[s->after]);
    text(&w,",\"depth\":\"");number(&w,s->depth);text(&w,"\",\"epoch\":\"");number(&w,s->epoch);
    text(&w,"\",\"events\":[");
    for(unsigned i=0;i<s->event_count;i++){if(i)text(&w,",");event(&w,&s->events[i]);}
    text(&w,"],\"site\":{");
    if(s->machine_site<0){text(&w,"\"node\":\"");number(&w,s->node);text(&w,"\"");}
    else {text(&w,"\"machine\":");quote(&w,sites[s->machine_site]);}
    text(&w,",\"rule\":");quote(&w,rules[s->rule]);text(&w,"}}");
    if(w.bad)return 0;
    out[w.at]=0;return w.at;
}
