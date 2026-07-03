;; Title: mia-single-faktory
;; Summary: Single-sided liquidity offering for the MIA(v2)/sBTC pool. The MIA
;;   side is provided (for free to the contract) by the Fast Pool arb
;;   `mia-fair-faktory`; the community supplies ONLY sBTC, locked ~3 months, and
;;   on unlock keeps 60% of their LP position. Port of SPV9K21....flat-single-
;;   faktory with the amendments below.
;;
;; AMENDMENTS vs flat-single-faktory (diff these side by side):
;;   1. token (single side): flat-earth-stxcity -> miamicoin-token-v2 (v2 only)
;;   2. pool: flatearth-faktory-pool -> .mia-pool-faktory (this repo)
;;   3. UNLOCK SPLIT: the depositor's 40% is NOT returned. On withdraw we remove
;;      only 60% of the user's LP and hand 100% of THAT to the user; the other
;;      40% of LP stays held by this contract and is never removed -> permanently
;;      locked liquidity in the pool.
;;   4. DEPOSITOR is a CONSTANT = mia-fair-faktory (the arb/accumulator), not a
;;      var set at init. Only it may seed the MIA side.
;;   5. SEEDING IS REPEATABLE: initialize-pool has no one-shot guard, so the
;;      accumulator can top up MIA over 2-3 cycles. `initial-token-amount`
;;      accumulates; the lock CLOCK (`creation-block`) is anchored ONCE on the
;;      first seed. NO entry deadline: the community can pair sBTC for as long
;;      as the contract still holds unpaired MIA (add-liquidity fails once the
;;      MIA is exhausted).
;;   6. REMOVED the depositor-only withdrawals: nothing ever returns to the
;;      standalone.
;;   7. Clarity 5: uses `current-contract` (not a CONTRACT constant) and moves
;;      contract-held assets under `as-contract?` with explicit post-conditions.

