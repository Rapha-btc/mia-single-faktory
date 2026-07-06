;; Rendezvous fuzzing harness for mia-arb-faktory (atomic triangular arb:
;; book -> ALEX -> Bitflow/Velar, plus the sBTC -> STX -> MIA replenish loop).
;;
;; World: rv-sync.sh PATCH 8 rewrites the four venue principals in the
;; contract copy to the LOCAL book (.mia-orderbook-jing) and the real-balance
;; xyk mocks (.mock-alex / .mock-xyk / .mock-velar), which preserve the
;; fixed-8 conversion semantics the arb depends on. The full loop against
;; live liquidity is covered by simulations/verify-arb.js on a mainnet fork;
;; this harness fuzzes the arb's OWN promises:
;;   - success  => caller profit >= min-profit, sBTC delta >= reported profit
;;                 (the caller may additionally earn maker proceeds when the
;;                 fuzzer fills its own planted offer -- settler is the arb
;;                 contract, so the book's self-skip does not apply)
;;   - failure  => the caller's sBTC balance is EXACTLY untouched
;;   - always   => the arb contract retains no sBTC / MIA / STX
;;
;; Note the caller's own sBTC also funds the mocks' liquidity via rv-seed
;; helpers; RV dials those organically in invariant mode.

(define-constant RV-MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant RV-SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

;; ---- rendezvous invariant-mode bookkeeping ---------------------------------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context
    (function-name (string-ascii 100))
    (called uint)
  )
  (ok (map-set context function-name { called: called }))
)

;; ---- world seeding (public so invariant-mode dials them organically) ------

(define-public (rv-seed-mocks)
  (begin
    ;; MIA side of the ALEX mock comes from the faucet (PATCH 4)
    (try! (contract-call? RV-MIA rv-faucet u50000000000000 tx-sender)) ;; 50M MIA
    (try! (contract-call? .mock-alex fund-mia u50000000000000))
    (try! (contract-call? .mock-alex fund-stx u50000000000)) ;; 50k STX
    (try! (contract-call? .mock-xyk fund-sbtc u100000000)) ;; 1 sBTC
    (try! (contract-call? .mock-xyk fund-stx u50000000000))
    (try! (contract-call? .mock-velar fund-sbtc u100000000))
    (try! (contract-call? .mock-velar fund-stx u50000000000))
    (try! (contract-call? .mock-dlmm fund-sbtc u100000000))
    (try! (contract-call? .mock-dlmm fund-stx u50000000000))
    (ok true)
  )
)

(define-public (rv-plant-offer
    (amount uint)
    (ask uint)
  )
  (let (
      (amt (+ u100000000000 (mod amount u1000000000000))) ;; 100k .. 1.1M MIA
      (ask2 (+ u1000 (mod ask u1000000))) ;; 1k .. ~1M sats
    )
    (try! (contract-call? RV-MIA rv-faucet amt tx-sender))
    (match (contract-call? .mia-orderbook-jing place-offer amt ask2)
      fine (ok true)
      ;; duplicate offer (u13016) or full book (u13015) are fine mid-fuzz
      e (if (or (is-eq e u13016) (is-eq e u13015)) (ok true) (err e))
    )
  )
)

;; ---- invariants: the arb contract NEVER retains funds ----------------------

;; NOTE: read-only context needs the literal token principal -- clarinet
;; cannot statically prove a constant-target contract-call? is read-only
(define-read-only (invariant-no-resting-sbtc)
  (is-eq u0
    (unwrap-panic (contract-call?
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      get-balance current-contract
    ))
  )
)

(define-read-only (invariant-no-resting-mia)
  (is-eq u0
    (unwrap-panic (contract-call?
      'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
      get-balance current-contract
    ))
  )
)

(define-read-only (invariant-no-resting-stx)
  (is-eq u0 (stx-get-balance current-contract))
)

;; ---- properties -------------------------------------------------------------

