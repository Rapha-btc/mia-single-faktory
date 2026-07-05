;; mia-orderbook-jing -- fork of mia-fair-faktory-v2 with the par machinery
;; removed: a plain 50-deep sell book for MIA v2 priced in sBTC. Sellers
;; escrow MIA and name any ask (no par ceiling); the book stays sorted
;; cheapest-first. Settling is a true limit order crossing the book:
;; market-order(spend-btc, max-price-per-1m) walks cheapest-first, fills
;; only offers priced at or below the limit, full asks while the budget
;; covers them, then PARTIAL-fills the frontier offer pro-rata at the
;; maker's own ratio -- so spent <= spend-btc, every fill is at or below
;; max-price-per-1m, and the settler receives everything acquired.
;; A 10 bps taker fee in sBTC is charged ON TOP of the book spend (makers
;; receive their full ask; the settler pays spent + fee), so spend-btc
;; bounds the book spend only. Min offer size is an admin-settable var
;; (starts at 100k MIA).
(define-constant ERR_UNAUTHORIZED (err u13000))
(define-constant ERR_INVALID_OFFER (err u13013))
(define-constant ERR_OFFER_NOT_FOUND (err u13014))
(define-constant ERR_BOOK_FULL (err u13015))
(define-constant ERR_HAS_OFFER (err u13016))
(define-constant ERR_BELOW_MIN_DEPOSIT (err u13018))
(define-constant ERR_NO_FILL (err u13019))
(define-constant ERR_PAUSED (err u13020))

(define-constant MICRO_CITYCOINS (pow u10 u6))
;; price unit for the settle limit: sats per 1M MIA (1M MIA = 1e12 uMIA)
(define-constant ONE_MILLION_MIA (* u1000000 MICRO_CITYCOINS))
(define-constant MAX_OFFERS u50)
;; ask/limit ceiling: 1e15 sats (10M BTC) -- far above any real price, but
;; keeps every cross-multiplication (ask * 1e12, ask * amount, max * amount)
;; well under 2^128. Without it one poison offer with an astronomical ask
;; overflows the folds and permanently bricks the whole book (audit CRIT-1).
(define-constant MAX_ASK u1000000000000000)
;; taker fee: 10 bps of the book spend, paid in sBTC on top of it
(define-constant FEE_BPS u10)
(define-constant BPS_DENOM u10000)

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant SBTC_TOKEN 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

(define-data-var admin principal tx-sender)
;; pause gates place-offer / change-offer / market-order. cancel-offer is
;; NEVER pausable: makers can always exit with their escrow.
(define-data-var paused bool false)
(define-data-var fee-recipient principal 'SM362G0X1YNB2M3FWWFAASV9WB3XHQ8RWP512SSX3)
(define-data-var min-deposit uint (* u100000 MICRO_CITYCOINS))

(define-data-var offer-book
  (list 50 { owner: principal, amount: uint, btc: uint })
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

(define-public (set-fee-recipient (who principal))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (ok (var-set fee-recipient who))
  )
)

(define-public (set-paused (pause bool))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (var-set paused pause)
    (ok (print { notification: "set-paused", payload: { paused: pause } }))
  )
)

(define-public (set-min-deposit (amount uint))
  (begin
    (asserts! (is-admin) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_OFFER)
    (var-set min-deposit amount)
    (ok (print { notification: "set-min-deposit", payload: { min-deposit: amount } }))
  )
)


