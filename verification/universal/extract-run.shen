\\ Driver for extract.shen. Paths are relative to the repository root.
(load "models/tc0/i64.shen")
(load "models/tc0/pure-call-machine.shen")
(load "verification/universal/extract.shen")
(set *maximum-print-sequence-size* 1000000)
(fu.emit add [tc0.i64.checked tc0.i64.add tc0.i64.parse])
(fu.emit arithmetic [tc0.arithmetic])
(fu.emit step [tc0.pc.step])
