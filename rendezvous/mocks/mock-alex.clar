;; TEST-ONLY mock of ALEX amm-pool-v2-01 (pool 16 shape: x = wSTX, y = wMIA)
;; for the rendezvous simnet, where the real pool has no state. Preserves the
;; fixed-point contract the arb depends on: amounts are 1e8-fixed over the
;; 6-decimal base assets, so dy pulls floor(dy/100) real uMIA from the caller
;; and the returned dx pays floor(dx/100) real uSTX -- exactly ALEX's floor
;; behavior. Constant-product over the mock's REAL balances (can never pay
;; out more than it holds), 0.5% fee like pool 16. Trait-typed params of the
;; real pool are accepted as plain principals and ignored.

(define-constant MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant FEE_BPS u50)
(define-constant ERR-MIN (err u2001))
(define-constant ERR-NO-LIQUIDITY (err u2002))

;; anyone can seed liquidity; test-only, there is no withdraw
(define-public (fund-stx (amount uint))
  (stx-transfer? amount tx-sender current-contract)
)

(define-public (fund-mia (amount uint))
  (contract-call? MIA transfer amount tx-sender current-contract none)
)

;; MIA in -> STX out (sell MIA): dy is wMIA 1e8-fixed
(define-public (swap-y-for-x
    (token-x principal)
    (token-y principal)
    (factor uint)
    (dy uint)
    (min-dx (optional uint))
  )
  (let (
      (caller tx-sender)
      (umia-in (/ dy u100))
      (rx (stx-get-balance current-contract))
      (ry (unwrap-panic (contract-call? MIA get-balance current-contract)))
      (net (- umia-in (/ (* umia-in FEE_BPS) u10000)))
      (ustx-out (/ (* rx net) (+ ry net)))
      (dx (* ustx-out u100))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (> ustx-out u0) ERR-MIN)
    (asserts! (>= dx (default-to u0 min-dx)) ERR-MIN)
    (try! (contract-call? MIA transfer umia-in caller current-contract none))
    (try! (as-contract? ((with-stx ustx-out))
      (try! (stx-transfer? ustx-out tx-sender caller))
    ))
    (ok { dx: dx, dy: dy })
  )
)

;; STX in -> MIA out (buy MIA): dx is wSTX 1e8-fixed
(define-public (swap-x-for-y
    (token-x principal)
    (token-y principal)
    (factor uint)
    (dx uint)
    (min-dy (optional uint))
  )
  (let (
      (caller tx-sender)
      (ustx-in (/ dx u100))
      (rx (stx-get-balance current-contract))
      (ry (unwrap-panic (contract-call? MIA get-balance current-contract)))
      (net (- ustx-in (/ (* ustx-in FEE_BPS) u10000)))
      (umia-out (/ (* ry net) (+ rx net)))
      (dy (* umia-out u100))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (> umia-out u0) ERR-MIN)
    (asserts! (>= dy (default-to u0 min-dy)) ERR-MIN)
    (try! (stx-transfer? ustx-in caller current-contract))
    (try! (as-contract? ((with-ft MIA "miamicoin" umia-out))
      (try! (contract-call? MIA transfer umia-out tx-sender caller none))
    ))
    (ok { dx: dx, dy: dy })
  )
)
