# Rendezvous fuzzing project

An isolated Clarinet project for fuzzing the three contracts with
[Rendezvous (`rv`) 1.x](https://github.com/stx-labs/rendezvous). Run from the
repo root:

```bash
npm run rv:fair:invariant     # random call sequences vs. state invariants
npm run rv:fair:test          # property-based tests with fuzzed arguments
npm run rv:single:invariant   npm run rv:single:test
npm run rv:pool:invariant     npm run rv:pool:test
npm run fuzz                  # all six
```

Every script first runs `scripts/rv-sync.sh`, which **generates**
`rendezvous/contracts/*.clar` as *real contract source + fuzzing harness*
(rv 1.x expects tests inside the contract) and applies the test-only patches
below. Never edit the generated files — edit `contracts/*.clar` (the real
contracts) or `rendezvous/harnesses/*.tests.clar` (the fuzz harnesses).

## Test-only patches (scripts/rv-sync.sh)

1. **mia-single-faktory: `DEPOSITOR` -> the simnet deployer wallet.** Mainnet
   pins the fak.fun deployer's fair contract; simnet cannot impersonate
   contract principals, and a contract-principal patch would create a
   fair<->single dependency cycle in clarinet's deploy ordering. The real
   contract-to-contract seed path is covered by `tests/*.test.ts`, which
   deploys the trio under the fak.fun address.
2. **mia-single-faktory: `LOCK_PERIOD` u12960 -> u25** so fuzz runs organically
   cross the unlock boundary (each simnet block advances the burn height).
3. **mia-pool-faktory: `pool-opened` starts `true`** so deposits can bootstrap
   the pool during single-target runs (the open/close gate itself is
   unit-tested).
4. **`.cache` MIA v2 token copy gains an open `rv-faucet`** — the mainnet mint
   is auth-gated, so fuzz wallets could never obtain MIA otherwise. The
   patched copy lives only in this project's cache and is never deployed
   anywhere. (sBTC needs no faucet: simnet pre-funds every wallet with
   10 sBTC.)

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

### Fuzz trophy

`rv` (seed `1439452765`) surfaced that dust inputs abort with the token's
`(err u3)` whenever a quoted leg floors to zero on skewed reserves — see
AUDIT.md F-10. The revert is the safe behavior; the harness now asserts it.
