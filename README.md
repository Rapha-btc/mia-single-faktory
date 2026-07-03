# mia-single-faktory

Standalone contracts for the **Fast Pool whitehat-MEV** loop on the CityCoins
MIA burn-to-exit market, plus a **single-sided MIA/sBTC pool** on fak.fun that
recycles the arb MIA into community liquidity.

## The idea (from the Rapha ↔ Friedger design thread)

CCD014 (`ccd014-fair-burn-to-exit-mia`) runs an **offer book**: MIA holders
escrow MIA and bid at or below **par** (the frozen ratio, currently **1710 STX
per 1M MIA**) to exit early. Today two bots race to `settle-offers`, capturing
the book-vs-market spread. Fast Pool already receives the mining reward STX
(~16.7k STX/cycle) and can settle the book itself:

- **Read the book first.** If there is escrowed MIA bidding *below* par, run the
  loop; otherwise don't bother. No mempool guessing — it only acts when the
  profit is already sitting there.
- **Settle with Fast Pool's STX** instead of burning against the DAO treasury,
  and **acquire** the MIA rather than burning it.
- Fast Pool stays **neutral in MIA terms** (it swaps reward STX for the
  par-equivalent MIA). The **below-par surplus** — the arb — is *not* kept as
  profit (Fast Pool earns its fees elsewhere). Instead it becomes the MIA side
  of a **single-sided pool** on fak.fun.
- MIA now has **two pools** — STX pair on Alex, sBTC pair on fak.fun — which
  gives bots a *sustainable* arb source instead of the one-shot book scoop.

## Contracts

### `contracts/reference/` — unmodified copies, for diffing only (not deployed)
| file | source |
|---|---|
| `ccd014-fair-burn-to-exit-mia.clar` | CCIP-026 PR #7 — the offer-book redemption we amend |
| `ccd013-burn-to-exit-mia.clar` | the fixed-rate base it extends |
| `flat-single-faktory.clar` | `SPV9K21…flat-single-faktory` — the single-sided LP template |
| `flatearth-faktory-pool-v2.clar` | `SPV9K21…flatearth-faktory-pool-v2` — the AMM pool template |

### To be built (the standalone set)
- **`mia-single-faktory.clar`** — amended CCD014: Fast-Pool-funded `settle-offers`,
  MIA acquired (not burned), surplus routed to the single-sided pool.
- **`mia-sbtc-single.clar`** — single-sided offering (MIA provided by the arb,
  users bring sBTC, ~3-month lock, 60/40 unlock split).
- **`mia-sbtc-pool.clar`** — the MIA/sBTC AMM (pool-v2 shape) underneath.

## Key on-chain facts (mainnet, verified)
- Redemption ratio (par): **1710** → `uMIA = uSTX * 1e6 / 1710`.
- CCD013 cumulative: 934.28M MIA burned for 1,597,626 STX (confirms 1710/1M).
- MIA mining treasury: ~10.24M STX; ~16,772 STX/cycle reward.
- pox-5 lands in ~2–3 cycles (end of month), which changes the reward game — so
  this is a short-horizon play; build it correct and simple.
