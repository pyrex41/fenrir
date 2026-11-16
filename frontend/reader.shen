\\ Fenrir frontend, reader: source bytes to S-expressions that remember where
\\ they were written. Contract for the syntax: spec/tc1/SURFACE.md (a draft).
\\
\\ Input is the file as a list of octets, so that positions are counted here and
\\ string literals keep their exact bytes. A datum is one of
\\   [sym Line Column Text]      any other word: names, keywords, ->, +, ...
\\   [int Line Column Decimal]   canonical decimal text (never a Shen number:
\\                               Shen/JIT integers are 62-bit, I64 is not)
\\   [hex Line Column Hex]       a bytes literal #x..., lowercase hex
\\   [str Line Column Octets]    a string literal, as its octets
\\   [list Line Column Items]    ( ... )
\\   [brace Line Column Items]   { ... }
\\ Lines and columns start at 1. A column counts characters, not octets: UTF-8
\\ continuation octets do not advance it.
\\
\\ Every loop over the input is tail recursive: a source file is thousands of
\\ octets and must not need that much stack.

\\ ---------- diagnostics ----------

\\ A rejected program is reported by raising a Shen error after recording the
\\ position and message here. The driver tells a diagnostic from a defect in the
\\ frontend itself by this record, not by the error text.
(set fe.*diagnostic* [])

\\ A position inside an included file has [at-file File Line] for its line
\\ (elaborate.shen, fe.retag); the diagnostic then names that file.
(define fe.fail
  [at-file File Line] Column Message -> (do (set fe.*diagnostic* [Line Column Message File])
                                            (error "fenrir diagnostic"))
  Line Column Message -> (do (set fe.*diagnostic* [Line Column Message])
                             (error "fenrir diagnostic")))

\\ ---------- octets ----------

(define fe.digit?
  B -> (and (>= B 48) (<= B 57)))

(define fe.hex-digit?
  B -> (or (fe.digit? B) (and (>= B 97) (<= B 102)) (and (>= B 65) (<= B 70))))

\\ Bytes literals are stored in lowercase, the artifact's spelling.
(define fe.lower-hex
  B -> (+ B 32) where (and (>= B 65) (<= B 70))
  B -> B)

(define fe.all?
  _ [] -> true
  F [X | Xs] -> (and (F X) (fe.all? F Xs)))

\\ Octets (most recent first) to a string. Only used for ASCII words.
(define fe.text
  [] Acc -> Acc
  [B | Bs] Acc -> (fe.text Bs (cn (n->string B) Acc)))

(define fe.string-of
  Octets -> (fe.text (reverse Octets) ""))

\\ What ends a word: white space, a bracket, a quote, or the end of input.
(define fe.delimiter?
  B -> (element? B [32 9 10 13 40 41 123 125 34]))

\\ ---------- words ----------

(define fe.drop-zeros
  [48 D | Ds] -> (fe.drop-zeros [D | Ds])
  Ds -> Ds)

\\ Canonical decimal: no leading zeros, no negative zero.
(define fe.decimal
  [45 | Ds] -> (let Digits (fe.drop-zeros Ds)
                 (if (= Digits [48]) "0" (cn "-" (fe.string-of Digits))))
  Ds -> (fe.string-of (fe.drop-zeros Ds)))

\\ I64 range, decided on the digits: |N| <= 2^63 - 1, or N = -2^63.
(define fe.digits<=?
  [] [] -> true
  [A | As] [B | Bs] -> (if (= A B) (fe.digits<=? As Bs) (< A B)))

(define fe.magnitude-fits?
  Digits Limit -> (let N (length Digits)
                       M (length Limit)
                    (or (< N M) (and (= N M) (fe.digits<=? Digits Limit)))))

(define fe.i64?
  [45 | Ds] -> (fe.magnitude-fits? (fe.drop-zeros Ds) [57 50 50 51 51 55 50 48 51 54 56 53 52 55 55 53 56 48 56])
  Ds -> (fe.magnitude-fits? (fe.drop-zeros Ds) [57 50 50 51 51 55 50 48 51 54 56 53 52 55 55 53 56 48 55]))

(define fe.integer
  L C Octets -> (if (fe.i64? Octets)
                    [int L C (fe.decimal Octets)]
                    (fe.fail L C (make-string "integer literal ~A is outside I64 (-9223372036854775808 to 9223372036854775807)"
                                              (fe.string-of Octets)))))

(define fe.pairs?
  [] -> true
  [_ _ | Xs] -> (fe.pairs? Xs)
  _ -> false)

(define fe.bytes-literal
  L C Digits -> (fe.fail L C "a bytes literal is #x followed by hexadecimal digits")
    where (not (fe.all? (/. B (fe.hex-digit? B)) Digits))
  L C Digits -> (fe.fail L C "a bytes literal needs an even number of hexadecimal digits: two for each octet")
    where (not (fe.pairs? Digits))
  L C Digits -> [hex L C (fe.string-of (map (/. B (fe.lower-hex B)) Digits))])

\\ Classify one word, given its octets in order.
(define fe.word
  L C [45 D | Ds] -> (if (fe.all? (/. B (fe.digit? B)) Ds)
                         (fe.integer L C [45 D | Ds])
                         (fe.fail L C (make-string "~A is not an integer literal" (fe.string-of [45 D | Ds]))))
    where (fe.digit? D)
  L C [D | Ds] -> (if (fe.all? (/. B (fe.digit? B)) Ds)
                      (fe.integer L C [D | Ds])
                      (fe.fail L C (make-string "~A is not an integer literal, and a name cannot start with a digit" (fe.string-of [D | Ds]))))
    where (fe.digit? D)
  L C [35 120 | Digits] -> (fe.bytes-literal L C Digits)
  L C [35 | _] -> (fe.fail L C "a bytes literal is #x followed by hexadecimal digits")
  L C Octets -> (if (fe.all? (/. B (and (> B 32) (< B 127))) Octets)
                    [sym L C (fe.string-of Octets)]
                    (fe.fail L C "a word may only contain printable ASCII characters")))

