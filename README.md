# mia-single-faktory

Standalone contracts for the **Fast Pool whitehat-MEV** loop on the CityCoins
MIA burn-to-exit market, plus a **single-sided MIA/sBTC pool** on fak.fun that
recycles the arb MIA into community liquidity.

## The idea (Rapha ↔ Friedger design thread)

CCD014 (`ccd014-fair-burn-to-exit-mia`) runs an **offer book**: MIA holders
escrow MIA and bid at or below **par** (the frozen redemption ratio, ~**1710 STX
per 1M MIA**) to exit early. Today two bots race to settle the book. Fast Pool
already receives the mining-reward STX (~16.7k STX/cycle) and can settle it
itself, as a **whitehat** rather than for profit:

- **Read the book first.** Only act when there's escrowed MIA bidding *below*
  par — no mempool guessing, the profit is already sitting there.
- **Settle with the caller's own STX** (not the DAO treasury), and **acquire**
  the MIA instead of burning it.
- The settler receives only the **par-equivalent** of the STX they spent — i.e.
  they buy MIA *at par* (~1710), which is above market (~1027), so settling is
  deliberately unprofitable: anyone may do it, but only a whitehat will.
- The below-par **spread** is captured and accumulates, then seeds the MIA side
  of a **single-sided pool** on fak.fun where the community supplies only sBTC.
- MIA gains a **second pool** (STX on Alex + sBTC on fak.fun) → a sustainable
  arb source for bots instead of a one-shot book scoop. Short horizon: pox-5
  lands in ~2–3 cycles and changes the reward game.

## Contracts (`contracts/`)

Deploy order is **pool → single → fair** (`mia-fair-faktory` calls into
`mia-single-faktory`; the single-sided references the accumulator only as a
value, so no cycle).

| contract | clarity | role |
|---|---|---|
| **`mia-fair-faktory.clar`** | 5 / epoch 3.4 | Fork of ccd014. Permissionless, **caller-funded** `settle-offers`; settler gets par-equiv MIA, the below-par **spread** is retained in `surplus-mia`; `seed-single-sided` pushes it into the offering. NOT a DAO extension (admin-gated `initialize`/`seed`; no treasury payout, no `revoke-delegate-stx`). Par computed self-contained at init from live MIA v1+v2 supply + mining treasury. `current-contract` + `as-contract?` post-conditions on every MIA payout. |
| **`mia-single-faktory.clar`** | 5 / epoch 3.4 | Single-sided offering. `DEPOSITOR` (= `mia-fair-faktory`) seeds MIA **repeatably** (clock anchored on the first seed). Community supplies only sBTC — **no entry deadline** (open while the contract holds unpaired MIA). ~90-day lock; on unlock the user keeps **60%** of their LP, the other **40% stays locked in the pool forever**. `current-contract` + `as-contract?`. |
| **`mia-pool-faktory.clar`** | 3 / epoch 3.4 | MIA(v2)/sBTC constant-product AMM — **verbatim** port of `flatearth-faktory-pool-v2` (battle-tested Clarity-3 template) aside from the token/LP swap. `initialize-pool` does **not** auto-approve a swap caller, so swaps stay **gated** until the admin opens them — the anti-imbalance lever while the single-sided offering takes deposits. |

Only MIA **v2** is used for trading/escrow (v1 appears solely in the init par
computation).

### `contracts/reference/` — unmodified on-chain copies, for diffing only (not built)
| file | source |
|---|---|
| `ccd014-fair-burn-to-exit-mia.clar` | CCIP-026 PR #7 — the offer-book redemption we fork |
| `ccd013-burn-to-exit-mia.clar` | the fixed-rate base it extends |
| `flat-single-faktory.clar` | `SPV9K21…flat-single-faktory` — the single-sided template |
| `flatearth-faktory-pool-v2.clar` | `SPV9K21…flatearth-faktory-pool-v2` — the AMM template |

## Key on-chain facts (mainnet, verified)
- Redemption ratio (par): **1710** → `uMIA = uSTX * 1e6 / 1710`.
- CCD013 economics (from sim/live state): 934.28M MIA burned for 1,597,626 STX (confirms 1710/1M).
- MIA mining treasury (`ccd002-treasury-mia-mining-v3`): ~10.24M STX; ~16,772 STX/cycle reward.
- MIA v2: `SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2`; sBTC: `SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token`.
- **CCIP-026 is not yet deployed on mainnet** — so par is computed self-contained (live supply + treasury), not read from the DAO.

## Status
- `clarinet check` → **✔ 3 contracts checked** (clarinet 3.19 and 3.21).
- Not deployed. No tests or UI yet (next: stxer sim + Clarinet SDK tests, then the simple UI).

## Build
```bash
clarinet check
```
