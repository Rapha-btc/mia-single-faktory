;; mia-to-mia-faktory -- "Miami to Miami": one function that routes MIA
;; through the ccd013 par redemption into the mia-fair-faktory-v2 exit
;; book, and back to MIA.
;;
;;   redeem-and-settle(amount-umia)
;;     amount > 0  the whitehat (FASTPOOL, hardcoded beneficiary) feeds
;;                 MIA v2 into the machine
;;     amount = 0  ANYONE re-triggers the machine
;;   then, whatever is currently possible happens:
;;     redeem leg  if the ccd013 treasury has STX and this contract holds
;;                 MIA: burn at par (u1710) in <= 10M-MIA chunks (the
;;                 ccd013 per-tx cap) -- the STX stays HERE
;;     settle leg  if this contract holds STX and the fair book has
;;                 offers: settle-offers -- the par-equivalent MIA goes to
;;                 the DEPOSITOR (fastpool), never to the caller
;;
;; The ccd013 rewards treasury is empty between PoX cycles and refills in
;; ~16.7k-STX bursts, and the fair book fills as the community sells above
;; the Alex price (but <= par) -- so the surplus STX simply sits here as a
;; standing par bid until both sides show up. ccd013 partial fills
;; (treasury smaller than the request) leave the unburned MIA here for the
;; next trigger. MIA v2 only.

(define-constant ERR_UNAUTHORIZED (err u9000))
(define-constant ERR_NOTHING_TO_DO (err u9002))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS)) ;; ccd013's per-tx cap

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant FAIR_V2 .mia-fair-faktory-v2)

;; Hardcoded beneficiary (fastpool.btc) -- a first-depositor slot would be
;; front-runnable, handing a griefer the MIA output AND the hatches
;; (AUDIT R-2). CONFIRM this address with friedger before deploying.
(define-constant FASTPOOL 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X)
(define-data-var total-redeemed-umia uint u0)
(define-data-var total-stx-received uint u0)
(define-data-var total-stx-spent uint u0)
(define-data-var total-mia-returned uint u0)

(define-public (redeem-and-settle (amount-umia uint))
  (begin
    ;; optional deposit leg: only the beneficiary feeds the machine
    (and (> amount-umia u0)
      (begin
        (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
        (try! (contract-call? MIA_TOKEN_V2 transfer amount-umia tx-sender current-contract none))
        (print { notification: "deposit", payload: { owner: tx-sender, amount: amount-umia } })
        true
      )
    )
    (let (
        (redeemed (try! (try-redeem)))
        (settled (try! (try-settle)))
      )
      ;; a bare re-trigger that can do nothing reverts, so bots never pay
      ;; for no-ops; a deposit is allowed to just park MIA
      (asserts! (or (> amount-umia u0) (is-some redeemed) (is-some settled))
        ERR_NOTHING_TO_DO)
      (ok { redeemed: redeemed, settled: settled })
    )
  )
)

;; Redeem leg: burn this contract's MIA through ccd013 so the STX lands
;; here. Skips when the contract holds no MIA or the treasury is empty.
(define-private (try-redeem)
  (let (
      (balance-v2 (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
      (amount (if (> balance-v2 MAX_PER_TRANSACTION) MAX_PER_TRANSACTION balance-v2))
      (quote (contract-call? CCD013 get-redemption-for-balance amount))
    )
    ;; skip unless the redemption would actually pay STX: covers an empty
    ;; machine, an empty treasury, AND sub-585-uMIA dust whose value floors
    ;; to zero -- ccd013 errors on those, which would abort the settle leg
    ;; with it (AUDIT R-1 dust-donation grief)
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

;; Settle leg: spend this contract's STX on the fair book; the
;; par-equivalent MIA goes to the depositor. Skips when the escrow or the
;; book is empty (or the escrow is dust too small to take a single uMIA).
(define-private (try-settle)
  (let (
      (recipient FASTPOOL)
      (budget (stx-get-balance current-contract))
    )
    (if (or (is-eq budget u0)
        (is-eq (get ustx (contract-call? FAIR_V2 get-book-totals)) u0))
      (ok none)
      (let (
          (settled (try! (as-contract? ((with-stx budget))
            (try! (contract-call? FAIR_V2 settle-offers budget)))))
          (par-equiv (get par-equiv settled))
        )
        (if (is-eq par-equiv u0)
          (ok none)
          (begin
            (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" par-equiv))
              (try! (contract-call? MIA_TOKEN_V2 transfer par-equiv current-contract recipient none))))
            (var-set total-stx-spent (+ (var-get total-stx-spent) (get spent settled)))
            (var-set total-mia-returned (+ (var-get total-mia-returned) par-equiv))
            (print { notification: "settle", payload: {
              caller: tx-sender,
              recipient: recipient,
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

;; Owner-only emergency hatches: if pox-5 kills the treasury refills or
;; the book stops filling, the beneficiary pulls whatever is left.
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
    mia-escrow: (unwrap-panic (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 get-balance current-contract)),
    stx-escrow: (stx-get-balance current-contract),
    ccd013-treasury: (contract-call? 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia get-redemption-current-balance),
    book: (contract-call? .mia-fair-faktory-v2 get-book-totals),
    total-redeemed-umia: (var-get total-redeemed-umia),
    total-stx-received: (var-get total-stx-received),
    total-stx-spent: (var-get total-stx-spent),
    total-mia-returned: (var-get total-mia-returned),
  }
)