\\ ---------- tokens ----------

\\ Skip a comment: everything up to, not including, the end of the line.
(define fe.skip-line
  [] -> []
  [10 | Bs] -> [10 | Bs]
  [_ | Bs] -> (fe.skip-line Bs))

\\ A UTF-8 continuation octet belongs to the character before it.
(define fe.advance
  B C -> C where (and (>= B 128) (< B 192))
  _ C -> (+ C 1))

\\ Rest L C are the input and position after the opening quote; L0 C0 is the quote.
\\ Escapes: \\ \" \n. A string ends on its own line.
(define fe.string
  [] _ _ L0 C0 _ _ -> (fe.fail L0 C0 "this string literal is never closed")
  [10 | _] _ _ L0 C0 _ _ -> (fe.fail L0 C0 "this string literal is not closed on its line")
  [34 | Bs] L C L0 C0 Octets Acc -> (fe.tokens Bs L (+ C 1) [[str L0 C0 (reverse Octets)] | Acc])
  [92 92 | Bs] L C L0 C0 Octets Acc -> (fe.string Bs L (+ C 2) L0 C0 [92 | Octets] Acc)
  [92 34 | Bs] L C L0 C0 Octets Acc -> (fe.string Bs L (+ C 2) L0 C0 [34 | Octets] Acc)
  [92 110 | Bs] L C L0 C0 Octets Acc -> (fe.string Bs L (+ C 2) L0 C0 [10 | Octets] Acc)
  [92 | _] L C _ _ _ _ -> (fe.fail L C "unknown escape in a string literal: the escapes are \\, \c#34; and \n")
  [B | Bs] L C L0 C0 Octets Acc -> (fe.string Bs L (fe.advance B C) L0 C0 [B | Octets] Acc))

\\ Collect one word. Word holds its octets, most recent first.
(define fe.scan-word
  [B | Bs] L C L0 C0 Word Acc -> (fe.scan-word Bs L (fe.advance B C) L0 C0 [B | Word] Acc)
    where (not (fe.delimiter? B))
  Bs L C L0 C0 Word Acc -> (fe.tokens Bs L C [(fe.word L0 C0 (reverse Word)) | Acc]))

\\ Tokens are the atoms above and [open L C], [close L C], [open-brace L C],
\\ [close-brace L C].
(define fe.tokens
  [] _ _ Acc -> (reverse Acc)
  [10 | Bs] L _ Acc -> (fe.tokens Bs (+ L 1) 1 Acc)
  [B | Bs] L C Acc -> (fe.tokens Bs L (+ C 1) Acc) where (element? B [32 9 13])
  [92 92 | Bs] L C Acc -> (fe.tokens (fe.skip-line Bs) L C Acc)
  [40 | Bs] L C Acc -> (fe.tokens Bs L (+ C 1) [[open L C] | Acc])
  [41 | Bs] L C Acc -> (fe.tokens Bs L (+ C 1) [[close L C] | Acc])
  [123 | Bs] L C Acc -> (fe.tokens Bs L (+ C 1) [[open-brace L C] | Acc])
  [125 | Bs] L C Acc -> (fe.tokens Bs L (+ C 1) [[close-brace L C] | Acc])
  [34 | Bs] L C Acc -> (fe.string Bs L (+ C 1) L C [] Acc)
  [B | _] L C _ -> (fe.fail L C "control characters are not allowed in a program") where (< B 32)
  Bs L C Acc -> (fe.scan-word Bs L C L C [] Acc))

\\ ---------- nesting ----------

\\ Stack holds the open brackets, innermost first, each [Kind Line Column Items]
\\ with Items most recent first. Done holds the finished top-level data.
(define fe.close
  Datum Ts [] Done -> (fe.nest Ts [] [Datum | Done])
  Datum Ts [[Kind L C Items] | Stack] Done -> (fe.nest Ts [[Kind L C [Datum | Items]] | Stack] Done))

(define fe.nest
  [] [] Done -> (reverse Done)
  [] [[list L C _] | _] _ -> (fe.fail L C "this ( is never closed")
  [] [[brace L C _] | _] _ -> (fe.fail L C "this { is never closed")
  [[open L C] | Ts] Stack Done -> (fe.nest Ts [[list L C []] | Stack] Done)
  [[open-brace L C] | Ts] Stack Done -> (fe.nest Ts [[brace L C []] | Stack] Done)
  [[close _ _] | Ts] [[list L C Items] | Stack] Done -> (fe.close [list L C (reverse Items)] Ts Stack Done)
  [[close-brace _ _] | Ts] [[brace L C Items] | Stack] Done -> (fe.close [brace L C (reverse Items)] Ts Stack Done)
  [[close L C] | _] [[brace L0 C0 _] | _] _ ->
    (fe.fail L C (make-string ") closes the { opened at line ~A, column ~A: a } is expected" L0 C0))
  [[close-brace L C] | _] [[list L0 C0 _] | _] _ ->
    (fe.fail L C (make-string "} closes the ( opened at line ~A, column ~A: a ) is expected" L0 C0))
  [[close L C] | _] [] _ -> (fe.fail L C "this ) has no matching (")
  [[close-brace L C] | _] [] _ -> (fe.fail L C "this } has no matching {")
  [Atom | Ts] Stack Done -> (fe.close Atom Ts Stack Done))

\\ The top-level data of a source file, in order.
(define fe.read
  Octets -> (fe.nest (fe.tokens Octets 1 1 []) [] []))
