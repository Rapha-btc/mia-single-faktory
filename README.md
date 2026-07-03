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
| **`mia-fair-faktory.clar`** | 5 / epoch 3.4 | Fork of ccd014. Permissionless, **caller-funded** `settle-offers`; the settler gets only par-equiv MIA, the below-par **spread** is retained in `surplus-mia`; `seed-single-sided` pushes it into the offering. NOT a DAO extension (admin-gated `initialize`/`seed`; no treasury payout, no `revoke-delegate-stx`). Par computed self-contained at init from live MIA v1+v2 supply + mining treasury. `current-contract` + `as-contract?` post-conditions on every MIA payout. |
| **`mia-single-faktory.clar`** | 5 / epoch 3.4 | Single-sided offering. `DEPOSITOR` (= `mia-fair-faktory`) seeds MIA **repeatably** (clock anchored on the first seed). Community supplies only sBTC — **no entry deadline** (open while the contract holds unpaired MIA). ~90-day lock; on unlock the user keeps **60%** of their LP, the other **40% stays locked in the pool forever**. `current-contract` + `as-contract?`. |
| **`mia-pool-faktory.clar`** | 3 / epoch 3.4 | MIA(v2)/sBTC constant-product AMM — **verbatim** port of `flatearth-faktory-pool-v2` (battle-tested Clarity-3 template) aside from the token/LP swap. `initialize-pool` does **not** auto-approve a swap caller, so swaps stay **gated** until the admin opens them — the anti-imbalance lever while the single-sided offering takes deposits. |

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
- **CCIP-026 is not yet deployed on mainnet** — so par is computed self-contained (live supply + treasury), not read from the DAO.

Design notes live in [`DECISIONS.md`](./DECISIONS.md).

## Status
- `clarinet check` → **✔ 3 contracts checked** (clarinet 3.19 and 3.21).
- Not deployed. No tests or UI yet (next: stxer sim + Clarinet SDK tests, then the simple UI).

## Build
```bash
clarinet check
```
