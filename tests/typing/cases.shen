\\ Test support for tests/typing/typing.test.mjs: run the Shen-side validator and
\\ the fixed checker on given cases and report one JSON line.
\\
\\   shen-jit script tests/typing/cases.shen LIBDIR ROOT CASES.jsonl
\\
\\ Each line of CASES is {name, text, expect} with an optional derivation:
\\   with a derivation: the checker alone judges it against the artifact in text
\\     (after the structural checks); expect "accept" or "reject";
\\   without one: full Shen-side validation; for "accept" the derivation found is
\\     also written as JSON, read back, and must be accepted again.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "typing/validate.shen"))

(define tt.input -> ["int" "0"])

(define tt.case
  L -> (let Text (fh.field "text" L)
            Expect (fh.field "expect" L)
            D (fh.member "derivation" L)
            Got (if (= D []) (tt.validated Text) (tt.checked Text D))
         (= Got Expect)))

(define tt.checked
  Text D -> (tt.verdict (tt.check-structure (st.check Text) D)))

(define tt.check-structure
  [ok A] D -> (tc.check A (tt.input) D)
  _ _ -> false)

(define tt.validated
  Text -> (tt.round-trip (st.check Text) (tv.validate Text (tt.input) 2000000)))

\\ A found derivation, written out as JSON and read back, is still accepted.
(define tt.round-trip
  [ok A] [valid D] -> (tt.verdict (tc.check A (tt.input) (json.parse (json.stringify D [[byte-limit 67108864]]) [[byte-limit 67108864]])))
  _ _ -> "reject")

(define tt.verdict
  true -> "accept"
  _ -> "reject")

(define tt.run
  [] Failures N -> (do (output "~A~%" (json.stringify [object ["cases" (str N)] ["failures" (reverse Failures)]] []))
                       (shen-jit.exit (if (= Failures []) 0 1)))
  [L | Ls] Failures N -> (tt.run Ls (if (tt.case L) Failures [(fh.field "name" L) | Failures]) (+ N 1)))

(let View (buffer.from-string (read-file-as-string (hd (tl (tl (tl (value *argv*)))))))
  (tt.run (fh.json-lines View 0 (buffer.length View) []) [] 0))
