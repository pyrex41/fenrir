/* Matched Solo5 handler. The shared port serializes the transaction before
 * borrowing the reply. Only one command is active at a time. */
#include "heap.h"
#define FEN_TAGS_ONLY
#include "types.h"

typedef struct { fen_object *value; uintptr_t status; } outcome;
extern outcome service_commit(fen_object *);
static fen_object response;

outcome fenrir_entry(fen_object *cmd) {
    uintptr_t cap = cmd->fields[0], key = cmd->fields[1], digest = cmd->fields[2];
    fen_object done = {.tag = TAG_Writes_Done};
    fen_object guard, tx = {.tag = TAG_Tx_Tx};
    fen_object ops[3], writes[3];
    size_t n;
    if (cmd->tag == TAG_Command_Submit) {
        guard = (fen_object){.tag = TAG_Guard_Once, .fields = {key}};
        ops[0] = (fen_object){.tag = TAG_Write_StageJob};
        ops[1] = (fen_object){.tag = TAG_Write_PutReport, .fields = {digest, cmd->fields[3]}};
        ops[2] = (fen_object){.tag = TAG_Write_RecordKey, .fields = {key, digest}};
        n = 3;
    } else {
        guard = (fen_object){.tag = TAG_Guard_Pending, .fields = {key}};
        ops[0] = (fen_object){.tag = TAG_Write_Finish, .fields = {key, digest}};
        n = 1;
    }
    fen_object *rest = &done;
    while (n) {
        --n;
        writes[n] = (fen_object){.tag = TAG_Writes_Then, .fields = {(uintptr_t)&ops[n], (uintptr_t)rest}};
        rest = &writes[n];
    }
    tx.fields[0] = cap;
    tx.fields[1] = (uintptr_t)&guard;
    tx.fields[2] = (uintptr_t)rest;
    outcome result = service_commit(&tx);
    if (result.status) return result;
    fen_object *reply = result.value;
    if (cmd->tag == TAG_Command_Complete) {
        response.tag = TAG_Response_Delivered;
    } else if (reply->tag == TAG_Reply_Committed || reply->tag == TAG_Reply_Recorded) {
        if (reply->tag == TAG_Reply_Recorded && reply->fields[0] != digest) {
            response.tag = TAG_Response_Conflict;
            response.fields[0] = ((fen_object *)cap)->fields[0];
            response.fields[1] = key;
        } else {
            response.tag = TAG_Response_Accepted;
            response.fields[0] = reply->fields[reply->tag == TAG_Reply_Recorded];
        }
    } else {
        response.tag = TAG_Response_Refused;
    }
    return (outcome){&response, 0};
}
