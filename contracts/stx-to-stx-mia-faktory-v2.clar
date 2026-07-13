;; stx-to-stx-mia-faktory-v2
;; v2 of the STX->STX MIA exit machine, superseding the 2026-07 deploy after
;; the "14 STX" episode (STX resting in the machine between transactions let
;; a third party exit at machine terms with zero book competition) and
;; Friedger's operational feedback. The fair book (mia-fair-faktory-v2) is
;; untouched: coupling is one-directional, settle-offers is settler-agnostic.
;;
;; Fixes over v1:
;;   F-1 operator allowlist replaces the single hardcoded FASTPOOL constant:
;;       rewards arrive from SP21..FFP, which could not deposit or withdraw
;;       in v1 - forcing the two-tx dance that exposed the 14 STX episode.
;;   F-2 built-in atomic runs: run() = deposit -> ONE settle/redeem cycle ->
;;       withdraw to the calling operator; run-loops(amount, cycles) = the
;;       capital-recycling variant with an explicit cycle count (capped 5).
;;       Looping lets a deposit eat ~N x its size in book offers when
;;       redemption headroom allows; either way STX enters and leaves in
;;       the same transaction - the machine is never left armed. Mechanics
;;       verified end-to-end on a mainnet fork by the wrapper harness
;;       (simulations/verify-wrapper.js) before folding in.
;;   F-3 treasury guard: the settle budget is capped by LIVE ccd013
;;       redemption headroom, so the machine never acquires MIA it cannot
;;       redeem in the same transaction. A deposit against a dry treasury
;;       settles nothing and boomerangs home instead of stranding as
;;       escrow. This also makes the NOTHING_TO_DO assert honest: with no
;;       headroom, a bare trigger fails loudly instead of quietly spending
;;       the balance on unredeemable MIA.
;;   F-4 withdraw-stx / withdraw-mia pay the CALLING operator instead of a
;;       hardcoded recipient.
;;   F-5 settle-and-redeem loses its deposit parameter: capital only enters
;;       through run(), which cannot finish without attempting the
;;       withdraw. v1's deposit-here-withdraw-later path is how STX ends up
;;       resting in the machine between transactions.

(define-constant ERR_UNAUTHORIZED (err u9000))
(define-constant ERR_NOTHING_TO_DO (err u9002))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS))

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant FAIR_V2 .mia-fair-faktory-v2)

