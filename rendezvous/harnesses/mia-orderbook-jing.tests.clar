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
