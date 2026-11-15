// The injected defects of the JavaScript durable machine (runtime/tc1/durable-machine.mjs),
// as report key -> constructor option.
export const MUTANTS=Object.freeze({double_reply:'doubleReply',late_request_record:'lateRequestRecord',early_request:'earlyRequest',
  host_first:'hostFirst',stale_handler:'staleHandler',unchecked_reply:'uncheckedReply',seq_reuse:'seqReuse'});
