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
(define-constant DEPOSITOR 'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-fair-faktory)


(define-constant ERR_UNAUTHORIZED (err u403))
(define-constant ERR_NOT_STARTED (err u404))
(define-constant ERR_INSUFFICIENT_AMOUNT (err u406))
(define-constant ERR_STILL_LOCKED (err u407))
(define-constant ERR_NO_DEPOSIT (err u408))
(define-constant ERR_CALC_AMOUNTS (err u410))

;; F-3: floor of 60% must be >= 1 to withdraw anything, i.e. entitlement >= 2
;; micro-LP. Require 10x that per deposit so no one can strand a dust position.
(define-constant MIN_LP_AMOUNT u20)

(define-constant LOCK_PERIOD u12960)  ;; ~90 days in bitcoin blocks

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

    ;; offering must have started. No time cap: deposits stay open as long as the
    ;; contract holds unpaired MIA (add-liquidity fails once it's exhausted).
    ;; Timing is irrelevant -- whenever you deposit, you keep 60% and 40% stays as
    ;; permanent pool liquidity, which is the intended distribution of the MIA.
    (asserts! (> (var-get creation-block) u0) ERR_NOT_STARTED)
    ;; F-3: reject dust deposits that could never withdraw (60% floors to 0)
    (asserts! (>= lp-amount MIN_LP_AMOUNT) ERR_INSUFFICIENT_AMOUNT)

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
