;; Title: mia-fair-faktory  (permissionless whitehat settle + spread accumulator)
;; Summary: STANDALONE fork of ccd014-fair-burn-to-exit-mia. Same below-par
;;   offer book, but settlement is funded by the CALLER's own STX (not the DAO
;;   rewards treasury) and the escrowed MIA is ACQUIRED, not burned. The settler
;;   receives only the par-equivalent of the STX they spent -- i.e. they buy MIA
;;   at par (~1710), ABOVE market, so settling is deliberately unprofitable: a
;;   pure whitehat anyone may run. The below-par SPREAD is captured HERE and
;;   accumulates across cycles to seed the single-sided MIA/sBTC pool on fak.fun.
;;
;; AMENDMENTS vs reference/ccd014-fair-burn-to-exit-mia.clar (diff side by side):
;;   1. NOT a DAO extension: no impl-trait, no is-dao-or-extension, no treasury
;;      revoke-delegate. `owner` var (deployer) only gates initialize + seed.
;;   2. v2 ONLY: dropped MIA v1 / core-v1-patch / is-v1 everywhere. Offer record
;;      is {owner, amount(uMIA v2), ustx}.
;;   3. settle-offers is PERMISSIONLESS and CALLER-FUNDED: pays each filled ask
;;      in STX from tx-sender directly to the offer owner; no treasury, no burn.
;;      Escrowed MIA stays in the contract. Rational actors won't call it (you
;;      overpay at par); only a whitehat does -> "anyone is free, but illogical".
;;   4. After a settle: par-equiv MIA (spent*1e6/ratio) goes to the settler;
;;      the SPREAD (acquired - par-equiv) is retained in `surplus-mia` and
;;      accumulates over 2-3 cycles. A single seed-single-sided call at the end
;;      pushes it to the single-sided contract, which STARTS the offering then.
;;   5. redeem-mia (the fixed-rate ccd013 path) is REMOVED -- this contract only
;;      runs the offer book + arb; the DAO's own redemption is untouched.
;;   6. Clarity 5: uses `current-contract` (no CONTRACT constant); every MIA the
;;      contract sends out (refund, par-equiv payout, seed) runs under
;;      `as-contract?` with an exact post-condition.

;; CONSTANTS

(define-constant ERR_UNAUTHORIZED (err u13000))
(define-constant ERR_PANIC (err u13001))
(define-constant ERR_GETTING_TOTAL_SUPPLY (err u13002))
(define-constant ERR_GETTING_REDEMPTION_BALANCE (err u13003))
(define-constant ERR_ALREADY_ENABLED (err u13004))
(define-constant ERR_NOT_ENABLED (err u13005))
(define-constant ERR_SUPPLY_CALCULATION (err u13009))
(define-constant ERR_ABOVE_PAR (err u13012))
(define-constant ERR_INVALID_OFFER (err u13013))
(define-constant ERR_OFFER_NOT_FOUND (err u13014))
(define-constant ERR_BOOK_FULL (err u13015))
(define-constant ERR_HAS_OFFER (err u13016))
(define-constant ERR_INSUFFICIENT_SURPLUS (err u13017)) ;; not enough retained surplus MIA to seed

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant REDEMPTION_SCALE_FACTOR (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS)) ;; 10M MIA
(define-constant MAX_OFFERS u50)