;; ---- contract references (constants) ----
(define-constant POOL .mia-pool-faktory)
(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
;; the arb/accumulator that seeds the MIA side and is barred from depositing sBTC.
;; Full principal (not .mia-fair-faktory) so Clarity treats it as external and no
;; deploy-order cycle forms with mia-fair-faktory (which calls back into here).
(define-constant DEPOSITOR 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)


(define-constant ERR_UNAUTHORIZED (err u403))
(define-constant ERR_NOT_STARTED (err u404))
(define-constant ERR_INSUFFICIENT_AMOUNT (err u406))
(define-constant ERR_STILL_LOCKED (err u407))
(define-constant ERR_NO_DEPOSIT (err u408))
(define-constant ERR_CALC_AMOUNTS (err u410))

(define-constant LOCK_PERIOD u25)  ;; ~90 days in bitcoin blocks

;; user keeps 60% of their LP on unlock; 40% stays locked in the pool forever
(define-constant USER_BPS u60)

(define-data-var creation-block uint u0)        ;; 0 until the first seed; clock anchor
(define-data-var initial-token-amount uint u0)  ;; total MIA seeded (accumulates)
(define-data-var token-used-for-lp uint u0)
(define-data-var total-lp-tokens uint u0)

(define-map user-lp-tokens principal uint)

;; Seed / top up the MIA side. Only the accumulator (DEPOSITOR) may call, which
;; it does via as-contract, so tx-sender is mia-fair-faktory. Repeatable across
;; cycles: MIA accumulates and the clock is anchored on the first seed.
(define-public (initialize-pool (token-amount uint))
  (let ((init-token-amt (var-get initial-token-amount))
        (creation-b (var-get creation-block)))
    (asserts! (is-eq tx-sender DEPOSITOR) ERR_UNAUTHORIZED)
    (asserts! (> token-amount u0) ERR_INSUFFICIENT_AMOUNT)

    ;; pull MIA from the accumulator (tx-sender) into this contract
    (try! (contract-call? MIA transfer token-amount tx-sender current-contract none))

    ;; anchor the entry/lock clock on the FIRST seed only
    (if (is-eq creation-b u0)
      (var-set creation-block burn-block-height)
      true)
    (var-set initial-token-amount (+ init-token-amt token-amount))

    (print {
      type: "pool-seeded",
      depositor: DEPOSITOR,
      token-amount: token-amount,
      total-seeded: init-token-amt,
      creation-block: creation-b,
      unlock-block: (+ creation-b LOCK_PERIOD),
      ft: MIA
    })

    (ok true)
  )
)

;; Community supplies sBTC; contract pairs it with its MIA and mints LP (held by
;; this contract, attributed to the user).
(define-public (deposit-sbtc-for-lp (lp-amount uint))
    (let (
          (amounts (unwrap! (calculate-amounts-for-lp lp-amount) ERR_CALC_AMOUNTS))
          (sbtc-needed (get sbtc-needed amounts))
          (token-needed (get token-needed amounts))
          (deposit (try! (contract-call? SBTC transfer sbtc-needed tx-sender current-contract none)))
          ;; pair against the pool: contract sends sbtc-needed sBTC + token-needed
          ;; MIA out; nothing else may leave under this as-contract?.
          (lp-result (try! (as-contract? ((with-ft SBTC "sbtc-token" sbtc-needed)
                                          (with-ft MIA "miamicoin" token-needed))
                             (try! (contract-call? POOL add-liquidity lp-amount)))))
          (lp-tokens-received (get dk lp-result))
          (current-lp (default-to u0 (map-get? user-lp-tokens tx-sender))))

    ;; no entry deadline: pairing is open as long as the contract still holds
    ;; unpaired MIA (add-liquidity fails once it's exhausted). No DEPOSITOR guard
    ;; needed either -- mia-fair-faktory has no path that calls this.
    (asserts! (> (var-get creation-block) u0) ERR_NOT_STARTED)

      (map-set user-lp-tokens tx-sender (+ current-lp lp-tokens-received))
      (var-set total-lp-tokens (+ (var-get total-lp-tokens) lp-tokens-received))
      (var-set token-used-for-lp (+ (var-get token-used-for-lp) token-needed))

      (print {
        type: "community-lp-deposit",
        user: tx-sender,
        sbtc-in: sbtc-needed,
        token-used: token-needed,
        lp-tokens: lp-tokens-received,
        unlock-block: (+ (var-get creation-block) LOCK_PERIOD),
        ft: MIA
      })

      (ok lp-tokens-received)
    )
  )

;; After the lock: user removes 60% of their LP and keeps 100% of the proceeds.
;; The remaining 40% LP stays with this contract and is never removed -> locked
;; liquidity in the pool forever (nothing returns to the standalone/depositor).
(define-public (withdraw-lp-tokens)
  (let ((unlock-block (+ (var-get creation-block) LOCK_PERIOD))
        (user-lp (default-to u0 (map-get? user-lp-tokens tx-sender)))
        (user-lp-to-remove (/ (* user-lp USER_BPS) u100))
        (user tx-sender))
    (asserts! (>= burn-block-height unlock-block) ERR_STILL_LOCKED)
    (asserts! (> user-lp u0) ERR_NO_DEPOSIT)

    (let ((remove-result (try! (as-contract? ((with-ft POOL "sBTC-MIA" user-lp-to-remove))
                                 (try! (contract-call? POOL remove-liquidity user-lp-to-remove)))))
          (sbtc-received (get dx remove-result))
          (token-received (get dy remove-result)))

        ;; hand the user 100% of the proceeds of the 60% we removed
        (try! (as-contract? ((with-ft SBTC "sbtc-token" sbtc-received))
               (try! (contract-call? SBTC transfer sbtc-received current-contract user none))))
        (try! (as-contract? ((with-ft MIA "miamicoin" token-received))
               (try! (contract-call? MIA transfer token-received current-contract user none))))

        ;; settle the user's full entitlement out of the books; the 40% of LP we
        ;; did NOT remove remains held by this contract, unattributed, locked.
        (map-delete user-lp-tokens user)
        (var-set total-lp-tokens (- (var-get total-lp-tokens) user-lp))

        (print {
          type: "lp-withdrawal",
          user: user,
          lp-entitlement: user-lp,
          lp-removed: user-lp-to-remove,
          lp-locked-forever: (- user-lp user-lp-to-remove),
          user-sbtc: sbtc-received,
          user-token: token-received,
          ft: MIA
        })

        (ok user-lp)
      )
    )
  )

(define-read-only (get-pool-info)
  {
    depositor: DEPOSITOR,
    creation-block: (var-get creation-block),
    started: (> (var-get creation-block) u0),
    unlock-block: (+ (var-get creation-block) LOCK_PERIOD),
    is-unlocked: (and (> (var-get creation-block) u0)
                      (>= burn-block-height (+ (var-get creation-block) LOCK_PERIOD))),
    initial-token: (var-get initial-token-amount),
    token-used: (var-get token-used-for-lp),
    total-lp-tokens: (var-get total-lp-tokens),
    user-bps: USER_BPS
  }
)

(define-read-only (get-user-lp-tokens (user principal))
  (default-to u0 (map-get? user-lp-tokens user))
)

;; read-only context: call the pool via its literal so clarinet can statically
;; verify `quote` is read-only (a constant target defeats that check).
(define-read-only (get-quote-for-lp (lp-amount uint))
  (contract-call? .mia-pool-faktory quote lp-amount (some 0x02)))

(define-read-only (calculate-amounts-for-lp (lp-amount uint))
  (begin
        (asserts! (> lp-amount u0) ERR_INSUFFICIENT_AMOUNT)
        (match (get-quote-for-lp lp-amount)
          liquidity-quote (ok {
            sbtc-needed: (get dx liquidity-quote),
            token-needed: (get dy liquidity-quote)
          })
          error-value (err error-value))))

(define-read-only (get-config)
    {
        ft: MIA,
        pool: POOL,
        denomination: SBTC,
        depositor: DEPOSITOR,
    }
)
;; Rendezvous fuzzing harness for mia-single-faktory.
;;
;; Deploy-time setup (bottom of the file): simulates the accumulated seed by
;; fauceting MIA straight to the contract and anchoring the clock -- the REAL
;; contract-to-contract seed path (fair -> single) is covered by the vitest
;; suites. The synced copy (scripts/rv-sync.sh) points DEPOSITOR at the
;; deployer wallet so fuzzed initialize-pool top-ups can succeed too, and
;; shortens LOCK_PERIOD so runs organically cross the unlock boundary and
;; exercise both branches of withdraw. sBTC comes pre-funded by simnet.

(define-constant RV_SEED u1000000000) ;; 1e9 uMIA simulated seed

;; ---- invariants ------------------------------------------------------------

;; the LP the contract holds always covers what users are owed; the gap is the
;; forever-locked 40% remainders
(define-read-only (invariant-lp-covers-entitlements)
  (>= (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract))
      (var-get total-lp-tokens))
)

;; every seeded uMIA is either still here or was paired into the pool
(define-read-only (invariant-seeded-mia-accounted)
  (is-eq
    (unwrap-panic (contract-call?
      'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
      get-balance current-contract))
    (- (var-get initial-token-amount) (var-get token-used-for-lp)))
)

(define-read-only (invariant-used-never-exceeds-seeded)
  (<= (var-get token-used-for-lp) (var-get initial-token-amount))
)

;; the clock never moves once anchored
(define-read-only (invariant-clock-anchored-in-past)
  (or
    (is-eq (var-get creation-block) u0)
    (<= (var-get creation-block) burn-block-height))
)

;; ---- property tests --------------------------------------------------------

(define-private (test-deposit-attributes-lp (lp uint))
  (let (
      (amt (+ u1 (mod lp u10000)))
      (before (default-to u0 (map-get? user-lp-tokens tx-sender)))
      (total-before (var-get total-lp-tokens))
      (got (try! (deposit-sbtc-for-lp amt)))
    )
    (asserts! (> got u0) (err u930))
    (asserts!
      (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) (+ before got))
      (err u931))
    (asserts! (is-eq (var-get total-lp-tokens) (+ total-before got)) (err u932))
    (ok true))
)

