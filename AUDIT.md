# Contract audit — mia-fair-faktory / mia-single-faktory / mia-pool-faktory

Structured review (clarity-audit framework) of the three contracts, performed
2026-07-03 alongside the Clarity 6 upgrade. Static analysis plus behavioural
verification through the vitest suites (`tests/`) and Rendezvous fuzzing
(`rendezvous/`). Findings marked **FIXED** were corrected in this pass; each
fix is pinned by a unit test.

**Verdict: CONDITIONAL PASS** — no open critical or high findings after the
fixes; the deployment-address coupling (F-6) must be respected at deploy time.

---

## Fixed in this pass

### F-1 (HIGH, security/logic) — swap gate was bypassable by direct calls — **FIXED**
`mia-pool-faktory.clar`, `is-approved-caller`.

The template's check `(or (is-eq tx-sender contract-caller) …)` is true for
**every direct wallet call**, so "gated" only blocked router-mediated swaps.
That defeats the repo's stated amendment ("while the single-sided offering is
taking sBTC deposits, nobody can move the pool ratio by swapping"): anyone
could swap directly, move the price, and snipe the standalone's MIA during the
entry window.

Fix: the escape hatch is removed; while gated, only explicitly
`approve-caller`-ed callers may swap. Pinned by the "swap gating" unit tests.

### F-2 (MEDIUM, logic) — settle-offers aborted when the settler's own offer was affordable — **FIXED**
`mia-fair-faktory.clar`, `settle-step`.

`(unwrap-panic (stx-transfer? … tx-sender (get owner entry)))` hard-aborts when
`owner == tx-sender` (self-transfer returns `(err u2)`). Any community member
with a resting offer who also acted as whitehat got an opaque runtime abort.

Fix: the fold now always keeps the caller's own offer (they can cancel it
instead). Pinned by "a settler's own offer is kept, not filled".

---

## Open findings (documented, deliberately not changed)

### F-3 (LOW, logic) — dust LP entitlements cannot be withdrawn
`mia-single-faktory.clar`, `withdraw-lp-tokens`.

A 1-uLP entitlement floors `60%` to 0; `remove-liquidity u0` hits
`ft-burn? u0` → `(err u1)` and the withdraw always fails. Affected value is
≤ 1 uLP (10⁻⁶ of one LP token) per user and a later deposit that raises the
entitlement to ≥ 2 unblocks it. Documented by the "dust entitlement" unit test
and the rv withdraw property. If desired, assert `(> user-lp-to-remove u0)`
with a dedicated error for clearer UX.

### F-4 (LOW, logic) — settle-offers panics instead of erroring when the caller cannot fund an affordable ask
`mia-fair-faktory.clar`, `settle-step`.

`unwrap-panic` on the STX transfer aborts the transaction when the caller's
balance is below an affordable ask (budget larger than balance). Funds are
safe (aborts revert), but callers get a runtime panic instead of a clean
error. Surfaced by fuzzing (huge random budgets). Cosmetic; a pre-check of
`(stx-get-balance tx-sender)` against `budget` would make it a clean error.

### F-5 (LOW, design) — no entry cutoff at unlock
`mia-single-faktory.clar`, `deposit-sbtc-for-lp`.

Deposits stay open as long as unpaired MIA remains — including **after** the
unlock height. A depositor entering after unlock immediately forfeits 40% with
no lock-time benefit. Consider asserting `burn-block-height < unlock-block` on
deposit, or documenting the hazard for the UI.

### F-6 (MEDIUM, deployment) — hard coupling to the SPV9K21… deployer address
`mia-single-faktory.clar` (`DEPOSITOR`), `mia-fair-faktory.clar` (`SINGLE_SIDED`).

