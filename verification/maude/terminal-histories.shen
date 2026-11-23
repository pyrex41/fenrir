(set sx.*as-library* true)
(load (cn (nth 3 (value *argv*)) "/harness/service-explore.shen"))

(define mh.walk
  Machine Sys Budget Path ->
    (let Labels (sx.filter (/. L (not (= exhausted (sx.spend (sx.kind L) Budget))))
                        ((sx.labels-fn Machine) [1 1 1] Sys))
      (if (= Labels [])
          (output "HISTORY ~A~%" (sx.json [(reverse Path) (sx.state Sys)]))
          (map (/. L (mh.next Machine L Sys Budget Path)) Labels))))

(define mh.next
  Machine L Sys Budget Path ->
    (let Result ((sx.step-fn Machine) L Sys)
      (if (= (hd Result) ok)
          (do (mh.walk Machine (nth 2 Result) (sx.spend (sx.kind L) Budget)
                       [(sx.label L) | Path]) true)
          (error "enabled label failed ~S" L))))

(mh.walk (smu.machine (nth 5 (value *argv*))) (svc.initial 1) [2 2 2 1] [])
