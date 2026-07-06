;; TEST-ONLY mock of Velar univ2-pool-v1_0_0-0070 (sBTC / wSTX) for the
;; rendezvous simnet. Direction is inferred from token-in like the real pool
;; keys on token order; returns { amt-out: uint } (the only key the arb
;; reads). Constant-product over REAL balances, 0.3% fee.

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

(define-public (swap
    (token-in principal)
    (token-out principal)
    (fees principal)
    (amt-in uint)
    (min-out uint)
  )
  (let (
      (caller tx-sender)
      (sbtc-r (unwrap-panic (contract-call? SBTC get-balance current-contract)))
      (stx-r (stx-get-balance current-contract))
      (net (- amt-in (/ (* amt-in FEE_BPS) u10000)))
      (sbtc-in (is-eq token-in SBTC))
      (amt-out (if sbtc-in
        (/ (* stx-r net) (+ sbtc-r net))
        (/ (* sbtc-r net) (+ stx-r net))
      ))
    )
    (asserts! (and (> sbtc-r u0) (> stx-r u0)) ERR-NO-LIQUIDITY)
    (asserts! (and (> amt-out u0) (>= amt-out min-out)) ERR-MIN)
    (if sbtc-in
      (begin
        (try! (contract-call? SBTC transfer amt-in caller current-contract none))
        (try! (as-contract? ((with-stx amt-out))
          (try! (stx-transfer? amt-out tx-sender caller))
        ))
      )
      (begin
        (try! (stx-transfer? amt-in caller current-contract))
        (try! (as-contract? ((with-ft SBTC "sbtc-token" amt-out))
          (try! (contract-call? SBTC transfer amt-out tx-sender caller none))
        ))
      )
    )
    (ok { amt-out: amt-out })
  )
)
