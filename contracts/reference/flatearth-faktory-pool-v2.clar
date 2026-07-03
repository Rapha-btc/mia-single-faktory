
    (impl-trait 'SP2ZNGJ85ENDY6QRHQ5P2D4FXKGZWCKTB2T0Z55KS.charisma-traits-v1.sip010-ft-trait)
    (impl-trait 'SP2ZNGJ85ENDY6QRHQ5P2D4FXKGZWCKTB2T0Z55KS.dexterity-traits-v0.liquidity-pool-trait)

    (define-constant DEPLOYER tx-sender)
    (define-constant CONTRACT (as-contract tx-sender))

    (define-constant ERR_INVALID_OPERATION (err u400))
    (define-constant ERR_UNAUTHORIZED (err u403))
    (define-constant ERR_TOO_MUCH_SLIPPAGE (err u407))

    (define-constant PRECISION u1000000)
    (define-constant LP_REBATE u3000)
    (define-constant FAKTORY_FEE u1000)
    (define-constant FAKTORY_ADDRESS 'SMH8FRN30ERW1SX26NJTJCKTDR3H27NRJ6W75WQE)

    (define-constant OP_SWAP_A_TO_B 0x00)      
    (define-constant OP_SWAP_B_TO_A 0x01)      
    (define-constant OP_ADD_LIQUIDITY 0x02)  
    (define-constant OP_REMOVE_LIQUIDITY 0x03) 
    (define-constant OP_LOOKUP_RESERVES 0x04)  


    (define-fungible-token sBTC-FlatEarth)
    (define-data-var token-uri (optional (string-utf8 256)) none)
    (define-data-var pool-opened bool false)
    (define-data-var gated bool true)

    (define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
        (begin
            (asserts! (is-eq tx-sender sender) ERR_UNAUTHORIZED)
            (try! (ft-transfer? sBTC-FlatEarth amount sender recipient))
            (match memo to-print (print to-print) 0x0000)
            (print {
                type: "transfer-lp",
                sender: sender,
                recipient: recipient,
                amount: amount,
                pool-contract: CONTRACT
            })
            (ok true)))

    (define-read-only (get-name)
        (ok "sBTC-FlatEarth lp-token"))

    (define-read-only (get-symbol)
        (ok "sBTC-FlatEarth"))

    (define-read-only (get-decimals)
        (ok u6))

    (define-read-only (get-balance (who principal))
        (ok (ft-get-balance sBTC-FlatEarth who)))

    (define-read-only (get-total-supply)
        (ok (ft-get-supply sBTC-FlatEarth)))

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
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- amount fee-d) sender CONTRACT none))
            (if (> fee-d u0)
                (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer fee-d sender FAKTORY_ADDRESS none))
                true)
            (try! (as-contract (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity transfer dy-d CONTRACT sender none)))
            (print {
                type: "buy",
                sender: sender,
                token-in: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
                amount-in: amount,
                faktory-fee: fee-d,
                token-out: 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity,
                amount-out: dy-d,
                pool-reserves: (get-reserves-quote),
                pool-contract: CONTRACT,
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
            (try! (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity transfer amount sender CONTRACT none))
            (try! (as-contract (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer (- dy-d fee-d) CONTRACT sender none)))
            (if (> fee-d u0)
                (try! (as-contract (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer fee-d CONTRACT FAKTORY_ADDRESS none)))
                true)
            (print {
                type: "sell",
                sender: sender,
                token-in: 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity,
                amount-in: amount,
                token-out: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
                amount-out: dy-d,
                faktory-fee: fee-d,
                pool-reserves: (get-reserves-quote),
                pool-contract: CONTRACT,
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
            (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer dx-d sender CONTRACT none))
            (try! (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity transfer dy-d sender CONTRACT none))
            (try! (ft-mint? sBTC-FlatEarth dk-d sender))
            (print {
                type: "add-liquidity",
                sender: sender,
                token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
                token-a-amount: dx-d,
                token-b: 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity,
                token-b-amount: dy-d,
                lp-tokens: dk-d,
                pool-reserves: (get-reserves-quote),
                pool-contract: CONTRACT
            })
            (ok delta)))

    (define-public (remove-liquidity (amount uint))
        (let (
            (sender tx-sender)
            (delta (get-liquidity-quote amount))
            (dx-d (get dx delta))
            (dy-d (get dy delta))
            (dk-d (get dk delta)))
            (try! (ft-burn? sBTC-FlatEarth dk-d sender))
            (try! (as-contract (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token transfer dx-d CONTRACT sender none)))
            (try! (as-contract (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity transfer dy-d CONTRACT sender none)))
            (print {
                  type: "remove-liquidity",
                  sender: sender,
                  token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
                  token-a-amount: dx-d,
                  token-b: 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity,
                  token-b-amount: dy-d,
                  lp-tokens: dk-d,
                  pool-reserves: (get-reserves-quote),
                  pool-contract: CONTRACT
            })
            (ok delta)))

    (define-private (get-byte (opcode (buff 16)) (position uint))
        (default-to 0x00 (element-at? opcode position)))

    (define-private (get-reserves)
        {
          a: (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token get-balance CONTRACT)),
          b: (unwrap-panic (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity get-balance CONTRACT))
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
            (k (ft-get-supply sBTC-FlatEarth))
            (reserves (get-reserves)))
            {
              dx: (if (> k u0) (/ (* amount (get a reserves)) k) amount),
              dy: (if (> k u0) (/ (* amount (get b reserves)) k) amount),
              dk: amount
            }))

    (define-read-only (get-reserves-quote)
        (let (
            (reserves (get-reserves))
            (supply (ft-get-supply sBTC-FlatEarth)))
            {
              dx: (get a reserves),
              dy: (get b reserves),
              dk: supply
            }))

    (define-public (initialize-pool (lowest uint) (highest uint))
      (begin
         (asserts! (is-eq contract-caller DEPLOYER) ERR_UNAUTHORIZED)
         (var-set pool-opened true)
         (try! (add-liquidity lowest))
         (try! (contract-call? 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity transfer highest contract-caller CONTRACT none))
         (map-set approved-callers 'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.fakfun-core-v2 true)
         (print {
                  type: "initialize-pool",
                  sender: tx-sender,
                  token-a: 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token,
                  token-b: 'SP3W69VDG9VTZNG7NTW1QNCC1W45SNY98W1JSZBJH.flat-earth-stxcity,
                  initial-pool-reserves: (get-reserves-quote),
                  pool-contract: CONTRACT
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

    (define-private (is-approved-caller)
        (or
        (is-eq tx-sender contract-caller)
        (default-to false (map-get? approved-callers contract-caller))
        )
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
