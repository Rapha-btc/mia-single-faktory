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
;; Rendezvous fuzzing harness for mia-orderbook-jing (sBTC sell book,
;; marketable-limit takers, 10 bps taker fee, no par).
;;
;; Adapted from the mia-fair-faktory-v2 harness. Differences:
;;   - no par machinery: asks are unconstrained, so no par invariants; the
;;     settler keeps EVERYTHING acquired (exact MIA delta, no surplus split)
;;   - quote currency is sBTC (simnet pre-funds every wallet with 10 sBTC,
;;     so no faucet needed on that side)
;;   - market-order takes (spend-btc, max-price-per-1m); fills must respect
;;     the limit up to one partial-fill flooring per call (see bound below)
;;   - change-offer (reprice / add) is fuzzed as a first-class action
;;
;; Sorted-book invariant slack: a partial fill floors `taken`, so the
;; remainder's implied price dips below its original by < 1 uMIA worth per
;; market-order call. Same bound as the v2 harness, keyed on the
;; market-order context counter.

;; ---- rendezvous invariant-mode bookkeeping ---------------------------------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))

(define-read-only (rv-order-calls)
  (get called (default-to { called: u0 } (map-get? context "market-order"))))

;; ---- invariants ------------------------------------------------------------

;; the book is sorted ascending by price (btc/amount), pairwise via
;; cross-multiplication, up to one uMIA of partial-fill rounding drift per
;; market-order call
(define-private (rv-sorted-step
    (r { owner: principal, amount: uint, btc: uint })
    (acc { prev-btc: uint, prev-amount: uint, slack: uint, sorted: bool })
  )
  (let (
      (amt-floor (if (> (get amount r) (get slack acc))
        (- (get amount r) (get slack acc))
        u0))
    )
    {
      prev-btc: (get btc r),
      prev-amount: (get amount r),
      slack: (get slack acc),
      sorted: (and
        (get sorted acc)
        (<= (* (get prev-btc acc) amt-floor)
            (* (get btc r) (get prev-amount acc)))),
    }
  )
)

(define-read-only (invariant-book-sorted-by-price)
  (get sorted (fold rv-sorted-step (var-get offer-book)
    { prev-btc: u0, prev-amount: u1, slack: (rv-order-calls), sorted: true }))
)

;; every uMIA the contract holds is escrowed behind a live offer -- EXACT:
;; with no surplus retention, contract balance == book sum at all times
(define-private (rv-sum-amount
    (r { owner: principal, amount: uint, btc: uint })
    (acc uint)
  )
  (+ acc (get amount r))
)

;; NOTE: read-only context needs the literal token principal -- clarinet cannot
;; statically prove a constant-target contract-call? is read-only
(define-read-only (invariant-escrow-matches-book)
  (is-eq
    (unwrap-panic (contract-call?
      'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
      get-balance current-contract))
    (fold rv-sum-amount (var-get offer-book) u0))
)

;; no zombie entries: every resting record has both sides positive (a partial
;; fill that drained either side to zero must remove the record instead)
(define-private (rv-alive-step
    (r { owner: principal, amount: uint, btc: uint })
    (all-ok bool)
  )
  (and all-ok (> (get amount r) u0) (> (get btc r) u0))
)

(define-read-only (invariant-no-zombie-entries)
  (fold rv-alive-step (var-get offer-book) true)
)

