// The injected defects of the JavaScript task machine (runtime/tc1/task-machine.mjs), as
// report key -> constructor option. Shared by the batch runners so the hand fixtures and
// the explored schedules are run against the same nine.
export const TASK_MUTANTS=Object.freeze({
  stale_waiter:'staleWaiter',                 // cancellation leaves the blocked waiter registered
  waiter_not_woken:'waiterNotWoken',          // an item is committed to a receiver that stays Blocked
  waiter_woken_twice:'waiterWokenTwice',      // a served receiver stays registered and is served again
  eager_cancel:'eagerCancel',                 // cancellation delivered mid-stretch, at a pure step
  lifo_channel:'lifoChannel',                 // receive takes the newest value
  no_sibling_cancel:'noSiblingCancel',        // a child's trap does not cancel its siblings
  capacity_off_by_one:'capacityOffByOne',     // a channel holds capacity + 1 values
  lost_wakeup_close:'lostWakeupClose',        // first close does not end waiting receivers
  lost_wakeup_await:'lostWakeupAwait'});      // termination does not wake pending awaits
