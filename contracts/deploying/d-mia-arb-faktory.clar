(define-constant ERR-NO-PROFIT (err u1001))
(define-constant ERR-SLIPPAGE (err u1000))
(define-constant ERR-PARTIAL-FILL (err u1002))

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
      (print { notification: "mia-arb", payload: {
        venue: "dlmm", caller: caller, buffer: buffer, cost: cost,
        acquired: acquired, ustx: ustx-out, sbtc-out: sbtc-out,
        profit: (- sbtc-out cost),
      } })
      (ok { cost: cost, acquired: acquired, sbtc-out: sbtc-out, profit: (- sbtc-out cost) })
    )
  )
)

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

(define-private (swap-stx-to-mia-alex (ustx uint))
  (let ((result (try! (contract-call?
      'SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM.amm-pool-v2-01
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
    (asserts! (is-eq (get in res) ustx) ERR-PARTIAL-FILL)
    (ok (get out res))
  )
)

(define-private (swap-sbtc-to-stx-bitflow (sbtc-in uint))
  (contract-call?
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-core-v-1-2
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
      'SP20X3DC5R091J8B6YPQT638J8NR1W83KN6TN5BJY.univ2-pool-v1_0_0-0070
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
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-core-v-1-2
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
      'SP20X3DC5R091J8B6YPQT638J8NR1W83KN6TN5BJY.univ2-pool-v1_0_0-0070
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
