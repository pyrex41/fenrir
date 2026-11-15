\\ The A4 host contracts on the A4 state: the v2 storage contract (spec/service/UPGRADE.md
\\ section 2.2), fencing of commits by version (section 4.3), and the migration contract
\\ (section 5: rows read one at a time from a snapshot, staged, and installed as a
\\ compare-and-swap). Load models/service/accepted-job.shen,
\\ models/service-a2/store-contract.shen (the v1 storage contract, unchanged) and
\\ upgrade.shen first. UNQUALIFIED.
\\
\\ Values are TC1 model values (models/tc1/durable-machine.shen), as in the A2 contract.
\\
\\ sst4.commit U Stores Tx    [Stores' Reply], or fenced (refused: nothing applied, no reply)
\\ sst4.read, sst4.stage, sst4.install   the migration session (below)

\\ ---------- receipts of either version ----------

(define sst4.receipt-value
  [receipt T K D R J] -> [data "Receipt" "Receipt" (sst.int T) (sst.int K) (sst.int D) (sst.int R) (sst.int J)]
  [receipt T K D R J 2] -> [data "Receipt" "Receipt2" (sst.int T) (sst.int K) (sst.int D) (sst.int R) (sst.int J)])

(define sst4.receipt-of
  [data "Receipt" "Receipt" T K D R J] -> [receipt (sst.n T) (sst.n K) (sst.n D) (sst.n R) (sst.n J)]
  [data "Receipt" "Receipt2" T K D R J] -> [receipt (sst.n T) (sst.n K) (sst.n D) (sst.n R) (sst.n J) 2])

\\ ---------- the v2 storage contract on a schema-2 store ----------

(define sst2.commit
  Stores [data "Tx" "Tx2" [data "Cap" "Tenant" T] Guard Writes] ->
    (let Tenant (sst.n T)
      (if (svc.tenant? Tenant Stores)
          (sst2.guarded Tenant Guard Writes Stores (svc.store Tenant Stores))
          [Stores (sst.reply "Unauthorized")]))
  Stores _ -> [Stores (sst.reply "Unauthorized")])

(define sst2.guarded
  T [data "Guard" "Always"] Writes Stores Store -> (sst2.apply T Writes Stores Store)
  T [data "Guard" "Once" K] Writes Stores Store ->
    (let Found (svc.lookup (sst.n K) (svc.keys Store))
      (if (= Found none)
          (sst2.apply T Writes Stores Store)
          [Stores [data "Reply" "Recorded" (sst.int (nth 2 Found)) (sst4.receipt-value (nth 3 Found))]]))
  T [data "Guard" "Pending" J] Writes Stores Store ->
    (if (sst2.pending? (sst.n J) (svc.jobs Store))
        (sst2.apply T Writes Stores Store)
        [Stores (sst.reply "Skipped")]))

(define sst2.pending?
  _ [] -> false
  J [[J _ pending | _] | _] -> true
  J [_ | Js] -> (sst2.pending? J Js))

\\ The writes in order with N = Next; Acc is [Reports Jobs Keys Allocated Receipt].
(define sst2.apply
  T Writes Stores [store Reports Jobs Keys N] ->
    (let Done (sst2.writes T N Writes [Reports Jobs Keys false none])
         Next (if (nth 4 Done) (+ N 1) N)
      [(svc.replace T [store (nth 1 Done) (nth 2 Done) (nth 3 Done) Next] Stores)
       (if (= (nth 5 Done) none) (sst.reply "Applied") [data "Reply" "Committed" (sst4.receipt-value (nth 5 Done))])]))

(define sst2.writes
  _ _ [data "Writes" "Done"] Acc -> Acc
  T N [data "Writes" "Then" W Ws] Acc -> (sst2.writes T N Ws (sst2.write T N W Acc)))

(define sst2.write
  T N [data "Write" "PutReport" D _] [Rs Js Ks _ Rc] -> [[[N (sst.n D)] | Rs] Js Ks true Rc]
  T N [data "Write" "StageJob2" A] [Rs Js Ks _ Rc] -> [Rs [[N N pending (sst.n A)] | Js] Ks true Rc]
  T N [data "Write" "RecordKey" K D] [Rs Js Ks _ _] ->
    (let Rc [receipt T (sst.n K) (sst.n D) N N 2]
      [Rs Js [[(sst.n K) (sst.n D) Rc] | Ks] true Rc])
  T N [data "Write" "Finish" J [bool Ok]] [Rs Js Ks A Rc] ->
    [Rs (map (/. E (sst2.set-status (sst.n J) Ok E)) Js) Ks A Rc]
  T N [data "Write" "CountAttempt" J] [Rs Js Ks A Rc] ->
    [Rs (map (/. E (sst2.count (sst.n J) E)) Js) Ks A Rc])

(define sst2.set-status
  J true [J R _ A] -> [J R done A]
  J false [J R _ A] -> [J R failed A]
  _ _ E -> E)

(define sst2.count
  J [J R St A] -> [J R St (+ A 1)]
  _ E -> E)

\\ ---------- fencing (UPGRADE.md section 4.3) ----------

\\ The contract version a commit carries in band: its constructor.
(define sst4.version-of
  [data "Tx" "Tx" | _] -> 1
  [data "Tx" "Tx2" | _] -> 2
  _ -> none)

(define sst4.commit
  U Stores Tx -> (let V (sst4.version-of Tx)
                   (cond ((or (= V none) (not (= V (sua.in-force U)))) fenced)
                         ((= V 1) (sst.commit Stores Tx))
                         (true (sst2.commit Stores Tx)))))

\\ The program's result as the A4 response: an event of either receipt representation,
\\ or none.
(define sst4.response
  [data "Response" "Accepted" Rc] -> [accepted (sst4.receipt-of Rc)]
  [data "Response" "Conflict" T K] -> [conflict (sst.n T) (sst.n K)]
  _ -> none)

\\ ---------- the migration contract (UPGRADE.md section 5) ----------

(define sst4.status
  pending -> [data "Status" "Pending"]
  done -> [data "Status" "Done"]
  failed -> [data "Status" "Failed"])

(define sst4.status-of
  [data "Status" "Pending"] -> pending
  [data "Status" "Done"] -> done
  [data "Status" "Failed"] -> failed)

\\ Every job row, then every key row, of tenant 0, then tenant 1, ...; each in the
\\ store's own order.
(define sst4.rows
  _ [] -> []
  T [[store _ Jobs Keys _] | Stores] ->
    (append (map (/. J [data "Row1" "Job1" (sst.int T) (sst.int (hd J)) (sst.int (nth 2 J)) (sst4.status (nth 3 J))]) Jobs)
            (map (/. K [data "Row1" "Key1" (sst.int T) (sst.int (hd K)) (sst.int (nth 2 K)) (sst4.receipt-value (nth 3 K))]) Keys)
            (sst4.rows (+ T 1) Stores)))


\\ The host's migration session, volatile and the migration run's own: [session Rows
\\ Staged] or none. Rows is the snapshot taken when row 0 was read, Staged the rows the
\\ program staged since, in order.
\\
\\ sst4.read Session Stores I       [Session' Reply]: row I of the snapshot, or NoMore;
\\                                  reading row 0 takes a new snapshot and drops the staged rows
\\ sst4.stage Session Row           [Session' Reply]
\\ sst4.install U Stores Session N  [U' Stores' Session' Reply]: Installed when U is
\\   prepared, the program read all N rows of the snapshot, and the store still holds
\\   exactly the snapshot (compare-and-swap); then every job and key row is replaced by
\\   the staged rows, in their order, reports and Next are kept, the schema becomes 2 and
\\   U [migrated Img]. Changed when the store moved since the snapshot; Refused otherwise.
\\   Nothing is applied unless Installed; the session ends either way.

(define sst4.read
  _ Stores [int "0"] -> (let Rows (sst4.rows 0 Stores) [[session Rows []] (sst4.nth-row Rows 0)])
  [session Rows Staged] _ I -> [[session Rows Staged] (sst4.nth-row Rows (sst.n I))]
  Session _ _ -> [Session [data "Next1" "NoMore"]])

(define sst4.nth-row
  Rows I -> (if (and (>= I 0) (< I (length Rows))) [data "Next1" "Next" (nth (+ I 1) Rows)] [data "Next1" "NoMore"]))

(define sst4.stage
  [session Rows Staged] Row -> [[session Rows (append Staged [Row])] [data "Ack" "Ack"]]
  Session _ -> [Session [data "Ack" "Ack"]])

(define sst4.install
  [prepared Img] Stores [session Rows Staged] N ->
    (cond ((not (= (sst.n N) (length Rows))) [[prepared Img] Stores none [data "Migrated" "Refused"]])
          ((not (= Rows (sst4.rows 0 Stores))) [[prepared Img] Stores none [data "Migrated" "Changed"]])
          (true (let New (sst4.place Staged (map (/. S [store (svc.reports S) [] [] (svc.next S)]) Stores))
                  (if (= New refused)
                      [[prepared Img] Stores none [data "Migrated" "Refused"]]
                      [[migrated Img] (map (/. S (sst4.reverse-rows S)) New) none [data "Migrated" "Installed"]]))))
  U Stores _ _ -> [U Stores none [data "Migrated" "Refused"]])

\\ Rows are placed by prepending, then each list is reversed: the program's order.
(define sst4.place
  [] Stores -> Stores
  [[data "Row2" "Job2" T J R St A] | Rows] Stores ->
    (sst4.place-in (sst.n T) (/. S [store (svc.reports S) [[(sst.n J) (sst.n R) (sst4.status-of St) (sst.n A)] | (svc.jobs S)] (svc.keys S) (svc.next S)])
                   Rows Stores)
  [[data "Row2" "Key2" T K D Rc] | Rows] Stores ->
    (sst4.place-in (sst.n T) (/. S [store (svc.reports S) (svc.jobs S) [[(sst.n K) (sst.n D) (sst4.receipt-of Rc)] | (svc.keys S)] (svc.next S)])
                   Rows Stores))

(define sst4.place-in
  T F Rows Stores -> (if (svc.tenant? T Stores) (sst4.place Rows (svc.replace T (F (svc.store T Stores)) Stores)) refused))

(define sst4.reverse-rows
  [store Reports Jobs Keys N] -> [store Reports (reverse Jobs) (reverse Keys) N])
