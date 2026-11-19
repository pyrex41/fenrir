\\ Fenrir harness, in Shen: the peer programs of the remote-perform model check,
\\ from their source files. Load after common.shen and the remote models.
\\
\\ A peer of the model is the program of a source file with a (serve ...) form
\\ (spec/tc1/EFFECTS.md section 12.12). This file elaborates such a source with
\\ the frontend, in this process (frontend/reader.shen, frontend/elaborate.shen),
\\ has the artifact validator judge the bytes (tools/tc0/pure-call-artifact.mjs,
\\ through frontend/validate.mjs: read-only is checked there too), and makes the
\\ model's peer of what is decoded from those same bytes (fh.peer). Nothing
\\ else of an implementation is run: no image, no supervisor.
\\   fp.served Tag HasStore Source   -> [served Program], a handler of the model
\\ Source is named relative to the repository.

(load (cn (value fh.*root*) "frontend/reader.shen"))
(load (cn (value fh.*root*) "frontend/elaborate.shen"))

(set fp.*work* [])

(define fp.work
  -> (if (= (value fp.*work*) [])
         (let R (fh.exec "mktemp" ["-d"] 30)
           (if (= (hd R) 0) (set fp.*work* (cn (fh.trim (hd (tl R))) "/")) (error "harness: no scratch directory")))
         (value fp.*work*)))

\\ The artifact of a source file: decoded from the bytes the validator accepted.
(define fp.artifact
  Tag Source ->
    (let File (cn (value fh.*root*) Source)
         Cleared (set fe.*diagnostic* [])
         Elaborated (trap-error (fe.elaborate File Tag (read-file-as-bytelist File))
                                (/. E (error "harness: ~A is rejected by the frontend: ~S ~A" Source (value fe.*diagnostic*) (error-to-string E))))
         Text (json.stringify Elaborated [[byte-limit 16777216]])
         Path (cn (fp.work) (cn Tag ".json"))
         Written (write-to-file Path Text)
         R (fh.exec "node" [(cn (value fh.*root*) "frontend/validate.mjs") Path] 120)
         Report (fh.last-report (hd (tl R)))
      (if (and (= (hd R) 0) (= (fh.member "status" Report) "valid") (= (fh.member "canonical" Report) true))
          (json.parse Text [[byte-limit 16777216]])
          (error "harness: the artifact of ~A is not valid: ~S" Source Report))))

(define fp.served
  Tag HasStore Source -> [served (fh.peer Tag HasStore (fp.artifact Tag Source))])
