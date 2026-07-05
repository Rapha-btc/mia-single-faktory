;; Rendezvous fuzzing harness for stx-to-stx-mia-faktory ("STX to STX").
;;
;; Mirror of the mia-to-mia harness (see rv-sync.sh PATCH 6/7): the cached
;; ccd013 copy self-initializes (par u1710) and pays redemptions from its
;; OWN balance (rv-fund-treasury stands in for cycle payouts); FASTPOOL is
;; the simnet deployer wallet, which simnet pre-funds with STX so the
;; deposit leg needs no faucet. rv-place-offer gives the settle leg a live
;; below-par fair-v2 book; the MIA faucet funds the maker wallets.

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))

(define-read-only (rv-sr-calls)
  (get called (default-to { called: u0 } (map-get? context "settle-and-redeem"))))

;; ---- fuzzer plumbing (public so rv exercises them organically) -------------

;; stands in for a PoX cycle payout landing in the (patched) ccd013 treasury
(define-public (rv-fund-treasury (amount uint))
  (stx-transfer? (+ u1 (mod amount u10000000000)) tx-sender
    'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia))

;; a community maker posting a below-par offer on the fair-v2 copy
(define-public (rv-place-offer (amount uint) (ask uint))
  (let (
      (amt (+ u1000000 (mod amount u1000000000000)))
      (par (contract-call? .mia-fair-faktory-v2 get-par-ustx amt))
    )
    (if (or (is-eq par u0)
        (is-some (contract-call? .mia-fair-faktory-v2 get-offer tx-sender))
        (< (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)) amt))
      (ok false)
      (match (contract-call? .mia-fair-faktory-v2 place-offer amt (+ u1 (mod ask par)))
        fine (ok true)
        e (if (is-eq e u13015) (ok false) (err e))
      )
    )
  )
)

;; ---- invariants -------------------------------------------------------------

;; every uSTX spent on the book bought MIA at par or better, up to one
;; uMIA of floor rounding per settle-and-redeem call
(define-read-only (invariant-acquired-covers-spent-at-par)
  (>= (+ (var-get total-mia-acquired) (rv-sr-calls))
      (/ (* (var-get total-stx-spent) MICRO_CITYCOINS) u1710)))

;; every uMIA burned was paid back at par or better, up to one uSTX of
;; floor rounding per settle-and-redeem call
(define-read-only (invariant-received-covers-redeemed-at-par)
  (>= (+ (var-get total-stx-received) (rv-sr-calls))
      (/ (* (var-get total-redeemed-umia) u1710) MICRO_CITYCOINS)))

;; STX-to-STX parity: over the whole life, what came back is never more
;; than a hair above what went out (each leg is par-exact; only floor dust
;; separates them, bounded per call)
(define-read-only (invariant-roundtrip-parity)
  (<= (var-get total-stx-received)
      (+ (var-get total-stx-spent) (rv-sr-calls))))

;; ---- property tests ----------------------------------------------------------

;; deposit conservation: the machine's STX moves by deposit - spent +
;; redeemed; its MIA by par-equiv acquired - burned (all from one call)
(define-private (test-deposit-conserves (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000000)))
      (stx-before (stx-get-balance current-contract))
      (mia-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
      (res (try! (settle-and-redeem amt)))
      (spent (match (get settled res) s (get spent s) u0))
      (got-mia (match (get settled res) s (get par-equiv s) u0))
      (burned (match (get redeemed res) r (get umia r) u0))
      (got-stx (match (get redeemed res) r (get ustx r) u0))
    )
    (asserts!
      (is-eq (stx-get-balance current-contract)
        (- (+ stx-before amt got-stx) spent))
      (err u850))
    (asserts!
      (is-eq (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract))
        (- (+ mia-before got-mia) burned))
      (err u851))
    (ok true))
)

(define-read-only (can-test-deposit-conserves (amount uint))
  (and
    (is-eq tx-sender FASTPOOL)
    (>= (stx-get-balance tx-sender) (+ u1 (mod amount u10000000000))))
)

;; a non-beneficiary deposit is always rejected
(define-private (test-foreign-deposit-rejected (amount uint))
  (match (settle-and-redeem (+ u1 (mod amount u1000000000)))
    fine (err u860)
    e (if (is-eq e u9000) (ok true) (err e)))
)

(define-read-only (can-test-foreign-deposit-rejected (amount uint))
  (not (is-eq tx-sender FASTPOOL))
)

;; a re-trigger never enriches the caller in MIA (their STX can only grow
;; if they happen to be a maker whose offer just got filled)
(define-private (test-retrigger-caller-flat)
  (let (
      (mine-mia (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
      (mine-stx (stx-get-balance tx-sender))
    )
    (match (settle-and-redeem u0)
      res (begin
        (asserts!
          (is-eq (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)) mine-mia)
          (err u870))
        (asserts! (>= (stx-get-balance tx-sender) mine-stx) (err u871))
        (ok true))
      e (if (is-eq e u9002) (ok true) (err e))))
)

(define-read-only (can-test-retrigger-caller-flat)
  (not (is-eq tx-sender FASTPOOL))
)

;; AUDIT R-1 regression: dust donations must never brick the trigger
(define-private (test-dust-donation-never-bricks (dust uint))
  (begin
    (try! (contract-call? MIA_TOKEN_V2 transfer
      (+ u1 (mod dust u584)) tx-sender current-contract none))
    (match (settle-and-redeem u0)
      fine (ok true)
      e (if (or (is-eq e u13007) (is-eq e u13008)) (err e) (ok true))))
)

(define-read-only (can-test-dust-donation-never-bricks (dust uint))
  (>= (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance tx-sender))
      u585)
)

;; hatches: non-beneficiary always rejected
(define-private (test-withdraw-guards (amount uint))
  (begin
    (asserts! (is-eq (withdraw-stx (+ u1 amount)) (err u9000)) (err u880))
    (asserts! (is-eq (withdraw-mia (+ u1 amount)) (err u9000)) (err u881))
    (ok true))
)

(define-read-only (can-test-withdraw-guards (amount uint))
  (not (is-eq tx-sender FASTPOOL))
)

;; hatches: the beneficiary's STX withdrawal is exact
(define-private (test-withdraw-stx-exact (amount uint))
  (let (
      (escrow (stx-get-balance current-contract))
      (amt (+ u1 (mod amount escrow)))
      (mine-before (stx-get-balance tx-sender))
    )
    (try! (withdraw-stx amt))
    (asserts! (is-eq (stx-get-balance tx-sender) (+ mine-before amt)) (err u890))
    (asserts! (is-eq (stx-get-balance current-contract) (- escrow amt)) (err u891))
    (ok true))
)

(define-read-only (can-test-withdraw-stx-exact (amount uint))
  (and
    (is-eq tx-sender FASTPOOL)
    (> (stx-get-balance current-contract) u0))
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? MIA_TOKEN_V2 rv-faucet u120000000000 who))
)

;; 10 wallets x 1.2e11 uMIA (makers for rv-place-offer + dust donors)
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
