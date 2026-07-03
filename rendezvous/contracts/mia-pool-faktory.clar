;; Title: mia-pool-faktory
;; Summary: Constant-product MIA(v2)/sBTC AMM for fak.fun. Port of
;;   SPV9K21....flatearth-faktory-pool-v2 with token-b swapped to MIA v2 and the
;;   behavioural changes called out below. Upgraded from the Clarity-3 template
;;   to Clarity 6: `current-contract` replaces the as-contract-based constant and every
;;   contract-held asset moves under `as-contract?` with an exact allowance.
;;
;; AMENDMENTS vs flatearth-faktory-pool-v2 (diff these side by side):
;;   1. token-b: flat-earth-stxcity  ->  miamicoin-token-v2  (v2 only, per spec)
;;   2. LP token: sBTC-FlatEarth      ->  sBTC-MIA
;;   3. initialize-pool NO LONGER auto-approves fakfun-core-v2. Swaps stay GATED
;;      (only `gated=false` or an approved-caller can swap) until the admin opens
;;      them AFTER the single-sided entry window. This is the anti-imbalance
;;      lever: while the single-sided offering is taking sBTC deposits, nobody
;;      can move the pool ratio by swapping, so deposits always pair at the
;;      seeded price and the standalone's MIA can't be sniped. add/remove
;;      liquidity are NOT swap-gated, so the single-sided contract still works.
;;   4. is-approved-caller DROPS the template's `(is-eq tx-sender contract-caller)`
;;      escape hatch. In the template that clause lets ANY direct (wallet) call
;;      swap while "gated", which would defeat amendment 3 entirely -- the gate
;;      must hold against direct calls too, not just routers. While gated, only
;;      explicitly approved callers can swap.
;;   5. Clarity 6 port: plain `as-contract` no longer exists. Every outbound
;;      transfer from the pool runs under `as-contract?` with a `with-ft`
;;      allowance for exactly the amount sent.

