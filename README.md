# mia-single-faktory

A **whitehat exit auction** for CityCoins MIA that spins up a **new sBTC market
for MIA** on fak.fun — and lets anyone provide sBTC single-sided for a bonus.

## The three contracts (plain version)

**`mia-fair-faktory` — the exit auction.** MIA holders who want out early lock up
MIA and name a price at or below par (~**1710 STX per 1M MIA**). Anyone can act
as a **white hat** and settle the book: they pay the sellers from their own STX
and only ever get back the par-equivalent — **no profit** — so it's only worth
doing to help the market. Cheapest / most-in-pain offers are filled first,
first-come-first-serve on ties. The **discount** the sellers accepted (the
"spread") is kept by this contract and used to seed liquidity.

**`mia-pool-faktory` — the MIA/sBTC trading pool.** A standard automated market
maker (think a Uniswap-style pool) where MIA and sBTC trade against each other.
This is the **new venue** for MIA on fak.fun, alongside its existing STX pool on
Alex.

**`mia-single-faktory` — the single-sided sBTC vault.** Where the community joins
with **only sBTC** — the MIA side is already supplied by the spread above. Your
deposit is locked **~3 months**; on unlock you keep **60% of your position (a
20% bonus** over a normal 50% split, subsidized by that MIA), and the remaining
**40% stays in the pool for good**, permanently deepening the market.

**The net effect.** MIA ends up trading in **two places** — STX on Alex and sBTC
on fak.fun — opening a standing arbitrage loop between them. The bots that today
race to grab the **one-shot** book scoop get a **sustainable** arb source
instead: the one-time extraction is taken away and replaced with ongoing, healthy
volume that benefits MIA. Short horizon: pox-5 lands in ~2–3 cycles and changes
the reward game.

*Sparked by a CityCoins community proposal for a below-par MIA burn auction,
built on CCIP-026.*

## Contracts (`contracts/`) — technical

Deploy order is **pool → single → fair** (`mia-fair-faktory` calls into
`mia-single-faktory`; the single-sided references the accumulator only as a
value, so no cycle).

| contract | clarity | role |
|---|---|---|
| **`mia-fair-faktory.clar`** | 6 / epoch 4.0 | Fork of ccd014. Permissionless, **caller-funded** `settle-offers`; the settler gets only par-equiv MIA, the below-par **spread** is retained in `surplus-mia`; `seed-single-sided` pushes it into the offering. NOT a DAO extension (admin-gated `initialize`/`seed`; no treasury payout, no `revoke-delegate-stx`). Par is COPIED at init from the live DAO redemption (`SP2PABAF9….ccd013-burn-to-exit-mia`, frozen u1710) — recomputing from live supply would drift above the DAO's real conversion rate. `current-contract` + `as-contract?` post-conditions on every MIA payout. A settler's own resting offer is always kept, never self-filled (AUDIT F-2). |
| **`mia-single-faktory.clar`** | 6 / epoch 4.0 | Single-sided offering. `DEPOSITOR` (= `mia-fair-faktory`) seeds MIA **repeatably** (clock anchored on the first seed). Community supplies only sBTC — **no entry deadline** (open while the contract holds unpaired MIA). ~90-day lock; on unlock the user keeps **60%** of their LP, the other **40% stays locked in the pool forever**. `current-contract` + `as-contract?`. |
| **`mia-pool-faktory.clar`** | 6 / epoch 4.0 | MIA(v2)/sBTC constant-product AMM — port of `flatearth-faktory-pool-v2` upgraded to Clarity 6 (plain `as-contract` no longer exists there: every outbound transfer now runs under `as-contract?` with an exact allowance). `initialize-pool` does **not** auto-approve a swap caller, so swaps stay **gated** until the admin opens them — the anti-imbalance lever while the single-sided offering takes deposits. Unlike the template, the gate holds against **direct wallet calls** too (AUDIT F-1). |

Only MIA **v2** is used for trading/escrow (v1 appears solely in the init par computation).

