(define-constant ERR_UNAUTHORIZED (err u13000))
(define-constant ERR_REFERENCE_NOT_ENABLED (err u13001))
(define-constant ERR_ALREADY_ENABLED (err u13004))
(define-constant ERR_NOT_ENABLED (err u13005))
(define-constant ERR_ABOVE_PAR (err u13012))
(define-constant ERR_INVALID_OFFER (err u13013))
(define-constant ERR_OFFER_NOT_FOUND (err u13014))
(define-constant ERR_BOOK_FULL (err u13015))
(define-constant ERR_HAS_OFFER (err u13016))
(define-constant ERR_INSUFFICIENT_SURPLUS (err u13017))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant REDEMPTION_SCALE_FACTOR (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS))
(define-constant MAX_OFFERS u50)

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant SINGLE_SIDED .mia-single-faktory-v2)

(define-data-var admin principal tx-sender)
(define-data-var redemptions-enabled bool false)
(define-data-var redemption-ratio uint u0)
(define-data-var total-settled uint u0)
(define-data-var total-spent uint u0)
(define-data-var surplus-mia uint u0)

(define-data-var offer-book
  (list 50 { owner: principal, amount: uint, ustx: uint })
  (list)
)
(define-data-var target-owner principal 'SP000000000000000000002Q6VF78)


(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

(define-public (set-admin (who principal))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (ok (var-set admin who))
  )
)

(define-public (initialize)
  (let (
      (ratio u1710) ;; rv PATCH 5: mainnet-verified par (see rv-sync.sh)
    )
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (asserts! (not (var-get redemptions-enabled)) ERR_ALREADY_ENABLED)
    (asserts! (> ratio u0)
      ERR_REFERENCE_NOT_ENABLED)
    (var-set redemption-ratio ratio)
    (var-set redemptions-enabled true)
    (ok (print { notification: "initialize", payload: (get-info) }))
  )
)


(define-public (place-offer (amount uint) (ask-ustx uint))
  (let (
      (owner tx-sender)
      (nrec { owner: owner, amount: amount, ustx: ask-ustx })
      (book (var-get offer-book))
    )
    (asserts! (var-get redemptions-enabled) ERR_NOT_ENABLED)
    (asserts! (and (> amount u0) (<= amount MAX_PER_TRANSACTION)) ERR_INVALID_OFFER)
    (asserts! (and (> ask-ustx u0) (<= ask-ustx (get-par-ustx amount))) ERR_ABOVE_PAR)
    (var-set target-owner owner)
    (asserts! (is-eq (len (filter is-target-owner book)) u0) ERR_HAS_OFFER)
    (try! (contract-call? MIA_TOKEN_V2 transfer amount owner current-contract none))
    (let (
        (base (if (is-eq (len book) MAX_OFFERS)
          (let ((worst (unwrap-panic (element-at? book (- (len book) u1)))))
            (asserts!
              (< (* ask-ustx (get amount worst)) (* (get ustx worst) amount))
              ERR_BOOK_FULL)
            (try! (refund-rec worst))
            (var-set target-owner (get owner worst))
            (filter not-target-owner book)
          )
          book
        ))
        (res (fold insert-step base { nrec: nrec, out: (list), placed: false }))
      )
      (var-set offer-book
        (if (get placed res) (get out res) (push-rec (get out res) nrec)))
    )
    (print { notification: "place-offer", payload: nrec })
    (ok true)
  )
)

(define-public (cancel-offer)
  (let ((owner tx-sender))
    (var-set target-owner owner)
    (let ((mine (filter is-target-owner (var-get offer-book))))
      (asserts! (> (len mine) u0) ERR_OFFER_NOT_FOUND)
      (try! (refund-rec (unwrap-panic (element-at? mine u0))))
      (var-set offer-book (filter not-target-owner (var-get offer-book)))
    )
    (print { notification: "cancel-offer", payload: { owner: owner } })
    (ok true)
  )
)

(define-public (settle-offers (budget uint))
  (let ((settler tx-sender))
    (asserts! (var-get redemptions-enabled) ERR_NOT_ENABLED)
    (let (
      (res (fold settle-step (var-get offer-book) {
        remaining: budget,
        spent: u0,
        acquired: u0,
        kept: (list),
      }))
      (spent (get spent res))
      (acquired (get acquired res))
      (par-equiv (if (> (var-get redemption-ratio) u0)
        (/ (* spent REDEMPTION_SCALE_FACTOR) (var-get redemption-ratio))
        u0))
      (surplus (if (> acquired par-equiv) (- acquired par-equiv) u0))
    )
    (var-set offer-book (get kept res))
    (and (> par-equiv u0)
      (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" par-equiv))
             (try! (contract-call? MIA_TOKEN_V2 transfer par-equiv current-contract settler none)))))
    (var-set surplus-mia (+ (var-get surplus-mia) surplus))
    (var-set total-settled (+ (var-get total-settled) acquired))
    (var-set total-spent (+ (var-get total-spent) spent))
    (print { notification: "settle-offers", payload: {
      settler: settler, spent: spent, acquired: acquired, par-equiv: par-equiv,
      surplus: surplus, surplus-mia: (var-get surplus-mia),
    } })
    (ok { spent: spent, acquired: acquired, par-equiv: par-equiv, surplus: surplus })
    )
  )
)

(define-public (seed-single-sided (amount uint))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (asserts! (<= amount (var-get surplus-mia)) ERR_INSUFFICIENT_SURPLUS)
    (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
           (try! (contract-call? SINGLE_SIDED initialize-pool amount))))
    (var-set surplus-mia (- (var-get surplus-mia) amount))
    (print { notification: "seed-single-sided", payload: { amount: amount, surplus-mia: (var-get surplus-mia) } })
    (ok true)
  )
)


