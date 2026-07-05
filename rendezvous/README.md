# Rendezvous fuzzing project

An isolated Clarinet project for fuzzing the six contracts (v1 trio, the
v2 partial-fill pair, and the mia-orderbook-jing sBTC sell book) with
[Rendezvous (`rv`) 1.x](https://github.com/stx-labs/rendezvous). Run from the
repo root:

```bash
npm run rv:fair:invariant     # random call sequences vs. state invariants
npm run rv:fair:test          # property-based tests with fuzzed arguments
npm run rv:single:invariant     npm run rv:single:test
npm run rv:pool:invariant       npm run rv:pool:test
npm run rv:fair-v2:invariant    npm run rv:fair-v2:test
npm run rv:single-v2:invariant  npm run rv:single-v2:test
npm run rv:orderbook:invariant  npm run rv:orderbook:test
npm run fuzz                  # all twelve
```

Every script first runs `scripts/rv-sync.sh`, which **generates**
`rendezvous/contracts/*.clar` as *real contract source + fuzzing harness*
(rv 1.x expects tests inside the contract) and applies the test-only patches
below. Never edit the generated files — edit `contracts/*.clar` (the real
contracts) or `rendezvous/harnesses/*.tests.clar` (the fuzz harnesses).

## Test-only patches (scripts/rv-sync.sh)

1. **both singles: `DEPOSITOR` -> the simnet deployer wallet.** Mainnet
   pins the fak.fun deployer's fair contract; simnet cannot impersonate
   contract principals, and a contract-principal patch would create a
   fair<->single dependency cycle in clarinet's deploy ordering. The real
   contract-to-contract seed path is covered by `tests/*.test.ts`, which
   deploys the trio under the fak.fun address.
2. **both singles: `LOCK_PERIOD` u12960 -> u25** so fuzz runs organically
   cross the unlock boundary (each simnet block advances the burn height).
3. **mia-pool-faktory: `pool-opened` starts `true`** so deposits can bootstrap
   the pool during single-target runs (the open/close gate itself is
   unit-tested).
4. **`.cache` MIA v2 token copy gains an open `rv-faucet`** — the mainnet mint
   is auth-gated, so fuzz wallets could never obtain MIA otherwise. The
   patched copy lives only in this project's cache and is never deployed
   anywhere. (sBTC needs no faucet: simnet pre-funds every wallet with
   10 sBTC.)
5. **both fairs: `initialize` freezes par at the mainnet-verified u1710**
   instead of copying it from ccd013. The simnet copy of ccd013 deploys
   un-initialized (ratio u0, disabled), so the real copy-from-live call would
   silently leave `redemptions-enabled` false and every fair property and
   invariant would be vacuously discarded (and clarinet/rv resolution of the
   unlisted ccd013 dependency flip-flopped with Hiro rate limits). The
   patched copy behaves exactly like the initialized mainnet deployment.

## What is checked

Harnesses live in `harnesses/<contract>.tests.clar`; each also carries the
rv `context`/`update-context` bookkeeping required by invariant mode.

**mia-fair-faktory** — invariants: book sorted ascending by price
(cross-multiplied), contract MIA == open offers + surplus (strict equality),
no ask above par, one offer per owner, cumulative settled >= par-equivalent of
cumulative spent. Properties: place-offer escrows exactly and keeps the book
sorted; cancel refunds exactly; settle never overspends the budget, pays the
settler exactly par-equivalent (no whitehat profit), and retains the full
spread.

**mia-single-faktory** — invariants: held LP covers all user entitlements,
seeded MIA fully accounted (balance == seeded - paired), pairing never exceeds
the seed, clock anchored in the past. Properties: deposits attribute exactly
the minted LP; withdraw fails before unlock, removes exactly 60% after, and
dust entitlements (60% floors to 0) abort without touching the books.

**mia-pool-faktory** — invariant: reserves stay positive while LP supply
exists. Properties: swaps never decrease x*y; quotes match execution;
add-liquidity mints exactly the requested LP — and for dust whose quoted side
floors to 0, the whole call must revert (**no free LP**); an add/remove round
trip never pays out more than it took in.

**mia-fair-faktory-v2** — same coverage as v1 with two invariants restated
for partial-fill floor rounding, each bounded by the settle-offers call count
read from rv's own invariant-mode `context` map (a real bug still violates
them by economically meaningful margins):
- *sorted book*: a partial fill floors `taken`, so the remainder's implied
  price can dip below its original by < 1 uMIA per settle; a settler's own
  resting offer can sit ahead of it within that dust window.
- *cumulative par coverage*: each partial's floor'd `taken` can trail the
  real-valued par line by < 1 uMIA per settle.

Two v2-only properties: `test-settle-spends-exactly-min` (a settle consumes
EXACTLY min(budget, whole-book cost) — no budget stranded) and
`test-partial-fill-frontier` (a budget below the frontier ask shrinks exactly
that record to `{amount - taken, ask - budget}`, pays the maker at/above
their per-uMIA ask, and touches nothing later). The escrow, par-cap and
one-offer-per-owner invariants remain strict equalities.

**mia-single-faktory-v2** — byte-mirror of the v1 harness (the only v2
source change is the `DEPOSITOR` constant, which PATCH 1 rewrites in both
versions anyway).

### Fuzz trophy

`rv` (seed `1439452765`) surfaced that dust inputs abort with the token's
`(err u3)` whenever a quoted leg floors to zero on skewed reserves — see
AUDIT.md F-10. The revert is the safe behavior; the harness now asserts it.