(impl-trait 'SP2ZNGJ85ENDY6QRHQ5P2D4FXKGZWCKTB2T0Z55KS.charisma-traits-v1.sip010-ft-trait)
(impl-trait 'SP2ZNGJ85ENDY6QRHQ5P2D4FXKGZWCKTB2T0Z55KS.dexterity-traits-v0.liquidity-pool-trait)

(define-constant DEPLOYER tx-sender)

(define-constant ERR_INVALID_OPERATION (err u400))
(define-constant ERR_UNAUTHORIZED (err u403))
(define-constant ERR_TOO_MUCH_SLIPPAGE (err u407))

(define-constant PRECISION u1000000)
(define-constant LP_REBATE u3000)
(define-constant FAKTORY_FEE u1000)
(define-constant FAKTORY_ADDRESS 'SMH8FRN30ERW1SX26NJTJCKTDR3H27NRJ6W75WQE)

;; token-a = sBTC (SM3VDXK3....sbtc-token), token-b = MIA v2
;; (SP1H1733....miamicoin-token-v2) -- referenced inline throughout, matching the
;; flatearth-faktory-pool-v2 style.

(define-constant OP_SWAP_A_TO_B 0x00)
(define-constant OP_SWAP_B_TO_A 0x01)
(define-constant OP_ADD_LIQUIDITY 0x02)
(define-constant OP_REMOVE_LIQUIDITY 0x03)
(define-constant OP_LOOKUP_RESERVES 0x04)

(define-fungible-token sBTC-MIA)
(define-data-var token-uri (optional (string-utf8 256)) none)
(define-data-var pool-opened bool true)
(define-data-var gated bool true)

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
    (begin
        (asserts! (is-eq tx-sender sender) ERR_UNAUTHORIZED)
        (try! (ft-transfer? sBTC-MIA amount sender recipient))
        (match memo to-print (print to-print) 0x0000)
        (print {
            type: "transfer-lp",
            sender: sender,
            recipient: recipient,
            amount: amount,
            pool-contract: current-contract
        })
        (ok true)))

(define-read-only (get-name)
    (ok "sBTC-MIA lp-token"))

(define-read-only (get-symbol)
    (ok "sBTC-MIA"))

(define-read-only (get-decimals)
    (ok u6))

(define-read-only (get-balance (who principal))
    (ok (ft-get-balance sBTC-MIA who)))

(define-read-only (get-total-supply)
    (ok (ft-get-supply sBTC-MIA)))

(define-read-only (get-token-uri)
    (ok (var-get token-uri)))

(define-public (set-token-uri (uri (string-utf8 256)))
    (if (is-eq contract-caller DEPLOYER)
        (ok (var-set token-uri (some uri)))
        ERR_UNAUTHORIZED))

(define-public (execute (amount uint) (opcode (optional (buff 16))))
    (let (
        (sender tx-sender)
        (operation (get-byte (default-to 0x00 opcode) u0)))
        (if (is-eq operation OP_SWAP_A_TO_B) (swap-a-to-b amount u0)
        (if (is-eq operation OP_SWAP_B_TO_A) (swap-b-to-a amount u0)
        (if (is-eq operation OP_ADD_LIQUIDITY) (add-liquidity amount)
        (if (is-eq operation OP_REMOVE_LIQUIDITY) (remove-liquidity amount)
        ERR_INVALID_OPERATION))))))

(define-read-only (quote (amount uint) (opcode (optional (buff 16))))
    (let (
        (operation (get-byte (default-to 0x00 opcode) u0)))
        (if (is-eq operation OP_SWAP_A_TO_B) (let ((sq (get-swap-quote amount (some 0x00)))) (ok {dx: (get dx sq), dy: (get dy sq), dk: u0}))
        (if (is-eq operation OP_SWAP_B_TO_A) (let ((sq (get-swap-quote amount (some 0x01)))) (ok {dx: (get dx sq), dy: (get dy sq), dk: u0}))
        (if (is-eq operation OP_ADD_LIQUIDITY) (ok (get-liquidity-quote amount))
        (if (is-eq operation OP_REMOVE_LIQUIDITY) (ok (get-liquidity-quote amount))
        (if (is-eq operation OP_LOOKUP_RESERVES) (ok (get-reserves-quote))
        ERR_INVALID_OPERATION)))))))

(define-public (swap-a-to-b (amount uint) (min-y-out uint))
    (let (
        (sender tx-sender)
        (delta (get-swap-quote amount (some 0x00)))
        (dy-d (get dy delta))
        (fee-d (get fee delta)))
        (and (var-get gated) (asserts! (is-approved-caller) ERR_UNAUTHORIZED))
        (asserts! (>= dy-d min-y-out) ERR_TOO_MUCH_SLIPPAGE)
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- amount fee-d) sender current-contract none))
        (if (> fee-d u0)
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer fee-d sender FAKTORY_ADDRESS none))
            true)
        (try! (as-contract? ((with-ft 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 "miamicoin" dy-d))
               (try! (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 transfer dy-d current-contract sender none))))
        (print {
            type: "buy",
            sender: sender,
            token-in: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
            amount-in: amount,
            faktory-fee: fee-d,
            token-out: 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2,
            amount-out: dy-d,
            pool-reserves: (get-reserves-quote),
            pool-contract: current-contract,
            min-y-out: min-y-out
        })
        (ok {dx: (get dx delta), dy: dy-d, dk: u0})))

(define-public (swap-b-to-a (amount uint) (min-y-out uint))
    (let (
        (sender tx-sender)
        (delta (get-swap-quote amount (some 0x01)))
        (dy-d (get dy delta))
        (fee-d (get fee delta)))
        (and (var-get gated) (asserts! (is-approved-caller) ERR_UNAUTHORIZED))
        (asserts! (>= (- dy-d fee-d) min-y-out) ERR_TOO_MUCH_SLIPPAGE)
        (try! (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 transfer amount sender current-contract none))
        ;; one allowance covers both legs: (dy-d - fee-d) to the trader + fee-d
        ;; to faktory = dy-d sBTC total leaving the pool
        (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" dy-d))
               (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- dy-d fee-d) current-contract sender none))
               (if (> fee-d u0)
                   (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer fee-d current-contract FAKTORY_ADDRESS none))
                   true)))
        (print {
            type: "sell",
            sender: sender,
            token-in: 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2,
            amount-in: amount,
            token-out: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
            amount-out: dy-d,
            faktory-fee: fee-d,
            pool-reserves: (get-reserves-quote),
            pool-contract: current-contract,
            min-y-out: min-y-out
        })
        (ok {dx: (get dx delta), dy: dy-d, dk: u0})))

