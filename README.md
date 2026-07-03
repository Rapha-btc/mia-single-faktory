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

## Verification

- `clarinet check` → ✔ 3 contracts (repo manifest at Clarity 6 / epoch 4.0 for analysis).
- **68 unit tests** (Clarinet SDK + vitest) green, including a full
  end-to-end run of the auction → seed → deposit → gate → 60/40 unlock story.
- **Fuzzed with Rendezvous 1.x**: 3 contracts × property + invariant modes,
  zero failures (see [`rendezvous/README.md`](./rendezvous/README.md)); audit +
  dispositions in [`AUDIT.md`](./AUDIT.md).
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

## Build & test
```bash
clarinet check      # type-check the contracts
npm install
npm test            # unit + integration suites (vitest + Clarinet SDK simnet)
npm run fuzz        # all six rendezvous fuzz targets (or rv:<contract>:<mode>)
```

Testing notes:
- Unit suites fund mainnet-pinned tokens via simnet console commands
  (`::mint_ft`, `::mint_stx`) and deploy the trio under the fak.fun deployer
  address where the cross-contract wiring requires it (simnet cannot
  impersonate contract principals).
- Fuzzing runs in the isolated [`rendezvous/`](./rendezvous) project with four
  documented test-only patches (deposit gate, lock length, pool gate, MIA
  faucet).
