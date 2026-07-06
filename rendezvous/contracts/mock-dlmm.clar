;; TEST-ONLY mock of Bitflow dlmm-swap-router-v-1-2 restricted to the
;; stx-sbtc pool shape (x = STX, y = sBTC) for the rendezvous simnet.
;; Preserves the router's contract the arb depends on: returns {in, out}
;; with `in` = amount actually consumed -- this mock always consumes fully
;; (the arb's ERR-PARTIAL-FILL guard is exercised by construction: in ==
;; amount must hold). Constant-product over REAL balances, 15 bps fee.
;; Trait-typed params of the real router are accepted as principals.

(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant FEE_BPS u15)
(define-constant ERR-MIN (err u2001))
(define-constant ERR-NO-LIQUIDITY (err u2002))

(define-public (fund-sbtc (amount uint))
  (contract-call? SBTC transfer amount tx-sender current-contract none)
)

(define-public (fund-stx (amount uint))
  (stx-transfer? amount tx-sender current-contract)
)

;; STX in -> sBTC out (x = STX, y = sBTC)
(define-public (swap-x-for-y-simple-multi
    (pool principal)
    (x-token principal)
    (y-token principal)
    (x-amount uint)
    (min-dy uint)
    (deadline-time (optional uint))
  )
  (let (
      (caller tx-sender)
      (rx (stx-get-balance current-contract))
      (ry (unwrap-panic (contract-call? SBTC get-balance current-contract)))
      (net (- x-amount (/ (* x-amount FEE_BPS) u10000)))
      (dy (/ (* ry net) (+ rx net)))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (and (> dy u0) (>= dy min-dy)) ERR-MIN)
    (try! (stx-transfer? x-amount caller current-contract))
    (try! (as-contract? ((with-ft SBTC "sbtc-token" dy))
      (try! (contract-call? SBTC transfer dy tx-sender caller none))
    ))
    (ok { in: x-amount, out: dy })
  )
)

;; sBTC in -> STX out
(define-public (swap-y-for-x-simple-multi
    (pool principal)
    (x-token principal)
    (y-token principal)
    (y-amount uint)
    (min-dx uint)
    (deadline-time (optional uint))
  )
  (let (
      (caller tx-sender)
      (rx (stx-get-balance current-contract))
      (ry (unwrap-panic (contract-call? SBTC get-balance current-contract)))
      (net (- y-amount (/ (* y-amount FEE_BPS) u10000)))
      (dx (/ (* rx net) (+ ry net)))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (and (> dx u0) (>= dx min-dx)) ERR-MIN)
    (try! (contract-call? SBTC transfer y-amount caller current-contract none))
    (try! (as-contract? ((with-stx dx))
      (try! (stx-transfer? dx tx-sender caller))
    ))
    (ok { in: y-amount, out: dx })
  )
)
