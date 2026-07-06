;; mia-arb-faktory -- atomic taker arb around the MIA sell book:
;;   1. sBTC -> MIA   mia-orderbook-faktory market-order (fills cheapest asks
;;                    at or below the limit; 10 bps taker fee on top)
;;   2. MIA  -> STX   ALEX amm pool 16 (token-wstx-v2 / token-wmia, factor 1e8;
;;                    amounts are 1e8-fixed: uMIA*100 in, dx/100 uSTX out)
;;   3. STX  -> sBTC  Bitflow xyk sbtc-stx (or Velar univ2 pool 0070)
;; Caller fronts spend-btc + the worst-case 10 bps fee, receives every sat
;; back in the same tx; reverts unless sbtc-out covers the actual book cost
;; plus min-profit. Nothing ever rests in this contract between calls.
;; Swap legs lifted from the mainnet-proven flatearth-arbitrage-faktory-v2.

(define-constant ERR-NO-PROFIT (err u1001))
(define-constant ERR-SLIPPAGE (err u1000))

(define-constant DEPLOYER tx-sender)

(define-constant SBTC-TOKEN 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant MIA-TOKEN 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant ALEX-FACTOR u100000000)

(define-public (arb-book-alex-bitflow
    (spend-btc uint)
    (max-price-per-1m uint)
    (min-profit uint)
  )
  (let (
      (caller tx-sender)
      ;; book spend + worst-case 10 bps taker fee (fee = floor(spent/1000),
      ;; monotone in spent, so floor(spend-btc/1000) always covers it)
      (buffer (+ spend-btc (/ spend-btc u1000)))
    )
    (try! (contract-call? SBTC-TOKEN transfer buffer tx-sender current-contract none))
    (let (
        (book (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" buffer))
          (try! (contract-call?
            .mia-orderbook-jing
            market-order spend-btc max-price-per-1m
          ))
        )))
        (cost (+ (get spent book) (get fee book)))
        (acquired (get acquired book))
        (ustx-out (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" acquired))
          (try! (swap-mia-to-stx-alex acquired))
        )))
        (sbtc-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-sbtc-bitflow ustx-out))
        )))
        (payout (+ sbtc-out (- buffer cost)))
      )
      (asserts! (> sbtc-out cost) ERR-NO-PROFIT)
      (asserts! (>= sbtc-out (+ cost min-profit)) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" payout))
        (try! (contract-call? SBTC-TOKEN transfer payout current-contract caller none))
      ))
      (print { notification: "mia-arb", payload: {
        venue: "bitflow", caller: caller, buffer: buffer, cost: cost,
        acquired: acquired, ustx: ustx-out, sbtc-out: sbtc-out,
        profit: (- sbtc-out cost),
      } })
      (ok { cost: cost, acquired: acquired, sbtc-out: sbtc-out, profit: (- sbtc-out cost) })
    )
  )
)

(define-public (arb-book-alex-velar
    (spend-btc uint)
    (max-price-per-1m uint)
    (min-profit uint)
  )
  (let (
      (caller tx-sender)
      (buffer (+ spend-btc (/ spend-btc u1000)))
    )
    (try! (contract-call? SBTC-TOKEN transfer buffer tx-sender current-contract none))
    (let (
        (book (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" buffer))
          (try! (contract-call?
            .mia-orderbook-jing
            market-order spend-btc max-price-per-1m
          ))
        )))
        (cost (+ (get spent book) (get fee book)))
        (acquired (get acquired book))
        (ustx-out (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" acquired))
          (try! (swap-mia-to-stx-alex acquired))
        )))
        (sbtc-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-sbtc-velar ustx-out))
        )))
        (payout (+ sbtc-out (- buffer cost)))
      )
      (asserts! (> sbtc-out cost) ERR-NO-PROFIT)
      (asserts! (>= sbtc-out (+ cost min-profit)) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" payout))
        (try! (contract-call? SBTC-TOKEN transfer payout current-contract caller none))
      ))
      (print { notification: "mia-arb", payload: {
        venue: "velar", caller: caller, buffer: buffer, cost: cost,
        acquired: acquired, ustx: ustx-out, sbtc-out: sbtc-out,
        profit: (- sbtc-out cost),
      } })
      (ok { cost: cost, acquired: acquired, sbtc-out: sbtc-out, profit: (- sbtc-out cost) })
    )
  )
)

;; Maker-side replenish loop: after a book offer fills at a high ask (MIA
;; sold for sBTC), atomically re-acquire MIA cheaper: sBTC -> STX on Bitflow
;; (or Velar), STX -> MIA on ALEX. min-mia-out is the profit guard -- set it
;; to at least the MIA the filled offer sold.
(define-public (replenish-bitflow-alex
    (sbtc-in uint)
    (min-mia-out uint)
  )
  (let ((caller tx-sender))
    (try! (contract-call? SBTC-TOKEN transfer sbtc-in tx-sender current-contract none))
    (let (
        (ustx-out (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" sbtc-in))
          (try! (swap-sbtc-to-stx-bitflow sbtc-in))
        )))
        (mia-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-mia-alex ustx-out))
        )))
      )
      (asserts! (>= mia-out min-mia-out) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" mia-out))
        (try! (contract-call? MIA-TOKEN transfer mia-out current-contract caller none))
      ))
      (print { notification: "mia-replenish", payload: {
        venue: "bitflow", caller: caller, sbtc-in: sbtc-in, ustx: ustx-out,
        mia-out: mia-out,
      } })
      (ok { sbtc-in: sbtc-in, mia-out: mia-out })
    )
  )
)

