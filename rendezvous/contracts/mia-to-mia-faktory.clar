;; mia-to-mia-faktory -- "Miami to Miami": one function that routes MIA
;; through the ccd013 par redemption into the mia-fair-faktory-v2 exit
;; book, and back to MIA.
;;
;;   redeem-and-settle(amount-umia)
;;     amount > 0  the whitehat (FASTPOOL, hardcoded beneficiary) feeds
;;                 MIA v2 into the machine
;;     amount = 0  ANYONE re-triggers the machine
;;   then, whatever is currently possible happens:
;;     redeem leg  if the ccd013 treasury has STX and this contract holds
;;                 MIA: burn at par (u1710) in <= 10M-MIA chunks (the
;;                 ccd013 per-tx cap) -- the STX stays HERE
;;     settle leg  if this contract holds STX and the fair book has
;;                 offers: settle-offers -- the par-equivalent MIA goes to
;;                 the DEPOSITOR (fastpool), never to the caller
;;
;; The ccd013 rewards treasury is empty between PoX cycles and refills in
;; ~16.7k-STX bursts, and the fair book fills as the community sells above
;; the Alex price (but <= par) -- so the surplus STX simply sits here as a
;; standing par bid until both sides show up. ccd013 partial fills
;; (treasury smaller than the request) leave the unburned MIA here for the
;; next trigger. MIA v2 only.

(define-constant ERR_UNAUTHORIZED (err u9000))
(define-constant ERR_NOTHING_TO_DO (err u9002))

(define-constant MICRO_CITYCOINS (pow u10 u6))
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS)) ;; ccd013's per-tx cap

(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant CCD013 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)
(define-constant FAIR_V2 .mia-fair-faktory-v2)

;; Hardcoded beneficiary (fastpool.btc) -- a first-depositor slot would be
;; front-runnable, handing a griefer the MIA output AND the hatches
;; (AUDIT R-2). CONFIRM this address with friedger before deploying.
(define-constant FASTPOOL 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
(define-data-var total-redeemed-umia uint u0)
(define-data-var total-stx-received uint u0)
(define-data-var total-stx-spent uint u0)
(define-data-var total-mia-returned uint u0)

(define-public (redeem-and-settle (amount-umia uint))
  (begin
    ;; optional deposit leg: only the beneficiary feeds the machine
    (and (> amount-umia u0)
      (begin
        (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
        (try! (contract-call? MIA_TOKEN_V2 transfer amount-umia tx-sender current-contract none))
        (print { notification: "deposit", payload: { owner: tx-sender, amount: amount-umia } })
        true
      )
    )
    (let (
        (redeemed (try! (try-redeem)))
        (settled (try! (try-settle)))
      )
      ;; a bare re-trigger that can do nothing reverts, so bots never pay
      ;; for no-ops; a deposit is allowed to just park MIA
      (asserts! (or (> amount-umia u0) (is-some redeemed) (is-some settled))
        ERR_NOTHING_TO_DO)
      (ok { redeemed: redeemed, settled: settled })
    )
  )
)

;; Redeem leg: burn this contract's MIA through ccd013 so the STX lands
;; here. Skips when the contract holds no MIA or the treasury is empty.
(define-private (try-redeem)
  (let (
      (balance-v2 (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
      (amount (if (> balance-v2 MAX_PER_TRANSACTION) MAX_PER_TRANSACTION balance-v2))
      (quote (contract-call? CCD013 get-redemption-for-balance amount))
    )
    ;; skip unless the redemption would actually pay STX: covers an empty
    ;; machine, an empty treasury, AND sub-585-uMIA dust whose value floors
    ;; to zero -- ccd013 errors on those, which would abort the settle leg
    ;; with it (AUDIT R-1 dust-donation grief)
    (if (is-eq (default-to u0 (get ustx quote)) u0)
      (ok none)
      (let ((redeemed (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
          (try! (contract-call? CCD013 redeem-mia amount))))))
        (var-set total-redeemed-umia (+ (var-get total-redeemed-umia) (get umia redeemed)))
        (var-set total-stx-received (+ (var-get total-stx-received) (get ustx redeemed)))
        (print { notification: "redeem", payload: {
          caller: tx-sender,
          redeemed: redeemed,
          stx-escrow: (stx-get-balance current-contract),
        } })
        (ok (some redeemed))
      )
    )
  )
)

;; Settle leg: spend this contract's STX on the fair book; the
;; par-equivalent MIA goes to the depositor. Skips when the escrow or the
;; book is empty (or the escrow is dust too small to take a single uMIA).
(define-private (try-settle)
  (let (
      (recipient FASTPOOL)
      (budget (stx-get-balance current-contract))
    )
    (if (or (is-eq budget u0)
        (is-eq (get ustx (contract-call? FAIR_V2 get-book-totals)) u0))
      (ok none)
      (let (
          (settled (try! (as-contract? ((with-stx budget))
            (try! (contract-call? FAIR_V2 settle-offers budget)))))
          (par-equiv (get par-equiv settled))
        )
        (if (is-eq par-equiv u0)
          (ok none)
          (begin
            (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" par-equiv))
              (try! (contract-call? MIA_TOKEN_V2 transfer par-equiv current-contract recipient none))))
            (var-set total-stx-spent (+ (var-get total-stx-spent) (get spent settled)))
            (var-set total-mia-returned (+ (var-get total-mia-returned) par-equiv))
            (print { notification: "settle", payload: {
              caller: tx-sender,
              recipient: recipient,
              settled: settled,
              stx-escrow: (stx-get-balance current-contract),
            } })
            (ok (some settled))
          )
        )
      )
    )
  )
)

;; Owner-only emergency hatches: if pox-5 kills the treasury refills or
;; the book stops filling, the beneficiary pulls whatever is left.
(define-public (withdraw-stx (amount uint))
  (begin
    (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-stx amount))
      (try! (stx-transfer? amount current-contract FASTPOOL))))
    (print { notification: "withdraw-stx", payload: { amount: amount, recipient: FASTPOOL } })
    (ok true)
  )
)

