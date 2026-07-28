;; mia-burn-and-run
;; One-transaction cycle settle for the MIA fair book.
;;
;; Burns the CALLER's own leftover MIA through ccd013, then runs the fair-book
;; machine in capped passes. Both legs in one transaction, so there is no gap
;; between them for a mempool racer to redeem the headroom the first leg frees
;; up - which is exactly what happened in cycle 139 (0x491e1f6c, 5,526.232964
;; STX taken two blocks later).
;;
;; NO CUSTODY AND NO as-contract ANYWHERE. tx-sender flows straight through:
;;   - ccd013 reads tx-sender, and miamicoin-token-v2.burn asserts
;;     (is-eq tx-sender owner), so the burn hits the CALLER's balance and the
;;     STX lands in the CALLER's wallet.
;;   - the machine's is-operator check and its stx-transfer? deposit both see
;;     the CALLER too.
;; This contract never holds MIA or STX. If it is ever superseded there is
;; nothing to migrate.
;;
;; WHY THE CAP. ccd013 burns at most 10M MIA per call and the ratio is frozen
;; at 1710, so one redeem pass can only ever return 17,100 STX. The machine
;; settles BEFORE it redeems, so a settle pass funded above 17,100 buys MIA
;; the next line cannot burn. Burning first drops the headroom below 17,100,
;; and from there the machine's own F-3 guard (budget = min(balance, headroom))
;; keeps every pass under the ceiling by itself. Passes after the first are
;; self-capping regardless: the machine's balance is then exactly the
;; redemption proceeds of one capped pass.

(define-constant ERR_ABOVE_CAP (err u9100))

(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
;; same deployer as the machine, so the local form resolves in simnet and on
;; mainnet alike (matches stx-to-stx-migrate.clar)
(define-constant MACHINE .stx-to-stx-mia-faktory-v2)

(define-constant MICRO_CITYCOINS (pow u10 u6))
;; ccd013's 10M MIA per-call ceiling priced at the frozen ratio 1710: the most
;; a single redeem pass can ever return, and therefore the most a single settle
;; pass may spend.
(define-constant MAX_RUN_USTX u17100000000)

;; Burn leg. Skipped cleanly when the caller has nothing left over, so the
;; same entry point works on a cycle with no rollover. ccd013 silently caps
;; the request at 10M MIA and partial-pays against the live treasury, so
;; over-asking on `umia` is safe.
(define-private (maybe-burn (umia uint))
  (if (> umia u0)
    (begin
      (try! (contract-call? CCD013 redeem-mia umia))
      (ok true)
    )
    (ok false)
  )
)

;; Burn the caller's leftover MIA, then settle/redeem the book in `cycles`
;; capped passes. `ustx` is the per-transaction float, not a cost: the machine
;; returns it in the same call, so the caller only needs it on hand.
;; Over-asking on `cycles` is free - a pass with no headroom no-ops through
;; (ok none) on both legs.
(define-public (burn-and-run
    (umia uint)
    (ustx uint)
    (cycles uint)
  )
  (begin
    (asserts! (<= ustx MAX_RUN_USTX) ERR_ABOVE_CAP)
    (try! (maybe-burn umia))
    (contract-call? MACHINE run-loops ustx cycles)
  )
)

;; What to pass. `umia` is the caller's full MIA balance, `cycles` is the
;; treasury divided by the per-pass ceiling, rounded up and capped at the
;; machine's own limit of 5.
(define-read-only (get-plan (who principal))
  (let (
      ;; literal principals, not the constants: the read-only analyzer cannot
      ;; prove read-only-ness through a constant callee (same reason
      ;; stx-to-stx-mia-faktory-v2's get-status spells them out).
      (umia (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance who
      )))
      (treasury (contract-call?
        'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia
        get-redemption-current-balance
      ))
      (needed (/ (+ treasury (- MAX_RUN_USTX u1)) MAX_RUN_USTX))
    )
    {
      umia: umia,
      ustx: MAX_RUN_USTX,
      cycles: (if (> needed u5) u5 needed),
      treasury: treasury,
      redeems-first: (if (> (* umia u1710) (* treasury MICRO_CITYCOINS))
        treasury
        (/ (* umia u1710) MICRO_CITYCOINS)
      ),
    }
  )
)