(define-read-only (can-test-deposit-attributes-lp (lp uint))
  (let ((amt (+ u1 (mod lp u10000))))
    (and
      (> (var-get creation-block) u0)
      (match (calculate-amounts-for-lp amt)
        q (and
            ;; the contract still holds enough unpaired MIA...
            (>= (unwrap-panic (contract-call?
                  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
                  get-balance current-contract))
                (get token-needed q))
            ;; ...and the caller can pay the sBTC side
            (>= (unwrap-panic (contract-call?
                  'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
                  get-balance tx-sender))
                (get sbtc-needed q)))
        e false)))
)

;; before unlock every withdraw fails; after unlock the user's books are
;; settled and exactly 60% of the entitlement leaves the pool position
(define-private (test-withdraw-respects-lock-and-split)
  (let (
      (unlock (+ (var-get creation-block) LOCK_PERIOD))
      (entitlement (default-to u0 (map-get? user-lp-tokens tx-sender)))
      (to-remove (/ (* entitlement USER_BPS) u100))
      (lp-before (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract)))
    )
    (if (< burn-block-height unlock)
      (begin
        (asserts! (is-err (withdraw-lp-tokens)) (err u940))
        (ok true))
      (if (is-eq to-remove u0)
        (begin
          ;; dust entitlement: documented audit finding -- the withdraw aborts
          ;; inside the pool (burn of 0) and the books stay untouched
          (asserts! (is-err (withdraw-lp-tokens)) (err u941))
          (asserts!
            (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) entitlement)
            (err u942))
          (ok true))
        (begin
          (try! (withdraw-lp-tokens))
          (asserts!
            (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) u0)
            (err u943))
          (asserts!
            (is-eq
              (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract))
              (- lp-before to-remove))
            (err u944))
          (ok true)))))
)

(define-read-only (can-test-withdraw-respects-lock-and-split)
  (> (default-to u0 (map-get? user-lp-tokens tx-sender)) u0)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(unwrap-panic (contract-call?
  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
  rv-faucet RV_SEED current-contract))
(var-set creation-block burn-block-height)
(var-set initial-token-amount RV_SEED)

;; give the deployer wallet (= patched DEPOSITOR) MIA so fuzzed
;; initialize-pool top-ups can succeed
(unwrap-panic (contract-call?
  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
  rv-faucet u1000000000 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM))

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))
