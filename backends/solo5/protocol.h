/* ISC: freely use/copy/modify/distribute; AS IS without warranty or liability.
 * Fixed UNQUALIFIED transport demo; these are wire constants, not oracle transitions.
 */
#ifndef FENRIR_PROTOCOL_H
#define FENRIR_PROTOCOL_H
#define FG_COMMON "\"profile\":\"fenrir.solo5.control-demo/1\",\"run_id\":\"demo-0\""
#define FG_CONFIG "ba6400d1dc04d544d51e27fa3acc8b113a06a88de5c43c8c6d118c3dc586e3cf"
#define FG_D0 "b72fe6951f970bde6dac693e3ed5909449a0aa83fd09bbdcf4b1845fa4f57eaa"
#define FG_D1 "11080677314bfff6c924ceddd9d879a73d5aa78cf5257d971d97aaf86d1d7573"
#define FG_HELLO "{\"config_hash\":\"" FG_CONFIG "\",\"kind\":\"Hello\"," FG_COMMON ",\"sequence\":\"0\"}"
#define FG_INIT "{\"config_hash\":\"" FG_CONFIG "\",\"kind\":\"Init\"," FG_COMMON ",\"sequence\":\"0\"}"
#define FG_BOUNDARY0 "{\"domain_hash\":\"" FG_D0 "\",\"epoch\":\"0\",\"kind\":\"Boundary\"," FG_COMMON ",\"sequence\":\"1\",\"site\":\"Probe0\"}"
#define FG_BOUNDARY1 "{\"domain_hash\":\"" FG_D1 "\",\"epoch\":\"1\",\"kind\":\"Boundary\"," FG_COMMON ",\"sequence\":\"2\",\"site\":\"Probe1\"}"
#define FG_PROCEED0 "{\"decision\":[\"Proceed\",\"0\"],\"domain_hash\":\"" FG_D0 "\",\"epoch\":\"0\",\"kind\":\"Proceed\"," FG_COMMON ",\"sequence\":\"1\",\"site\":\"Probe0\"}"
#define FG_PROCEED1 "{\"decision\":[\"Proceed\",\"1\"],\"domain_hash\":\"" FG_D1 "\",\"epoch\":\"1\",\"kind\":\"Proceed\"," FG_COMMON ",\"sequence\":\"2\",\"site\":\"Probe1\"}"
#define FG_TERMINAL "{\"accepted\":\"2\",\"epoch\":\"2\",\"kind\":\"Terminal\"," FG_COMMON ",\"sequence\":\"3\"}"
#define FG_ACK "{\"kind\":\"Ack\"," FG_COMMON ",\"sequence\":\"3\"}"
int fg_equal(const char *,const char *);
void fg_frame(const char *);
int fg_expect(const char *);
long fg_syscall(long,long,long,long);
#endif
