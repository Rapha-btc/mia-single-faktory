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
(define-constant SINGLE_SIDED .mia-single-faktory)

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