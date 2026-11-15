/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Shared by the remote-perform guests: console frames and the mailbox pair of a
 * member (wire.h). UNQUALIFIED development code. */
#ifndef FENRIR_REMOTE_SUPPORT_H
#define FENRIR_REMOTE_SUPPORT_H
#include <solo5.h>
#include "wire.h"
/* Guest exit codes. 0: finished. 1: bad command line. 2: machine or capacity
 * failure. 3: the lifetime given on the command line ran out. 4: malformed
 * input from the supervisor or a malformed store. 5: device failure. */
enum { EXIT_USAGE=1,EXIT_MACHINE=2,EXIT_LIFETIME=3,EXIT_MALFORMED=4,EXIT_DEVICE=5 };

/* One console frame: "FGRUN/1 <length>\n<payload>\n". Build the payload with
 * the out_ functions, then frame_end. A payload that does not fit is truncated
 * and frame_end reports 0. */
void out_begin(void);
void out_text(const char *);
void out_natural(uint64_t);
void out_integer(int64_t);
void out_name(const char name[FRW_NAME]);
/* Room for a formatter that writes directly: the position and the space left. */
char *out_room(size_t *space);
void out_advance(size_t count);
int frame_end(void);
void frame_text(const char *payload);
/* A Fault frame with the reason; returns code, for "return fault(...)". */
int fault(const char *reason,int code);

/* "life=<milliseconds>" then optional " <word>" options. 1 ok. */
int parse_life(const char *cmdline,uint64_t *life_ns,const char **rest);
int word_is(const char *rest,const char *expected);
void *memset(void *dest,int value,size_t count);
void *memcpy(void *dest,const void *source,size_t count);

struct mailbox {
    solo5_handle_t inbox,outbox;
    uint64_t inbox_blocks,outbox_blocks;
    uint32_t incarnation,count,grant,hold,consumed,sent;
    solo5_time_t deadline;
};
/* 1 ok; otherwise an EXIT_ code, negated. mailbox_open reads the inbox header,
 * which gives the incarnation. mailbox_announce writes the empty outbox header:
 * that is how the supervisor learns the image is running, so it comes after the
 * Hello frame. */
int mailbox_open(struct mailbox *,uint64_t life_ns);
int mailbox_announce(struct mailbox *);
/* Fills seq and incarnation, writes the record and then the header. */
int mailbox_send(struct mailbox *,struct frw_record *);
/* Waits for the next granted inbox record. 1 ok; -EXIT_LIFETIME when the
 * lifetime ran out; -EXIT_MALFORMED; -EXIT_DEVICE. */
int mailbox_receive(struct mailbox *,struct frw_record *);
/* 1 if the supervisor asked for the image to stop before replying to record seq
 * (the inbox header's hold, as last read by mailbox_receive). */
int mailbox_held(const struct mailbox *,uint32_t seq);
/* Stops here without exiting, until killed or until the lifetime runs out;
 * then returns -EXIT_LIFETIME. */
int mailbox_hold(struct mailbox *);
#endif
