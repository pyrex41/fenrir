/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Fenrir remote perform, wire format version 4 (spec/tc1/EFFECTS.md §12,
 * supervisor/README.md). UNQUALIFIED development code.
 *
 * Version 4 (16 November 2026) came with peers written in Fenrir (EFFECTS.md
 * §12.12). A REQUEST and a DELIVER name their operation, "Effect.operation", so
 * a peer serves any number of operations of each mode. The peer's store is a
 * log: CELL records, each one write of the peer's program to its key-value
 * store, and STORED records, each the reply record of one request id, which now
 * keeps the operation with the argument. The store header counts the log's
 * records. A REPLY may say trapped. An inbox header says where its hold is.
 *
 * Version 3 (16 November 2026, later the same day as version 2) differs from
 * version 2 in two places: a REQUEST and a DELIVER carry a mode, keyed or
 * read-only, before the key, and a REPLY may say read. A read-only operation
 * has no request key and leaves no record (EFFECTS.md §12.3).
 *
 * Version 2 (16 November 2026) differs from version 1 in three places: an
 * OUTCOME of kind reply carries a status, a REPLY may say conflict, and a
 * STORED record carries the argument the request id was applied with. Outcome
 * kind 2 is unchanged on the wire; it was called peer_down and is now
 * not_delivered, because it may also be reported while the peer is up. The
 * record magic "FRW1" names the format family, not the version. A block whose
 * version field is not 4 is malformed.
 *
 * Transport: a mailbox is a Solo5 block device of 512-byte blocks with exactly
 * one writer. A member has an inbox (written by the supervisor, read by the
 * guest) and an outbox (written by the guest, read by the supervisor). Block 0
 * is the mailbox header; record number n (from 1) is block n. The writer writes
 * the record first and then the header whose count includes it, so a reader
 * that trusts only records up to the header's count never sees a partial one.
 *
 * All integers are little-endian. Every block carries a CRC-32 (IEEE, as zlib)
 * over the whole block with the CRC field taken as zero. Unused bytes are zero
 * and are checked. Anything else is malformed and is rejected, by both sides.
 *
 * Header block                         Record block
 *   0  u32 magic "FRMB" / "FRST"         0  u32 magic "FRW1"
 *   4  u16 version = 4                   4  u16 version = 4
 *   6  u16 kind                          6  u16 type
 *   8  u32 incarnation                   8  u32 seq (its block number)
 *  12  u32 count                        12  u32 incarnation
 *  16  u32 grant                        16  u32 ref
 *  20  u32 hold                         20  u32 length of the payload
 *  24  u32 crc                          24  u32 crc
 *  28  u32 where                        28  u32 zero
 *  32  zero to the end                  32  payload, then zero to the end
 *
 * Mailbox header: count is the number of records written. In an inbox, grant
 * is how many of them the guest may consume (grant <= count): the supervisor's
 * scheduling of when the image runs. In an outbox grant equals count.
 * hold is zero except in an inbox, where it may be the number of a granted
 * record (hold <= grant): the image consumes that record and then stops,
 * without exiting, until it is killed. where says at which point: 0, just
 * before it would send the reply, which is after its durable commit (EFFECTS.md
 * §12.7); 1, inside the commit, when every record of the commit is written and
 * the store header that would count them is not. where is zero when hold is.
 * This is how the supervisor places a kill between a peer's commit and its
 * reply, and one inside the commit. It exists for scheduled runs; an image
 * never sets it.
 *
 * The peer's durable store. Block 0 is the store header: incarnation zero,
 * count the number of log records, grant the number of STORED records among
 * them. Blocks 1..count are the log, in the order written. A CELL record sets
 * one cell of the key-value store; the value of a cell is that of the latest
 * CELL record for its key, and 0 if there is none. A STORED record is the reply
 * record of a request id; the latest for a request id is the one that counts.
 * THE COMMIT of one request is: its CELL records and its STORED record written
 * to the blocks after the last counted one, and then ONE write of the header,
 * with the new count. A record the header does not count does not exist: it is
 * not read when the store is opened, and the next commit writes over it. So a
 * crash before the header write leaves the store as it was, and a crash after
 * it leaves every write of the request and its record. That is atomic if one
 * 512-byte block write is atomic (the header is never seen half written) and a
 * write that returned is not lost by the death of the image; nothing here
 * defends against a host that tears a block or loses a completed write.
 * The log is never compacted: a store holds as many records as its file has
 * blocks, less one.
 *
 * Records, by type (ref; payload):
 *   REQUEST caller -> supervisor   ref 0; peer name[16], mode u32, zero u32, key i64, argument i64, operation[64]
 *   OUTCOME supervisor -> caller   ref = seq of the REQUEST; kind u32, status u32, value i64
 *   DELIVER supervisor -> peer     ref 0; caller name[16], mode u32, zero u32, key i64, argument i64, operation[64]
 *   REPLY   peer -> supervisor     ref = seq of the DELIVER; how u32, zero u32, value i64
 *   HALT    caller -> supervisor   ref 0; no payload: the program has finished
 *   STORED  in the store only      ref 0; caller name[16], key i64, argument i64, value i64, operation[64]
 *   CELL    in the store only      ref 0; key i64, value i64
 * Names are 1..15 bytes of [a-z0-9-], zero padded. An operation is
 * "Effect.operation", 3..63 bytes of [A-Za-z0-9_.], zero padded. Values are I64
 * in this version.
 *
 * mode: 1 keyed, an operation that may change the peer's state, with its request
 * key and an I64 argument; 2 read-only, an operation the peer answers from its
 * state and records nothing for: no key, and its argument is unit in this
 * version, so key and argument are zero.
 *
 * OUTCOME kind: 1 reply, 2 not_delivered, 3 timed_out. status is 0 (ok: value is
 * the operation's value) or 1 (conflict: the key has a record made with another
 * argument; value is zero), and is zero unless the kind is reply. value is zero
 * unless the kind is reply. The program sees reply((status, value)) for a keyed
 * operation and reply(value) for a read-only one, whose status is always 0.
 * REPLY how: 1 applied, 2 replayed, 3 conflict (value zero), 4 read (a read-only
 * operation's value; nothing was recorded), 5 trapped (value zero: the peer's
 * program trapped, nothing was committed, and the supervisor gives the caller
 * no reply for it).
 * STORED operation and argument: what the peer keeps to tell a retry from a
 * reused key. They are the operation's name and the argument itself, which for
 * an I64 is its own collision-free digest. */
