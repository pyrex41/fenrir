\\ Test support for tests/typing/typing.test.mjs: run the Shen-side validator and
\\ the fixed checker on given cases and report one JSON line.
\\
\\   shen-jit script tests/typing/cases.shen LIBDIR ROOT CASES.jsonl
\\
\\ Each line of CASES is {name, text, expect} with optional input and derivation:
\\   with a derivation: the checker alone judges it against the artifact in text
\\     (after the structural checks); expect "accept" or "reject";
\\   without one: full Shen-side validation; for "accept" the derivation found is
\\     also written as JSON, read back, and must be accepted again.
\\   "direct": true exercises the raw checker on unsupported schemas.
\\   "low_budget": true selects one inference.
\\   "unsound": true or "scope" expects a test-only extension to produce a proof
\\     that the fixed checker rejects, rather than a search failure.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "typing/validate.shen"))
(load (cn (value fh.*root*) "typing/unsound.shen"))

(define tt.input -> ["int" "0"])

(define tt.case
  L -> (let Text (fh.field "text" L)
            Expect (fh.field "expect" L)
            Given (fh.member "input" L)
            Input (if (= Given []) (tt.input) Given)
            Limit (if (= (fh.member "low_budget" L) true) 1 2000000)
            D (fh.member "derivation" L)
            Unsound (fh.member "unsound" L)
            Got (cond ((= Unsound true) (tt.unsound (st.check Text) Input Limit fenrir-unsound-anything))
                      ((= Unsound "scope") (tt.unsound (st.check Text) Input Limit fenrir-unsound-scope))
                      ((= (fh.member "direct" L) true) (tt.verdict (tc.check (st.transport Text) Input D)))
                      ((= D []) (tt.validated Text Input Limit))
                      (true (tt.check-structure (st.with-input (st.check Text) Input) Input D)))
         (= Got Expect)))

(define tt.check-structure
  [ok A] V D -> (tt.verdict (tc.check A V D))
  _ _ _ -> "reject")

(define tt.validated
  Text Input Limit -> (tt.round-trip (tv.validate Text Input Limit) Text Input))

\\ A found derivation, written out as JSON and read back, is still accepted.
(define tt.round-trip
  [valid D] Text Input ->
    (tt.verdict (tc.check (st.transport Text) Input (json.parse (json.stringify D [[byte-limit 67108864]]) [[byte-limit 67108864]])))
  [unsupported _] _ _ -> "unsupported"
  [unknown _] _ _ -> "unknown"
  [limit _ _] _ _ -> "limit"
  _ _ _ -> "reject")

(define tt.unsound
  [ok A] V Limit Rule -> (let On (include [Rule])
                         D (ts.derive A V Limit)
                         Off (preclude [Rule])
                      (if (and (cons? D) (= (hd D) "Program") (not (tc.check A V D)))
                          "forgery-rejected" "not-a-rejected-forgery"))
  _ _ _ _ -> "bad-fixture")

(define tt.verdict
  true -> "accept"
  _ -> "reject")

(define tt.run
  [] Failures N -> (do (output "~A~%" (json.stringify [object ["cases" (str N)] ["failures" (reverse Failures)]] []))
                       (shen-jit.exit (if (= Failures []) 0 1)))
  [L | Ls] Failures N -> (tt.run Ls (if (tt.case L) Failures [(fh.field "name" L) | Failures]) (+ N 1)))

(let View (buffer.from-string (read-file-as-string (hd (tl (tl (tl (value *argv*)))))))
  (tt.run (fh.json-lines View 0 (buffer.length View) []) [] 0))