(define-public (add-liquidity (amount uint))
    (let (
        (sender tx-sender)
        (delta (get-liquidity-quote amount))
        (dx-d (get dx delta))
        (dy-d (get dy delta))
        (dk-d (get dk delta)))
        (asserts! (var-get pool-opened) ERR_UNAUTHORIZED)
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer dx-d sender current-contract none))
        (try! (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 transfer dy-d sender current-contract none))
        (try! (ft-mint? sBTC-MIA dk-d sender))
        (print {
            type: "add-liquidity",
            sender: sender,
            token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
            token-a-amount: dx-d,
            token-b: 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2,
            token-b-amount: dy-d,
            lp-tokens: dk-d,
            pool-reserves: (get-reserves-quote),
            pool-contract: current-contract
        })
        (ok delta)))

(define-public (remove-liquidity (amount uint))
    (let (
        (sender tx-sender)
        (delta (get-liquidity-quote amount))
        (dx-d (get dx delta))
        (dy-d (get dy delta))
        (dk-d (get dk delta)))
        (try! (ft-burn? sBTC-MIA dk-d sender))
        (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token "sbtc-token" dx-d)
                             (with-ft 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 "miamicoin" dy-d))
               (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer dx-d current-contract sender none))
               (try! (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 transfer dy-d current-contract sender none))))
        (print {
              type: "remove-liquidity",
              sender: sender,
              token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
              token-a-amount: dx-d,
              token-b: 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2,
              token-b-amount: dy-d,
              lp-tokens: dk-d,
              pool-reserves: (get-reserves-quote),
              pool-contract: current-contract
        })
        (ok delta)))

(define-private (get-byte (opcode (buff 16)) (position uint))
    (default-to 0x00 (element-at? opcode position)))

(define-private (get-reserves)
    {
      a: (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token get-balance current-contract)),
      b: (unwrap-panic (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 get-balance current-contract))
    })

(define-read-only (get-swap-quote (amount uint) (opcode (optional (buff 16))))
    (let (
        (reserves (get-reserves))
        (operation (get-byte (default-to 0x00 opcode) u0))
        (is-a-in (is-eq operation OP_SWAP_A_TO_B))
        (x (if is-a-in (get a reserves) (get b reserves)))
        (y (if is-a-in (get b reserves) (get a reserves)))
        (fee-in (if is-a-in (/ (* amount FAKTORY_FEE) PRECISION) u0))
        (effective-amount (- amount fee-in))
        (dx (/ (* effective-amount (- PRECISION LP_REBATE)) PRECISION))
        (numerator (* dx y))
        (denominator (+ x dx))
        (dy (/ numerator denominator))
        (fee-out (if is-a-in u0 (/ (* dy FAKTORY_FEE) PRECISION)))
        (fee (+ fee-in fee-out)))
        {
          dx: dx,
          dy: dy,
          dk: u0,
          fee: fee
        }))

(define-read-only (get-liquidity-quote (amount uint))
    (let (
        (k (ft-get-supply sBTC-MIA))
        (reserves (get-reserves)))
        {
          dx: (if (> k u0) (/ (* amount (get a reserves)) k) amount),
          dy: (if (> k u0) (/ (* amount (get b reserves)) k) amount),
          dk: amount
        }))

(define-read-only (get-reserves-quote)
    (let (
        (reserves (get-reserves))
        (supply (ft-get-supply sBTC-MIA)))
        {
          dx: (get a reserves),
          dy: (get b reserves),
          dk: supply
        }))

