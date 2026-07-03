# mia-single-faktory

A **whitehat exit auction** for CityCoins MIA that spins up a **new sBTC market
for MIA** on fak.fun — anyone can provide sBTC single-sided and earn a bonus.

## How it works (plain version)

**1. An exit auction for MIA holders.** Holders who want out early escrow MIA
and name a price at or below par (~**1710 STX / 1M MIA**). Settlement fills the
**cheapest — most-in-pain — offers first**, first-come-first-serve on ties. The
people most eager to exit get prioritized at the rate they'll accept, instead of
a flat rate that just rewards whoever's fastest.

**2. Fast Pool settles it as a whitehat.** Today bots race to capture the gap
between those below-par offers and par. Fast Pool settles the book itself: it
pays offers from its own STX and only ever recovers the *par-equivalent*, so it
takes **no profit**. The **below-par spread** (the discount sellers accepted) is
captured by the contract instead of a bot.

**3. That spread opens a single-sided sBTC pool.** The captured MIA seeds a
**MIA/sBTC pool on fak.fun** that anyone can join by supplying **only sBTC**:
- The MIA side is already there (from the captured spread) — you bring just sBTC.
- Your position is locked **~3 months**.
- On unlock you keep **60% of your LP** — a **20% bonus** over the 50% a fair
  split would return (the extra is subsidized by the arb's MIA). It's an LP
  position, so it tracks the MIA/sBTC pool.
- The other **40% stays in the pool permanently**, deepening the market.

**4. Why it matters.** MIA now trades in **two venues** — STX on Alex and sBTC
on fak.fun — opening a standing arbitrage loop between them. That gives bots a
*sustainable* source of activity instead of a one-shot book scoop, and means
more liquidity and price discovery for MIA. Short horizon: pox-5 lands in ~2–3
cycles and changes the reward game.

*Origin: CityCoins Discord — DerekS.btc proposed a below-par burn auction, Rapha
reframed it to prioritize the most-in-pain exits, built on top of Friedger's
CCIP-026.*

## Contracts (`contracts/`)

Deploy order is **pool → single → fair**.

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
