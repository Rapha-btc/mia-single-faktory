(define-constant ERR_UNAUTHORIZED (err u9000))
(define-constant ERR_NOTHING_TO_DO (err u9002))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS))

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant FAIR_V2 .mia-fair-faktory-v2)

(define-constant FASTPOOL 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X)

(define-data-var total-stx-spent uint u0)
(define-data-var total-mia-acquired uint u0)
(define-data-var total-redeemed-umia uint u0)
(define-data-var total-stx-received uint u0)

(define-public (settle-and-redeem (amount-ustx uint))
  (begin
    (and (> amount-ustx u0)
      (begin
        (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
        (try! (stx-transfer? amount-ustx tx-sender current-contract))
        (print { notification: "deposit", payload: { owner: tx-sender, amount: amount-ustx } })
        true
      )
    )
    (let (
        (settled (try! (try-settle)))
        (redeemed (try! (try-redeem)))
      )
      (asserts! (or (> amount-ustx u0) (is-some settled) (is-some redeemed))
        ERR_NOTHING_TO_DO)
      (ok { settled: settled, redeemed: redeemed })
    )
  )
)

(define-private (try-settle)
  (let ((budget (stx-get-balance current-contract)))
    (if (or (is-eq budget u0)
        (is-eq (get ustx (contract-call? FAIR_V2 get-book-totals)) u0))
      (ok none)
      (let ((settled (try! (as-contract? ((with-stx budget))
          (try! (contract-call? FAIR_V2 settle-offers budget))))))
        (if (is-eq (get spent settled) u0)
          (ok none)
          (begin
            (var-set total-stx-spent (+ (var-get total-stx-spent) (get spent settled)))
            (var-set total-mia-acquired (+ (var-get total-mia-acquired) (get par-equiv settled)))
            (print { notification: "settle", payload: {
              caller: tx-sender,
              settled: settled,
              stx-escrow: (stx-get-balance current-contract),
            } })
            (ok (some settled))
          )
        )
      )
    )
  )
)

(define-private (try-redeem)
  (let (
      (balance-v2 (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
      (amount (if (> balance-v2 MAX_PER_TRANSACTION) MAX_PER_TRANSACTION balance-v2))
      (quote (contract-call? CCD013 get-redemption-for-balance amount))
    )
    (if (is-eq (default-to u0 (get ustx quote)) u0)
      (ok none)
      (let ((redeemed (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
          (try! (contract-call? CCD013 redeem-mia amount))))))
        (var-set total-redeemed-umia (+ (var-get total-redeemed-umia) (get umia redeemed)))
        (var-set total-stx-received (+ (var-get total-stx-received) (get ustx redeemed)))
        (print { notification: "redeem", payload: {
          caller: tx-sender,
          redeemed: redeemed,
          stx-escrow: (stx-get-balance current-contract),
        } })
        (ok (some redeemed))
      )
    )
  )
)

(define-public (withdraw-stx (amount uint))
  (begin
    (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-stx amount))
      (try! (stx-transfer? amount current-contract FASTPOOL))))
    (print { notification: "withdraw-stx", payload: { amount: amount, recipient: FASTPOOL } })
    (ok true)
  )
)

(define-public (withdraw-mia (amount uint))
  (begin
    (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
      (try! (contract-call? MIA_TOKEN_V2 transfer amount current-contract FASTPOOL none))))
    (print { notification: "withdraw-mia", payload: { amount: amount, recipient: FASTPOOL } })
    (ok true)
  )
)

(define-read-only (get-status)
  {
    beneficiary: FASTPOOL,
    stx-escrow: (stx-get-balance current-contract),
    mia-escrow: (unwrap-panic (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 get-balance current-contract)),
    ccd013-treasury: (contract-call? 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia get-redemption-current-balance),
    book: (contract-call? .mia-fair-faktory-v2 get-book-totals),
    total-stx-spent: (var-get total-stx-spent),
    total-mia-acquired: (var-get total-mia-acquired),
    total-redeemed-umia: (var-get total-redeemed-umia),
    total-stx-received: (var-get total-stx-received),
  }
)
