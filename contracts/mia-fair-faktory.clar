;; Title: mia-fair-faktory  (permissionless whitehat settle + spread accumulator)
;; Summary: STANDALONE fork of ccd014-fair-burn-to-exit-mia. Same below-par
;;   offer book, but settlement is funded by the CALLER's own STX (not the DAO
;;   rewards treasury) and the escrowed MIA is ACQUIRED, not burned. The settler
;;   receives only the par-equivalent of the STX they spent -- i.e. they buy MIA
;;   at par (1710), ABOVE market, so settling is deliberately unprofitable: a
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
;;   7. PAR SOURCE: the ratio is COPIED from the live DAO redemption
;;      (SP2PABAF9....ccd013-burn-to-exit-mia, frozen u1710) at initialize --
;;      NOT recomputed from live supply/treasury like ccd014 does. Recomputing
;;      today gives ~2025 (redemptions burned ~935M MIA since ccd013's
;;      snapshot), which would let sellers ask above the DAO's actual 1710
;;      conversion rate and silently cost the whitehat ~16% on the round trip.

;; CONSTANTS

(define-constant ERR_UNAUTHORIZED (err u13000))
(define-constant ERR_REFERENCE_NOT_ENABLED (err u13001)) ;; live ccd013 not initialized / zero ratio
(define-constant ERR_ALREADY_ENABLED (err u13004))
(define-constant ERR_NOT_ENABLED (err u13005))
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

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
;; the LIVE DAO redemption (frozen ratio u1710) -- our canonical par reference
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant SINGLE_SIDED .mia-single-faktory)

;; DATA VARS
(define-data-var admin principal tx-sender)           ;; admin: gates initialize + seed only
(define-data-var redemptions-enabled bool false)
(define-data-var redemption-ratio uint u0)            ;; par copied from live ccd013 (u1710)
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

;; Copy par from the LIVE ccd013 (its ratio is frozen/immutable after its own
;; init, so this is the DAO's canonical redemption rate -- NOT recomputed from
;; live supply, which would drift above 1710 as redemptions burn supply and
;; break the settler's neutrality vs the real conversion rate). One-shot.
(define-public (initialize)
  (let (
      (ratio (contract-call? CCD013 get-redemption-ratio))
    )
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (asserts! (not (var-get redemptions-enabled)) ERR_ALREADY_ENABLED)
    (asserts! (and (contract-call? CCD013 is-redemption-enabled) (> ratio u0))
      ERR_REFERENCE_NOT_ENABLED)
    (var-set redemption-ratio ratio)
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
    reference: CCD013,
    total-settled: (var-get total-settled),
    total-spent: (var-get total-spent),
    surplus-mia: (var-get surplus-mia),
    offer-count: (len (var-get offer-book)),
  }
)
