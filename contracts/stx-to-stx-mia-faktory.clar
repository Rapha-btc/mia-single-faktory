;; stx-to-stx-mia-faktory -- "STX to STX": one function that routes STX
;; through the mia-fair-faktory-v2 exit book into the ccd013 par
;; redemption, and back to STX. The mirror of mia-to-mia-faktory: the
;; whitehat's working capital is STX (which fastpool has) instead of MIA
;; (which it would have to source).
;;
;;   settle-and-redeem(amount-ustx)
;;     amount > 0  the whitehat (FASTPOOL, hardcoded beneficiary) feeds
;;                 STX into the machine
;;     amount = 0  ANYONE re-triggers the machine
;;   then, in friedger's order -- first fill the book, then claim STX:
;;     settle leg  if this contract holds STX and the fair book has
;;                 offers: settle-offers -- the machine KEEPS the
;;                 par-equivalent MIA it is paid
;;     redeem leg  if this contract holds MIA and the ccd013 treasury has
;;                 STX: burn at par (u1710) in <= 10M-MIA chunks (the
;;                 ccd013 per-tx cap) -- the STX returns HERE
;;
;; Both legs at par means STX in ~= STX out (minus integer-division
;; dust): the capital only cycles, servicing exactly what the fair book
;; holds. When the treasury is empty at settle time the MIA simply waits
;; here for the next cycle payout; when it refills, one trigger does the
;; whole loop atomically. The below-par spread stays in fair-v2 for the
;; vault; the MIA acquired is permanently burned. The redeem leg
;; pre-quotes via get-redemption-for-balance and skips zero-value
;; redemptions (sub-585-uMIA dust, empty machine, empty treasury), so
;; dust donations can never brick a trigger (AUDIT R-1). MIA v2 only.

(define-constant ERR_UNAUTHORIZED (err u9000))
(define-constant ERR_NOTHING_TO_DO (err u9002))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS)) ;; ccd013's per-tx cap

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant FAIR_V2 .mia-fair-faktory-v2)

;; Hardcoded beneficiary (fastpool.btc) -- a first-depositor slot would be
;; front-runnable (AUDIT R-2). CONFIRM this address before deploying.
(define-constant FASTPOOL 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X)

(define-data-var total-stx-spent uint u0) ;; paid to fair-book makers
(define-data-var total-mia-acquired uint u0) ;; par-equiv kept by the machine
(define-data-var total-redeemed-umia uint u0) ;; burned through ccd013
(define-data-var total-stx-received uint u0) ;; paid back by ccd013

(define-public (settle-and-redeem (amount-ustx uint))
  (begin
    ;; optional deposit leg: only the beneficiary feeds the machine
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
      ;; a bare re-trigger that can do nothing reverts, so bots never pay
      ;; for no-ops; a deposit is allowed to just park STX
      (asserts! (or (> amount-ustx u0) (is-some settled) (is-some redeemed))
        ERR_NOTHING_TO_DO)
      (ok { settled: settled, redeemed: redeemed })
    )
  )
)

;; Settle leg: spend this contract's STX on the fair book and KEEP the
;; par-equivalent MIA for the redeem leg. Skips when the escrow or the
;; book is empty (or the escrow is dust too small to take a single uMIA).
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

;; Redeem leg: burn this contract's MIA through ccd013 so the STX lands
;; back here. Pre-quoted so it skips instead of aborting (AUDIT R-1).
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

;; Owner-only emergency hatches: exit the STX capital, or rescue MIA if
;; pox-5 ever ends the treasury refills mid-cycle.
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
