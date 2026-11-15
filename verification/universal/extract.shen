\\ Extract the KLambda that the TC0 model's checked `add` compiles to, and
\\ convert it, without change of meaning, into the program data format of
\\ Búri's certificate checker (shen/contract-cert.shen at Búri 47491e2).
\\
\\ Run on the pinned Shen/JIT AFTER loading models/tc0/i64.shen and
\\ models/tc0/pure-call-machine.shen:
\\   shen-jit script extract-run.shen
\\ It prints, between markers, one line per definition in the call closure of
\\ the roots: the raw KLambda that `ps` returns, and the converted program data.
\\
\\ The conversion follows Búri's own reader of KLambda data,
\\ KLSemantics.parse (rocq/KLSemantics.v at 47491e2): keywords are special
\\ forms; a symbol bound by an enclosing lambda/let/defun parameter is a
\\ variable, any other symbol is a literal; an application whose head is a
\\ bound symbol is an application of that variable; any other symbol head is a
\\ call through the global function namespace. Nothing is simplified: in
\\ particular `cond`, `and` and `or` are kept, because that is what the model
\\ compiles to and what a certificate must be about.

(define fu.expr
  Scope X -> [num X] where (number? X)
  Scope X -> [str X] where (string? X)
  Scope X -> [bool X] where (boolean? X)
  Scope [] -> [nil]
  Scope X -> [var (str X)] where (and (symbol? X) (element? X Scope))
  Scope X -> [sym (str X)] where (symbol? X)
  Scope [lambda X B] -> [lambda (str X) (fu.expr [X | Scope] B)]
  Scope [let X A B] -> [let (str X) (fu.expr Scope A) (fu.expr [X | Scope] B)]
  Scope [if C A B] -> [if (fu.expr Scope C) (fu.expr Scope A) (fu.expr Scope B)]
  Scope [and A B] -> [and (fu.expr Scope A) (fu.expr Scope B)]
  Scope [or A B] -> [or (fu.expr Scope A) (fu.expr Scope B)]
  Scope [cond | Cs] -> [cond (map (/. C (fu.clause Scope C)) Cs)]
  Scope [trap-error A H] -> [trap (fu.expr Scope A) (fu.expr Scope H)]
  Scope [freeze A] -> [freeze (fu.expr Scope A)]
  Scope [type A _] -> [type (fu.expr Scope A)]
  Scope [defun F Ps B] -> [defun (str F) (map (/. P (str P)) Ps) (fu.expr Ps B)]
  Scope [F | Args] -> [app [var (str F)] (fu.args Scope Args)] where (and (symbol? F) (element? F Scope))
  Scope [F | Args] -> [call (str F) (fu.args Scope Args)] where (symbol? F)
  Scope [H | Args] -> [app (fu.expr Scope H) (fu.args Scope Args)]
  _ X -> (simple-error (cn "extract: unsupported KLambda " (str X))))

(define fu.args
  Scope Args -> (map (/. A (fu.expr Scope A)) Args))

(define fu.clause
  Scope [C B] -> [(fu.expr Scope C) (fu.expr Scope B)])

\\ A definition as program data: [Name Params Body].
(define fu.def
  [defun F Ps B] -> [(str F) (map (/. P (str P)) Ps) (fu.expr Ps B)])

\\ Global names called anywhere in a KLambda term.
(define fu.calls
  Scope [lambda X B] -> (fu.calls [X | Scope] B)
  Scope [let X A B] -> (append (fu.calls Scope A) (fu.calls [X | Scope] B))
  Scope [defun _ Ps B] -> (fu.calls Ps B)
  Scope [cond | Cs] -> (fu.calls-list Scope (fu.flatten Cs))
  Scope [K | Args] -> (fu.calls-list Scope Args) where (element? K [if and or trap-error freeze type])
  Scope [F | Args] -> [F | (fu.calls-list Scope Args)] where (and (symbol? F) (not (element? F Scope)))
  Scope [H | Args] -> (fu.calls-list Scope [H | Args]) where (cons? H)
  Scope [_ | Args] -> (fu.calls-list Scope Args)
  _ _ -> [])

(define fu.calls-list
  _ [] -> []
  Scope [X | Xs] -> (append (fu.calls Scope X) (fu.calls-list Scope Xs)))

(define fu.flatten
  [] -> []
  [[C B] | Cs] -> [C B | (fu.flatten Cs)])

(define fu.model?
  F -> (= "tc0." (fu.prefix 4 (str F))))

(define fu.prefix
  0 _ -> ""
  _ "" -> ""
  N S -> (cn (pos S 0) (fu.prefix (- N 1) (tlstr S))))

\\ Depth-first closure of model functions reachable from Roots, in first-visit order.
(define fu.closure
  [] Seen -> (reverse Seen)
  [F | Fs] Seen -> (fu.closure Fs Seen) where (element? F Seen)
  [F | Fs] Seen -> (fu.closure (append (fu.model-calls F) Fs) [F | Seen]))

(define fu.model-calls
  F -> (fu.uniq (fu.keep-model (fu.calls [] (ps F))) []))

(define fu.keep-model
  [] -> []
  [F | Fs] -> [F | (fu.keep-model Fs)] where (fu.model? F)
  [_ | Fs] -> (fu.keep-model Fs))

(define fu.uniq
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (fu.uniq Xs Acc) where (element? X Acc)
  [X | Xs] Acc -> (fu.uniq Xs [X | Acc]))

\\ Non-model (kernel or primitive) names called by the closure.
(define fu.external
  Fs -> (fu.uniq (fu.drop-model (fu.calls-list [] (map (/. F (ps F)) Fs))) []))

(define fu.drop-model
  [] -> []
  [F | Fs] -> (fu.drop-model Fs) where (fu.model? F)
  [F | Fs] -> [F | (fu.drop-model Fs)])

\\ Does a KLambda term contain a special form that BURI/KL-CONTRACT-1 has no rule for?
(define fu.uncovered
  [K | Rest] -> true where (element? K [cond and or])
  [X | Xs] -> (or (fu.uncovered X) (fu.uncovered Xs))
  _ -> false)

(define fu.emit
  Tag Roots ->
    (let Fs (fu.closure Roots [])
      (do (output "fu-begin ~A~%" Tag)
          (fu.emit-defs Fs)
          (output "fu-external ~S~%" (map (/. F (str F)) (fu.external Fs)))
          (output "fu-end ~A~%" Tag))))

(define fu.emit-defs
  [] -> done
  [F | Fs] -> (let K (ps F)
                (do (output "fu-kl ~S~%" K)
                    (output "fu-def ~A ~S~%" (if (fu.uncovered K) uncovered covered) (fu.def K))
                    (fu.emit-defs Fs))))
