/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * One request served by a peer's program (spec/tc1/EFFECTS.md §12.12): the
 * machine of ../pure-call, unchanged, with the peer's store carried out here.
 * UNQUALIFIED development code. No I/O: used by the peer image (peer.c) and by
 * the image that only compares runs (check.c).
 *
 * A peer's program has one function for each operation it serves. A request is
 * one run of that function on the request's input. The store is a map from I64
 * to I64 in which a cell never written reads 0. The program reaches it through
 * two effects no frame handles: when the machine is Ready at
 *   perform(StoreRead, get, k)         the perform's value is what this request
 *                                      last put at k, else the store's, else 0;
 *   perform(StoreWrite, put, (k, v))   v is kept aside for k; the value is unit.
 * The machine takes no step for such a perform; its frames stay where they are.
 * Nothing is committed here: the result says what the request would write. */
#ifndef FENRIR_REMOTE_SERVE_H
#define FENRIR_REMOTE_SERVE_H
#include "machine.h"
#define SERVE_MAX_WRITES 16u
struct serve_cell { int64_t key,value; };
struct serve_event { int put; int64_t key,value; };
/* completed 0: the step bound ran out. trap: PC_NO_TRAP, or the trap the run
 * ended in. value: the run's value when it completed without a trap. writes: the
 * final value of each cell written, in ascending key order. */
struct serve_result {
    int completed,trap; const struct pc_value *value;
    unsigned write_count; struct serve_cell writes[SERVE_MAX_WRITES];
};
/* Called for every machine step (event 0) and every store perform (sample 0), in order. */
typedef void serve_observer(void *context,const struct pc_sample *sample,const struct serve_event *event);
/* 1: the run was made and *result says how it ended. -1: machine or capacity
 * failure (infrastructure, never a trap). stale_reads is a deliberate defect,
 * for the harness: get ignores what this request has written. */
int serve_request(struct pc_machine *machine,const struct pc_program *program,unsigned function,const struct pc_value *input,
                  const struct serve_cell *cells,unsigned cell_count,int stale_reads,uint64_t fuel,
                  serve_observer *observe,void *context,struct serve_result *result);
#endif