`DEPOSITOR` is the absolute principal
`'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-fair-faktory` while
`SINGLE_SIDED` is project-relative. The trio only composes when **all three
contracts are deployed under SPV9K21…**; under any other deployer,
`seed-single-sided` always fails and the accumulated `surplus-mia` can never
leave the fair contract. This is by design (Clarinet.toml notes it), but it is
a deploy-time gate: verify the deployer address before broadcasting.
(Simnet cannot impersonate contract principals, so the test suites deploy the
trio under SPV9K21… to run the real seed path.)

### F-7 (LOW, logic) — swap quote divides by zero on an empty pool
`mia-pool-faktory.clar`, `get-swap-quote`.

With zero reserves and an amount whose effective input floors to 0, the
denominator is 0 → runtime abort (also aborts read-only `quote` calls). Only
reachable pre-seeding; `initialize-pool` always funds reserves before swaps
open. Documented by the "empty-pool quote edge" unit test.

### F-8 (LOW, security) — admin/deployer auth uses tx-sender in most places
`mia-fair-faktory.clar` (`is-admin`), `mia-pool-faktory.clar`
(`approve-caller`, `revoke-caller`, `set-gated`).

`tx-sender`-based auth is phishable: a malicious contract the admin calls can
act with the admin's authority. `set-token-uri`/`initialize-pool` already use
`contract-caller`; the rest do not (template parity). Consider
`contract-caller` consistently, or an explicit allowlist policy for the admin
wallet.

### F-9 (INFO) — settle fills are affordability-gated, not strictly cheapest-first
A budget too small for the cheapest (absolute ask) offer can still fill a
later, pricier-per-unit but smaller offer. Economically harmless (the settler
overpays either way, spread stays non-negative — fuzz-verified), but worth
documenting for sellers. Pinned by the "skip behavior" unit test.

### F-10 (LOW, logic) — dust amounts abort in the token when a computed leg floors to zero
`mia-pool-faktory.clar`, all quote-driven paths.

`get-liquidity-quote`/`get-swap-quote` floor their legs; with dust inputs on
skewed reserves one leg rounds to 0 and the token transfer rejects with
`(err u3)`, aborting add-liquidity / remove-liquidity / swaps.
**Fuzz-confirmed** (rv seed 1439452765: `add-liquidity u1` after swaps skewed
the reserves). The important flip side is a fuzz-verified property: the revert
means **no free LP is ever minted for a zero-cost side**
(`test-add-liquidity-mints-exact`, dust branch) and a round trip never pays
out more than it took in (`test-add-remove-roundtrip-no-profit`).

---

## What works correctly (verified)

- **Par math**: `ratio = treasury × 1e6 / (v1×1e6 + v2)` reproduces the
  mainnet 1710; `par-equiv ≤ acquired` holds for every fill combination
  (floor-rounding proof + `invariant-settled-covers-spent-at-par`).
- **Whitehat semantics**: the settler pays their own STX and receives exactly
  the par-equivalent MIA — no profit path (unit + fuzz property).
- **Escrow accounting**: contract MIA == Σ open offers + surplus at all times
  (`invariant-escrow-matches-book-plus-surplus`, equality not just ≥).
- **Book ordering**: ascending by price via cross-multiplication; FIFO on
  price ties (DECISIONS.md D1) for both insert and full-book eviction; one
  offer per wallet (`invariant-one-offer-per-owner`).
- **60/40 unlock**: exactly 60% of the entitlement leaves the pool; the 40%
  remainder stays with the contract unattributed, forever
  (`invariant-lp-covers-entitlements`, full-flow test).
- **Seed clock**: anchored on first seed only; top-ups accumulate without
  moving the unlock (unit test via the real fair → single call).
- **Constant product**: `x·y` never decreases across swaps; quotes match
  execution; faktory fee lands at the fee address (unit + fuzz).
- **Clarity 6 asset safety**: every outbound transfer from all three contracts
  runs under `as-contract?` with an exact `with-ft` allowance.

## Coverage map