### `contracts/reference/` — unmodified on-chain copies, for diffing only (not built)
| file | source |
|---|---|
| `ccd014-fair-burn-to-exit-mia.clar` | CCIP-026 PR #7 — the offer-book redemption we fork |
| `ccd013-burn-to-exit-mia.clar` | the fixed-rate base it extends |
| `flat-single-faktory.clar` | `SPV9K21…flat-single-faktory` — the single-sided template |
| `flatearth-faktory-pool-v2.clar` | `SPV9K21…flatearth-faktory-pool-v2` — the AMM template |

## Operating sequence

Deploy order is **pool → single → fair** (all under `SPV9K21…` — the trio is
address-coupled, see AUDIT F-6).

1. **`fair.initialize`** — copy par (u1710) from the live ccd013 redemption.
2. **whitehat `settle-offers`** — below-par offers filled; the spread accumulates
   in `fair.surplus-mia`.
3. **`pool.initialize-pool(lowest, highest)`** — admin seeds initial sBTC + MIA
   depth at a *fair* starting price. **Swaps stay gated** (no approved caller).
4. **`fair.seed-single-sided(amount)`** — push the accumulated MIA into the vault
   (repeatable; the lock clock anchors on the first seed).
5. **community `deposit-sbtc-for-lp`** — sBTC pairs with vault MIA at the frozen
   ratio; LP locked ~3 months. While swaps are gated the price can't move, so
   every deposit pairs fairly and the MIA can't be sniped.
6. **open the market** — once the single-sided has done its job (MIA paired /
   offering done), the admin **`approve-caller` for `fakfun-core-v2`** (or
   `set-gated false`) to open swaps. This is the moment the second market goes
   live and the Alex↔fak.fun arb loop begins. **Do not open swaps while unpaired
   MIA remains** — that's the only window in which the vault could be sniped.
7. **after the lock** — `withdraw-lp-tokens`: the user keeps 60% of their LP; the
   other 40% stays in the pool permanently.

## Key on-chain facts (mainnet, verified)
- Redemption ratio (par): **1710** → `uMIA = uSTX * 1e6 / 1710`.
- CCD013 economics (sim/live): 934.28M MIA burned for 1,597,626 STX (confirms 1710/1M).
- MIA mining treasury (`ccd002-treasury-mia-mining-v3`): ~10.24M STX; ~16,772 STX/cycle reward.
- MIA v2: `SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2`; sBTC: `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token`.
- Par is copied at init from live ccd013 (`get-redemption-ratio` = u1710, frozen).

Design notes live in [`DECISIONS.md`](./DECISIONS.md); the structured contract
review lives in [`AUDIT.md`](./AUDIT.md).

## Deployed (mainnet, 2026-07-03)

| contract | id |
|---|---|
| pool | `SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-pool-faktory` |
| single | `SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-single-faktory` |
| fair | `SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-fair-faktory` |

