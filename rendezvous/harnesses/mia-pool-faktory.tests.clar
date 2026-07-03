;; Rendezvous fuzzing harness for mia-pool-faktory.
;;
;; Deploy-time setup (bottom of the file): faucets MIA to every wallet (sBTC is
;; pre-funded by simnet), seeds the pool with reserves a=10_000 sats /
;; b=1_000_000 uMIA via the real initialize-pool, and ungates swaps so the
;; fuzzer can exercise the AMM math (the gate itself is unit-tested).

(define-constant RV_MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant RV_SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

;; ---- invariants ------------------------------------------------------------

;; while LP supply exists, neither reserve can be drained to zero: swaps output
;; strictly less than the reserve and proportional removes only empty the pool
;; when the LAST LP exits
(define-read-only (invariant-reserves-positive-while-lp-exists)
  (let (
      (k (ft-get-supply sBTC-MIA))
      (a (unwrap-panic (contract-call?
        'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        get-balance current-contract)))
      (b (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance current-contract)))
    )
    (or (is-eq k u0) (and (> a u0) (> b u0))))
)

;; ---- property tests --------------------------------------------------------

(define-private (test-swap-a-to-b-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000)))
      (r0 (get-reserves))
      (res (try! (swap-a-to-b amt u0)))
      (r1 (get-reserves))
    )
    (asserts!
      (>= (* (get a r1) (get b r1)) (* (get a r0) (get b r0)))
      (err u950))
    (ok true))
)

(define-read-only (can-test-swap-a-to-b-keeps-product (amount uint))
  (let ((amt (+ u1 (mod amount u10000000))))
    (and
      (not (var-get gated))
      (> (ft-get-supply sBTC-MIA) u0)
      ;; dust swaps whose output floors to zero abort in the token (err u3)
      (> (get dy (get-swap-quote amt (some 0x00))) u0)
      (>= (unwrap-panic (contract-call?
            'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            get-balance tx-sender))
          amt)))
)

(define-private (test-swap-b-to-a-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000000)))
      (r0 (get-reserves))
      (res (try! (swap-b-to-a amt u0)))
      (r1 (get-reserves))
    )
    (asserts!
      (>= (* (get a r1) (get b r1)) (* (get a r0) (get b r0)))
      (err u951))
    (ok true))
)

(define-read-only (can-test-swap-b-to-a-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000000)))
      (q (get-swap-quote amt (some 0x01)))
    )
    (and
      (not (var-get gated))
      (> (ft-get-supply sBTC-MIA) u0)
      ;; dust swaps whose net output floors to zero abort in the token (err u3)
      (> (- (get dy q) (get fee q)) u0)
      (>= (unwrap-panic (contract-call?
            'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
            get-balance tx-sender))
          amt)))
)

;; add then remove the same LP amount: rounding may cost the caller dust but
;; can never pay them out more than they put in
(define-private (test-add-remove-roundtrip-no-profit (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
      (sbtc0 (unwrap-panic (contract-call? RV_SBTC get-balance tx-sender)))
      (mia0 (unwrap-panic (contract-call? RV_MIA get-balance tx-sender)))
    )
    ;; dust adds abort inside the token (err u3) -- covered by
    ;; test-add-liquidity-mints-exact; discard them here
    (if (or (is-eq (get dx q) u0) (is-eq (get dy q) u0))
      (ok false)
      (begin
        (try! (add-liquidity amt))
        ;; the matching remove can itself hit the documented dust abort; the
        ;; caller keeps the LP they just paid for -- still no profit
        (match (remove-liquidity amt)
          r2 (let (
              (sbtc1 (unwrap-panic (contract-call? RV_SBTC get-balance tx-sender)))
              (mia1 (unwrap-panic (contract-call? RV_MIA get-balance tx-sender)))
            )
            (asserts! (<= sbtc1 sbtc0) (err u960))
            (asserts! (<= mia1 mia0) (err u961))
            (ok true))
          e (if (is-eq e u3) (ok true) (err e))))))
)

(define-read-only (can-test-add-remove-roundtrip-no-profit (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
    )
    (and
      (var-get pool-opened)
      (>= (unwrap-panic (contract-call?
            'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            get-balance tx-sender))
          (get dx q))
      (>= (unwrap-panic (contract-call?
            'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
            get-balance tx-sender))
          (get dy q))))
)

;; adding liquidity mints exactly the requested LP; this test deliberately
;; KEEPS the position, building pool depth so the swap properties stop
;; discarding (the deploy-time seed cannot run: simnet funds wallets with
;; sBTC only after contract deployment).
;; FUZZ TROPHY: rv (seed 1439452765) found that when skewed reserves floor one
;; quoted side to zero, add-liquidity aborts with the token's (err u3) -- so
;; the dust branch asserts the flip side: NO free LP can ever be minted.
(define-private (test-add-liquidity-mints-exact (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
      (lp-before (ft-get-balance sBTC-MIA tx-sender))
    )
    (if (or (is-eq (get dx q) u0) (is-eq (get dy q) u0))
      (begin
        ;; a zero-cost side must make the whole add revert, not mint free LP
        (asserts! (is-err (add-liquidity amt)) (err u957))
        (asserts! (is-eq (ft-get-balance sBTC-MIA tx-sender) lp-before) (err u958))
        (ok true))
      (let ((res (try! (add-liquidity amt))))
        (asserts! (is-eq (get dk res) amt) (err u955))
        (asserts! (is-eq (ft-get-balance sBTC-MIA tx-sender) (+ lp-before amt)) (err u956))
        (ok true))))
)

(define-read-only (can-test-add-liquidity-mints-exact (amount uint))
  (can-test-add-remove-roundtrip-no-profit amount)
)

;; the quote is exactly what a swap delivers in the same block
(define-private (test-quote-matches-swap-a-to-b (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000)))
      (q (get-swap-quote amt (some 0x00)))
      (res (try! (swap-a-to-b amt u0)))
    )
    (asserts! (is-eq (get dy res) (get dy q)) (err u970))
    (ok true))
)

(define-read-only (can-test-quote-matches-swap-a-to-b (amount uint))
  (can-test-swap-a-to-b-keeps-product amount)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? RV_MIA rv-faucet u1000000000000 who))
)

(map rv-fund-mia (list
  'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM
  'ST1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2ZQ8YPD5
  'ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG
  'ST2JHG361ZXG51QTKY2NQCVBPPRRE2KZB1HR05NNC
  'ST2NEB84ASENDXKYGJPQW86YXQCEFEX2ZQPG87ND
  'ST2REHHS5J3CERCRBEPMGH7921Q6PYKAADT7JP2VB
  'ST3AM1A56AK2C1XAFJ4115ZSV26EB49BVQ10MGCS0
  'ST3NBRSFKX28FQ2ZJ1MAKX58HKHSDGNV5N7R21XCP
  'ST3PF13W7Z0RRM42A8VZRVFQ75SV1K26RXEP8YGKJ
  'STNHKEPYEPJ8ET55ZZ0M5A34J0R3N5FM2CMMMAZ6))

;; is-ok (not unwrap-panic): succeeds under rv's funded simnet; the fuzzer can
;; also bootstrap liquidity itself since the synced pool starts opened
(is-ok (initialize-pool u10000 u990000))
(var-set gated false)

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))
