;; TEST-ONLY mock of Bitflow xyk-core-v-1-2 restricted to the sbtc-stx pool
;; shape (x = sBTC in sats, y = STX in uSTX), for the rendezvous simnet.
;; Native units on both sides, returns a plain uint like the real core.
;; Constant-product over REAL balances, 0.3% fee. Trait-typed params of the
;; real core (pool / token contracts) are accepted as principals and ignored.

(define-constant SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant FEE_BPS u30)
(define-constant ERR-MIN (err u2001))
(define-constant ERR-NO-LIQUIDITY (err u2002))

(define-public (fund-sbtc (amount uint))
  (contract-call? SBTC transfer amount tx-sender current-contract none)
)

(define-public (fund-stx (amount uint))
  (stx-transfer? amount tx-sender current-contract)
)

;; sBTC in -> STX out
(define-public (swap-x-for-y
    (pool principal)
    (x-token principal)
    (y-token principal)
    (dx uint)
    (min-dy uint)
  )
  (let (
      (caller tx-sender)
      (rx (unwrap-panic (contract-call? SBTC get-balance current-contract)))
      (ry (stx-get-balance current-contract))
      (net (- dx (/ (* dx FEE_BPS) u10000)))
      (dy (/ (* ry net) (+ rx net)))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (and (> dy u0) (>= dy min-dy)) ERR-MIN)
    (try! (contract-call? SBTC transfer dx caller current-contract none))
    (try! (as-contract? ((with-stx dy))
      (try! (stx-transfer? dy tx-sender caller))
    ))
    (ok dy)
  )
)

;; STX in -> sBTC out
(define-public (swap-y-for-x
    (pool principal)
    (x-token principal)
    (y-token principal)
    (dy uint)
    (min-dx uint)
  )
  (let (
      (caller tx-sender)
      (rx (unwrap-panic (contract-call? SBTC get-balance current-contract)))
      (ry (stx-get-balance current-contract))
      (net (- dy (/ (* dy FEE_BPS) u10000)))
      (dx (/ (* rx net) (+ ry net)))
    )
    (asserts! (and (> rx u0) (> ry u0)) ERR-NO-LIQUIDITY)
    (asserts! (and (> dx u0) (>= dx min-dx)) ERR-MIN)
    (try! (stx-transfer? dy caller current-contract))
    (try! (as-contract? ((with-ft SBTC "sbtc-token" dx))
      (try! (contract-call? SBTC transfer dx tx-sender caller none))
    ))
    (ok dx)
  )
)