(define-public (withdraw-mia (amount uint))
  (begin
    (asserts! (is-eq tx-sender FASTPOOL) ERR_UNAUTHORIZED)
    (try! (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" amount))
      (try! (contract-call? MIA_TOKEN_V2 transfer amount current-contract FASTPOOL none))))
    (print { notification: "withdraw-mia", payload: { amount: amount, recipient: FASTPOOL } })
    (ok true)
  )
)

(define-read-only (get-status)
  {
    beneficiary: FASTPOOL,
    mia-escrow: (unwrap-panic (contract-call? 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2 get-balance current-contract)),
    stx-escrow: (stx-get-balance current-contract),
    ccd013-treasury: (contract-call? 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia get-redemption-current-balance),
    book: (contract-call? .mia-fair-faktory-v2 get-book-totals),
    total-redeemed-umia: (var-get total-redeemed-umia),
    total-stx-received: (var-get total-stx-received),
    total-stx-spent: (var-get total-stx-spent),
    total-mia-returned: (var-get total-mia-returned),
  }
)
;; Rendezvous fuzzing harness for mia-to-mia-faktory ("Miami to Miami").
;;
;; Simnet reality (rv-sync.sh PATCH 6/7): the cached ccd013 copy is
;; self-initialized at deploy (frozen mainnet par u1710) and pays
;; redemptions from its OWN STX balance -- rv-fund-treasury below lets
;; fuzzer wallets stand in for the PoX cycle payouts. FASTPOOL is patched
;; to the simnet deployer wallet so the deposit leg is reachable. The
;; synced fair-v2 copy self-initializes at deploy (its own harness), so
;; rv-place-offer gives the settle leg a live below-par book to trade
;; against. The machine itself starts empty and stateless.

;; ---- rendezvous invariant-mode bookkeeping (Rendezvous book, ch. 6) --------

(define-map context (string-ascii 100) { called: uint })

(define-private (update-context (function-name (string-ascii 100)) (called uint))
  (ok (map-set context function-name { called: called })))

(define-read-only (rv-rs-calls)
  (get called (default-to { called: u0 } (map-get? context "redeem-and-settle"))))

;; ---- fuzzer plumbing (public so rv exercises them organically) -------------

;; stands in for a PoX cycle payout landing in the (patched) ccd013 treasury
(define-public (rv-fund-treasury (amount uint))
  (stx-transfer? (+ u1 (mod amount u10000000000)) tx-sender
    'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia))

;; a community maker posting a below-par offer on the fair-v2 copy; skips
;; (ok false) when the caller can't -- rv treats both branches as passing
(define-public (rv-place-offer (amount uint) (ask uint))
  (let (
      (amt (+ u1000000 (mod amount u1000000000000)))
      (par (contract-call? .mia-fair-faktory-v2 get-par-ustx amt))
    )
    (if (or (is-eq par u0)
        (is-some (contract-call? .mia-fair-faktory-v2 get-offer tx-sender))
        (< (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)) amt))
      (ok false)
      (match (contract-call? .mia-fair-faktory-v2 place-offer amt (+ u1 (mod ask par)))
        fine (ok true)
        ;; a full book may reject a not-strictly-cheaper newcomer
        e (if (is-eq e u13015) (ok false) (err e))
      )
    )
  )
)

;; ---- invariants -------------------------------------------------------------

;; the machine can only ever spend STX it received from redemptions
(define-read-only (invariant-spent-le-received)
  (<= (var-get total-stx-spent) (var-get total-stx-received)))

;; escrow never exceeds the running ledger (equality minus owner withdrawals)
(define-read-only (invariant-escrow-le-ledger)
  (<= (stx-get-balance current-contract)
      (- (var-get total-stx-received) (var-get total-stx-spent))))

;; every uSTX spent came back as MIA at par or better, up to one uMIA of
;; floor rounding per redeem-and-settle call
(define-read-only (invariant-returned-covers-spent-at-par)
  (>= (+ (var-get total-mia-returned) (rv-rs-calls))
      (/ (* (var-get total-stx-spent) MICRO_CITYCOINS) u1710)))

;; every uMIA burned was paid at par or better, up to one uSTX of floor
;; rounding per redeem-and-settle call (ccd013's treasury-cap branch floors
;; the burned umia, never the paid ustx below par)
(define-read-only (invariant-received-covers-redeemed-at-par)
  (>= (+ (var-get total-stx-received) (rv-rs-calls))
      (/ (* (var-get total-redeemed-umia) u1710) MICRO_CITYCOINS)))

;; ---- property tests ----------------------------------------------------------

;; deposit conservation: the machine's MIA grows by exactly the deposit
;; minus whatever the same call burned; the beneficiary-caller's MIA moves
;; by -deposit + the par-equiv of whatever the same call settled
(define-private (test-deposit-conserves (amount uint))
  (let (
      (amt (+ u1 (mod amount u10000000000000)))
      (machine-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract)))
      (mine-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
      (res (try! (redeem-and-settle amt)))
      (burned (match (get redeemed res) r (get umia r) u0))
      (paid (match (get settled res) s (get par-equiv s) u0))
    )
    (asserts!
      (is-eq
        (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance current-contract))
        (- (+ machine-before amt) burned))
      (err u800))
    (asserts!
      (is-eq
        (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender))
        (- (+ mine-before paid) amt))
      (err u801))
    (ok true))
)