Deployed at **Clarity 5** (mainnet rejects version byte 6; every construct used
— `current-contract`, `as-contract?`/`with-ft` — is Clarity-5). UI:
[fak.fun/m/mia](https://fak.fun/m/mia) · story:
[fak.fun/m/blog/mia-fair-exit](https://fak.fun/m/blog/mia-fair-exit).

## v2 — frontier partial fill (pending deploy)

v1's `settle-offers` skips any offer whose full ask exceeds the remaining
budget — and keeps scanning, so a pricier-per-MIA offer with a smaller
absolute ask could still fill (a mild price-priority violation), and a
settler's budget was never consumed exactly. **v2 partial-fills the frontier
offer instead**: when `0 < remaining < ask`, the settler pays the owner the
whole remainder, takes `taken = amount * remaining / ask` uMIA, and the
record stays in the book shrunk to `{amount - taken, ustx - remaining}`.

Properties (all sim-proven):
- `taken` **floors**, so the maker is never paid below their ask per-uMIA;
  the remainder's implied price stays ≤ its original price ≤ par, preserving
  the below-par invariant and the ascending sort.
- After a partial, `remaining` is u0 — **strict price-time priority** (the
  v1 queue-jumping quirk is gone).
- The remainder always keeps `amount ≥ 1` and `ustx ≥ 1`; a dust budget too
  small to buy a single uMIA leaves the entry untouched.
- `spent = min(budget, book total)` exactly → the settler's STX
  post-condition can be an exact amount, and split settles **conserve
  totals**: N partial settles pay every maker their full ask to the digit.
- New read-only **`get-book-totals`** → `{ustx, amount}` — one call tells a
  settler the budget that clears the whole book (any smaller budget is
  consumed exactly).

Only the two cross-referencing contracts get a v2 — **the pool is reused
as-is** (it authorizes on `DEPLOYER`/approved-callers and never names its
siblings; add/remove-liquidity are not swap-gated):

| contract | change |
|---|---|
| `mia-fair-faktory-v2.clar` | partial-fill `settle-step`, `get-book-totals`, `SINGLE_SIDED → .mia-single-faktory-v2` |
| `mia-single-faktory-v2.clar` | `DEPOSITOR → SPV9K21….mia-fair-faktory-v2` only (the constant is frozen at deploy) |

Deploy order: **single-v2 → fair-v2** (fair-v2 cross-calls single-v2; the
live pool is already on-chain). Migration: the v1 book currently holds one
live offer (`SP1JAG6TV…AJV91`, 457,230 MIA @ 526.96 STX) — the maker must
`cancel-offer` on v1 and re-place on v2, or a whitehat settles it on v1
(v1's spread can only seed v1's single, not v2's).

## mia-to-mia-faktory — "Miami to Miami" (pending deploy)

**One function**: `redeem-and-settle(amount-umia)`. `amount > 0` — the
**hardcoded beneficiary** (`FASTPOOL` = fastpool.btc, per AUDIT R-2 a
first-depositor slot would be front-runnable) feeds MIA v2 into the
machine; `amount = 0` — **anyone** re-triggers it. Then
whatever is currently possible happens:

- **redeem leg** — if the ccd013 treasury has STX and the machine holds
  MIA, it redeems at par (u1710) in ≤10M-MIA chunks (the ccd013 per-tx
  cap); the STX escrows **in the machine**;
- **settle leg** — if the machine holds STX and the fair book has offers,
  it settles; the par-equiv MIA goes straight to the **depositor**, never
  the caller.

A bare re-trigger with nothing to do reverts `u9002`, so bots don't pay
for no-ops. Built for the reality that the ccd013 rewards treasury
(`ccd002-treasury-mia-rewards-v3`) is **empty between PoX cycles**
(verified u0 on 2026-07-05) and refills in ~16.7k-STX bursts (~9.8M MIA at
par), while the fair book refills as the community sells above the Alex
price (≤ par) — the surplus STX sits in the machine as a standing par bid
until both sides show up. Escrowed STX can only exit through the
par-capped book, so the MIA always comes back at ≥ the u1710 it was minted
at. ccd013 partial fills (treasury smaller than the request) leave the
unburned MIA escrowed for the next trigger; the redeem leg pre-quotes via
`get-redemption-for-balance` and skips zero-value redemptions, so dust
donations can't brick the trigger (AUDIT R-1). **MIA v2 only.**
Owner-only `withdraw-stx`/`withdraw-mia` emergency hatches cover the two
stranding modes (pox-5 ends the treasury refills / the book stops
filling).

- `npm run sim:route` — deployed on the fork against **LIVE ccd013 + LIVE
  fair-v2** (real 3-offer book, 1,741.86 STX / 1.363M MIA), **48/48**:
  [run](https://stxer.xyz/simulations/mainnet/4eb4a77f26c6f72fb8848fec213ecc16).
  Covers the empty-treasury deposit (both legs skip, nothing reverts), the
  cycle-payout re-trigger (10M MIA → exactly 17,100 STX **and** the
  live-book sweep in one stranger tx — also the runtime proof that
  `with-ft` allowances cover ccd013's ft *burn* under `as-contract?`), the
  settle-only re-trigger with exact economics, caller-earns-nothing, the
  beneficiary-slot guard, both hatch guards + exact owner withdrawals,
  the 2,900-STX partial redemption with the residual MIA left escrowed, and a final `get-status` reconciling every
  running total to the digit.

## Verification

- `clarinet check` → ✔ 5 contracts (v1 trio + v2 pair; repo manifest at Clarity 6 / epoch 4.0 for analysis).
- **68 unit tests** (Clarinet SDK + vitest) green, including a full
  end-to-end run of the auction → seed → deposit → gate → 60/40 unlock story.
- **Fuzzed with Rendezvous 1.x**: 5 contracts (v1 trio + v2 pair) × property +
  invariant modes, 100 runs each, zero failures (see
  [`rendezvous/README.md`](./rendezvous/README.md)); audit + dispositions in
  [`AUDIT.md`](./AUDIT.md). The v2 fair harness adds partial-fill properties
  (exact min(budget, book) spend; frontier record shrinks exactly, maker paid
  at/above ask) and restates the sorted-book and par-coverage invariants with
  their exact floor-rounding bounds.
- **stxer mainnet-fork sims** (self-verifying, exit non-zero on any failure):
  - `npm run sim:happy` — full lifecycle from fresh deploys, **46/46**:
    [run](https://stxer.xyz/simulations/mainnet/931933e40784527147b308eb220f8537)
  - `npm run sim:deployed` — the same arc against the **LIVE on-chain bytecode**
    (no deploys), **43/43**:
    [run](https://stxer.xyz/simulations/mainnet/35bf36c99ea5a6d967b13b7898060372).
    Covers the pending admin `initialize` (par copied from live ccd013 = u1710),
    real MIA whales placing 9M MIA of offers, a whitehat settling for 12,900 STX
    (sellers paid their exact asks, settler receives exactly par-equiv, 1.456M MIA
    spread retained), pool seeding while gated, vault seeding, community sBTC
    deposits, every guard (u403 gated swap, u406 dust, u407 early withdraw,
    u408 no-deposit, u13005/12/16/17), gate opening, both swap directions with
    exact faktory fees, a 12,960-block advance, and the 60/40 exit with 120k LP
    provably locked forever.
  - `npm run sim:v2` — the **v2 pair** deployed on the fork against the **LIVE
    pool** (mirroring the real v2 deploy path; live pool verified uninitialized
    2026-07-03), **71/71**:
    [run](https://stxer.xyz/simulations/mainnet/ebd1f4048b58612d5f27012a6258f847).
    Adds to the v1 arc: frontier partial (4,800 STX → C full + exactly half of
    B, A untouched), a 1-uSTX micro fill taking a floor'd 714 uMIA, three split
    settles conserving v1's exact totals (12,900 STX / 9M MIA, every maker paid
    their full ask across split fills), cancel-after-partial refunding exactly
    the shrunken remainder, the escrow invariant (fair-v2 MIA balance ==
    `surplus-mia` to the digit with an empty book), `get-book-totals`
    before/after each settle, and the DEPOSITOR rewiring guard (direct
    `initialize-pool` on single-v2 → u403; only fair-v2 seeds the vault).
  - `npm run sim:orderbook` — **mia-orderbook-jing** (sBTC sell book, no par)
    deployed on the fork, **58/58**:
    [run](https://stxer.xyz/simulations/mainnet/f94dcfc076a6366c35140fed12529f92).
    Guards (min-deposit, zero/poison ask incl. the MAX_ASK overflow-DoS fix —
    see AUDIT.md O-1 — duplicate offer, no-offer change, non-admin admin
    calls), sort through place / reprice change-offer / add change-offer,
    a marketable-limit taker filling C fully + half of B at B's exact ratio
    with the 10 bps fee on top, a 5M-sat order STOPPING below an above-limit
    offer, a 1-sat dust fill (fee floors to 0), self-offer skip, pause (all
    three mutating entrypoints gated, cancel still refunding while paused),
    cancel-after-partial, and sat-exact maker/taker/fee-recipient deltas with
    the escrow == book invariant checked at every stage.

## Build & test
```bash
clarinet check      # type-check the contracts
npm install
npm test            # unit + integration suites (vitest + Clarinet SDK simnet)
npm run fuzz        # all twelve rendezvous fuzz targets (or rv:<contract>:<mode>, e.g. rv:orderbook:test)
```

Testing notes:
- Unit suites fund mainnet-pinned tokens via simnet console commands
  (`::mint_ft`, `::mint_stx`) and deploy the trio under the fak.fun deployer
  address where the cross-contract wiring requires it (simnet cannot
  impersonate contract principals).
- Fuzzing runs in the isolated [`rendezvous/`](./rendezvous) project with four
  documented test-only patches (deposit gate, lock length, pool gate, MIA
  faucet).
