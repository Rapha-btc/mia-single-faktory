;; Rendezvous fuzzing harness for mia-fair-faktory-v2 (frontier partial fill).
;;
;; Mirror of the mia-fair-faktory harness with the v1 invariants restated for
;; v2's partial-fill semantics, plus two v2-only properties. Two v1 invariants
;; are no longer EXACTLY true under partial fill -- both drift by floor-
;; rounding dust, bounded by the number of settle-offers calls:
;;
;;   - sorted book: a partial fill floors `taken`, so the remainder's implied
;;     price dips below its original by < 1 uMIA worth. A settler's own
;;     resting offer (never touched) can sit ahead of the remainder within
;;     that dust window, making the book pairwise-unsorted by < 1 uMIA per
;;     partial. Each settle call partial-fills at most one record, so the
;;     total drift is bounded by the settle-call count.
;;   - cumulative par coverage: each partial's floor'd `taken` can fall below
;;     the real-valued par line by < 1 uMIA, so total-settled can trail
;;     floor(total-spent * 1e6 / ratio) by up to one uMIA per settle call.
;;
;; Both invariants below use that exact bound (rv's invariant-mode context
;; map records per-function call counts), so a REAL bug -- misplaced insert,
;; over-paying the settler -- still violates them by economically meaningful
;; margins.

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------
;; defined FIRST (the v1 harness keeps it at the bottom): the v2 invariants
;; read the settle-offers call count as their rounding-dust bound

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))

(define-read-only (rv-settle-calls)
  (get called (default-to { called: u0 } (map-get? context "settle-offers"))))

;; ---- invariants ------------------------------------------------------------

;; the book is sorted ascending by price (ustx/amount), pairwise via
;; cross-multiplication, up to one uMIA of partial-fill rounding drift per
;; settle-offers call (see header)
(define-private (rv-sorted-step
    (r { owner: principal, amount: uint, ustx: uint })
    (acc { prev-ustx: uint, prev-amount: uint, slack: uint, sorted: bool })
  )
  (let (
      (amt-floor (if (> (get amount r) (get slack acc))
        (- (get amount r) (get slack acc))
        u0))
    )
    {
      prev-ustx: (get ustx r),
      prev-amount: (get amount r),
      slack: (get slack acc),
      sorted: (and
        (get sorted acc)
        (<= (* (get prev-ustx acc) amt-floor)
            (* (get ustx r) (get prev-amount acc)))),
    }
  )
)

(define-read-only (invariant-book-sorted-by-price)
  (get sorted (fold rv-sorted-step (var-get offer-book)
    { prev-ustx: u0, prev-amount: u1, slack: (rv-settle-calls), sorted: true }))
)

;; every uMIA the contract holds is accounted for: escrowed offers + retained
;; surplus, nothing more, nothing less -- still EXACT under partial fill (a
;; settle moves `acquired` out of the book, pays out par-equiv, retains the
;; rest as surplus; the ledger stays balanced to the digit)
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

;; no resting ask above par -- still EXACT under partial fill (the remainder's
;; implied price only ever decreases, and floor(par) of the smaller amount
;; still covers the smaller ask)
(define-private (rv-par-step
    (r { owner: principal, amount: uint, ustx: uint })
    (all-ok bool)
  )
  (and all-ok (<= (get ustx r) (get-par-ustx (get amount r))))
)

(define-read-only (invariant-asks-at-or-below-par)
  (fold rv-par-step (var-get offer-book) true)
)

;; one offer per wallet -- a partial fill shrinks a record in place, never
;; duplicates it
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
;; spent, up to one uMIA of floor rounding per settle-offers call (see header)
(define-read-only (invariant-settled-covers-spent-at-par)
  (let ((ratio (var-get redemption-ratio)))
    (or
      (is-eq ratio u0)
      (>= (+ (var-get total-settled) (rv-settle-calls))
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
    ;; the spread is non-negative and fully retained (holds for partial fills
    ;; too: a floor'd taken from a below-par ask still covers par-equiv)
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

;; v2: a settle consumes EXACTLY min(budget, whole-book cost) -- the frontier
;; partial fill means no budget is ever left stranded. Requires ratio < 1e6
;; (1 uMIA costs < 1 uSTX at par) so any 1-uSTX remainder can always buy at
;; least one uMIA from a below-par ask
(define-private (test-settle-spends-exactly-min (budget uint))
  (let (
      (b (mod budget u100000))
      (book-cost (get ustx (get-book-totals)))
      (res (try! (settle-offers b)))
    )
    (asserts! (is-eq (get spent res) (if (< b book-cost) b book-cost)) (err u950))
    (ok true))
)

(define-read-only (can-test-settle-spends-exactly-min (budget uint))
  (and
    (var-get redemptions-enabled)
    (< (var-get redemption-ratio) u1000000)
    (is-none (get-offer tx-sender))
    (>= (stx-get-balance tx-sender) (mod budget u100000)))
)

;; v2: a budget below the frontier ask partial-fills EXACTLY that offer --
;; floor'd taken, maker paid at or above their per-uMIA ask, the record
;; shrinks in place to {amount - taken, ask - budget}, and no later offer
;; is touched (strict price-time priority)
(define-private (test-partial-fill-frontier (budget uint))
  (let (
      (front (unwrap! (element-at? (var-get offer-book) u0) (err u960)))
      (b (+ u1 (mod budget (- (get ustx front) u1))))
      (taken (/ (* (get amount front) b) (get ustx front)))
      (count-before (get-offer-count))
      (res (try! (settle-offers b)))
      (after (unwrap! (get-offer (get owner front)) (err u961)))
    )
    (asserts! (is-eq (get spent res) b) (err u962))
    (asserts! (is-eq (get acquired res) taken) (err u963))
    (asserts! (is-eq (get amount after) (- (get amount front) taken)) (err u964))
    (asserts! (is-eq (get ustx after) (- (get ustx front) b)) (err u965))
    ;; maker paid at/above their ask rate: b/taken >= ask/amount
    (asserts! (>= (* b (get amount front)) (* taken (get ustx front))) (err u966))
    ;; the remainder replaced the frontier in place: nothing else consumed
    (asserts! (is-eq (get-offer-count) count-before) (err u967))
    (ok true))
)

(define-read-only (can-test-partial-fill-frontier (budget uint))
  (match (element-at? (var-get offer-book) u0)
    front (and
      (var-get redemptions-enabled)
      (< (var-get redemption-ratio) u1000000)
      ;; no resting offer => the frontier is a foreign offer
      (is-none (get-offer tx-sender))
      (> (get ustx front) u1)
      (>= (stx-get-balance tx-sender) (get ustx front)))
    false)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? MIA_TOKEN_V2 rv-faucet u120000000000 who))
)

;; 10 wallets x 1.2e11 uMIA
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

;; initialize freezes par at u1710 in the synced copy (rv-sync PATCH 5: the
;; simnet ccd013 copy deploys un-initialized, so the real copy-from-live call
;; would silently disable redemptions and make every fair run vacuous).
;; is-ok (not unwrap-panic): `clarinet check` interprets deploys WITHOUT the
;; genesis STX funding the real simnet has, so this must not abort there
(is-ok (initialize))
