;; stx-to-stx-migrate
;; One-tx lifecycle closer for the v1 -> v2 transition, deployable AFTER
;; stx-to-stx-mia-faktory-v2. In a single transaction:
;;
;;   1. churn the OLD machine (settle-and-redeem u0, permissionless): when
;;      the ccd013 treasury has a tranche, its stranded MIA escrow (the
;;      8,187.134502 MIA "14 STX" from 2026-07-13) burns back into STX
;;      inside the old machine. Swallowed if there is nothing to do, so
;;      this helper works before AND after the tranche lands.
;;   2. withdraw the old machine's full STX balance - only attempted when
;;      tx-sender is the old machine's hardcoded FASTPOOL (its gate and
;;      its payout target), so other callers skip this leg cleanly.
;;   3. run-loops on the V2 machine with recovered + extra capital, which
;;      ends - as always - by withdrawing the remainder to the caller.
;;
;; Signed by fastpool.btc, this recovers the 14 STX and operates v2
;; atomically: nothing rests anywhere between steps, and a tranche-day
;; call beats snipers to both the old escrow and the fresh book.

(define-constant OLD_MACHINE .stx-to-stx-mia-faktory)
(define-constant V2_MACHINE .stx-to-stx-mia-faktory-v2)
(define-constant OLD_FASTPOOL 'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X)

;; OPERATOR_REWARDS-friendly variant: churn the old machine WITHOUT the
;; withdraw leg (only the old FASTPOOL can withdraw there), then run v2
;; with fresh capital - both atomic in one tx. Lets SP21..FFP consume a
;; tranche the moment it funds one: the old escrow redeems and its ~14 STX
;; PARKS in the old machine (re-strandable by old-machine triggers while
;; headroom remains - the accepted trade) until fastpool.btc collects it,
;; e.g. via migrate-and-run below. Ungated here: v2's operator gate
;; reverts strangers wholesale, old churn alone is permissionless anyway.
(define-public (churn-and-run (extra-ustx uint) (cycles uint))
  (begin
    (match (contract-call? OLD_MACHINE settle-and-redeem u0)
      churned true
      skipped true
    )
    (let (
        (parked (stx-get-balance OLD_MACHINE))
        (result (try! (contract-call? V2_MACHINE run-loops extra-ustx cycles)))
      )
      (print { notification: "churn-and-run", payload: {
        caller: tx-sender,
        old-parked: parked,
        result: result,
      } })
      (ok { old-parked: parked, run: result })
    )
  )
)

(define-public (migrate-and-run (extra-ustx uint) (cycles uint))
  (begin
    ;; 1. permissionless churn of the old machine; nothing-to-do is fine
    (match (contract-call? OLD_MACHINE settle-and-redeem u0)
      churned true
      skipped true
    )
    (let ((recovered (stx-get-balance OLD_MACHINE)))
      ;; 2. only the old FASTPOOL can (and gets paid by) the old withdraw
      (and (> recovered u0) (is-eq tx-sender OLD_FASTPOOL)
        (try! (contract-call? OLD_MACHINE withdraw-stx recovered)))
      ;; 3. operate v2 with everything: recovered (now in the caller's
      ;; account) + extra. v2's run-loops gates on its operator allowlist
      ;; and finishes by withdrawing the remainder to the caller.
      (let ((result (try! (contract-call? V2_MACHINE run-loops
          (+ (if (is-eq tx-sender OLD_FASTPOOL) recovered u0) extra-ustx)
          cycles))))
        (print { notification: "migrate-and-run", payload: {
          caller: tx-sender,
          recovered: recovered,
          result: result,
        } })
        (ok { recovered: recovered, run: result })
      )
    )
  )
)
