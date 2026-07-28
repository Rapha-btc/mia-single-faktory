# stx-to-stx simulations: the wrapper and the v2 machine

Context: on 2026-07-13, Friedger's redeem left 15,100 STX resting in
`stx-to-stx-mia-faktory` between two transactions (his rewards address
`SP21..FFP` could trigger the redeem, but only the hardcoded admin
`SP3KJB...` could withdraw). In the gap, a third party's permissionless
trigger spent 14 STX of it buying an 8,400 MIA exit - correct machine
behavior, but it exposed three design gaps. The wrapper was the quick fix;
the v2 machine incorporates everything natively. Both were verified on
stxer mainnet forks against the LIVE fair book, ccd013, and real balances
before any deploy.

## verify-wrapper.js - the atomic driver (superseded by v2)

`contracts/stx-to-stx-wrapper.clar`: one tx = deposit -> up to 5
settle/redeem cycles -> withdraw remainder. Callable only by the machine's
hardcoded admin (the machine's `FASTPOOL` is a constant - a wrapper cannot
grant `SP21..FFP` anything, which is why v2 exists).

Runs:

- https://stxer.xyz/simulations/mainnet/ee38d53e114a74976cdfb25cf48b6920 -
  first run; discovered FASTPOOL's live balance is ~11.58 STX (deposits
  failed `u1`), i.e. the fork mirrors reality hard enough to catch ops
  assumptions, not just code.
- https://stxer.xyz/simulations/mainnet/d05f6bef44c970c9b0dcafe27b8496ce -
  funded run, 24/28. The 4 misses were live-book drift between authoring
  and execution (a fresh 1,000-STX offer appeared and was correctly
  bought) plus 3 uSTX of floor dust - the contract logic itself passed
  everything: gates, loop across offers with recycled capital, exact
  seller payouts, machine ending 0 STX / 0 MIA, whole book consumed, and
  the stranded 14 STX recovered inside a run.

Verdict: mechanics proven; do not deploy - v2 folds this in.

## verify-v2-machine.js - stx-to-stx-mia-faktory-v2 (29/29)

`contracts/stx-to-stx-mia-faktory-v2.clar`, the redeploy candidate. The
fair book is NOT redeployed: coupling is one-directional and
`settle-offers` is settler-agnostic, so live offers and the surplus pool
carry over untouched.

Fixes proven, one act each:

- **F-1 operator allowlist** (`SP3KJB...` admin + `SP21..FFP` rewards):
  strangers get `u9000` on `run()` and on deposits; SP21 drives a full
  deposit->loop->withdraw run end-to-end - the exact thing v1 forbade.
- **F-2 atomic run()**: 3,100 STX deposit consumed 5,800 STX of book
  offers by recycling through redemption (whole offers only, cheapest
  first), both sellers received exactly their asks, and the machine ended
  every run at 0 STX / 0 MIA. SP21's net cost for eating 5,800 STX of
  book: 2 uSTX of floor dust.
- **F-3 treasury guard**: settle budget = min(balance, live ccd013
  redemption headroom). Against a dry treasury a 2,000 STX deposit
  boomeranged exactly (v1 would have stranded it as MIA escrow), and a
  bare trigger failed honestly with `u9002 NOTHING_TO_DO`.
- **F-4 withdraw-to-caller**: the run's remainder landed on the calling
  operator (SP21), not a hardcoded recipient.
- **F-5 deposit-free settle-and-redeem**: the bare trigger stays
  permissionless but no longer takes an amount - capital only enters via
  run(), which cannot finish without attempting the withdraw. Closes the
  last deposit-here-withdraw-later path.

Final interface: run(amount) = deposit -> ONE cycle -> withdraw;
run-loops(amount, cycles<=5) = the capital-recycling variant;
settle-and-redeem() = permissionless bare trigger, no deposit.

Runs (chronological):
- https://stxer.xyz/simulations/mainnet/4a689c4cbab6c3193002a0ebff351587 -
  29/29, draft with unconditional 5-cycle run(), pre-F-5.
- https://stxer.xyz/simulations/mainnet/bc705b22dea99b5ab0aaea6620ee282c -
  28/28, F-5 added (deposit-free settle-and-redeem).
- https://stxer.xyz/simulations/mainnet/3aabee74d505840b5e0bb3193b8099ef -
  intentional-looking accident: the harness still called single-cycle
  run() for the loop act, which VALIDATED run()'s one-cycle semantics
  (offer A filled, offer B partial-filled from leftover budget - the
  deployed fair-v2 partial-fills the frontier offer - one redeem,
  remainder boomeranged, machine 0/0).
- https://stxer.xyz/simulations/mainnet/169da2ae1139fb2a9806fd225e4f19eb -
  **29/29 FINAL**: run/run-loops split, both gates checked, cleanup and
  the recycle act via run-loops(_, u5). GREEN.

Fork setup both harnesses use: fund actors via `addSTXTransfer` (FASTPOOL
holds ~11.58 STX live), open redemption headroom by calling the rewards
treasury's public `deposit-stx` (ccd013's `get-redemption-current-balance`
is literally that contract's STX balance), and clear the drifting live
book with a big run before exact-math acts so expectations depend only on
offers the sim places.