;; Seed initial reserves and depth. `lowest` sets the first proportional add
;; (dx=dy=lowest since supply is 0), `highest` tops up the MIA side to set the
;; starting price. AMENDMENT: does NOT approve fakfun-core-v2 here -- swaps stay
;; gated until `approve-caller`/`set-gated` is called AFTER the entry window.
(define-public (initialize-pool (lowest uint) (highest uint))
  (begin
     (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
     (var-set pool-opened true)
     (try! (add-liquidity lowest))
     (try! (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 transfer highest contract-caller current-contract none))
     (print {
              type: "initialize-pool",
              sender: tx-sender,
              token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
              token-b: 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2,
              initial-pool-reserves: (get-reserves-quote),
              pool-contract: current-contract
      })
     (ok true)
  )
)

(define-map approved-callers principal bool)

(define-public (approve-caller (caller principal))
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (ok (map-set approved-callers caller true))
  )
)

(define-public (revoke-caller (caller principal))
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (ok (map-set approved-callers caller false))
  )
)

;; AMENDMENT 4: no `(is-eq tx-sender contract-caller)` escape hatch -- while
;; gated, direct wallet calls must be blocked too, otherwise anyone could move
;; the pool ratio during the single-sided entry window.
(define-private (is-approved-caller)
    (default-to false (map-get? approved-callers contract-caller))
)

(define-public (set-gated (enabled bool))
  (begin
    (asserts! (is-eq tx-sender DEPLOYER) ERR_UNAUTHORIZED)
    (ok (var-set gated enabled))
  )
)

(define-read-only (is-gated)
  (var-get gated)
)
;; Rendezvous fuzzing harness for mia-pool-faktory.
;;
;; Deploy-time setup (bottom of the file): faucets MIA to every wallet (sBTC is
;; pre-funded by simnet), seeds the pool with reserves a=10_000 sats /
;; b=1_000_000 uMIA via the real initialize-pool, and ungates swaps so the
;; fuzzer can exercise the AMM math (the gate itself is unit-tested).

(define-constant RV_MIA 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant RV_SBTC 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)

;; ---- invariants ------------------------------------------------------------

;; while LP supply exists, neither reserve can be drained to zero: swaps output
;; strictly less than the reserve and proportional removes only empty the pool
;; when the LAST LP exits
(define-read-only (invariant-reserves-positive-while-lp-exists)
  (let (
      (k (ft-get-supply sBTC-MIA))
      (a (unwrap-panic (contract-call?
        'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        get-balance current-contract)))
      (b (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance current-contract)))
    )
    (or (is-eq k u0) (and (> a u0) (> b u0))))
)

;; ---- property tests --------------------------------------------------------

(define-private (test-swap-a-to-b-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000)))
      (r0 (get-reserves))
      (res (try! (swap-a-to-b amt u0)))
      (r1 (get-reserves))
    )
    (asserts!
      (>= (* (get a r1) (get b r1)) (* (get a r0) (get b r0)))
      (err u950))
    (ok true))
)

(define-read-only (can-test-swap-a-to-b-keeps-product (amount uint))
  (let ((amt (+ u1 (mod amount u10000000))))
    (and
      (not (var-get gated))
      (> (ft-get-supply sBTC-MIA) u0)
      ;; dust swaps whose output floors to zero abort in the token (err u3)
      (> (get dy (get-swap-quote amt (some 0x00))) u0)
      (>= (unwrap-panic (contract-call?
            'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            get-balance tx-sender))
          amt)))
)

(define-private (test-swap-b-to-a-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000000)))
      (r0 (get-reserves))
      (res (try! (swap-b-to-a amt u0)))
      (r1 (get-reserves))
    )
    (asserts!
      (>= (* (get a r1) (get b r1)) (* (get a r0) (get b r0)))
      (err u951))
    (ok true))
)

(define-read-only (can-test-swap-b-to-a-keeps-product (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000000)))
      (q (get-swap-quote amt (some 0x01)))
    )
    (and
      (not (var-get gated))
      (> (ft-get-supply sBTC-MIA) u0)
      ;; dust swaps whose net output floors to zero abort in the token (err u3)
      (> (- (get dy q) (get fee q)) u0)
      (>= (unwrap-panic (contract-call?
            'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
            get-balance tx-sender))
          amt)))
)

