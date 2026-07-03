;; Title: CCD014 - MIA Fair Burn To Exit
;; Version: 1.0.0
;; Summary: Redemption extension that gives the community a priority, market-
;;   priced exit ahead of the fixed-rate redemption. Holders escrow MIA in
;;   standing burn offers priced at or below par; settle-offers clears them
;;   cheapest-first against the rewards treasury. The fixed-rate redeem-mia
;;   (unchanged from ccd013) only opens once the offer book is empty.
;; Description: Par is the frozen ratio set at initialization:
;;     par = (miningTreasuryBalance * 10^6) / totalMIASupply
;;   uSTX at par for a micro-MIA amount: (par * uMIA) / 10^6. An offer may ask
;;   any uSTX <= its par value. settle-offers burns escrowed MIA (v1 then v2)
;;   and pays the offer's uSTX from the rewards treasury, filling ascending by
;;   price until the treasury is drained. While any offer is open, redeem-mia
;;   asserts ERR_OFFERS_PENDING; with an empty book it behaves exactly as
;;   ccd013. Burns v1 first, then v2. Capped at 10M MIA per tx/offer.

;; TRAITS
(impl-trait 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.extension-trait.extension-trait)

;; CONSTANTS

;; error codes
(define-constant ERR_UNAUTHORIZED (err u13000)) ;; caller is not the DAO or an authorized extension
(define-constant ERR_PANIC (err u13001)) ;; internal error getting total supply from token contracts
(define-constant ERR_GETTING_TOTAL_SUPPLY (err u13002)) ;; combined MIA v1+v2 total supply is zero
(define-constant ERR_GETTING_REDEMPTION_BALANCE (err u13003)) ;; treasury STX balance is zero
(define-constant ERR_ALREADY_ENABLED (err u13004)) ;; initialize-redemption was already called
(define-constant ERR_NOT_ENABLED (err u13005)) ;; redemptions are not yet enabled
(define-constant ERR_BALANCE_NOT_FOUND (err u13006)) ;; user has no MIA v1 or v2 balance
(define-constant ERR_NOTHING_TO_REDEEM (err u13007)) ;; calculated STX amount is zero or treasury is empty
(define-constant ERR_ZERO_BALANCE (err u13008)) ;; user's combined MIA v1+v2 balance is zero
(define-constant ERR_SUPPLY_CALCULATION (err u13009)) ;; redemption ratio calculation returned none
(define-constant ERR_INVALID_REDEMPTION_AMOUNT (err u13010)) ;; sanity check that burn amounts add up to the expected redemption amount
;; fair burn-to-exit (offer book) error codes
(define-constant ERR_OFFERS_PENDING (err u13011)) ;; redeem-mia blocked: settle/cancel open offers first
(define-constant ERR_ABOVE_PAR (err u13012)) ;; offer asks more STX than par (or zero)
(define-constant ERR_INVALID_OFFER (err u13013)) ;; offer umia is zero or exceeds MAX_PER_TRANSACTION
(define-constant ERR_OFFER_NOT_FOUND (err u13014)) ;; caller has no open offer to cancel
(define-constant ERR_BOOK_FULL (err u13015)) ;; book full and new ask not below the worst offer
(define-constant ERR_HAS_OFFER (err u13016)) ;; caller already has an open offer (one per wallet)
;; helpers
;; Conversion factor: MIA v1 uses whole tokens, v2 uses micro tokens (6 decimals)
(define-constant MICRO_CITYCOINS (pow u10 u6))
;; Fixed-point scaling for the redemption ratio calculation
(define-constant REDEMPTION_SCALE_FACTOR (pow u10 u6))
;; Maximum MIA per redemption call (prevents single-transaction draining)
(define-constant MAX_PER_TRANSACTION (* u10000000 MICRO_CITYCOINS)) ;; 10M MIA in micro units
;; Hard cap on concurrent open offers (size of the sorted book list-var). When
;; full, a new offer only lands if it's strictly cheaper than the worst, which
;; it then evicts. Combined with one-offer-per-wallet, this bounds spam.
(define-constant MAX_OFFERS u50)
;; MIA token + treasury principals (asset lives in the token contracts; v1 burns
;; must route through the core patch; STX pays out from the rewards treasury)
(define-constant MIA_TOKEN_V1 'SP466FNC0P7JWTNM2R9T199QRZN1MYEDTAR0KP27.miamicoin-token)
(define-constant MIA_TOKEN_V2 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2)
(define-constant MIA_CORE_V1_PATCH 'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-core-v1-patch)
(define-constant MIA_REWARDS_TREASURY 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3)

;; DATA VARS
;; Whether redemptions are open (set to true once by initialize-redemption)
(define-data-var redemptions-enabled bool false)
;; Stacks block height at which redemptions were initialized
(define-data-var redemption-block-height uint u0)
;; Total MIA supply snapshot (v1*10^6 + v2) at initialization
(define-data-var total-supply uint u0)
;; Mining treasury STX balance snapshot at initialization
(define-data-var mining-treasury-ustx uint u0)
;; Immutable after initialization.
(define-data-var redemption-ratio uint u0)
;; Running total of micro-MIA burned across all redemptions
(define-data-var total-redeemed uint u0)
;; Running total of micro-STX transferred to redeemers
(define-data-var total-transferred uint u0)
;; The offer book: open burn offers as full records, kept sorted ascending by
;; price (ustx / umia) so settle can consume cheapest-first from the head. The
;; fixed-rate redeem-mia is gated on this being empty, so offers take priority.
(define-data-var offer-book
  (list 50 {
    owner: principal,
    is-v1: bool,  ;; which MIA edition is escrowed (true = v1 whole, false = v2 micro)
    amount: uint, ;; escrowed amount in that edition's native unit
    ustx: uint,   ;; STX asked for the whole offer (<= par)
  })
  (list)
)
;; Scratch var holding the owner a filter/fold predicate should match against
;; (Clarity has no closures, so the dynamic target is passed via this var).
(define-data-var target-owner principal 'SP000000000000000000002Q6VF78)

;; DATA MAPS

;; Per-user cumulative redemption tracking
(define-map redemption-claims
  principal
  {
    umia: uint, ;; total micro-MIA redeemed by this user
    ustx: uint, ;; total micro-STX received by this user
  }
)

;; (Offers live in the `offer-book` list-var above, not a map -- one record per
;; owner, sorted by price. See the FAIR BURN-TO-EXIT section below.)

;; PUBLIC FUNCTIONS

;; Authorization check: caller must be the DAO base contract or an enabled extension.
(define-public (is-dao-or-extension)
  (ok (asserts!
    (or
      (is-eq tx-sender 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.base-dao)
      (contract-call? 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.base-dao
        is-extension contract-caller
      )
    )
    ERR_UNAUTHORIZED
  ))
)

;; Required by extension-trait. No-op callback.
(define-public (callback
    (sender principal)
    (memo (buff 34))
  )
  (ok true)
)

;; Initializes the redemption mechanism. Can only be called once, and only
;; by the DAO or an authorized extension. Flow:
;; 1. Fetches total supply of MIA v1 and v2 tokens
;; 2. Gets current STX balance of the rewards treasury
;; 3. Computes the redemption ratio as a fixed-point value
;; 4. Revokes any stacking delegation on the treasury
;; 5. Records all snapshot values and enables redemptions
(define-public (initialize-redemption)
  (let (
      (mia-total-supply-v1 (unwrap!
        (contract-call? MIA_TOKEN_V1
          get-total-supply
        )
        ERR_PANIC
      ))
      (mia-total-supply-v2 (unwrap!
        (contract-call?
          MIA_TOKEN_V2
          get-total-supply
        )
        ERR_PANIC
      ))
      (mia-total-supply (+ (* mia-total-supply-v1 MICRO_CITYCOINS) mia-total-supply-v2))
      (mining-treasury-total-balance (get-mining-treasury-total-balance))
      (mia-redemption-ratio (calculate-redemption-ratio mining-treasury-total-balance mia-total-supply))
    )
    ;; check if sender is DAO or extension
    (try! (is-dao-or-extension))
    ;; check that total supply is greater than 0
    (asserts! (> mia-total-supply u0) ERR_GETTING_TOTAL_SUPPLY)
    ;; check that mining treasury balance is greater than 0
    (asserts! (> mining-treasury-total-balance u0) ERR_GETTING_REDEMPTION_BALANCE)
    ;; check that redemption ratio has a value
    (asserts! (is-some mia-redemption-ratio) ERR_SUPPLY_CALCULATION)
    ;; check if redemptions are already enabled
    (asserts! (not (var-get redemptions-enabled)) ERR_ALREADY_ENABLED)
    ;; revoke delegation before recording values
    (try! (contract-call?
      MIA_REWARDS_TREASURY
      revoke-delegate-stx
    ))
    ;; record current block height
    (var-set redemption-block-height stacks-block-height)
    ;; record total supply at block height
    (var-set total-supply mia-total-supply)
    ;; record mining treasury balance at block height
    (var-set mining-treasury-ustx mining-treasury-total-balance)
    ;; calculate redemption ratio
    (var-set redemption-ratio (unwrap-panic mia-redemption-ratio))
    ;; set redemptions-enabled to true, can only run once
    (var-set redemptions-enabled true)
    ;; print redemption info
    (ok (print {
      notification: "initialize-contract",
      payload: (get-redemption-info),
    }))
  )
)

;; Burns MIA tokens and transfers the corresponding STX to the caller.
;;
;; Burn priority: v1 tokens first (converted to micro-MIA), then v2 for the
;; remainder. The requested amount is capped at MAX_PER_TRANSACTION (10M MIA).
;; STX amount is calculated via get-redemption-for-balance using the
;; initialized ratio. Order: burn v1 -> burn v2 -> transfer STX -> record claims.
(define-public (redeem-mia (amount-umia uint))
  (let (
      ;; balances for user
      (user-address tx-sender)
      (redemption-info (try! (get-user-redemption-info user-address (some amount-umia))))
      (burn-amount-umia (get burn-amount-umia redemption-info))
      (burn-amount-v1-in-mia (get burn-amount-v1-mia redemption-info))
      (burn-amount-v2-in-umia (get burn-amount-v2-umia redemption-info))
      (redemption-amount-ustx (get redemption-amount-ustx redemption-info))
      (redemption-claimed (get redemption-claims redemption-info))
    )
    ;; check if redemptions are enabled
    (asserts! (var-get redemptions-enabled) ERR_NOT_ENABLED)
    ;; fixed-rate exit only opens once the offer book is empty (offers first)
    (asserts! (is-eq (len (var-get offer-book)) u0) ERR_OFFERS_PENDING)
    ;; check that user has at least one positive balance
    (asserts! (or (> burn-amount-v1-in-mia u0) (> burn-amount-v2-in-umia u0))
      ERR_ZERO_BALANCE
    )
    ;; check that redemption amount is > 0
    (asserts! (> redemption-amount-ustx u0) ERR_NOTHING_TO_REDEEM)
    ;; burn MIA tokens v1
    (and
      (> burn-amount-v1-in-mia u0)
      (try! (contract-call?
        MIA_CORE_V1_PATCH
        burn-mia-v1 burn-amount-v1-in-mia user-address
      ))
    )
    ;; burn MIA tokens v2
    (and
      (> burn-amount-v2-in-umia u0)
      (try! (contract-call?
        MIA_TOKEN_V2 burn
        burn-amount-v2-in-umia user-address
      ))
    )
    ;; transfer STX
    (try! (contract-call?
      MIA_REWARDS_TREASURY
      withdraw-stx redemption-amount-ustx user-address
    ))
    ;; update redemption claims
    (var-set total-redeemed (+ (var-get total-redeemed) burn-amount-umia))
    (var-set total-transferred
      (+ (var-get total-transferred) redemption-amount-ustx)
    )
    (map-set redemption-claims user-address {
      umia: (+ (get umia redemption-claimed) burn-amount-umia),
      ustx: (+ (get ustx redemption-claimed) redemption-amount-ustx),
    })
    ;; print redemption info
    (print {
      notification: "contract-redemption",
      payload: (get-redemption-info),
    })
    ;; print user redemption info
    (print {
      notification: "user-redemption",
      payload: redemption-info,
    })
    ;; return redemption amount
    (ok {
      ustx: redemption-amount-ustx,
      umia: burn-amount-umia,
      umia-v2: burn-amount-v2-in-umia,
      mia-v1: burn-amount-v1-in-mia,
    })
  )
)

;; READ ONLY FUNCTIONS

;; Returns true if initialize-redemption has been called successfully.
(define-read-only (is-redemption-enabled)
  (var-get redemptions-enabled)
)

;; Stacks block height when redemptions were initialized.
(define-read-only (get-redemption-block-height)
  (var-get redemption-block-height)
)

;; Total MIA supply snapshot (v1*10^6 + v2) at initialization.
(define-read-only (get-redemption-total-supply)
  (var-get total-supply)
)

;; Mining treasury STX balance snapshot at initialization.
(define-read-only (get-mining-treasury-balance)
  (var-get mining-treasury-ustx)
)

;; Live unlocked STX balance of the rewards treasury (decreases as users redeem).
(define-read-only (get-redemption-current-balance)
  (stx-get-balance MIA_REWARDS_TREASURY)
)

(define-read-only (get-mining-treasury-total-balance)
  (let ((acc (stx-account 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-mining-v3)))
    (+ (get locked acc) (get unlocked acc))
  )
)

;; The fixed-point redemption ratio: (treasuryBalance * 10^6) / total-supply.
(define-read-only (get-redemption-ratio)
  (var-get redemption-ratio)
)

;; Running total of micro-MIA burned across all redemptions.
(define-read-only (get-total-redeemed)
  (var-get total-redeemed)
)

;; Running total of micro-STX transferred to redeemers.
(define-read-only (get-total-transferred)
  (var-get total-transferred)
)

;; Aggregates all redemption state into a single tuple for convenience.
(define-read-only (get-redemption-info)
  {
    redemption-enabled: (is-redemption-enabled),
    block-height: (get-redemption-block-height),
    total-supply: (get-redemption-total-supply),
    mining-treasury-ustx: (get-mining-treasury-balance),
    current-contract-balance: (get-redemption-current-balance),
    redemption-ratio: (get-redemption-ratio),
    total-redeemed: (get-total-redeemed),
    total-transferred: (get-total-transferred),
  }
)

;; Returns v1, v2, and combined micro-MIA balances for an address.
(define-read-only (get-mia-balances (address principal))
  (let (
      (balance-v1-mia (unwrap!
        ;; read-only contract-call must target a literal (a constant can't be
        ;; statically verified as read-only), so keep the principal inline here
        (contract-call? 'SP466FNC0P7JWTNM2R9T199QRZN1MYEDTAR0KP27.miamicoin-token
          get-balance address
        )
        ERR_BALANCE_NOT_FOUND
      ))
      (balance-v2-umia (unwrap!
        (contract-call?
          'SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
          get-balance address
        )
        ERR_BALANCE_NOT_FOUND
      ))
      (total-balance-umia (+ (* balance-v1-mia MICRO_CITYCOINS) balance-v2-umia))
    )
    (ok {
      address: address,
      balance-v1-mia: balance-v1-mia,
      balance-v2-umia: balance-v2-umia,
      total-balance-umia: total-balance-umia,
    })
  )
)

;; Returns a user's MIA balances, potential redemption amount, and past claims.
(define-read-only (get-user-redemption-info
    (user principal)
    (amount-umia (optional uint))
  )
  (let (
      (mia-balances (try! (get-mia-balances user)))
      (total-balance-umia (get total-balance-umia mia-balances))
      (redemption-amount-umia (default-to total-balance-umia amount-umia))
      (max-redemption-amount-umia (if (> redemption-amount-umia total-balance-umia)
        total-balance-umia
        redemption-amount-umia
      ))
      (capped-umia (if (> max-redemption-amount-umia MAX_PER_TRANSACTION)
        MAX_PER_TRANSACTION
        max-redemption-amount-umia
      ))
      (redemption (get-redemption-for-balance capped-umia))
      (claims (default-to {
        umia: u0,
        ustx: u0,
      }
        (map-get? redemption-claims user)
      ))
      (balance-v1-mia (get balance-v1-mia mia-balances))
      (balance-v2-umia (get balance-v2-umia mia-balances))
      (burn-amount-umia (default-to u0 (get umia redemption)))
      (burn-amount-mia (/ burn-amount-umia MICRO_CITYCOINS))
      (burn-amount-v1-mia (if (> burn-amount-mia balance-v1-mia)
        balance-v1-mia
        burn-amount-mia
      ))
      (burn-amount-v1-umia (* burn-amount-v1-mia MICRO_CITYCOINS))
      (remaining-amount-umia (- burn-amount-umia burn-amount-v1-umia))
      (burn-amount-v2-umia (if (> remaining-amount-umia balance-v2-umia)
        balance-v2-umia
        remaining-amount-umia
      ))
    )
    (asserts!
      (is-eq burn-amount-umia (+ burn-amount-v1-umia burn-amount-v2-umia))
      ERR_INVALID_REDEMPTION_AMOUNT
    )
    (ok {
      address: user,
      mia-balances: mia-balances,
      redemption-amount-ustx: (default-to u0 (get ustx redemption)),
      burn-amount-umia: burn-amount-umia,
      burn-amount-v1-mia: burn-amount-v1-mia,
      burn-amount-v2-umia: burn-amount-v2-umia,
      redemption-claims: claims,
    })
  )
)

;; Calculates the STX amount for a given micro-MIA balance:
;;   redemption-amount = (redemption-ratio * balance) / REDEMPTION_SCALE_FACTOR
;; If the result exceeds the current treasury balance, returns the treasury
;; balance instead (safety cap). Returns none if the computed amount is zero.
(define-read-only (get-redemption-for-balance (balance uint))
  (let (
      (redemption-amount-scaled (* (var-get redemption-ratio) balance))
      (redemption-amount (scale-down redemption-amount-scaled))
      (contract-current-balance (get-redemption-current-balance))
    )
    (if (> redemption-amount u0)
      (if (< redemption-amount contract-current-balance)
        ;; if redemption amount is less than contract balance, return redemption amount
        (some {
          ustx: redemption-amount,
          umia: balance,
        })
        ;; if redemption amount is greater than contract balance, return contract balance
        (some {
          ustx: contract-current-balance,
          umia: (/ (scale-up contract-current-balance) (var-get redemption-ratio)),
        })
      )
      ;; if redemption amount is 0, return none
      none
    )
  )
)

;; PRIVATE FUNCTIONS

;; Fixed-point arithmetic helpers (credit: ALEX math-fixed-point-16.clar)

;; Multiplies by REDEMPTION_SCALE_FACTOR (10^6) for fixed-point representation.
(define-private (scale-up (a uint))
  (* a REDEMPTION_SCALE_FACTOR)
)

;; Divides by REDEMPTION_SCALE_FACTOR to convert back from fixed-point.
(define-private (scale-down (a uint))
  (/ a REDEMPTION_SCALE_FACTOR)
)

;; Computes the fixed-point redemption ratio:
;;   ratio = (balance * REDEMPTION_SCALE_FACTOR) / supply
;; Returns none if either input is zero (division by zero guard).
(define-private (calculate-redemption-ratio
    (balance uint)
    (supply uint)
  )
  (if (or (is-eq supply u0) (is-eq balance u0))
    none
    (some (/ (scale-up balance) supply))
  )
)

;; FAIR BURN-TO-EXIT (OFFER BOOK)
;;
;; Priority exit for the community: holders escrow MIA in standing offers priced
;; at or below par. The book is a list-var kept sorted ascending by price, so
;; settle consumes cheapest-first from the head. One offer per wallet; a full
;; book evicts its worst offer for a strictly cheaper newcomer. redeem-mia (the
;; ccd013 path) stays blocked until the book is empty.

;; Micro-MIA equivalent of an offer amount (v1 is whole tokens -> * 10^6).
(define-read-only (offer-umia
    (is-v1 bool)
    (amount uint)
  )
  (if is-v1 (* amount MICRO_CITYCOINS) amount)
)

;; STX value at par for an escrowed amount of the given edition, using the
;; frozen redemption ratio. An offer may ask any uSTX <= this.
(define-read-only (get-par-ustx
    (is-v1 bool)
    (amount uint)
  )
  (/ (* (var-get redemption-ratio) (offer-umia is-v1 amount)) REDEMPTION_SCALE_FACTOR)
)

;; Append a record to a <=50 book list, coercing the length back to 50.
(define-private (push-rec
    (lst (list 50 {owner: principal, is-v1: bool, amount: uint, ustx: uint}))
    (r {owner: principal, is-v1: bool, amount: uint, ustx: uint})
  )
  (unwrap-panic (as-max-len? (append lst r) u50))
)

;; Filter predicates keyed on the `target-owner` scratch var (no closures).
(define-private (is-target-owner (r {owner: principal, is-v1: bool, amount: uint, ustx: uint}))
  (is-eq (get owner r) (var-get target-owner))
)
(define-private (not-target-owner (r {owner: principal, is-v1: bool, amount: uint, ustx: uint}))
  (not (is-eq (get owner r) (var-get target-owner)))
)

;; Fold step: surface `owner`'s offer record (for the get-offer read-only).
(define-private (find-owner-step
    (r {owner: principal, is-v1: bool, amount: uint, ustx: uint})
    (acc {target: principal, found: (optional {owner: principal, is-v1: bool, amount: uint, ustx: uint})})
  )
  (if (is-eq (get owner r) (get target acc))
    (merge acc { found: (some r) })
    acc
  )
)

;; The whole sorted book (cheapest-first).
(define-read-only (get-offer-book)
  (var-get offer-book)
)

;; An owner's open offer, if any.
(define-read-only (get-offer (owner principal))
  (get found (fold find-owner-step (var-get offer-book) { target: owner, found: none }))
)

;; Number of open offers (0 => redeem-mia is open).
(define-read-only (get-offer-count)
  (len (var-get offer-book))
)

;; Return an escrowed record's MIA to its owner (contract-sent -> as-contract?).
(define-private (refund-rec (r {owner: principal, is-v1: bool, amount: uint, ustx: uint}))
  (if (get is-v1 r)
    (as-contract? ((with-ft MIA_TOKEN_V1 "miamicoin" (get amount r)))
      (try! (contract-call? MIA_TOKEN_V1 transfer (get amount r) current-contract (get owner r) none)))
    (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" (get amount r)))
      (try! (contract-call? MIA_TOKEN_V2 transfer (get amount r) current-contract (get owner r) none)))
  )
)

;; Burn an escrowed record's MIA (contract-held -> as-contract? w/ allowance).
(define-private (burn-rec (r {owner: principal, is-v1: bool, amount: uint, ustx: uint}))
  (if (get is-v1 r)
    (as-contract? ((with-ft MIA_TOKEN_V1 "miamicoin" (get amount r)))
      (try! (contract-call? MIA_CORE_V1_PATCH burn-mia-v1 (get amount r) current-contract)))
    (as-contract? ((with-ft MIA_TOKEN_V2 "miamicoin" (get amount r)))
      (try! (contract-call? MIA_TOKEN_V2 burn (get amount r) current-contract)))
  )
)

;; Fold step: rebuild the book inserting `nrec` at its sorted (ascending price)
;; position. Price compare is cross-multiplied to stay integer:
;;   new <= entry  <=>  nask * entry-umia <= entry-ask * new-umia
(define-private (insert-step
    (entry {owner: principal, is-v1: bool, amount: uint, ustx: uint})
    (acc {
      nrec: {owner: principal, is-v1: bool, amount: uint, ustx: uint},
      out: (list 50 {owner: principal, is-v1: bool, amount: uint, ustx: uint}),
      placed: bool,
    })
  )
  (let (
      (nrec (get nrec acc))
      (nask (get ustx nrec))
      (numia (offer-umia (get is-v1 nrec) (get amount nrec)))
      (eask (get ustx entry))
      (eumia (offer-umia (get is-v1 entry) (get amount entry)))
    )
    (if (and (not (get placed acc)) (<= (* nask eumia) (* eask numia)))
      (merge acc { out: (push-rec (push-rec (get out acc) nrec) entry), placed: true })
      (merge acc { out: (push-rec (get out acc) entry) })
    )
  )
)

;; Place a standing burn offer: escrow `amount` of one MIA edition (is-v1 =
;; true for v1 whole tokens, false for v2 micro) and ask `ask-ustx` STX for it.
;; `ask-ustx` must be > 0 and <= par. One offer per wallet; inserts sorted by
;; price. If the book is full, only lands if strictly cheaper than the worst
;; offer, which it evicts (escrow refunded).
(define-public (place-offer
    (is-v1 bool)
    (amount uint)
    (ask-ustx uint)
  )
  (let (
      (owner tx-sender)
      (umia (offer-umia is-v1 amount))
      (nrec { owner: owner, is-v1: is-v1, amount: amount, ustx: ask-ustx })
      (book (var-get offer-book))
    )
    (asserts! (var-get redemptions-enabled) ERR_NOT_ENABLED)
    (asserts! (and (> amount u0) (<= umia MAX_PER_TRANSACTION)) ERR_INVALID_OFFER)
    (asserts! (and (> ask-ustx u0) (<= ask-ustx (get-par-ustx is-v1 amount))) ERR_ABOVE_PAR)
    ;; one open offer per wallet
    (var-set target-owner owner)
    (asserts! (is-eq (len (filter is-target-owner book)) u0) ERR_HAS_OFFER)
    ;; escrow the chosen edition into this contract (owner is tx-sender/from)
    (if is-v1
      (try! (contract-call? MIA_TOKEN_V1 transfer amount owner current-contract none))
      (try! (contract-call? MIA_TOKEN_V2 transfer amount owner current-contract none))
    )
    ;; if the book is full, the newcomer must be strictly cheaper than the worst
    ;; (last) offer, which it evicts (escrow refunded); otherwise reject.
    (let (
        (base (if (is-eq (len book) MAX_OFFERS)
          (let ((worst (unwrap-panic (element-at? book (- (len book) u1)))))
            (asserts!
              (< (* ask-ustx (offer-umia (get is-v1 worst) (get amount worst)))
                 (* (get ustx worst) umia))
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

;; Cancel your own open offer and get the escrowed edition back. One offer per
;; wallet, so the caller's own offer is unambiguous (no id needed).
(define-public (cancel-offer)
  (let ((owner tx-sender))
    (var-set target-owner owner)
    (let ((mine (filter is-target-owner (var-get offer-book))))
      (asserts! (> (len mine) u0) ERR_OFFER_NOT_FOUND)
      (try! (refund-rec (unwrap-panic (element-at? mine u0))))
      (var-set offer-book (filter not-target-owner (var-get offer-book)))
    )
    (print { notification: "cancel-offer", payload: { owner: owner } })
    (ok true)
  )
)

;; Fold step: fill an offer if the remaining budget covers its ask. The book is
;; sorted cheapest-first, so this fills the most-pained offers first. Burns the
;; escrowed edition, pays the owner from the treasury; unfilled records are kept.
(define-private (settle-step
    (entry {owner: principal, is-v1: bool, amount: uint, ustx: uint})
    (acc {
      remaining: uint,
      kept: (list 50 {owner: principal, is-v1: bool, amount: uint, ustx: uint}),
    })
  )
  (if (>= (get remaining acc) (get ustx entry))
    (begin
      (unwrap-panic (burn-rec entry))
      (unwrap-panic (contract-call? MIA_REWARDS_TREASURY withdraw-stx (get ustx entry) (get owner entry)))
      (var-set total-redeemed (+ (var-get total-redeemed) (offer-umia (get is-v1 entry) (get amount entry))))
      (var-set total-transferred (+ (var-get total-transferred) (get ustx entry)))
      (merge acc { remaining: (- (get remaining acc) (get ustx entry)) })
    )
    (merge acc { kept: (push-rec (get kept acc) entry) })
  )
)

;; Settle the book against the current rewards-treasury balance. Permissionless
;; and needs no ordering input -- the book is already sorted cheapest-first, so
;; this fills from the head until the drop is exhausted; the rest stays.
(define-public (settle-offers)
  (begin
    (asserts! (var-get redemptions-enabled) ERR_NOT_ENABLED)
    (var-set offer-book
      (get kept (fold settle-step (var-get offer-book) {
        remaining: (get-redemption-current-balance),
        kept: (list),
      })))
    (print { notification: "settle-offers", payload: (get-redemption-info) })
    (ok true)
  )
)