| Layer | Where | What |
|---|---|---|
| Unit (68 vitest tests) | `tests/*.test.ts` | exact-value math, auth, edges, full E2E story |
| Property fuzz | `rendezvous/harnesses/*.tests.clar` (`npm run rv:*:test`) | escrow/accounting per call, no-profit properties, lock/split |
| Invariant fuzz | same files (`npm run rv:*:invariant`) | state-machine safety under random call sequences |

---

## Team dispositions

Our decision on each finding.

| # | Sev | Disposition | Rationale |
|---|---|---|---|
| **F-1** | HIGH | **Fixed** (this PR) | Real — the gate was bypassable by direct wallet swaps. Escape hatch removed; while gated only approved callers swap. |
| **F-2** | MED | **Fixed** (this PR) | Real — a whitehat with a resting offer could crash settle. Own offer now skipped. |
| **F-3** | LOW | **Fixed** | Added `MIN_LP_AMOUNT u20` guard in `deposit-sbtc-for-lp` (10× the 2-microLP floor below which 60% rounds to 0). No one can strand a dust position. |
| **F-4** | LOW | **Won't fix** | Cosmetic. `unwrap-panic` on an underfunded settle aborts (funds safe) instead of a clean error. The whitehat simply funds the budget; a balance pre-check is optional polish, not worth the extra code. |
| **F-5** | LOW | **Accept (not a bug)** | No forfeit and no extraction: whenever a user deposits, they keep 60% (the 20% bonus) and 40% stays as permanent pool liquidity — that IS the intended distribution of the vault's MIA. A post-unlock instant deposit-withdraw just means the depositor supplied sBTC, took their bonus, and left 40% depth behind. Timing doesn't change the economics, so no cutoff is added. |
| **F-6** | MED | **Accept (by design)** | The trio is intentionally address-coupled to `SPV9K21…`. We deploy under that address; the operating sequence (README) notes verifying the deployer before broadcast. |
| **F-7** | LOW | **Accept (unreachable)** | Empty-pool divide-by-zero is only reachable pre-seeding; `initialize-pool` funds reserves and swaps are gated until then, so no one quotes/swaps an empty pool. |
| **F-8** | LOW | **Accept (known)** | `tx-sender` admin auth is phishable only if the admin calls through an untrusted contract, which the operator won't do. Accepted; `set-token-uri`/`initialize-pool` already use `contract-caller`. |
| **F-9** | INFO | **Accept (documented)** | Affordability-gated fills are economically harmless — the settler overpays either way and the spread stays non-negative (fuzz-verified). Noted for sellers. |
| **F-10** | LOW | **Accept (harmless)** | Dust legs flooring to 0 revert the call; the flip side is a fuzz-verified property that no free LP is ever minted and round-trips never profit. |

**Fixes landed:** F-1, F-2 (Clarity-6 pass) + F-3 (dust deposit guard). No open critical/high. Remaining findings accepted with rationale above.

---

## v2 addendum (frontier partial fill, 2026-07-03)

`mia-fair-faktory-v2` + `mia-single-faktory-v2` (pool reused). Verified by
stxer sim 71/71 (`npm run sim:v2`) and Rendezvous: all 10 targets (v1 trio +
v2 pair, property + invariant modes), 100 runs each, **zero contract bugs**.

### F-9 — RESOLVED by v2
`settle-offers` now partial-fills the frontier offer with the whole remaining
budget and stops, instead of skipping it and letting a pricier-per-MIA offer
with a smaller absolute ask fill first. Strict price-time priority;
`spent == min(budget, book total)` exactly (fuzz-verified property).

### F-11 (INFO) — partial-fill floor rounding, bounded and maker-favorable
Integer partial fills cannot keep both the maker's rate and the remainder's
price exact; v2 floors `taken`, which protects the maker (never paid below
their per-uMIA ask; full ask received across any split of fills — sim-verified
to the digit) at the cost of the remainder's implied price dipping < 1 uMIA
below its original per settle call. Consequences, each bounded by the
settle-call count and fuzz-verified with that exact bound:
- the book can be pairwise-"unsorted" by rounding dust next to a settler's
  own resting offer;