(define-constant MIA_TOKEN_V1 'SP466FNC0P7JWTNM2R9T199QRZN1MYEDTAR0KP27.miamicoin-token)
(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant MIA_MINING_TREASURY 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-mining-v3)
(define-constant SINGLE_SIDED .mia-single-faktory)

;; DATA VARS
(define-data-var admin principal tx-sender)           ;; admin: gates initialize + seed only
(define-data-var redemptions-enabled bool false)
(define-data-var total-supply uint u0)               ;; combined v1*1e6 + v2 snapshot at init
(define-data-var mining-treasury-ustx uint u0)       ;; mining treasury snapshot at init
(define-data-var redemption-ratio uint u0)           ;; par: uSTX-per-uMIA * 1e6 (~1710)
(define-data-var total-settled uint u0)              ;; cumulative uMIA acquired via settle
(define-data-var total-spent uint u0)                ;; cumulative uSTX settlers paid out
(define-data-var surplus-mia uint u0)                ;; retained below-par MIA, awaiting seeding

;; v2-only offer book, sorted ascending by price (ustx/amount)
(define-data-var offer-book
  (list 50 { owner: principal, amount: uint, ustx: uint })
  (list)
)
(define-data-var target-owner principal 'SP000000000000000000002Q6VF78)

;; ADMIN

(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

(define-public (set-admin (who principal))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (ok (var-set admin who))
  )
)

;; Snapshot par from live chain state (same formula as ccd014, reads only). No
;; DAO auth / treasury mutation -- gated to owner. One-shot.
(define-public (initialize)
  (let (
      (supply-v1 (unwrap! (contract-call? MIA_TOKEN_V1 get-total-supply) ERR_PANIC))
      (supply-v2 (unwrap! (contract-call? MIA_TOKEN_V2 get-total-supply) ERR_PANIC))
      (supply (+ (* supply-v1 MICRO_CITYCOINS) supply-v2))
      (treasury (get-mining-treasury-total-balance))
      (ratio (calculate-redemption-ratio treasury supply))
    )
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (asserts! (not (var-get redemptions-enabled)) ERR_ALREADY_ENABLED)
    (asserts! (> supply u0) ERR_GETTING_TOTAL_SUPPLY)
    (asserts! (> treasury u0) ERR_GETTING_REDEMPTION_BALANCE)
    (asserts! (is-some ratio) ERR_SUPPLY_CALCULATION)
    (var-set total-supply supply)
    (var-set mining-treasury-ustx treasury)
    (var-set redemption-ratio (unwrap-panic ratio))
    (var-set redemptions-enabled true)
    (ok (print { notification: "initialize", payload: (get-info) }))
  )
)

;; OFFER BOOK (v2 only)

;; Place a standing below-par offer: escrow `amount` v2 uMIA, ask `ask-ustx`.
;; ask must be > 0 and <= par. One offer per wallet; sorted insert; full book
;; evicts its worst (priciest) offer for a strictly cheaper newcomer.
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

;; Cancel your own open offer and get the escrowed MIA back.
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

;; SETTLE (permissionless, caller-funded)
;;
;; PERMISSIONLESS: anyone may call. `budget` caps the STX the caller will spend
;; this call; the book is cheapest-first so it fills the most-pained offers
;; first. Each fill pays the owner's ask in STX FROM THE CALLER and keeps the
;; escrowed MIA here. Afterwards the settler receives the par-equivalent MIA
;; (they buy at par, above market -> settling is unprofitable = whitehat), and
;; the below-par SPREAD is retained in `surplus-mia` to accumulate across cycles.
(define-public (settle-offers (budget uint))
  (let ((settler tx-sender)) ;; capture before as-contract flips tx-sender
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
    ;; the settler gets the par-equivalent of the STX they spent (bought at par)
    (and (> par-equiv u0)
      (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" par-equiv))
             (try! (contract-call? MIA_TOKEN_V2 transfer par-equiv current-contract settler none)))))
    ;; the below-par SPREAD stays here, accumulating over 2-3 cycles to seed the
    ;; single-sided MIA/sBTC offering
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

;; Push retained spread MIA into the single-sided offering. Repeatable: the
;; single-sided accumulates MIA and anchors its entry/lock clock on the FIRST
;; seed. Admin-gated; runs as-contract? so the single-sided sees tx-sender =
;; this contract (its DEPOSITOR) and pulls `amount` MIA from here (post-condition
;; bounds exactly that).
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

;; PRIVATE / READ-ONLY

(define-read-only (get-mining-treasury-total-balance)
  (let ((acc (stx-account MIA_MINING_TREASURY)))
    (+ (get locked acc) (get unlocked acc))
  )
)

(define-private (calculate-redemption-ratio (balance uint) (supply uint))
  (if (or (is-eq supply u0) (is-eq balance u0))
    none
    (some (/ (* balance REDEMPTION_SCALE_FACTOR) supply))
  )
)

;; STX value at par for `amount` uMIA v2, using the frozen ratio.
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
(define-read-only (get-offer (owner principal))
  (get found (fold find-owner-step (var-get offer-book) { target: owner, found: none })))
(define-read-only (get-offer-count) (len (var-get offer-book)))

;; Refund an escrowed record's v2 MIA to its owner, bounded by an exact
;; post-condition (matches the ccd014 original's allowance-scoped as-contract?).
(define-private (refund-rec (r { owner: principal, amount: uint, ustx: uint }))
  (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" (get amount r)))
    (try! (contract-call? MIA_TOKEN_V2 transfer (get amount r) current-contract (get owner r) none)))
)

;; Sorted insert, cheapest-first. STRICT `<` so a same-priced newcomer lands
;; AFTER existing equal-price offers (first-come-first-serve on ties, per
;; Friedger): new < entry  <=>  nask * eumia < eask * numia
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

;; Fill an offer if the remaining budget covers its ask: pay the owner in STX
;; from the caller, keep the escrowed MIA, accumulate spent/acquired. The
;; caller's OWN offer is always kept: stx-transfer? to oneself errors, which
;; the unwrap-panic would turn into a hard abort -- a settler who also has a
;; resting offer must not crash (they can cancel it instead).
(define-private (settle-step
    (entry { owner: principal, amount: uint, ustx: uint })
    (acc {
      remaining: uint,
      spent: uint,
      acquired: uint,
      kept: (list 50 { owner: principal, amount: uint, ustx: uint }),
    })
  )
  (if (and
        (>= (get remaining acc) (get ustx entry))
        (not (is-eq (get owner entry) tx-sender)))
    (begin
      (unwrap-panic (stx-transfer? (get ustx entry) tx-sender (get owner entry)))
      (merge acc {
        remaining: (- (get remaining acc) (get ustx entry)),
        spent: (+ (get spent acc) (get ustx entry)),
        acquired: (+ (get acquired acc) (get amount entry)),
      })
    )
    (merge acc { kept: (push-rec (get kept acc) entry) })
  )
)

(define-read-only (get-info)
  {
    admin: (var-get admin),
    enabled: (var-get redemptions-enabled),
    redemption-ratio: (var-get redemption-ratio),
    total-supply: (var-get total-supply),
    mining-treasury-ustx: (var-get mining-treasury-ustx),
    total-settled: (var-get total-settled),
    total-spent: (var-get total-spent),
    surplus-mia: (var-get surplus-mia),
    offer-count: (len (var-get offer-book)),
  }
)
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
