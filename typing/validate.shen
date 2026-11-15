\\ Fenrir typing: Shen-side validation of one artifact, spec/tc1/TYPING.md §1.
\\ Load harness/common.shen first; this file loads the other three.
\\
\\   (tv.validate Text V Budget)
\\     [valid D]                     structure holds, search found D, the checker accepts it
\\     [invalid Check Message]       a structural check of TYPING.md §2 failed
\\     [limit Check Message]         a cap of §2: not a judgement of the program
\\     [invalid "typing" Where]      search found no derivation
\\     [unknown Why]                 the search budget ran out: never acceptance
\\     [invalid "checker" Message]   search built a derivation the checker rejects
\\
\\ Only the first is acceptance, and only the checker can give it: what the search
\\ answers counts for nothing until tc.check has accepted the derivation it built.

\\ A heap image made from the three files (frontend/fenrir.sh) already holds them.
(if (trap-error (value ts.*loaded*) (/. E false))
    skip
    (map (/. F (load (cn (value fh.*root*) F))) ["typing/checker.shen" "typing/structure.shen" "typing/search.shen"]))

(define tv.validate
  Text V Budget -> (tv.typed (st.check Text) V Budget))

(define tv.typed
  [ok A] V Budget -> (tv.checked A V (ts.derive A V Budget))
  Verdict _ _ -> Verdict)

(define tv.checked
  _ _ [no-derivation Where] -> [invalid "typing" Where]
  _ _ [unknown Why] -> [unknown Why]
  A V D -> (if (tc.check A V D) [valid D] [invalid "checker" "the search's derivation is not accepted by the checker"]))