;; F-1: both of Friedger's addresses operate the machine.
(define-constant OPERATOR_ADMIN 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X) ;; fastpool.btc admin
(define-constant OPERATOR_REWARDS 'SP21YTSM60CAY6D011EZVEVNKXVW8FVZE198XEFFP) ;; fast pool rewards

(define-data-var total-stx-spent uint u0)
(define-data-var total-mia-acquired uint u0)
(define-data-var total-redeemed-umia uint u0)
(define-data-var total-stx-received uint u0)

(define-private (is-operator)
  (or (is-eq tx-sender OPERATOR_ADMIN) (is-eq tx-sender OPERATOR_REWARDS))
)

;; Single permissionless cycle - a keeper or anyone racing a treasury
;; refill can churn the machine's existing state. NO deposit path: v1's
;; deposit-here-withdraw-later is exactly how STX ends up resting in the
;; machine, so in v2 capital only ever enters through run(), which cannot
;; finish without attempting the withdraw. With F-3 unreachable-settle,
;; the NOTHING_TO_DO assert is now airtight: succeed only if a leg worked.
(define-public (settle-and-redeem)
  (let (
      (settled (try! (try-settle)))
      (redeemed (try! (try-redeem)))
    )
    (asserts! (or (is-some settled) (is-some redeemed)) ERR_NOTHING_TO_DO)
    (ok { settled: settled, redeemed: redeemed })
  )
)

;; Operator deposit: gate + optional STX in. Private helper shared by both
;; run variants; asserts propagate to the caller via try!.
(define-private (take-deposit (amount-ustx uint))
  (begin
    (asserts! (is-operator) ERR_UNAUTHORIZED)
    (and (> amount-ustx u0)
      (begin
        (try! (stx-transfer? amount-ustx tx-sender current-contract))
        (print { notification: "deposit", payload: { owner: tx-sender, amount: amount-ustx } })
        true
      )
    )
    (ok true)
  )
)

;; Shared epilogue: withdraw the full STX remainder to the calling operator
;; and report. STX enters and leaves in the same transaction, always.
(define-private (finish (amount-ustx uint))
  (let (
      (caller tx-sender)
      (remainder (stx-get-balance current-contract))
      (escrow (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
    )
    (and (> remainder u0)
      (try! (as-contract? ((with-stx remainder))
        (try! (stx-transfer? remainder current-contract caller)))))
    (print { notification: "run", payload: {
      caller: caller,
      deposited: amount-ustx,
      withdrawn: remainder,
      mia-escrow: escrow,
    } })
    (ok { deposited: amount-ustx, withdrawn: remainder, mia-escrow: escrow })
  )
)

;; F-2a: the simple atomic run. Deposit (optional), ONE settle/redeem
;; cycle, withdraw the remainder. Right-sized when the deposit covers the
;; book in one pass.
(define-public (run (amount-ustx uint))
  (begin
    (try! (take-deposit amount-ustx))
    (try! (try-settle)) (try! (try-redeem))
    (finish amount-ustx)
  )
)

;; F-2b: the capital-recycling variant: up to `cycles` (capped at 5)
;; settle/redeem passes before the withdraw. Each pass beyond what the
;; state supports no-ops via (ok none) at the cost of a few reads, so
;; over-asking is harmless; N useful cycles let a deposit eat roughly
;; N x its size in book offers when redemption headroom allows.
(define-public (run-loops (amount-ustx uint) (cycles uint))
  (begin
    (try! (take-deposit amount-ustx))
    (try! (try-settle)) (try! (try-redeem))
    (and (>= cycles u2) (begin (try! (try-settle)) (try! (try-redeem)) true))
    (and (>= cycles u3) (begin (try! (try-settle)) (try! (try-redeem)) true))
    (and (>= cycles u4) (begin (try! (try-settle)) (try! (try-redeem)) true))
    (and (>= cycles u5) (begin (try! (try-settle)) (try! (try-redeem)) true))
    (finish amount-ustx)
  )
)

;; One settle pass. F-3: budget = min(machine balance, ccd013 redemption
;; headroom) - never buy what cannot be redeemed in this same transaction.
(define-private (try-settle)
  (let (
      (headroom (contract-call? CCD013 get-redemption-current-balance))
      (balance (stx-get-balance current-contract))
      (budget (if (< balance headroom) balance headroom))
    )
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

;; One redeem pass: burn up to MAX_PER_TRANSACTION of held MIA through
;; ccd013. ccd013 partial-pays when the treasury cannot cover the full
;; quote, so low headroom shrinks the redemption instead of aborting it.
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

;; F-4: withdrawals pay whichever operator calls.
(define-public (withdraw-stx (amount uint))
  (let ((caller tx-sender))
    (asserts! (is-operator) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-stx amount))
      (try! (stx-transfer? amount current-contract caller))))
    (print { notification: "withdraw-stx", payload: { amount: amount, recipient: caller } })
    (ok true)
  )
)

(define-public (withdraw-mia (amount uint))
  (let ((caller tx-sender))
    (asserts! (is-operator) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
      (try! (contract-call? MIA_TOKEN_V2 transfer amount current-contract caller none))))
    (print { notification: "withdraw-mia", payload: { amount: amount, recipient: caller } })
    (ok true)
  )
)

(define-read-only (get-status)
  {
    operators: (list OPERATOR_ADMIN OPERATOR_REWARDS),
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