;; one offer per wallet -- fills shrink records in place, never duplicate
(define-private (rv-unique-step
    (r { owner: principal, amount: uint, btc: uint })
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

;; ---- property tests --------------------------------------------------------

(define-private (test-place-offer-escrows-and-sorts (amount uint) (ask uint))
  (let (
      (amt (+ (var-get min-deposit) (mod amount u1000000000000)))
      (ask2 (+ u1 (mod ask u100000000)))
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
  (let ((amt (+ (var-get min-deposit) (mod amount u1000000000000))))
    (and
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

;; change-offer: reprice-only keeps the escrowed amount and re-sorts; with an
;; add, escrow grows by exactly the addition; the stored ask is the new TOTAL
(define-private (test-change-offer (add uint) (ask uint) (reprice-only bool))
  (let (
      (rec (unwrap! (get-offer tx-sender) (err u930)))
      (adding (if reprice-only u0 (+ u1 (mod add u100000000000))))
      (ask2 (+ u1 (mod ask u100000000)))
      (bal-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
      (res (try! (change-offer (if reprice-only none (some adding)) ask2)))
      (after (unwrap! (get-offer tx-sender) (err u931)))
    )
    (asserts! (is-eq (get amount after) (+ (get amount rec) adding)) (err u932))
    (asserts! (is-eq (get btc after) ask2) (err u933))
    (asserts!
      (is-eq
        (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
        (- bal-before adding))
      (err u934))
    (asserts! (invariant-book-sorted-by-price) (err u935))
    (ok true))
)

(define-read-only (can-test-change-offer (add uint) (ask uint) (reprice-only bool))
  (match (get-offer tx-sender)
    rec (let ((adding (if reprice-only u0 (+ u1 (mod add u100000000000)))))
      (and
        ;; new total must clear min-deposit (the contract enforces it too)
        (>= (+ (get amount rec) adding) (var-get min-deposit))
        (>= (unwrap-panic (contract-call?
              'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
              get-balance tx-sender))
            adding)))
    false)
)

;; market-order: spent <= spend, fee == 10 bps of spent, taker's sBTC fell by
;; exactly spent + fee, taker's MIA rose by exactly acquired (settler keeps
;; everything -- no par split), and the aggregate price respected the limit up
;; to one flooring: spent * 1e12 <= max * acquired + max
(define-private (test-market-order (spend uint) (max-price uint))
  (let (
      (b (+ u1 (mod spend u10000000)))
      (mp (+ u1 (mod max-price u100000000)))
      (sbtc-before (unwrap-panic (contract-call? SBTC_TOKEN get-balance tx-sender)))
      (mia-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
    )
    (match (market-order b mp)
      res (begin
        (asserts! (<= (get spent res) b) (err u940))
        (asserts! (is-eq (get fee res) (/ (* (get spent res) u10) u10000)) (err u941))
        (asserts!
          (is-eq
            (unwrap-panic (contract-call? SBTC_TOKEN get-balance tx-sender))
            (- sbtc-before (+ (get spent res) (get fee res))))
          (err u942))
        (asserts!
          (is-eq
            (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
            (+ mia-before (get acquired res)))
          (err u943))
        (asserts!
          (<= (* (get spent res) u1000000000000)
              (+ (* mp (get acquired res)) mp))
          (err u944))
        (ok true))
      ;; nothing under the limit (or dust spend) reverts: acceptable outcome
      e (if (is-eq e u13019) (ok true) (err e))))
)

(define-read-only (can-test-market-order (spend uint) (max-price uint))
  (let ((b (+ u1 (mod spend u10000000))))
    (>= (unwrap-panic (contract-call?
          'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          get-balance tx-sender))
        (+ b (/ b u1000) u1)))
)

;; a spend below the frontier ask partial-fills EXACTLY that offer: floor'd
;; taken, maker paid at/above their per-uMIA ask, record shrinks in place,
;; nothing else consumed (strict price-time priority)
(define-private (test-partial-fill-frontier (spend uint))
  (let (
      (front (unwrap! (element-at? (var-get offer-book) u0) (err u960)))
      (b (+ u1 (mod spend (- (get btc front) u1))))
      (taken (/ (* (get amount front) b) (get btc front)))
      (count-before (get-offer-count))
      (res (try! (market-order b u1000000000000000)))
      (after (unwrap! (get-offer (get owner front)) (err u961)))
    )
    (asserts! (is-eq (get spent res) b) (err u962))
    (asserts! (is-eq (get acquired res) taken) (err u963))
    (asserts! (is-eq (get amount after) (- (get amount front) taken)) (err u964))
    (asserts! (is-eq (get btc after) (- (get btc front) b)) (err u965))
    ;; maker paid at/above their ask rate: b/taken >= ask/amount
    (asserts! (>= (* b (get amount front)) (* taken (get btc front))) (err u966))
    ;; the remainder replaced the frontier in place: nothing else consumed
    (asserts! (is-eq (get-offer-count) count-before) (err u967))
    (ok true))
)

(define-read-only (can-test-partial-fill-frontier (spend uint))
  (match (element-at? (var-get offer-book) u0)
    front (and
      ;; no resting offer => the frontier is a foreign offer
      (is-none (get-offer tx-sender))
      (> (get btc front) u1)
      ;; taken must be > 0 for the fill to land: 1 sat must buy >= 1 uMIA
      (>= (get amount front) (get btc front))
      (>= (unwrap-panic (contract-call?
            'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            get-balance tx-sender))
          (+ (get btc front) (/ (get btc front) u1000) u1)))
    false)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? MIA_TOKEN_V2 rv-faucet u10000000000000 who))
)

;; 10 wallets x 1e13 uMIA (10M MIA each; min-deposit default is 100k MIA)
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