;; add then remove the same LP amount: rounding may cost the caller dust but
;; can never pay them out more than they put in
(define-private (test-add-remove-roundtrip-no-profit (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
      (sbtc0 (unwrap-panic (contract-call? RV_SBTC get-balance tx-sender)))
      (mia0 (unwrap-panic (contract-call? RV_MIA get-balance tx-sender)))
    )
    ;; dust adds abort inside the token (err u3) -- covered by
    ;; test-add-liquidity-mints-exact; discard them here
    (if (or (is-eq (get dx q) u0) (is-eq (get dy q) u0))
      (ok false)
      (begin
        (try! (add-liquidity amt))
        ;; the matching remove can itself hit the documented dust abort; the
        ;; caller keeps the LP they just paid for -- still no profit
        (match (remove-liquidity amt)
          r2 (let (
              (sbtc1 (unwrap-panic (contract-call? RV_SBTC get-balance tx-sender)))
              (mia1 (unwrap-panic (contract-call? RV_MIA get-balance tx-sender)))
            )
            (asserts! (<= sbtc1 sbtc0) (err u960))
            (asserts! (<= mia1 mia0) (err u961))
            (ok true))
          e (if (is-eq e u3) (ok true) (err e))))))
)

(define-read-only (can-test-add-remove-roundtrip-no-profit (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
    )
    (and
      (var-get pool-opened)
      (>= (unwrap-panic (contract-call?
            'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
            get-balance tx-sender))
          (get dx q))
      (>= (unwrap-panic (contract-call?
            'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
            get-balance tx-sender))
          (get dy q))))
)

;; adding liquidity mints exactly the requested LP; this test deliberately
;; KEEPS the position, building pool depth so the swap properties stop
;; discarding (the deploy-time seed cannot run: simnet funds wallets with
;; sBTC only after contract deployment).
;; FUZZ TROPHY: rv (seed 1439452765) found that when skewed reserves floor one
;; quoted side to zero, add-liquidity aborts with the token's (err u3) -- so
;; the dust branch asserts the flip side: NO free LP can ever be minted.
(define-private (test-add-liquidity-mints-exact (amount uint))
  (let (
      (amt (+ u1 (mod amount u100000)))
      (q (get-liquidity-quote amt))
      (lp-before (ft-get-balance sBTC-MIA tx-sender))
    )
    (if (or (is-eq (get dx q) u0) (is-eq (get dy q) u0))
      (begin
        ;; a zero-cost side must make the whole add revert, not mint free LP
        (asserts! (is-err (add-liquidity amt)) (err u957))
        (asserts! (is-eq (ft-get-balance sBTC-MIA tx-sender) lp-before) (err u958))
        (ok true))
      (let ((res (try! (add-liquidity amt))))
        (asserts! (is-eq (get dk res) amt) (err u955))
        (asserts! (is-eq (ft-get-balance sBTC-MIA tx-sender) (+ lp-before amt)) (err u956))
        (ok true))))
)

(define-read-only (can-test-add-liquidity-mints-exact (amount uint))
  (can-test-add-remove-roundtrip-no-profit amount)
)

;; the quote is exactly what a swap delivers in the same block
(define-private (test-quote-matches-swap-a-to-b (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000)))
      (q (get-swap-quote amt (some 0x00)))
      (res (try! (swap-a-to-b amt u0)))
    )
    (asserts! (is-eq (get dy res) (get dy q)) (err u970))
    (ok true))
)

(define-read-only (can-test-quote-matches-swap-a-to-b (amount uint))
  (can-test-swap-a-to-b-keeps-product amount)
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? RV_MIA rv-faucet u1000000000000 who))
)

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

;; is-ok (not unwrap-panic): succeeds under rv's funded simnet; the fuzzer can
;; also bootstrap liquidity itself since the synced pool starts opened
(is-ok (initialize-pool u10000 u990000))
(var-set gated false)

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))
