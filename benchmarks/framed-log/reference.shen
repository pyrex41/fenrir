(shen-jit.library fl.lib ["libSystem.dylib"])
(define-foreign fl.read fl.lib "read" (int32 bytes int64) --> int64)
(define-foreign fl.write fl.lib "write" (int32 bytes int64) --> int64)

(define fl.reject
  Offset -> (let B (shen-jit.string->bytes (@s "reject " (str Offset) (n->string 10)))
                 _ (fl.write 2 B (shen-jit.bytes-length B))
              (shen-jit.exit 1)))

(define fl.sum
  _ I I Sum -> Sum
  B I End Sum -> (fl.sum B (+ I 1) End (+ Sum (shen-jit.u8 B I))))

(define fl.bump
  V K N -> (vector-> V K (+ (<-vector V K) N)))

(define fl.rows
  65 _ _ _ -> done
  K R S T -> (do (if (> (<-vector R K) 0)
                     (let Line (@s (str (- K 1)) " " (str (<-vector R K)) " "
                                   (str (<-vector S K)) " " (str (<-vector T K)) (n->string 10))
                          B (shen-jit.string->bytes Line)
                          N (shen-jit.bytes-length B)
                       (if (= (fl.write 1 B N) N) written (shen-jit.exit 2)))
                     skip)
                 (fl.rows (+ K 1) R S T)))

(define fl.scan
  B Cap I End At Phase Left K R S T ->
    (if (= I End)
      (let N (fl.read 0 B Cap)
        (cond ((< N 0) (shen-jit.exit 2))
              ((= N 0) (if (= Phase high) (fl.rows 1 R S T) (fl.reject At)))
              (true (fl.scan B Cap 0 N At Phase Left K R S T))))
      (cases (= Phase high)
               (fl.scan B Cap (+ I 1) End (+ At 1) low (* 256 (shen-jit.u8 B I)) K R S T)
             (= Phase low)
               (let Size (+ Left (shen-jit.u8 B I))
                 (if (= Size 0) (fl.reject (- At 1))
                     (fl.scan B Cap (+ I 1) End (+ At 1) key Size K R S T)))
             (= Phase key)
               (let Id (+ 1 (shen-jit.u8 B I))
                 (if (> Id 64) (fl.reject At)
                     (do (fl.bump R Id 1)
                         (fl.scan B Cap (+ I 1) End (+ At 1) (if (= Left 1) high payload)
                                  (- Left 1) Id R S T))))
             true
               (let N (if (< Left (- End I)) Left (- End I))
                    Stop (+ I N)
                    _ (fl.bump T K (fl.sum B I Stop 0))
                    _ (fl.bump S K N)
                 (fl.scan B Cap Stop End (+ At N) (if (= Left N) high payload) (- Left N) K R S T)))))

(define fl.zero
  0 V -> V
  N V -> (fl.zero (- N 1) (vector-> V N 0)))

(let Cap (value fl.chunk)
  (if (and (integer? Cap) (and (> Cap 0) (<= Cap 65536)))
      (fl.scan (shen-jit.bytes Cap) Cap 0 0 0 high 0 0
               (fl.zero 64 (vector 64)) (fl.zero 64 (vector 64)) (fl.zero 64 (vector 64)))
      (shen-jit.exit 2)))
