;; stx-to-stx-wrapper
;; Atomic driver for the deployed stx-to-stx-mia-faktory machine, born from
;; the 2026-07-13 "14 STX" episode: STX left resting in the machine between
;; transactions lets anyone exit at machine terms with zero book competition
;; (a third party settled 8,400 MIA against Friedger's un-withdrawn STX).
;;
;; One call = deposit -> up to 5 settle/redeem cycles -> withdraw remainder.
;; The loop (Friedger's suggestion) recycles the same STX through the book:
;; settle buys offers, redeem burns escrow via ccd013 when the treasury has
;; headroom, and the returned STX buys the next slice - compounding the
;; harvested spread within a single transaction. STX enters and leaves in
;; the same block; the machine is never left armed.
;;
;; FASTPOOL-only by construction: the machine hardcodes its beneficiary as a
;; constant (no set-admin), so depositing (amount > 0) and withdrawing both
;; require tx-sender = FASTPOOL. tx-sender flows through contract-call, so
;; this wrapper inherits the caller's authorization. A permissionless variant
;; was considered and rejected: cycles end settle-then-redeem, so a stranger's
;; trigger could finish with STX resting in the machine - the exact state
;; this wrapper exists to prevent.

(define-constant MACHINE 'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.stx-to-stx-mia-faktory)
(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant FASTPOOL 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X)

(define-constant ERR_UNAUTHORIZED (err u9100))

;; A cycle that finds nothing to do returns ERR_NOTHING_TO_DO (u9002) in the
;; machine; swallow it (and any other mid-loop hiccup) so completed cycles
;; stand and the final withdraw still runs. Funds are never at risk in a
;; skipped cycle: they simply stay in the machine until the withdraw below.
(define-private (cycle)
  (match (contract-call? MACHINE settle-and-redeem u0)
    done true
    skipped true
  )
)

;; Deposit amount-ustx (u0 = churn existing escrow only), run up to 5
;; settle/redeem cycles, withdraw whatever STX is left in the machine back
;; to FASTPOOL. MIA acquired in the final settle (or stranded by an empty
;; ccd013 treasury) stays escrowed in the machine, as always, and is picked
;; up by the next run's first redeem.
(define-public (run (amount-ustx uint))
  (begin
    (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
    ;; First cycle carries the deposit - surface its failure instead of
    ;; swallowing (an aborted deposit means nothing else is worth doing).
    (if (> amount-ustx u0)
      (begin (try! (contract-call? MACHINE settle-and-redeem amount-ustx)) true)
      (cycle)
    )
    (cycle)
    (cycle)
    (cycle)
    (cycle)
    (let (
        (remainder (stx-get-balance MACHINE))
        (mia-escrow (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance MACHINE)))
      )
      (and (> remainder u0)
        (try! (contract-call? MACHINE withdraw-stx remainder)))
      (print { notification: "wrapper-run", payload: {
        caller: tx-sender,
        deposited: amount-ustx,
        withdrawn: remainder,
        mia-escrow: mia-escrow,
      } })
      (ok { deposited: amount-ustx, withdrawn: remainder, mia-escrow: mia-escrow })
    )
  )
)