(define-read-only (can-test-deposit-conserves (amount uint))
  (and
    (is-eq tx-sender FASTPOOL)
    (>= (unwrap-panic (contract-call?
          'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
          get-balance tx-sender))
        (+ u1 (mod amount u10000000000000))))
)

;; a non-beneficiary deposit is always rejected
(define-private (test-foreign-deposit-rejected (amount uint))
  (match (redeem-and-settle (+ u1 (mod amount u1000000000000)))
    fine (err u810)
    e (if (is-eq e u9000) (ok true) (err e)))
)

(define-read-only (can-test-foreign-deposit-rejected (amount uint))
  (not (is-eq tx-sender FASTPOOL))
)

;; a re-trigger pays the BENEFICIARY, never the caller; the caller's MIA
;; is untouched no matter what the machine did
(define-private (test-retrigger-pays-beneficiary-only)
  (let (
      (mine-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)))
      (bene-before (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance FASTPOOL)))
    )
    (match (redeem-and-settle u0)
      res (let ((paid (match (get settled res) s (get par-equiv s) u0)))
        (asserts!
          (is-eq (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance tx-sender)) mine-before)
          (err u820))
        (asserts!
          (is-eq
            (unwrap-panic (contract-call? MIA_TOKEN_V2 get-balance FASTPOOL))
            (+ bene-before paid))
          (err u821))
        (ok true))
      ;; nothing to do is a legal outcome of a blind re-trigger
      e (if (is-eq e u9002) (ok true) (err e))))
)

(define-read-only (can-test-retrigger-pays-beneficiary-only)
  (not (is-eq tx-sender FASTPOOL))
)

;; AUDIT R-1 regression: dust donations must never brick the trigger --
;; a re-trigger can say "nothing to do" (u9002) but must NEVER surface
;; ccd013's zero-redemption aborts (u13007/u13008)
(define-private (test-dust-donation-never-bricks (dust uint))
  (begin
    (try! (contract-call? MIA_TOKEN_V2 transfer
      (+ u1 (mod dust u584)) tx-sender current-contract none))
    (match (redeem-and-settle u0)
      fine (ok true)
      e (if (or (is-eq e u13007) (is-eq e u13008)) (err e) (ok true))))
)

(define-read-only (can-test-dust-donation-never-bricks (dust uint))
  (>= (unwrap-panic (contract-call?
        'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
        get-balance tx-sender))
      u585)
)

;; hatches: non-beneficiary always rejected
(define-private (test-withdraw-guards (amount uint))
  (begin
    (asserts! (is-eq (withdraw-stx (+ u1 amount)) (err u9000)) (err u830))
    (asserts! (is-eq (withdraw-mia (+ u1 amount)) (err u9000)) (err u831))
    (ok true))
)

(define-read-only (can-test-withdraw-guards (amount uint))
  (not (is-eq tx-sender FASTPOOL))
)

;; hatches: the beneficiary's STX withdrawal is exact
(define-private (test-withdraw-stx-exact (amount uint))
  (let (
      (escrow (stx-get-balance current-contract))
      (amt (+ u1 (mod amount escrow)))
      (mine-before (stx-get-balance tx-sender))
    )
    (try! (withdraw-stx amt))
    (asserts! (is-eq (stx-get-balance tx-sender) (+ mine-before amt)) (err u840))
    (asserts! (is-eq (stx-get-balance current-contract) (- escrow amt)) (err u841))
    (ok true))
)

(define-read-only (can-test-withdraw-stx-exact (amount uint))
  (and
    (is-eq tx-sender FASTPOOL)
    (> (stx-get-balance current-contract) u0))
)

;; ---- deploy-time setup (runs last; tx-sender = deployer) --------------------

(define-private (rv-fund-mia (who principal))
  (unwrap-panic (contract-call? MIA_TOKEN_V2 rv-faucet u120000000000 who))
)

;; 10 wallets x 1.2e11 uMIA
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
