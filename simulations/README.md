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

## deploy notes

- Deploy `stx-to-stx-mia-faktory-v2` under SPV9K21 at **Clarity 5**
  (mainnet rejects 6); `.mia-fair-faktory-v2` resolves to the live book.
- The v1 machine winds down on its own: it holds 8,187.134502 MIA escrow
  (the "14 STX") which redeems at the next ccd013 tranche via anyone's
  `settle-and-redeem(u0)`, withdrawable only by `SP3KJB...`.
- Rerun `node simulations/verify-v2-machine.js` before deploying if days
  have passed - CLEANUP (30,000 STX) must stay above the live book's
  total asks (~13,400 at authoring).