(define-read-only (get-par-ustx (amount uint))
  (/ (* (var-get redemption-ratio) amount) REDEMPTION_SCALE_FACTOR)
)

(define-private (push-rec
    (lst (list 50 { owner: principal, amount: uint, ustx: uint }))
    (r { owner: principal, amount: uint, ustx: uint })
  )
  (unwrap-panic (as-max-len? (append lst r) u50))
)

(define-private (is-target-owner (r { owner: principal, amount: uint, ustx: uint }))
  (is-eq (get owner r) (var-get target-owner)))
(define-private (not-target-owner (r { owner: principal, amount: uint, ustx: uint }))
  (not (is-eq (get owner r) (var-get target-owner))))

(define-private (find-owner-step
    (r { owner: principal, amount: uint, ustx: uint })
    (acc { target: principal, found: (optional { owner: principal, amount: uint, ustx: uint }) })
  )
  (if (is-eq (get owner r) (get target acc))
    (merge acc { found: (some r) })
    acc
  )
)

(define-read-only (get-offer-book) (var-get offer-book))

;; total STX to clear the whole book (and the MIA escrowed behind it); any
;; smaller budget is consumed exactly thanks to the frontier partial fill
(define-private (sum-step
    (r { owner: principal, amount: uint, ustx: uint })
    (acc { ustx: uint, amount: uint })
  )
  { ustx: (+ (get ustx acc) (get ustx r)), amount: (+ (get amount acc) (get amount r)) }
)
(define-read-only (get-book-totals)
  (fold sum-step (var-get offer-book) { ustx: u0, amount: u0 })
)
(define-read-only (get-offer (owner principal))
  (get found (fold find-owner-step (var-get offer-book) { target: owner, found: none })))
(define-read-only (get-offer-count) (len (var-get offer-book)))

(define-private (refund-rec (r { owner: principal, amount: uint, ustx: uint }))
  (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" (get amount r)))
    (try! (contract-call? MIA_TOKEN_V2 transfer (get amount r) current-contract (get owner r) none)))
)

(define-private (insert-step
    (entry { owner: principal, amount: uint, ustx: uint })
    (acc {
      nrec: { owner: principal, amount: uint, ustx: uint },
      out: (list 50 { owner: principal, amount: uint, ustx: uint }),
      placed: bool,
    })
  )
  (let (
      (nrec (get nrec acc))
      (nask (get ustx nrec))
      (numia (get amount nrec))
      (eask (get ustx entry))
      (eumia (get amount entry))
    )
    (if (and (not (get placed acc)) (< (* nask eumia) (* eask numia)))
      (merge acc { out: (push-rec (push-rec (get out acc) nrec) entry), placed: true })
      (merge acc { out: (push-rec (get out acc) entry) })
    )
  )
)

;; v2: partial fill on the frontier offer. When the remaining budget can't
;; cover the full ask, consume the whole remainder into the entry pro-rata:
;; taken floors, so the owner is paid `remaining` for slightly LESS than
;; pro-rata MIA (never worse than their ask), and the leftover record's
;; implied price is <= its original price <= par, preserving both the
;; below-par invariant and the ascending sort. After a partial, remaining
;; is u0, so no later (pricier) offer can jump the queue with a smaller
;; absolute ask -- strict price-time priority.
(define-private (settle-step
    (entry { owner: principal, amount: uint, ustx: uint })
    (acc {
      remaining: uint,
      spent: uint,
      acquired: uint,
      kept: (list 50 { owner: principal, amount: uint, ustx: uint }),
    })
  )
  (let (
      (remaining (get remaining acc))
      (ask (get ustx entry))
    )
    (if (is-eq (get owner entry) tx-sender)
      ;; settler's own resting offer: never touch it (self stx-transfer errors)
      (merge acc { kept: (push-rec (get kept acc) entry) })
      (if (>= remaining ask)
        (begin
          (unwrap-panic (stx-transfer? ask tx-sender (get owner entry)))
          (merge acc {
            remaining: (- remaining ask),
            spent: (+ (get spent acc) ask),
            acquired: (+ (get acquired acc) (get amount entry)),
          })
        )
        (let ((taken (/ (* (get amount entry) remaining) ask)))
          ;; taken = u0 covers both remaining = u0 and dust budgets smaller
          ;; than the price of a single uMIA: keep the entry untouched
          (if (> taken u0)
            (begin
              (unwrap-panic (stx-transfer? remaining tx-sender (get owner entry)))
              (merge acc {
                remaining: u0,
                spent: (+ (get spent acc) remaining),
                acquired: (+ (get acquired acc) taken),
                kept: (push-rec (get kept acc)
                  (merge entry {
                    amount: (- (get amount entry) taken),
                    ustx: (- ask remaining),
                  })),
              })
            )
            (merge acc { kept: (push-rec (get kept acc) entry) })
          )
        )
      )
    )
  )
)

(define-read-only (get-info)
  {
    admin: (var-get admin),
    enabled: (var-get redemptions-enabled),
    redemption-ratio: (var-get redemption-ratio),
    reference: CCD013,
    total-settled: (var-get total-settled),
    total-spent: (var-get total-spent),
    surplus-mia: (var-get surplus-mia),
    offer-count: (len (var-get offer-book)),
  }
);; Rendezvous fuzzing harness for mia-fair-faktory-v2 (frontier partial fill).
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
