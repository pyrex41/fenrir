/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Fenrir remote perform, wire format version 1 (spec/tc1/EFFECTS.md §12,
 * supervisor/README.md). UNQUALIFIED development code.
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
 *   4  u16 version = 1                   4  u16 version = 1
 *   6  u16 kind                          6  u16 type
 *   8  u32 incarnation                   8  u32 seq (its block number)
 *  12  u32 count                        12  u32 incarnation
 *  16  u32 grant                        16  u32 ref
 *  20  u32 hold                         20  u32 length of the payload
 *  24  u32 crc                          24  u32 crc
 *  28  zero to the end                  28  u32 zero
 *                                       32  payload, then zero to the end
 *
 * Mailbox header: count is the number of records written. In an inbox, grant
 * is how many of them the guest may consume (grant <= count): the supervisor's
 * scheduling of when the image runs. In an outbox grant equals count.
 * hold is zero except in an inbox, where it may be the number of a granted
 * record (hold <= grant): the image consumes that record and then stops just
 * before it would send the reply, without exiting, until it is killed. This is
 * how the supervisor places a kill between a peer's durable commit and its
 * reply (EFFECTS.md §12.7). It exists for scheduled runs; an image never sets it.
 * Store header (the peer's durable store): incarnation is zero, count is the
 * number of reply records, grant is the number of applications.
 *
 * Records, by type (ref; payload):
 *   REQUEST caller -> supervisor   ref 0; peer name[16], key i64, argument i64
 *   OUTCOME supervisor -> caller   ref = seq of the REQUEST; kind u32, zero u32, value i64
 *   DELIVER supervisor -> peer     ref 0; caller name[16], key i64, argument i64
 *   REPLY   peer -> supervisor     ref = seq of the DELIVER; how u32, zero u32, value i64
 *   HALT    caller -> supervisor   ref 0; no payload: the program has finished
 *   STORED  in the store only      ref 0; caller name[16], key i64, value i64
 * Names are 1..15 bytes of [a-z0-9-], zero padded. Values are I64 in this version. */
#ifndef FENRIR_REMOTE_WIRE_H
#define FENRIR_REMOTE_WIRE_H
#include <stdint.h>
#include <stddef.h>
#define FRW_BLOCK 512u
#define FRW_VERSION 1u
#define FRW_RECORD_MAGIC 0x31575246u /* "FRW1" */
#define FRW_MAILBOX_MAGIC 0x424d5246u /* "FRMB" */
#define FRW_STORE_MAGIC 0x54535246u /* "FRST" */
#define FRW_PAYLOAD_MAX 480u
#define FRW_NAME 16u
enum frw_type { FRW_REQUEST=1,FRW_OUTCOME=2,FRW_DELIVER=3,FRW_REPLY=4,FRW_HALT=5,FRW_STORED=6 };
enum frw_kind { FRW_INBOX=1,FRW_OUTBOX=2,FRW_STORE=3 };
enum frw_outcome { FRW_REPLIED=1,FRW_PEER_DOWN=2,FRW_TIMED_OUT=3 };
enum frw_how { FRW_APPLIED=1,FRW_REPLAYED=2 };
struct frw_header { uint32_t magic; uint16_t kind; uint32_t incarnation,count,grant,hold; };
struct frw_record { uint16_t type; uint32_t seq,incarnation,ref,length; uint8_t payload[FRW_PAYLOAD_MAX]; };
/* Payload views. */
struct frw_call { char name[FRW_NAME]; int64_t key,value; };   /* REQUEST, DELIVER, STORED */
struct frw_result { uint32_t code; int64_t value; };           /* OUTCOME, REPLY */

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
void frw_put_call(const struct frw_call *,struct frw_record *,uint16_t type);
/* 1 ok, 0 malformed for the type. */
int frw_get_call(const struct frw_record *,struct frw_call *);
void frw_put_result(const struct frw_result *,struct frw_record *,uint16_t type);
int frw_get_result(const struct frw_record *,struct frw_result *);
#endif