- cumulative `total-settled` can trail `floor(total-spent * 1e6 / ratio)` by
  the same dust.
The escrow ledger (`contract MIA == open offers + surplus-mia`), the par cap
on every resting ask, and per-settle whitehat accounting (settler receives
exactly par-equiv, surplus never negative) remain strict equalities.
**Disposition: accept (inherent to integer pro-rata; maker-favorable).**

### Fuzz-harness fixes shipped with v2 (not contract bugs)
- fair harnesses were vacuous since the par source switched to the ccd013
  copy: the simnet ccd013 deploys un-initialized, so `initialize` silently
  failed and every fair run was discarded (rv also crashed when clarinet's
  lazy resolution of the unlisted ccd013 hit Hiro rate limits). rv-sync
  PATCH 5 freezes par at the mainnet-verified u1710 in the fuzz copies.
- the single deposit property predated the F-3 dust guard; fuzzed LP amounts
  now floor at `MIN_LP_AMOUNT`.

---

## mia-orderbook-jing addendum (sBTC sell book, 2026-07-04)

`mia-orderbook-jing` — fork of `mia-fair-faktory-v2` with the par machinery
removed: a 50-deep MIA-v2 sell book priced in sBTC. Sellers escrow MIA at any
ask (`place-offer`), can reprice / top up in one call (`change-offer`), and
cancel at will; takers cross the book with a marketable limit order
(`market-order(spend-btc, max-price-per-1m)`) paying a 10 bps fee on top of
the book spend. No initialize step; admin surface is `set-admin`,
`set-fee-recipient`, `set-min-deposit`, `set-paused`.

**Verdict: PASS** after the O-1 fix. Verified on the FINAL source by:
- stxer mainnet-fork sim **58/58** (`npm run sim:orderbook`) —
  https://stxer.xyz/simulations/mainnet/f94dcfc076a6366c35140fed12529f92
  (guards incl. poison-ask + pause, sort through place/reprice/add, crossing
  fills with frontier partial at the maker's exact ratio, limit-stop with
  budget headroom, 1-sat dust fill with fee floored to 0, self-offer skip,
  cancel-after-partial, sat-exact maker/taker/fee deltas, escrow == book at
  every stage and 0 when empty)
- Rendezvous property mode, 300 runs, and invariant mode, 200 runs
  (`npm run rv:orderbook:test` / `rv:orderbook:invariant`) — **zero
  failures**, including sequences where the fuzzer pauses/unpauses mid-run

### O-1 (CRITICAL) — unbounded ask = permanent book freeze via overflow — **FIXED**
Removing the par ceiling removed the only arithmetic bound on `ask-btc`. The
folds cross-multiply (`ask * ONE_MILLION_MIA` in the limit check,
`ask * amount` in insert/bump), and Clarity uint overflow ABORTS the tx. One
offer with `ask > ~3.4e26` (min-deposit escrow, refundable) therefore bricked
every future `market-order`, `place-offer` and `change-offer` — and could not
be bumped out, because the bump comparison itself multiplies against the
poison ask. Activity freeze only: `cancel-offer` does no multiplication, so
every maker could always exit with a full refund. v2 is NOT exposed (par cap
+ `MAX_PER_TRANSACTION` bound both factors; no `* 1e12` term exists there).

Fix: `MAX_ASK u1000000000000000` (1e15 sats = 10M BTC) enforced on `ask-btc`
(place), `new-ask-btc` (change) and `max-price-per-1m` (market-order — that
one is self-DoS only, but a clean `ERR_INVALID_OFFER` beats a runtime abort).
Worst product is now ~1e30 against the ~3.4e38 overflow line. Note the cap is
deliberately unit-incongruent (total sats vs sats-per-1M): it is an overflow
bound, not an economic policy. Pinned by two sim steps (poison ask and poison
limit both -> `err u13013`).