(define-public (replenish-velar-alex
    (sbtc-in uint)
    (min-mia-out uint)
  )
  (let ((caller tx-sender))
    (try! (contract-call? SBTC-TOKEN transfer sbtc-in tx-sender current-contract none))
    (let (
        (ustx-out (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" sbtc-in))
          (try! (swap-sbtc-to-stx-velar sbtc-in))
        )))
        (mia-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-mia-alex ustx-out))
        )))
      )
      (asserts! (>= mia-out min-mia-out) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" mia-out))
        (try! (contract-call? MIA-TOKEN transfer mia-out current-contract caller none))
      ))
      (print { notification: "mia-replenish", payload: {
        venue: "velar", caller: caller, sbtc-in: sbtc-in, ustx: ustx-out,
        mia-out: mia-out,
      } })
      (ok { sbtc-in: sbtc-in, mia-out: mia-out })
    )
  )
)

;; ALEX pool 16 is keyed (token-wstx-v2, token-wmia, 1e8); selling MIA for
;; STX is the y-for-x direction. dy is wMIA in 1e8-fixed (uMIA * 100); the
;; returned dx is wSTX 1e8-fixed, so /100 gives the uSTX actually unwrapped.
(define-private (swap-mia-to-stx-alex (umia uint))
  (let ((result (try! (contract-call?
      .mock-alex
      swap-y-for-x
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.token-wstx-v2
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.token-wmia
      ALEX-FACTOR
      (* umia u100)
      none
    ))))
    (ok (/ (get dx result) u100))
  )
)

;; buying MIA with STX is the x-for-y direction on the same pool: dx is wSTX
;; 1e8-fixed (uSTX * 100), returned dy is wMIA 1e8-fixed -> /100 gives uMIA.
(define-private (swap-stx-to-mia-alex (ustx uint))
  (let ((result (try! (contract-call?
      .mock-alex
      swap-x-for-y
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.token-wstx-v2
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.token-wmia
      ALEX-FACTOR
      (* ustx u100)
      none
    ))))
    (ok (/ (get dy result) u100))
  )
)

(define-private (swap-sbtc-to-stx-bitflow (sbtc-in uint))
  (contract-call?
    .mock-xyk
    swap-x-for-y
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-pool-sbtc-stx-v-1-1
    'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2
    sbtc-in
    u1
  )
)

(define-private (swap-sbtc-to-stx-velar (sbtc-in uint))
  (let ((result (try! (contract-call?
      .mock-velar
      swap
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      'SP1Y5YSTAHZ88XYK1VPDH24GY0HPX5J4JECTMY4A1.wstx
      'SP20X3DC5R091J8B6YPQT638J8NR1W83KN6TN5BJY.univ2-fees-v1_0_0-0070
      sbtc-in
      u1
    ))))
    (ok (get amt-out result))
  )
)

(define-private (swap-stx-to-sbtc-bitflow (ustx uint))
  (contract-call?
    .mock-xyk
    swap-y-for-x
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-pool-sbtc-stx-v-1-1
    'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2
    ustx
    u1
  )
)

(define-private (swap-stx-to-sbtc-velar (ustx uint))
  (let ((result (try! (contract-call?
      .mock-velar
      swap
      'SP1Y5YSTAHZ88XYK1VPDH24GY0HPX5J4JECTMY4A1.wstx
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      'SP20X3DC5R091J8B6YPQT638J8NR1W83KN6TN5BJY.univ2-fees-v1_0_0-0070
      ustx
      u1
    ))))
    (ok (get amt-out result))
  )
)

;; Every path pays out or reverts, so nothing should ever rest here -- but a
;; direct donation (or unforeseen dust) would otherwise be locked forever
;; (audit L-1). Sweep any balance to the deployer; callable by anyone since
;; funds can only move to DEPLOYER.
(define-public (rescue)
  (let (
      (sbtc-bal (unwrap-panic (contract-call? SBTC-TOKEN get-balance current-contract)))
      (mia-bal (unwrap-panic (contract-call? MIA-TOKEN get-balance current-contract)))
      (stx-bal (stx-get-balance current-contract))
    )
    (and (> sbtc-bal u0)
      (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" sbtc-bal))
        (try! (contract-call? SBTC-TOKEN transfer sbtc-bal current-contract DEPLOYER none))
      )))
    (and (> mia-bal u0)
      (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" mia-bal))
        (try! (contract-call? MIA-TOKEN transfer mia-bal current-contract DEPLOYER none))
      )))
    (and (> stx-bal u0)
      (try! (as-contract? ((with-stx stx-bal))
        (try! (stx-transfer? stx-bal tx-sender DEPLOYER))
      )))
    (ok { sbtc: sbtc-bal, mia: mia-bal, stx: stx-bal })
  )
)
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
