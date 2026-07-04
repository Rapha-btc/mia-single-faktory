;; Rendezvous fuzzing harness for mia-single-faktory-v2 (byte-mirror of the v1 harness;
;; the only v2 source change is the DEPOSITOR constant, which rv-sync patches
;; to the deployer wallet in both versions anyway).
;;
;; Deploy-time setup (bottom of the file): simulates the accumulated seed by
;; fauceting MIA straight to the contract and anchoring the clock -- the REAL
;; contract-to-contract seed path (fair -> single) is covered by the vitest
;; suites. The synced copy (scripts/rv-sync.sh) points DEPOSITOR at the
;; deployer wallet so fuzzed initialize-pool top-ups can succeed too, and
;; shortens LOCK_PERIOD so runs organically cross the unlock boundary and
;; exercise both branches of withdraw. sBTC comes pre-funded by simnet.

(define-constant RV_SEED u1000000000) ;; 1e9 uMIA simulated seed

;; ---- invariants ------------------------------------------------------------

;; the LP the contract holds always covers what users are owed; the gap is the
;; forever-locked 40% remainders
(define-read-only (invariant-lp-covers-entitlements)
  (>= (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract))
      (var-get total-lp-tokens))
)

;; every seeded uMIA is either still here or was paired into the pool
(define-read-only (invariant-seeded-mia-accounted)
  (is-eq
    (unwrap-panic (contract-call?
      'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
      get-balance current-contract))
    (- (var-get initial-token-amount) (var-get token-used-for-lp)))
)

(define-read-only (invariant-used-never-exceeds-seeded)
  (<= (var-get token-used-for-lp) (var-get initial-token-amount))
)

;; the clock never moves once anchored
(define-read-only (invariant-clock-anchored-in-past)
  (or
    (is-eq (var-get creation-block) u0)
    (<= (var-get creation-block) burn-block-height))
)

;; ---- property tests --------------------------------------------------------

(define-private (test-deposit-attributes-lp (lp uint))
  (let (
      (amt (+ MIN_LP_AMOUNT (mod lp u10000)))
      (before (default-to u0 (map-get? user-lp-tokens tx-sender)))
      (total-before (var-get total-lp-tokens))
      (got (try! (deposit-sbtc-for-lp amt)))
    )
    (asserts! (> got u0) (err u930))
    (asserts!
      (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) (+ before got))
      (err u931))
    (asserts! (is-eq (var-get total-lp-tokens) (+ total-before got)) (err u932))
    (ok true))
)

(define-read-only (can-test-deposit-attributes-lp (lp uint))
  (let ((amt (+ MIN_LP_AMOUNT (mod lp u10000))))
    (and
      (> (var-get creation-block) u0)
      (match (calculate-amounts-for-lp amt)
        q (and
            ;; the contract still holds enough unpaired MIA...
            (>= (unwrap-panic (contract-call?
                  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
                  get-balance current-contract))
                (get token-needed q))
            ;; ...and the caller can pay the sBTC side
            (>= (unwrap-panic (contract-call?
                  'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
                  get-balance tx-sender))
                (get sbtc-needed q)))
        e false)))
)

;; before unlock every withdraw fails; after unlock the user's books are
;; settled and exactly 60% of the entitlement leaves the pool position
(define-private (test-withdraw-respects-lock-and-split)
  (let (
      (unlock (+ (var-get creation-block) LOCK_PERIOD))
      (entitlement (default-to u0 (map-get? user-lp-tokens tx-sender)))
      (to-remove (/ (* entitlement USER_BPS) u100))
      (lp-before (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract)))
    )
    (if (< burn-block-height unlock)
      (begin
        (asserts! (is-err (withdraw-lp-tokens)) (err u940))
        (ok true))
      (if (is-eq to-remove u0)
        (begin
          ;; dust entitlement: documented audit finding -- the withdraw aborts
          ;; inside the pool (burn of 0) and the books stay untouched
          (asserts! (is-err (withdraw-lp-tokens)) (err u941))
          (asserts!
            (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) entitlement)
            (err u942))
          (ok true))
        (begin
          (try! (withdraw-lp-tokens))
          (asserts!
            (is-eq (default-to u0 (map-get? user-lp-tokens tx-sender)) u0)
            (err u943))
          (asserts!
            (is-eq
              (unwrap-panic (contract-call? .mia-pool-faktory get-balance current-contract))
              (- lp-before to-remove))
            (err u944))
          (ok true)))))
)

(define-read-only (can-test-withdraw-respects-lock-and-split)
  (> (default-to u0 (map-get? user-lp-tokens tx-sender)) u0)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(unwrap-panic (contract-call?
  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
  rv-faucet RV_SEED current-contract))
(var-set creation-block burn-block-height)
(var-set initial-token-amount RV_SEED)

;; give the deployer wallet (= patched DEPOSITOR) MIA so fuzzed
;; initialize-pool top-ups can succeed
(unwrap-panic (contract-call?
  'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
  rv-faucet u1000000000 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM))

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))