(define-public (place-offer (amount uint) (ask-btc uint))
  (let (
      (owner tx-sender)
      (nrec { owner: owner, amount: amount, btc: ask-btc })
      (book (var-get offer-book))
    )
    (asserts! (not (var-get paused)) ERR_PAUSED)
    (asserts! (>= amount (var-get min-deposit)) ERR_BELOW_MIN_DEPOSIT)
    (asserts! (and (> ask-btc u0) (<= ask-btc MAX_ASK)) ERR_INVALID_OFFER)
    (var-set target-owner owner)
    (asserts! (is-eq (len (filter is-target-owner book)) u0) ERR_HAS_OFFER)
    (try! (contract-call? MIA_TOKEN_V2 transfer amount owner current-contract none))
    (let (
        (base (if (is-eq (len book) MAX_OFFERS)
          (let ((worst (unwrap-panic (element-at? book (- (len book) u1)))))
            (asserts!
              (< (* ask-btc (get amount worst)) (* (get btc worst) amount))
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

;; change-offer: reprice a resting offer and optionally escrow more MIA in one
;; call (add-amount none = reprice only). new-ask-btc is the TOTAL ask for
;; the (existing + added) amount. The offer is re-inserted at its new price
;; position, so an amend queues like a fresh insert at that price.
(define-public (change-offer (add-amount (optional uint)) (new-ask-btc uint))
  (let (
      (owner tx-sender)
      (adding (default-to u0 add-amount))
      (book (var-get offer-book))
    )
    (asserts! (not (var-get paused)) ERR_PAUSED)
    (asserts! (and (> new-ask-btc u0) (<= new-ask-btc MAX_ASK)) ERR_INVALID_OFFER)
    (var-set target-owner owner)
    (let (
        (mine (filter is-target-owner book))
        (cur (unwrap! (element-at? mine u0) ERR_OFFER_NOT_FOUND))
        (namount (+ (get amount cur) adding))
        (nrec { owner: owner, amount: namount, btc: new-ask-btc })
        (rest (filter not-target-owner book))
      )
      (asserts! (>= namount (var-get min-deposit)) ERR_BELOW_MIN_DEPOSIT)
      (and (> adding u0)
        (try! (contract-call? MIA_TOKEN_V2 transfer adding owner current-contract none)))
      (let ((res (fold insert-step rest { nrec: nrec, out: (list), placed: false })))
        (var-set offer-book
          (if (get placed res) (get out res) (push-rec (get out res) nrec)))
      )
      (print { notification: "change-offer", payload: nrec })
      (ok true)
    )
  )
)

(define-public (cancel-offer)
  (let ((book (var-get offer-book)))
    (var-set target-owner tx-sender)
    (let ((mine (filter is-target-owner book)))
      (asserts! (> (len mine) u0) ERR_OFFER_NOT_FOUND)
      (try! (refund-rec (unwrap-panic (element-at? mine u0))))
      (var-set offer-book (filter not-target-owner book))
    )
    (print { notification: "cancel-offer", payload: { owner: tx-sender } })
    (ok true)
  )
)

;; Marketable limit order crossing the book: spend up to spend-btc sats, filling
;; only offers priced at or below max-price-per-1m (sats per 1M MIA). The
;; book is sorted ascending, so the first offer above the limit ends fills.
(define-public (market-order (spend-btc uint) (max-price-per-1m uint))
  (let ((settler tx-sender))
    (asserts! (not (var-get paused)) ERR_PAUSED)
    ;; cap the limit too so (* max-price amount) can't overflow (self-DoS only,
    ;; but a clean error beats a runtime abort)
    (asserts! (<= max-price-per-1m MAX_ASK) ERR_INVALID_OFFER)
    (let (
      (res (fold settle-step (var-get offer-book) {
        remaining: spend-btc,
        max-price: max-price-per-1m,
        spent: u0,
        acquired: u0,
        kept: (list),
      }))
      (spent (get spent res))
      (acquired (get acquired res))
      (fee (/ (* spent FEE_BPS) BPS_DENOM))
    )
    ;; zero fill (nothing under the limit / dust spend) reverts instead of
    ;; charging gas for a no-op
    (asserts! (> acquired u0) ERR_NO_FILL)
    (var-set offer-book (get kept res))
    (and (> fee u0)
      (try! (contract-call? SBTC_TOKEN transfer fee settler (var-get fee-recipient) none)))
    (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" acquired))
           (try! (contract-call? MIA_TOKEN_V2 transfer acquired current-contract settler none))))
    (print { notification: "market-order", payload: {
      settler: settler, spent: spent, acquired: acquired, fee: fee,
      spend-btc: spend-btc, max-price-per-1m: max-price-per-1m,
    } })
    (ok { spent: spent, acquired: acquired, fee: fee })
    )
  )
)

(define-private (push-rec
    (lst (list 50 { owner: principal, amount: uint, btc: uint }))
    (r { owner: principal, amount: uint, btc: uint })
  )
  (unwrap-panic (as-max-len? (append lst r) u50))
)

(define-private (is-target-owner (r { owner: principal, amount: uint, btc: uint }))
  (is-eq (get owner r) (var-get target-owner)))
(define-private (not-target-owner (r { owner: principal, amount: uint, btc: uint }))
  (not (is-eq (get owner r) (var-get target-owner))))

(define-private (find-owner-step
    (r { owner: principal, amount: uint, btc: uint })
    (acc { target: principal, found: (optional { owner: principal, amount: uint, btc: uint }) })
  )
  (if (is-eq (get owner r) (get target acc))
    (merge acc { found: (some r) })
    acc
  )
)

(define-read-only (get-offer-book) (var-get offer-book))

;; total sBTC to clear the whole book (and the MIA escrowed behind it); any
;; smaller budget is consumed exactly thanks to the frontier partial fill
(define-private (sum-step
    (r { owner: principal, amount: uint, btc: uint })
    (acc { btc: uint, amount: uint })
  )
  { btc: (+ (get btc acc) (get btc r)), amount: (+ (get amount acc) (get amount r)) }
)
(define-read-only (get-book-totals)
  (fold sum-step (var-get offer-book) { btc: u0, amount: u0 })
)
(define-read-only (get-offer (owner principal))
  (get found (fold find-owner-step (var-get offer-book) { target: owner, found: none })))

(define-read-only (get-offer-count) (len (var-get offer-book)))

(define-private (refund-rec (r { owner: principal, amount: uint, btc: uint }))
  (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" (get amount r)))
    (try! (contract-call? MIA_TOKEN_V2 transfer (get amount r) current-contract (get owner r) none)))
)

(define-private (insert-step
    (entry { owner: principal, amount: uint, btc: uint })
    (acc {
      nrec: { owner: principal, amount: uint, btc: uint },
      out: (list 50 { owner: principal, amount: uint, btc: uint }),
      placed: bool,
    })
  )
  (let (
      (nrec (get nrec acc))
      (nask (get btc nrec))
      (numia (get amount nrec))
      (eask (get btc entry))
      (eumia (get amount entry))
    )
    (if (and (not (get placed acc)) (< (* nask eumia) (* eask numia)))
      (merge acc { out: (push-rec (push-rec (get out acc) nrec) entry), placed: true })
      (merge acc { out: (push-rec (get out acc) entry) })
    )
  )
)

;; partial fill on the frontier offer. When the remaining budget can't cover
;; the full ask, consume the whole remainder into the entry pro-rata: taken
;; floors, so the owner is paid `remaining` for slightly LESS than pro-rata
;; MIA (never worse than their ask), and the leftover record's implied price
;; is <= its original price, preserving the ascending sort. After a partial,
;; remaining is u0, so no later (pricier) offer can jump the queue with a
;; smaller absolute ask -- strict price-time priority.
(define-private (settle-step
    (entry { owner: principal, amount: uint, btc: uint })
    (acc {
      remaining: uint,
      max-price: uint,
      spent: uint,
      acquired: uint,
      kept: (list 50 { owner: principal, amount: uint, btc: uint }),
    })
  )
  (let (
      (remaining (get remaining acc))
      (ask (get btc entry))
    )
    (if (or
        ;; settler's own resting offer: never touch it (self transfer errors)
        (is-eq (get owner entry) tx-sender)
        ;; limit price: entry price > max <=> ask/amount > max/1e12; the book
        ;; ascends, so every later entry fails this too and is kept as-is
        (> (* ask ONE_MILLION_MIA) (* (get max-price acc) (get amount entry))))
      (merge acc { kept: (push-rec (get kept acc) entry) })
      (if (>= remaining ask)
        (begin
          (unwrap-panic (contract-call? SBTC_TOKEN transfer ask tx-sender (get owner entry) none))
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
              (unwrap-panic (contract-call? SBTC_TOKEN transfer remaining tx-sender (get owner entry) none))
              (merge acc {
                remaining: u0,
                spent: (+ (get spent acc) remaining),
                acquired: (+ (get acquired acc) taken),
                kept: (push-rec (get kept acc)
                  (merge entry {
                    amount: (- (get amount entry) taken),
                    btc: (- ask remaining),
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
    paused: (var-get paused),
    min-deposit: (var-get min-deposit),
    fee-bps: FEE_BPS,
    fee-recipient: (var-get fee-recipient),
    offer-count: (len (var-get offer-book)),
  }
)
