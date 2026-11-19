\\ The A2 storage contract: what the host's Store.commit does to the A1 stores.
\\ Contract text: spec/service/HANDLER.md section 3. Load models/service/accepted-job.shen
\\ (the A1 model, unchanged) first. UNQUALIFIED.
\\
\\ The transaction and the reply are TC1 model values (models/tc1/durable-machine.shen):
\\ [data Type Constructor Field ...], [int "N"], [bool B], [bytes Octets]. Tenants, keys,
\\ digests and ids are A1's small naturals; in values they are decimal strings.
\\
\\ sst.commit Stores Tx gives [Stores' Reply]: one step of the host on one store.

(define sst.n
  [int N] -> (tc0.i64.small N))

(define sst.int
  N -> [int (str N)])

(define sst.receipt-value
  [receipt T K D R J] -> [data "Receipt" "Receipt" (sst.int T) (sst.int K) (sst.int D) (sst.int R) (sst.int J)])

(define sst.reply
  Name -> [data "Reply" Name])

(define sst.commit
  Stores [data "Tx" "Tx" [data "Cap" "Tenant" T] Guard Writes] ->
    (let Tenant (sst.n T)
      (if (svc.tenant? Tenant Stores)
          (sst.guarded Tenant Guard Writes Stores (svc.store Tenant Stores))
          [Stores (sst.reply "Unauthorized")]))
  Stores _ -> [Stores (sst.reply "Unauthorized")])

\\ The guard, on the tenant's store before any write.
(define sst.guarded
  T [data "Guard" "Always"] Writes Stores Store -> (sst.apply T Writes Stores Store)
  T [data "Guard" "Once" K] Writes Stores Store ->
    (let Found (svc.lookup (sst.n K) (svc.keys Store))
      (if (= Found none)
          (sst.apply T Writes Stores Store)
          [Stores [data "Reply" "Recorded" (sst.int (nth 2 Found)) (sst.receipt-value (nth 3 Found))]]))
  T [data "Guard" "Pending" J] Writes Stores Store ->
    (if (sst.pending? (sst.n J) (svc.jobs Store))
        (sst.apply T Writes Stores Store)
        [Stores (sst.reply "Skipped")]))

(define sst.pending?
  _ [] -> false
  J [[J _ pending] | _] -> true
  J [_ | Js] -> (sst.pending? J Js))

\\ Apply the writes in order with N = Next; [Stores' Reply].
(define sst.apply
  T Writes Stores [store Reports Jobs Keys N] ->
    (let Done (sst.writes T N Writes [Reports Jobs Keys false none])
         Next (if (nth 4 Done) (+ N 1) N)
      [(svc.replace T [store (nth 1 Done) (nth 2 Done) (nth 3 Done) Next] Stores)
       (if (= (nth 5 Done) none) (sst.reply "Applied") [data "Reply" "Committed" (sst.receipt-value (nth 5 Done))])]))

\\ Acc is [Reports Jobs Keys Allocated Receipt].
(define sst.writes
  _ _ [data "Writes" "Done"] Acc -> Acc
  T N [data "Writes" "Then" W Ws] Acc -> (sst.writes T N Ws (sst.write T N W Acc)))

(define sst.write
  T N [data "Write" "PutReport" D _] [Rs Js Ks _ Rc] -> [[[N (sst.n D)] | Rs] Js Ks true Rc]
  T N [data "Write" "StageJob"] [Rs Js Ks _ Rc] -> [Rs [[N N pending] | Js] Ks true Rc]
  T N [data "Write" "StageJobOf" R] [Rs Js Ks A Rc] -> [Rs [[(sst.n R) (sst.n R) pending] | Js] Ks A Rc]
  T N [data "Write" "RecordKey" K D] [Rs Js Ks _ _] ->
    (let Rc [receipt T (sst.n K) (sst.n D) N N]
      [Rs Js [[(sst.n K) (sst.n D) Rc] | Ks] true Rc])
  T N [data "Write" "Finish" J [bool Ok]] [Rs Js Ks A Rc] ->
    [Rs (map (/. E (sst.set-status (sst.n J) Ok E)) Js) Ks A Rc])

(define sst.set-status
  J true [J R _] -> [J R done]
  J false [J R _] -> [J R failed]
  _ _ E -> E)

\\ ---------- the request and the response, between A1 and the program ----------

\\ The entry input of A1's label, as a TC1 model value and as JSON. The payload of a
\\ submit is the one octet D (A1 abstracts a payload by its digest).
(define sst.command
  [submit T K D] -> [data "Command" "Submit" [data "Cap" "Tenant" (sst.int T)] (sst.int K) (sst.int D) [bytes [D]]]
  [complete T J Ok] -> [data "Command" "Complete" [data "Cap" "Tenant" (sst.int T)] (sst.int J) [bool Ok]])

\\ The program's result as A1's response: an event, or none.
(define sst.response
  [data "Response" "Accepted" [data "Receipt" "Receipt" T K D R J]] ->
    [accepted [receipt (sst.n T) (sst.n K) (sst.n D) (sst.n R) (sst.n J)]]
  [data "Response" "Conflict" T K] -> [conflict (sst.n T) (sst.n K)]
  _ -> none)
