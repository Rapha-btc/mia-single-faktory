;; Rendezvous fuzzing harness for mia-fair-faktory.
;;
;; rv concatenates this file onto the contract, so it has FULL access to the
;; internal vars/maps, and the top-level expressions at the bottom run once at
;; deploy time (tx-sender = deployer): they faucet MIA to every simnet wallet,
;; fund the mining treasury, and call `initialize`, freezing par at 1710 (the
;; verified mainnet ratio).
;;
;;   invariant mode: rv randomly calls the REAL public functions (place-offer,
;;     cancel-offer, settle-offers, ...) from random wallets and checks every
;;     `invariant-*` read-only after each step.
;;   test mode: rv drives the `test-*` properties with fuzzed arguments,
;;     discarding runs whose `can-test-*` gate returns false.

;; ---- invariants ------------------------------------------------------------

;; the book is sorted ascending by price (ustx/amount), checked pairwise via
;; cross-multiplication (no division, no precision loss)
(define-private (rv-sorted-step
    (r { owner: principal, amount: uint, ustx: uint })
    (acc { prev-ustx: uint, prev-amount: uint, sorted: bool })
  )
  {
    prev-ustx: (get ustx r),
    prev-amount: (get amount r),
    sorted: (and
      (get sorted acc)
      (<= (* (get prev-ustx acc) (get amount r))
          (* (get ustx r) (get prev-amount acc)))),
  }
)

(define-read-only (invariant-book-sorted-by-price)
  (get sorted (fold rv-sorted-step (var-get offer-book)
    { prev-ustx: u0, prev-amount: u1, sorted: true }))
)

;; every uMIA the contract holds is accounted for: escrowed offers + retained
;; surplus, nothing more, nothing less
(define-private (rv-sum-amount
    (r { owner: principal, amount: uint, ustx: uint })
    (acc uint)
  )
  (+ acc (get amount r))
)

;; NOTE: read-only context needs the literal token principal -- clarinet cannot
;; statically prove a constant-target contract-call? is read-only
(define-read-only (invariant-escrow-matches-book-plus-surplus)
  (is-eq
    (unwrap-panic (contract-call?
      'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
      get-balance current-contract))
    (+ (fold rv-sum-amount (var-get offer-book) u0) (var-get surplus-mia)))
)

;; no resting ask above par
(define-private (rv-par-step
    (r { owner: principal, amount: uint, ustx: uint })
    (all-ok bool)
  )
  (and all-ok (<= (get ustx r) (get-par-ustx (get amount r))))
)

(define-read-only (invariant-asks-at-or-below-par)
  (fold rv-par-step (var-get offer-book) true)
)

;; one offer per wallet
(define-private (rv-unique-step
    (r { owner: principal, amount: uint, ustx: uint })
    (acc { seen: (list 50 principal), dup: bool })
  )
  (if (is-some (index-of? (get seen acc) (get owner r)))
    (merge acc { dup: true })
    {
      seen: (unwrap-panic (as-max-len? (append (get seen acc) (get owner r)) u50)),
      dup: (get dup acc),
    }
  )
)

(define-read-only (invariant-one-offer-per-owner)
  (not (get dup (fold rv-unique-step (var-get offer-book)
    { seen: (list), dup: false })))
)

;; settlers cumulatively acquired at least the par-equivalent of what they
;; spent (the spread is never negative)
(define-read-only (invariant-settled-covers-spent-at-par)
  (let ((ratio (var-get redemption-ratio)))
    (or
      (is-eq ratio u0)
      (>= (var-get total-settled)
          (/ (* (var-get total-spent) REDEMPTION_SCALE_FACTOR) ratio))))
)

;; ---- property tests --------------------------------------------------------

(define-private (test-place-offer-escrows-and-sorts (amount uint) (ask uint))
  (let (
      (amt (+ u1 (mod amount u1000000000)))
      (ask2 (+ u1 (mod ask (get-par-ustx amt))))
      (bal-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
    )
    (match (place-offer amt ask2)
      fine (begin
        (asserts!
          (is-eq
            (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
            (- bal-before amt))
          (err u900))
        (asserts! (is-some (get-offer tx-sender)) (err u901))
        (asserts! (invariant-book-sorted-by-price) (err u902))
        (ok true))
      ;; a full book may reject a not-strictly-cheaper newcomer: acceptable
      e (if (is-eq e u13015) (ok true) (err e))))
)

(define-read-only (can-test-place-offer-escrows-and-sorts (amount uint) (ask uint))
  (let ((amt (+ u1 (mod amount u1000000000))))
    (and
      (var-get redemptions-enabled)
      (> (get-par-ustx amt) u0)
      (is-none (get-offer tx-sender))
      (>= (unwrap-panic (contract-call?
            'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
            get-balance tx-sender))
          amt)))
)

(define-private (test-cancel-restores-escrow)
  (let (
      (rec (unwrap! (get-offer tx-sender) (err u910)))
      (bal-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
    )
    (try! (cancel-offer))
    (asserts!
      (is-eq
        (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
        (+ bal-before (get amount rec)))
      (err u911))
    (asserts! (is-none (get-offer tx-sender)) (err u912))
    (ok true))
)

(define-read-only (can-test-cancel-restores-escrow)
  (is-some (get-offer tx-sender))
)

(define-private (test-settle-is-whitehat (budget uint))
  (let (
      (b (mod budget u100000))
      (stx-before (stx-get-balance tx-sender))
      (mia-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
      (surplus-before (var-get surplus-mia))
      (res (try! (settle-offers b)))
    )
    ;; never spends more than the budget
    (asserts! (<= (get spent res) b) (err u920))
    ;; the caller's STX went out one-for-one with `spent`
    (asserts! (is-eq (stx-get-balance tx-sender) (- stx-before (get spent res))) (err u921))
    ;; the settler received exactly the par-equivalent MIA -- no profit
    (asserts!
      (is-eq
        (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
        (+ mia-before (get par-equiv res)))
      (err u922))
    ;; the spread is non-negative and fully retained
    (asserts! (>= (get acquired res) (get par-equiv res)) (err u923))
    (asserts! (is-eq (var-get surplus-mia) (+ surplus-before (get surplus res))) (err u924))
    (ok true))
)

(define-read-only (can-test-settle-is-whitehat (budget uint))
  (and
    (var-get redemptions-enabled)
    ;; a settler with a resting offer keeps it (tested in the unit suite);
    ;; exclude here so the exact balance accounting stays checkable
    (is-none (get-offer tx-sender))
    (>= (stx-get-balance tx-sender) (mod budget u100000)))
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? MIA_TOKEN_V2 rv-faucet u120000000000 who))
)

;; 10 wallets x 1.2e11 uMIA = 1.2e12 uMIA total v2 supply
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

;; fund the treasury; the ratio initialize computes depends on the TOTAL MIA
;; fauceted across all three harnesses (every contract in this project carries
;; one), so par lands well below the mainnet 1710 -- the invariants and
;; properties are deliberately ratio-agnostic
;; is-ok (not unwrap-panic): `clarinet check` interprets deploys WITHOUT the
;; genesis STX/sBTC funding the real simnet has, so these must not abort there;
;; under rv both succeed and the can-/ratio guards would discard runs otherwise
(is-ok (stx-transfer? u2052000000 tx-sender
  'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-mining-v3))

(is-ok (initialize))

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))