#ifndef FENRIR_REMOTE_WIRE_H
#define FENRIR_REMOTE_WIRE_H
#include <stdint.h>
#include <stddef.h>
#define FRW_BLOCK 512u
#define FRW_VERSION 4u
#define FRW_RECORD_MAGIC 0x31575246u /* "FRW1" */
#define FRW_MAILBOX_MAGIC 0x424d5246u /* "FRMB" */
#define FRW_STORE_MAGIC 0x54535246u /* "FRST" */
#define FRW_PAYLOAD_MAX 480u
#define FRW_NAME 16u
#define FRW_OPERATION 64u
enum frw_type { FRW_REQUEST=1,FRW_OUTCOME=2,FRW_DELIVER=3,FRW_REPLY=4,FRW_HALT=5,FRW_STORED=6,FRW_CELL=7 };
enum frw_where { FRW_BEFORE_REPLY=0,FRW_IN_COMMIT=1 };
enum frw_kind { FRW_INBOX=1,FRW_OUTBOX=2,FRW_STORE=3 };
enum frw_outcome { FRW_REPLIED=1,FRW_NOT_DELIVERED=2,FRW_TIMED_OUT=3 };
enum frw_status { FRW_OK=0,FRW_KEY_CONFLICT=1 };
enum frw_how { FRW_APPLIED=1,FRW_REPLAYED=2,FRW_CONFLICT=3,FRW_READ=4,FRW_TRAPPED=5 };
enum frw_mode { FRW_KEYED=1,FRW_READ_ONLY=2 };
struct frw_header { uint32_t magic; uint16_t kind; uint32_t incarnation,count,grant,hold,where; };
struct frw_record { uint16_t type; uint32_t seq,incarnation,ref,length; uint8_t payload[FRW_PAYLOAD_MAX]; };
/* Payload views. */
struct frw_call { char name[FRW_NAME]; uint32_t mode; int64_t key,value; char operation[FRW_OPERATION]; };   /* REQUEST, DELIVER */
struct frw_stored { char name[FRW_NAME]; int64_t key,argument,value; char operation[FRW_OPERATION]; };   /* STORED */
struct frw_cell { int64_t key,value; };   /* CELL */
struct frw_result { uint32_t code,status; int64_t value; };    /* OUTCOME (status), REPLY (status zero) */

uint32_t frw_crc32(const uint8_t *bytes,size_t count);
void frw_encode_header(const struct frw_header *,uint8_t block[FRW_BLOCK]);
/* 1 well formed, 0 malformed. */
int frw_decode_header(const uint8_t block[FRW_BLOCK],struct frw_header *);
/* 1 ok, 0 if the record cannot be encoded (length). */
int frw_encode_record(const struct frw_record *,uint8_t block[FRW_BLOCK]);
int frw_decode_record(const uint8_t block[FRW_BLOCK],struct frw_record *);
/* 1 if name is 1..15 bytes of [a-z0-9-] followed by zero padding to 16. */
int frw_name_ok(const char name[FRW_NAME]);
int frw_name_set(char name[FRW_NAME],const char *text);
int frw_name_same(const char a[FRW_NAME],const char b[FRW_NAME]);
/* 1 if operation is 3..63 bytes of [A-Za-z0-9_.] with one dot inside, zero padded to 64. */
int frw_operation_ok(const char operation[FRW_OPERATION]);
int frw_operation_set(char operation[FRW_OPERATION],const char *text);
int frw_operation_same(const char a[FRW_OPERATION],const char b[FRW_OPERATION]);
void frw_put_call(const struct frw_call *,struct frw_record *,uint16_t type);
/* 1 ok, 0 malformed for the type. */
int frw_get_call(const struct frw_record *,struct frw_call *);
void frw_put_stored(const struct frw_stored *,struct frw_record *);
int frw_get_stored(const struct frw_record *,struct frw_stored *);
void frw_put_cell(const struct frw_cell *,struct frw_record *);
int frw_get_cell(const struct frw_record *,struct frw_cell *);
void frw_put_result(const struct frw_result *,struct frw_record *,uint16_t type);
int frw_get_result(const struct frw_record *,struct frw_result *);
#endif