## verify-migrate.js - stx-to-stx-migrate (15/15)

`contracts/stx-to-stx-migrate.clar`: one-tx lifecycle closer, deployed
AFTER v2. In a single fastpool.btc-signed transaction: churn the OLD
machine (redeeming its stranded 8,187.134502 MIA escrow when the treasury
allows), withdraw the old machine's STX, and run-loops on v2 with
recovered + extra capital. Without this, the 14 STX can never reliably
leave v1: any standalone redeem parks STX there, where the next trigger's
settle re-strands it (v1 has no treasury guard and no auto-withdraw).

Two entry points:
- migrate-and-run(extra, cycles): churn old + withdraw old (FASTPOOL leg)
  + v2 run-loops. fastpool.btc's full collect.
- churn-and-run(extra, cycles): churn old WITHOUT the withdraw - the
  redeemed ~14 STX PARKS in the old machine - + v2 run-loops. Lets
  SP21..FFP consume a tranche the moment its reward flow funds one; the
  parked STX is re-strandable by old-machine triggers while headroom
  remains (accepted trade), collected later by fastpool.btc.

Runs:
- https://stxer.xyz/simulations/mainnet/2bebc3977adf0ce2a63ad450cd1af557 -
  15/15, migrate-and-run only.
- https://stxer.xyz/simulations/mainnet/9ebead89997b1b8ee2a00f190a4a92a3 -
  **20/20 FINAL**, the full two-wallet lifecycle (re-verified fresh
  2026-07-13 evening: 5c75f0f0..., 20/20): strangers revert on both
  entry points; SP21 churn-and-run parks exactly u13999999 in the old
  machine and runs v2 with fresh capital; fastpool.btc migrate-and-run
  collects the parked 14 (recovered u13999998 - 1 uSTX of churn dust) and
  finishes the book; SP21 post-drain path reports old-parked u0.
  FASTPOOL net +13,999,995 uSTX; every machine ends 0/0.

## verify-v2-scenarios.js - edge-scenario suite (33/33)

Six states the happy path never reaches:

- S1 cycle-cap abuse: run-loops(u0, u99) is a harmless no-op (unroll caps at 5)
- S2 parity: run(X) returns byte-identical results to run-loops(X, u1)
- S3 partial treasury: with 2,000 headroom against a 3,000 ask, F-3 caps the
  settle to EXACTLY the headroom via fair-v2's frontier partial fill; the
  book keeps the remainder; stranded MIA is sub-0.001-MIA rounding dust
- S4 redeem-cap spillover: two 7M offers summed in one settle exceed the
  10M-per-redeem cap while the treasury drains mid-run - the ONE state
  where v2 legitimately ends holding MIA (1,695,906.43 MIA here), and
  conservation holds exactly: deposited == withdrawn + par(escrow)
- S5 donation sweep: naked STX sent to the machine comes out via run(u0)
  even with a dry treasury, without touching the escrow
- S6 withdraw gates: strangers get u9000 on withdraw-stx / withdraw-mia

Found along the way: fair-v2's place-offer caps single offers at 10M MIA
(u13013), so no single offer can exceed the redeem cap - spillover needs
multiple offers in one pass. And partial fills leave <= ~600 uMIA dust in
the machine (5 orders of magnitude below one MIA).

Run: https://stxer.xyz/simulations/mainnet/fced328476d1a5713e29e9ec621fb8d5
- 33 passed, 0 failed.

## reading the sim transactions

The individual transactions inside each stxer session (e.g. the SP21
churn-and-run or the fastpool migrate-and-run) can be opened in the stxer
viewer and read event-by-event like real txs - same explorer format, same
event logs. NOT MAINNET: v2 and migrate are not deployed yet; every tx id
from these sessions is fork-only. UI sizing note: inputs up to ~17,100 STX
(10M MIA at par, the per-cycle redeem cap) always end a run with an empty
machine; larger runs may roll redeemable MIA to the next run if the
treasury drains mid-run (S4) - safe, visible in the result, self-healing.

## deploy notes

- Deploy `stx-to-stx-mia-faktory-v2` then `stx-to-stx-migrate` under
  SPV9K21 at **Clarity 5** (mainnet rejects 6); relative refs resolve to
  the live book / live v1 / freshly deployed v2.
- The v1 machine winds down on its own: it holds 8,187.134502 MIA escrow
  (the "14 STX") which redeems at the next ccd013 tranche via anyone's
  `settle-and-redeem(u0)`, withdrawable only by `SP3KJB...`.
- Rerun `node simulations/verify-v2-machine.js` before deploying if days
  have passed - CLEANUP (30,000 STX) must stay above the live book's
  total asks (~13,400 at authoring).

## mia-burn-and-run

`burn-and-run(umia, ustx, cycles)` burns the CALLER's leftover MIA through
ccd013, then runs `stx-to-stx-mia-faktory-v2.run-loops` in up to 5 capped
passes - both legs in ONE transaction, so there is no gap for a racer to
take the headroom the burn frees. Born from cycle 139 (0x491e1f6c,
5,526.232964 STX taken two blocks later).