(define-private (rv-sbtc-of (who principal))
  (unwrap-panic (contract-call? RV-SBTC get-balance who))
)

(define-private (rv-mia-of (who principal))
  (unwrap-panic (contract-call? RV-MIA get-balance who))
)

(define-private (rv-contract-empty)
  (and
    (invariant-no-resting-sbtc)
    (invariant-no-resting-mia)
    (invariant-no-resting-stx)
  )
)

;; taker arb, Bitflow close: profit-or-exact-refund
(define-private (test-arb-bitflow
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (let (
      (spend2 (+ u1000 (mod spend u10000000))) ;; 1k sats .. 0.1 sBTC
      (mp (mod min-profit u1000000))
      (before (rv-sbtc-of tx-sender))
    )
    (try! (rv-seed-mocks))
    (try! (rv-plant-offer spend2 ask))
    (let ((seeded (rv-sbtc-of tx-sender))) ;; seeding itself spends sBTC
      (match (arb-book-alex-bitflow spend2 u999999999999 mp)
        r (begin
          (asserts! (>= (get profit r) mp) (err u960))
          (asserts! (>= (rv-sbtc-of tx-sender) (+ seeded (get profit r))) (err u961))
          (asserts! (rv-contract-empty) (err u962))
          (ok true)
        )
        e (begin
          (asserts! (is-eq (rv-sbtc-of tx-sender) seeded) (err u963))
          (asserts! (rv-contract-empty) (err u964))
          (ok true)
        )
      )
    )
  )
)

(define-read-only (can-test-arb-bitflow
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (let ((spend2 (+ u1000 (mod spend u10000000))))
    ;; enough sBTC for the buffer AND the two 1-sBTC mock seedings
    (>= (unwrap-panic (contract-call?
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      get-balance tx-sender
    ))
      (+ u200000000 spend2 (/ spend2 u1000))
    )
  )
)

;; taker arb, Velar close
(define-private (test-arb-velar
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (let (
      (spend2 (+ u1000 (mod spend u10000000)))
      (mp (mod min-profit u1000000))
    )
    (try! (rv-seed-mocks))
    (try! (rv-plant-offer spend2 ask))
    (let ((seeded (rv-sbtc-of tx-sender)))
      (match (arb-book-alex-velar spend2 u999999999999 mp)
        r (begin
          (asserts! (>= (get profit r) mp) (err u970))
          (asserts! (>= (rv-sbtc-of tx-sender) (+ seeded (get profit r))) (err u971))
          (asserts! (rv-contract-empty) (err u972))
          (ok true)
        )
        e (begin
          (asserts! (is-eq (rv-sbtc-of tx-sender) seeded) (err u973))
          (asserts! (rv-contract-empty) (err u974))
          (ok true)
        )
      )
    )
  )
)

(define-read-only (can-test-arb-velar
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (can-test-arb-bitflow spend ask min-profit)
)

;; taker arb, DLMM direct close (in == amount guard exercised on every fill)
(define-private (test-arb-dlmm
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (let (
      (spend2 (+ u1000 (mod spend u10000000)))
      (mp (mod min-profit u1000000))
    )
    (try! (rv-seed-mocks))
    (try! (rv-plant-offer spend2 ask))
    (let ((seeded (rv-sbtc-of tx-sender)))
      (match (arb-book-alex-dlmm spend2 u999999999999 mp)
        r (begin
          (asserts! (>= (get profit r) mp) (err u975))
          (asserts! (>= (rv-sbtc-of tx-sender) (+ seeded (get profit r))) (err u976))
          (asserts! (rv-contract-empty) (err u977))
          (ok true)
        )
        e (begin
          (asserts! (is-eq (rv-sbtc-of tx-sender) seeded) (err u978))
          (asserts! (rv-contract-empty) (err u979))
          (ok true)
        )
      )
    )
  )
)

(define-read-only (can-test-arb-dlmm
    (spend uint)
    (ask uint)
    (min-profit uint)
  )
  (can-test-arb-bitflow spend ask min-profit)
)

;; a limit of u1 can never fill: the book's u13019 must propagate and refund
(define-private (test-arb-no-fill-refunds (spend uint))
  (let (
      (spend2 (+ u1000 (mod spend u10000000)))
      (before (rv-sbtc-of tx-sender))
    )
    (match (arb-book-alex-bitflow spend2 u1 u0)
      r (err u980) ;; a fill at limit u1 should be impossible
      e (begin
        (asserts! (is-eq e u13019) (err u981))
        (asserts! (is-eq (rv-sbtc-of tx-sender) before) (err u982))
        (asserts! (rv-contract-empty) (err u983))
        (ok true)
      )
    )
  )
)

(define-read-only (can-test-arb-no-fill-refunds (spend uint))
  (let ((spend2 (+ u1000 (mod spend u10000000))))
    (>= (unwrap-panic (contract-call?
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      get-balance tx-sender
    ))
      (+ spend2 (/ spend2 u1000))
    )
  )
)

;; replenish: exact MIA-in-hand == mia-out, exact sBTC spend, or exact refund
(define-private (test-replenish-bitflow
    (sbtc-in uint)
    (min-mia uint)
  )
  (let (
      (amt (+ u1000 (mod sbtc-in u1000000))) ;; 1k sats .. 0.01 sBTC
      (floor (mod min-mia u10000000000))
    )
    (try! (rv-seed-mocks))
    (let (
        (sbtc-before (rv-sbtc-of tx-sender))
        (mia-before (rv-mia-of tx-sender))
      )
      (match (replenish-bitflow-alex amt floor)
        r (begin
          (asserts! (>= (get mia-out r) floor) (err u990))
          (asserts! (is-eq (rv-mia-of tx-sender) (+ mia-before (get mia-out r))) (err u991))
          (asserts! (is-eq (rv-sbtc-of tx-sender) (- sbtc-before amt)) (err u992))
          (asserts! (rv-contract-empty) (err u993))
          (ok true)
        )
        e (begin
          (asserts! (is-eq (rv-sbtc-of tx-sender) sbtc-before) (err u994))
          (asserts! (is-eq (rv-mia-of tx-sender) mia-before) (err u995))
          (asserts! (rv-contract-empty) (err u996))
          (ok true)
        )
      )
    )
  )
)

(define-read-only (can-test-replenish-bitflow
    (sbtc-in uint)
    (min-mia uint)
  )
  (>= (unwrap-panic (contract-call?
    'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance tx-sender
  ))
    (+ u200000000 u1000 (mod sbtc-in u1000000))
  )
)

(define-private (test-replenish-velar
    (sbtc-in uint)
    (min-mia uint)
  )
  (let (
      (amt (+ u1000 (mod sbtc-in u1000000)))
      (floor (mod min-mia u10000000000))
    )
    (try! (rv-seed-mocks))
    (let (
        (sbtc-before (rv-sbtc-of tx-sender))
        (mia-before (rv-mia-of tx-sender))
      )
      (match (replenish-velar-alex amt floor)
        r (begin
          (asserts! (>= (get mia-out r) floor) (err u997))
          (asserts! (is-eq (rv-mia-of tx-sender) (+ mia-before (get mia-out r))) (err u998))
          (asserts! (rv-contract-empty) (err u999))
          (ok true)
        )
        e (begin
          (asserts! (is-eq (rv-sbtc-of tx-sender) sbtc-before) (err u1994))
          (asserts! (is-eq (rv-mia-of tx-sender) mia-before) (err u1995))
          (asserts! (rv-contract-empty) (err u1996))
          (ok true)
        )
      )
    )
  )
)

(define-read-only (can-test-replenish-velar
    (sbtc-in uint)
    (min-mia uint)
  )
  (can-test-replenish-bitflow sbtc-in min-mia)
)
