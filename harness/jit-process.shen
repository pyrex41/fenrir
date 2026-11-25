(define fh.process-result
  (:result.ok Value) -> [ok Value]
  (:result.err Error) -> [error Error])

(define fh.run-process
  Program Args Input Options -> (fh.process-result (process.run Program Args Input Options)))

(define fh.exit-code
  (:process.exited N) -> N
  _ -> -1)

(define fh.read-result
  (:result.ok [N]) -> [read N]
  (:result.ok []) -> [eof]
  (:result.err E) -> [error E])

(define fh.status
  (:result.ok [(:process.exited N)]) -> N
  (:result.ok [(:process.signalled N)]) -> (- 0 N)
  _ -> pending)