DEPLOYED 2026-07-28 at burn 960,027, tx `0xb06bd4d5c6eda48234c6f060fae496b2bd4d2635509728e8ebfcbcc0dd2a6581`
-> `SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.mia-burn-and-run`, Clarity 5,
1,422 bytes, source sha256 `68d9c6c6188ba027...` (verified byte-identical
to `contracts/mia-burn-and-run.clar`).

All three harnesses use the same live state: fair-v2 book 34,270,999.305234
MIA asking 54,275.3936 STX, machine empty, ccd013 redemption balance **0**
(so every run funds `ccd002-treasury-mia-rewards-v3.deposit-stx` first),
FASTPOOL holding 3,231,716.020625 MIA and 11.667164 STX. The burn amount is
exactly what he withdrew at burn 959,973 (`withdraw-mia u3231715183625`).

### verify-burn-and-run.js - thin treasury, the literal ask

Treasury funded to EXACTLY 17,100 STX, then burn + 5 cycles.

Run: https://stxer.xyz/simulations/mainnet/dbb762b1f32ca6ab6854e60db0c09f60
- 12 passed, 1 failed (the failure is the assertion, not the contract - see
  the dust note below).

Shows that the two legs COMPETE for one treasury: the burn takes 5,526.232963
out first, leaving only 11,573.767037 for the settle pass, so just that much
book clears and the treasury ends at 0. For a FULL 17,100 pass after the burn
you need 22,626.23 in the treasury - which is exactly the `run u22626232964`
SP21..FFP fired at burn 959,970. Act B tops up by 30,000 and clears a further
30,000 STX of offers, returning the whole float.

Dust: 584 uMIA (0.000584 MIA, worth 0.000999 STX) stays in the machine. Cause
is a starved treasury, not a flaw - the last passes ran on a 1 uSTX budget,
and both the par-equiv and the redemption floor their integer division, so a
sub-unit pass acquires slightly more MIA than it can redeem. It never happens
with real headroom (see below), and any operator can `withdraw-mia` it.

### verify-burn-and-run-full.js - fat treasury, the loop actually recycles

Treasury funded to 100,000 STX (deliberate overkill), then burn + 5 cycles.
Takes an optional `[umia]` argv - pass `0` to skip the burn leg.

Run (burn): https://stxer.xyz/simulations/mainnet/c0dcd1fa876be2e3ce8460c83543d277
- 10 passed, 0 failed.
Run (umia = 0): https://stxer.xyz/simulations/mainnet/140f378386888ea38858cdd7985ce6a2
- 10 passed, 0 failed.

```
book consumed        54,275.3936 STX of offers  ->  book EMPTY (0 offers)
passes implied       3.17 x 17,100
treasury drained     59,801.626562 STX   (5,526.23 paid for his burn
                                          + 54,275.39 paid for the machine's)
treasury left over   40,198.373438 STX
FASTPOOL net         +5,526.232962 STX   float returned, gain == burn proceeds
fair-v2 surplus      +2,531,003.047925 MIA
machine after        0 STX, 0 MIA        (no dust - every pass had real headroom)
```

Three things this pins down:

- **The float recycles.** 17,100 STX of float cleared 54,275 STX of book -
  3.17x its own size, because each pass's redemption funds the next.
- **Over-asking on `cycles` is safe.** `get-plan` returned `cycles u5`, ~4
  were useful, the 5th found an empty book and no-oped through `(ok none)`
  on both legs. Result still `(ok ...)` with the full withdrawal.
- **The limiting factor flips.** Thin treasury -> the treasury caps you. Fat
  treasury -> the BOOK does: 5 passes could absorb 85,500 STX and the whole
  live book is only 54,275.

The `umia = 0` run confirms `maybe-burn`'s `(if (> umia u0) ... (ok false))`
guard: the ccd013 call is skipped entirely rather than erroring, so the same
entry point works on a cycle with no rollover MIA. Run leg is identical either
way; the only delta is the 5,526.23 STX the treasury pays him for his own MIA,
which is his to claim whether or not he runs the machine. The cleanup itself
costs him nothing but the fee.

### verify-burn-and-run-deployed.js - the live bytecode

Same scenario as `-full`, with NO deploy step, so it exercises the exact
contract fastpool will call.

Run: https://stxer.xyz/simulations/mainnet/f696f4c5181fd6be22d6d5e3e6a68d44
- 10 passed, 0 failed, numbers identical to the pre-deploy run.

### operating it

`get-plan(who)` returns what to pass: `umia` = the caller's full MIA balance,
`ustx` = 17,100 STX (the ceiling: 10M MIA, the ccd013 per-call cap, priced at
the frozen ratio 1710), `cycles` = treasury / ceiling rounded up, capped at 5.
`redeems-first` previews how much the burn leg will take out of the treasury
before the run leg sees it - i.e. `min(what your MIA is worth, what the
treasury can pay)`.

**The mainnet redemption treasury is 0 as of burn 960,020.** With a dry
treasury `burn-and-run` still succeeds but no-ops: no burn payout, no settle,
float straight back. It does real work only on a tranche day.
