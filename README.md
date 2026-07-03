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
| **`mia-fair-faktory.clar`** | 6 / epoch 4.0 | Fork of ccd014. Permissionless, **caller-funded** `settle-offers`; the settler gets only par-equiv MIA, the below-par **spread** is retained in `surplus-mia`; `seed-single-sided` pushes it into the offering. NOT a DAO extension (admin-gated `initialize`/`seed`; no treasury payout, no `revoke-delegate-stx`). Par computed self-contained at init from live MIA v1+v2 supply + mining treasury. `current-contract` + `as-contract?` post-conditions on every MIA payout. A settler's own resting offer is always kept, never self-filled (AUDIT F-2). |
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

## Key on-chain facts (mainnet, verified)
- Redemption ratio (par): **1710** → `uMIA = uSTX * 1e6 / 1710`.
- CCD013 economics (sim/live): 934.28M MIA burned for 1,597,626 STX (confirms 1710/1M).
- MIA mining treasury (`ccd002-treasury-mia-mining-v3`): ~10.24M STX; ~16,772 STX/cycle reward.
- MIA v2: `SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2`; sBTC: `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token`.
- Par is computed self-contained at init (live MIA supply + mining treasury).

Design notes live in [`DECISIONS.md`](./DECISIONS.md); the structured contract
review lives in [`AUDIT.md`](./AUDIT.md).

## Status
- Clarity **6** / epoch **4.0** (clarinet 3.21); `clarinet check` → ✔.
- **68 unit tests** (Clarinet SDK + vitest) green, including a full
  end-to-end run of the auction → seed → deposit → gate → 60/40 unlock story.
- **Fuzzed with Rendezvous 1.x**: 3 contracts × property + invariant modes,
  zero failures (see [`rendezvous/README.md`](./rendezvous/README.md)).
- Not deployed. No UI yet (next: stxer sim, then the simple UI).

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
