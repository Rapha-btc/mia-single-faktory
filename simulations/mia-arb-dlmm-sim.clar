;; SIM-ONLY variant of mia-arb-faktory: same book + ALEX legs, but the
;; closing STX -> sBTC leg goes through the Bitflow DLMM swap router --
;; either the direct stx-sbtc bps-15 pool (arb-book-alex-dlmm) or the 2-hop
;; through the USDCx bps-10 pools (arb-book-alex-dlmm2). Used only by
;; simulations/verify-arb-venues.js for fork quote racing; NOT for deploy.
;; DLMM legs assert in == amount: a bin-exhaustion partial fill reverts.

(define-constant ERR-NO-PROFIT (err u1001))
(define-constant ERR-SLIPPAGE (err u1000))
(define-constant ERR-PARTIAL (err u1002))

(define-constant SBTC-TOKEN 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token)
(define-constant MIA-TOKEN 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant USDCX-TOKEN 'SP120SBRBQJ00MCWS7TM5R8WJNTTKD5K0HFRC2CNE.usdcx)
(define-constant ALEX-FACTOR u100000000)

(define-public (arb-book-alex-dlmm
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
            'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-orderbook-faktory
            market-order spend-btc max-price-per-1m
          ))
        )))
        (cost (+ (get spent book) (get fee book)))
        (acquired (get acquired book))
        (ustx-out (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" acquired))
          (try! (swap-mia-to-stx-alex acquired))
        )))
        (sbtc-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-sbtc-dlmm ustx-out))
        )))
        (payout (+ sbtc-out (- buffer cost)))
      )
      (asserts! (> sbtc-out cost) ERR-NO-PROFIT)
      (asserts! (>= sbtc-out (+ cost min-profit)) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" payout))
        (try! (contract-call? SBTC-TOKEN transfer payout current-contract caller none))
      ))
      (ok { cost: cost, acquired: acquired, sbtc-out: sbtc-out, profit: (- sbtc-out cost) })
    )
  )
)

(define-public (arb-book-alex-dlmm2
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
            'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-orderbook-faktory
            market-order spend-btc max-price-per-1m
          ))
        )))
        (cost (+ (get spent book) (get fee book)))
        (acquired (get acquired book))
        (ustx-out (try! (as-contract? ((with-ft MIA-TOKEN "miamicoin" acquired))
          (try! (swap-mia-to-stx-alex acquired))
        )))
        (usdcx-out (try! (as-contract? ((with-stx ustx-out))
          (try! (swap-stx-to-usdcx-dlmm ustx-out))
        )))
        (sbtc-out (try! (as-contract? ((with-ft USDCX-TOKEN "usdcx-token" usdcx-out))
          (try! (swap-usdcx-to-sbtc-dlmm usdcx-out))
        )))
        (payout (+ sbtc-out (- buffer cost)))
      )
      (asserts! (> sbtc-out cost) ERR-NO-PROFIT)
      (asserts! (>= sbtc-out (+ cost min-profit)) ERR-SLIPPAGE)
      (try! (as-contract? ((with-ft SBTC-TOKEN "sbtc-token" payout))
        (try! (contract-call? SBTC-TOKEN transfer payout current-contract caller none))
      ))
      (ok { cost: cost, acquired: acquired, sbtc-out: sbtc-out, profit: (- sbtc-out cost) })
    )
  )
)

(define-private (swap-mia-to-stx-alex (umia uint))
  (let ((result (try! (contract-call?
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.amm-pool-v2-01
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

;; stx-sbtc pool: x = STX, y = sBTC -> STX in is x-for-y
(define-private (swap-stx-to-sbtc-dlmm (ustx uint))
  (let ((res (try! (contract-call?
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-swap-router-v-1-2
      swap-x-for-y-simple-multi
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-pool-stx-sbtc-v-1-bps-15
      'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      ustx
      u1
      none
    ))))
    (asserts! (is-eq (get in res) ustx) ERR-PARTIAL)
    (ok (get out res))
  )
)

;; stx-usdcx pool: x = STX, y = USDCx -> STX in is x-for-y
(define-private (swap-stx-to-usdcx-dlmm (ustx uint))
  (let ((res (try! (contract-call?
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-swap-router-v-1-2
      swap-x-for-y-simple-multi
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-pool-stx-usdcx-v-1-bps-10
      'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2
      USDCX-TOKEN
      ustx
      u1
      none
    ))))
    (asserts! (is-eq (get in res) ustx) ERR-PARTIAL)
    (ok (get out res))
  )
)

;; sbtc-usdcx pool: x = sBTC, y = USDCx -> USDCx in is y-for-x
(define-private (swap-usdcx-to-sbtc-dlmm (uusdcx uint))
  (let ((res (try! (contract-call?
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-swap-router-v-1-2
      swap-y-for-x-simple-multi
      'SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-pool-sbtc-usdcx-v-1-bps-10
      'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      USDCX-TOKEN
      uusdcx
      u1
      none
    ))))
    (asserts! (is-eq (get in res) uusdcx) ERR-PARTIAL)
    (ok (get out res))
  )
)
