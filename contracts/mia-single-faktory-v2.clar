(define-constant POOL .mia-pool-faktory)
(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant DEPOSITOR 'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-fair-faktory-v2)


(define-constant ERR_UNAUTHORIZED (err u403))
(define-constant ERR_NOT_STARTED (err u404))
(define-constant ERR_INSUFFICIENT_AMOUNT (err u406))
(define-constant ERR_STILL_LOCKED (err u407))
(define-constant ERR_NO_DEPOSIT (err u408))
(define-constant ERR_CALC_AMOUNTS (err u410))

(define-constant MIN_LP_AMOUNT u20)

(define-constant LOCK_PERIOD u12960)

(define-constant USER_BPS u60)

(define-data-var creation-block uint u0)
(define-data-var initial-token-amount uint u0)
(define-data-var token-used-for-lp uint u0)
(define-data-var total-lp-tokens uint u0)

(define-map user-lp-tokens principal uint)

(define-public (initialize-pool (token-amount uint))
  (let ((init-token-amt (var-get initial-token-amount))
        (creation-b (var-get creation-block)))
    (asserts! (is-eq tx-sender DEPOSITOR) ERR_UNAUTHORIZED)
    (asserts! (> token-amount u0) ERR_INSUFFICIENT_AMOUNT)

    (try! (contract-call? MIA transfer token-amount tx-sender current-contract none))

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

(define-public (deposit-sbtc-for-lp (lp-amount uint))
    (let (
          (amounts (unwrap! (calculate-amounts-for-lp lp-amount) ERR_CALC_AMOUNTS))
          (sbtc-needed (get sbtc-needed amounts))
          (token-needed (get token-needed amounts))
          (deposit (try! (contract-call? SBTC transfer sbtc-needed tx-sender current-contract none)))
          (lp-result (try! (as-contract? ((with-ft SBTC "sbtc-token" sbtc-needed)
                                          (with-ft MIA "miamicoin" token-needed))
                             (try! (contract-call? POOL add-liquidity lp-amount)))))
          (lp-tokens-received (get dk lp-result))
          (current-lp (default-to u0 (map-get? user-lp-tokens tx-sender))))

    (asserts! (> (var-get creation-block) u0) ERR_NOT_STARTED)
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

        (try! (as-contract? ((with-ft SBTC "sbtc-token" sbtc-received))
               (try! (contract-call? SBTC transfer sbtc-received current-contract user none))))
        (try! (as-contract? ((with-ft MIA "miamicoin" token-received))
               (try! (contract-call? MIA transfer token-received current-contract user none))))

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