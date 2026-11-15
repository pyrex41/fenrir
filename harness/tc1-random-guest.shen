\\ Fenrir harness: the generated TC1 family in the Solo5 guest. Load after common.shen,
\\ with fh.*jit* set to the Shen/JIT executable. Shared by tc1-random.shen and the
\\ proposed TC1 gate (tc1-random-rows.shen).
\\
\\ Nothing is compared here. For each seed, the programs tc1-random.shen wrote
\\ (OUT/seed-<i>.jsonl) are built into one guest image by the JavaScript builder
\\ (tools/solo5/freerun-pure-call.mjs --programs, which validates them again), and
\\ harness/solo5-pure-call.shen compares the guest with the model step for step, in its
\\ own process, and requires that both of the guest's injected defects are detected.
\\ One image per seed: the whole family would not fit in the tender's memory.

\\ The comparison's report for seed I, blocked when the image could not be built, or []
\\ when the comparison did not report.
(define fh.rg-seed
  Out I Fuel ->
    (let Directory (fh.guest-build ["--programs" (cn Out (cn "seed-" (cn (str I) ".jsonl"))) "--fuel" (str Fuel)])
      (if (= Directory blocked) blocked (fh.harness "solo5-pure-call.shen" [Directory] 3600))))

(define fh.rg-number
  Key Report -> (let N (fh.member Key Report) (if (string? N) (tc0.i64.small N) 0)))

\\ Sums is [Programs ModelSteps GuestSteps Differing Batches]. Stops at the first
\\ batch that cannot be built: [blocked Sums]; otherwise [Status Sums], where Status is
\\ "fail" once any batch fails and else "unknown" once any batch is missing or is not
\\ the batch asked for.
(define fh.rg-seeds
  Out I Seeds PerSeed Fuel Status Sums -> [Status Sums] where (>= I Seeds)
  Out I Seeds PerSeed Fuel Status [Programs Model Guest Differing Batches] ->
    (let Report (fh.rg-seed Out I Fuel)
      (if (= Report blocked)
          ["blocked" [Programs Model Guest Differing Batches]]
          (fh.rg-seeds Out (+ I 1) Seeds PerSeed Fuel
            (fh.rg-worse Status
              (if (= (fh.member "status" Report) "development-fail") "fail"
                  (if (and (= (fh.member "status" Report) "development-pass")
                           (= (fh.member "programs" Report) (str PerSeed))
                           (= (fh.member "fuel" Report) (str Fuel)))
                      "pass" "unknown")))
            [(+ Programs (fh.rg-number "programs" Report)) (+ Model (fh.rg-number "model_steps" Report))
             (+ Guest (fh.rg-number "guest_steps" Report)) (+ Differing (fh.rg-number "programs_differing" Report))
             (+ Batches 1)]))))

(define fh.rg-worse
  "fail" _ -> "fail"
  _ "fail" -> "fail"
  "unknown" _ -> "unknown"
  _ "unknown" -> "unknown"
  _ _ -> "pass")

\\ {status: pass | fail | unknown | blocked, batches, programs, model_steps, guest_steps, programs_differing}
(define fh.rg-family
  Out Seeds PerSeed Fuel ->
    (let R (fh.rg-seeds Out 0 Seeds PerSeed Fuel "pass" [0 0 0 0 0])
         Sums (hd (tl R))
      [object ["status" (hd R)] ["batches" (str (nth 5 Sums))] ["batches_expected" (str Seeds)] ["programs" (str (hd Sums))]
              ["step_bound" (str Fuel)] ["model_steps" (str (nth 2 Sums))] ["guest_steps" (str (nth 3 Sums))]
              ["programs_differing" (str (nth 4 Sums))]]))