### O-2 (LOW) — frontier partial can exceed the taker's limit by flooring
The partial fill floors `taken`, so the taker's effective price
(`remaining / taken`) can exceed `max-price-per-1m` by less than one uMIA's
worth per market-order call (the fuzz property asserts exactly that bound:
`spent * 1e12 <= max * acquired + max`). At min-deposit sizes (>= 100k MIA)
this is sub-satoshi. **Disposition: accept (inherent to integer pro-rata;
mirror of v2's F-11, maker-favorable).**

### O-3 (INFO) — pause switch — **ADDED by team decision**
Original fork had no emergency lever. `set-paused` (admin) now gates
`place-offer` / `change-offer` / `market-order` with `ERR_PAUSED u13020`;
`cancel-offer` is deliberately NOT pausable, so makers can always exit with
their escrow and the admin cannot freeze user funds. Sim-verified (all three
gated calls revert while paused; cancel refunds while paused).

### O-4 (INFO) — accepted as-is
- `unwrap-panic` on the sBTC transfers inside the settle fold: a taker with
  insufficient sBTC gets a runtime abort instead of a clean error. Atomic
  (full revert, no partial state); FE post-conditions (`spend + fee` sBTC
  out) make it a non-event. Same pattern as v2's `stx-transfer?`.
- `market-order` prints aggregate `spent/acquired/fee` only; per-maker fill
  attribution comes from the sBTC transfer events in the same tx.
- `change-offer` re-inserts at the new price with fresh time priority (a
  reprice queues behind equal-priced offers, like a new placement).
- `min-deposit` gates placement and amend totals only; a remainder ground
  below it by fills stays fillable/cancellable but cannot be repriced
  without topping up (anti-spam for the 50 slots).
- fee is a constant (`FEE_BPS u10`): takers cannot be rugged by a fee hike;
  changing it requires a new contract.

### Checked and sound (no action)
Escrow solvency on every path (contract MIA == book sum, fuzz-verified as a
strict equality — no surplus term in this contract); no double-refund; the
`change-offer` + bump-out + `target-owner` interplay; sort preservation
through partial fills (residual implied price only ever decreases); no
zombie entries (both sides of every record stay > 0; fuzz invariant); maker
never paid below their per-uMIA ask; one offer per owner; 10 bps fee math
(floor; zero-fee dust fills settle rather than revert); zero-fill
market-orders revert (`ERR_NO_FILL u13019`) so takers never pay gas-for-
nothing silently; admin cannot touch escrow or resting offers; no
reentrancy surface (SIP-010 has no callbacks).

## mia-to-mia-faktory addendum ("Miami to Miami", 2026-07-05)

Independent adversarial review of the escrowed ccd013→fair-v2 whitehat
route (one public trigger + two owner hatches). Findings numbered R-*.

### Fixed in this pass

- **R-2 CRIT — front-runnable beneficiary slot.** The original design let
  the FIRST depositor claim the beneficiary slot (and with it the MIA
  output stream AND both emergency hatches). Deploy and first deposit
  cannot be atomic on Stacks, so a griefer front-running fastpool's first
  deposit would own the machine. **Fix: the beneficiary is the hardcoded
  `FASTPOOL` constant (fastpool.btc = `SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X`);
  the slot, its data-var and all owner-none paths were removed.** ⚠ The
  address must be confirmed with friedger before deploy.
- **R-1 HIGH — dust-donation brick.** `try-redeem` called
  `ccd013.redeem-mia` whenever the machine held any MIA and the treasury
  any STX. A donation below ~585 uMIA (value floors to zero at par 1710)
  made ccd013 abort (`u13007`/`u13008`), and because both legs run in one
  transaction the settle leg died with it — a sub-cent griefing loop only
  the owner could clear. **Fix: `try-redeem` pre-quotes via ccd013's own
  `get-redemption-for-balance` and skips (ok none) unless the redemption
  pays out — one check that also covers the empty-machine and
  empty-treasury cases.** Regression-pinned in the stxer sim (dust +
  funded treasury → clean `u9002`) and fuzzed
  (`test-dust-donation-never-bricks`).

### Accepted / verified-clean (R-3…R-10)

- R-3 INFO: `spent>0 ∧ par-equiv=0` STX-stranding is impossible while
  `redemption-ratio < 1e6` (live: immutable u1710; min nonzero spend of
  1 uSTX yields par-equiv 584). Invariant documented, not guarded.
- R-4 INFO: STX/MIA donations ≥ 585 uMIA only ever benefit the
  beneficiary. Accepted.
- R-5 clean: the machine can never hold a resting fair-v2 offer, so the
  settle-step self-skip path is unreachable for it.
- R-6 clean: the settle budget reads `stx-get-balance` AFTER the redeem
  leg — freshly redeemed STX is spendable in the same trigger.
- R-7 clean: every `as-contract?` allowance is cap-or-exact (redeem caps
  at the request while ccd013 may burn less; settle caps at budget;
  forward/withdraw are exact).
- R-8 clean: prints and `get-status` reflect true post-op state.
- R-9 INFO (by design): the beneficiary receives exactly par-equiv; the
  below-par spread stays in fair-v2's `surplus-mia` for the vault.
- R-10 clean: `.mia-fair-faktory-v2` dot-reference requires deploying
  under SPV9K21 (fair-v2 already live there). Clarity 5.

### Verification

- stxer mainnet-fork `npm run sim:route` — **72/72** vs LIVE ccd013 +
  LIVE fair-v2, incl. both audit-fix regressions.
- Rendezvous `npm run rv:route:test` / `rv:route:invariant` — 6
  properties + 4 invariants, zero failures (PATCH 6 makes the cached
  ccd013 copy behave like the initialized mainnet deployment and pays
  redemptions from its own balance; PATCH 7 points FASTPOOL at the simnet
  deployer wallet).

### stx-to-stx-mia-faktory addendum (mirror, 2026-07-05)

Friedger's inversion: the working capital is STX; the legs run settle →
redeem ("first fill the book, then claim STX"). Inherits the audited
core (hardcoded FASTPOOL per R-2, pre-quoted redeem leg per R-1, same
allowance/hatch/no-op patterns). Independent adversarial pass focused on
what the inversion changes — **verdict PASS, no CRIT/HIGH/MED**:

- **S-1 LOW (accepted)** — settle-first means any permissionless trigger
  while the treasury is empty converts the machine's parked STX into MIA
  (fillable at up to a par-priced offer). Value-preserving: the MIA is
  redeemable at the same par when the treasury refills, and
  `withdraw-mia` recovers it any time; the cost is liquidity/timing,
  bounded to ≤1 uSTX floor dust per fill. Inherent to the chosen
  ordering — while waiting, the standing asset can be MIA, not STX.
- **S-2 INFO** — deposit sandwich/MEV bounded: a par-priced front-run
  offer sorts LAST (par is the ask ceiling), cannot jump honest sellers,
  and is merely serviced at par — exactly what ccd013 would pay it
  directly. No above-par extraction path exists.
- **S-3 INFO** — the machine may hold >10M MIA across triggers; the
  redeem leg drains it correctly at 10M/trigger, allowances stay
  cap-or-exact, residual untouchable by third parties.
- **S-4…S-9 clean** — inter-leg state (fresh balance reads, redeem
  output parked for the next trigger, never stranded/double-spent);
  `spent==0 ⟺ par-equiv==0` so the skip branch can't uncount a real
  settle; every `as-contract?` allowance cap-or-exact; accounting vars
  gate nothing; the plain STX deposit has no self-transfer/zero-amount
  edge; the machine can never own a fair-v2 book offer, so its held MIA
  is unreachable from the book side.

Verification: stxer `npm run sim:stx-route` — **60/60** vs LIVE fair-v2
+ LIVE ccd013 (fully-atomic one-tx loop, BOOK>escrow frontier partial
with same-tx refill, R-1 dust regression, exact final accounting; round
trip over 4 loops lost 4 uSTX total). Rendezvous
`rv:stx-route:test|invariant` — 6 properties + 3 invariants (acquired
covers spend at par, received covers burns at par, round-trip parity),
zero failures.

---

## mia-arb-faktory addendum (atomic triangular arb, 2026-07-06)

Static review (clarity-audit framework, independent agent pass) + behavioural
verification: mainnet-fork simulation (`simulations/verify-arb.js`, 40/40
against the LIVE deployed book, ALEX pool 16, Bitflow xyk and Velar 0070) and
Rendezvous fuzzing (`rendezvous/`, PATCH 8: local book + real-balance fixed-8
mock venues; 5 properties + 3 retention invariants, 0 failures).

**Verdict: PASS** — no open findings after the L-1 fix.

### Verified correct (load-bearing proofs)
- **Payout exact, nothing stuck**: `buffer = spend + floor(spend/1000) ≥
  cost = spent + floor(spent/1000)` for all inputs (book guarantees
  `spent ≤ spend`); `payout = sbtc-out + (buffer − cost)` equals the
  contract's entire end balance, so the contract zeroes out on success and
  atomic revert refunds everything. Fuzzed (invariant-no-resting-*) and
  fork-checked at every stage.
- **ALEX fixed-point exact**: `token-wstx-v2`/`token-wmia` confirmed on-chain
  as 8-dec wrappers over 6-dec bases; `dy = acquired·100` pulls exactly
  `acquired` uMIA, `floor(dx/100)` equals the native uSTX actually delivered
  — belief == actual, no over-credit, no dust.
- **Allowances**: every `as-contract?` cap ≥ (usually ==) what the leg moves;
  DEX fees come out of swap amounts, never as an extra pull.
- **No redirection**: funds pulled from `tx-sender`, payout hardcoded to the
  same principal — calling through an intermediary contract cannot divert.
- **No reentrancy / overflow / div-by-zero**; Velar direct-pool arg order
  matches the mainnet-proven flatearth arb.

### Fixed in this pass
**L-1 (LOW) — donated/stranded tokens were permanently locked — FIXED.**
`payout` is computed, never balance-swept, so a direct donation could never
leave. Added `rescue`: sweeps any resting sBTC/MIA/STX to `DEPLOYER`,
callable by anyone (funds can only move to the deployer). Pinned by the
fork sim (donate → rescue → deployer delta exact, contract zero).

### Dispositions (INFO, accepted)
- **I-1** Clarinet pins Clarity 6 for checking; mainnet deploy MUST force
  Clarity 5 (version byte 6 is rejected — see repo memory).
- **I-2** Per-leg min-outs are none/`u1`; `min-profit` (taker) and
  `min-mia-out` (replenish) are the sole economic guards — sandwich pressure
  can only force a revert. Keeper must size them.
- **I-3** Book/pool front-run or admin pause = revert-only griefing (gas).
- **I-4** FE/keeper should still set sBTC post-conditions on the signing
  wallet (permissionless tx-sender funding).

### Coverage map
- `simulations/verify-arb.js` — fork: profitable taker arb (Bitflow + Velar)
  with exact cost/fee/maker deltas; no-fill and min-profit reverts refund to
  the sat; replenish loops exact; rescue sweep; contract retention zero at
  every stage. Observed price-impact note: consecutive 2M-MIA fills degraded
  the composite (arb1 +262,779 sats, arb2 +88,611, round 3 unprofitable) —
  keepers must quote before firing.
- `rendezvous/` — properties: profit-or-exact-refund on both taker paths,
  u13019 propagation, replenish exactness both venues; invariants: the arb
  contract never retains sBTC / MIA / STX.
