#!/usr/bin/env bash
# Build the rendezvous/ fuzzing project: each contract copy = the real source
# + the matching fuzzing harness from rendezvous/harnesses/ (rendezvous 1.x
# expects tests INSIDE the contract), with the TEST-ONLY patches documented in
# rendezvous/README.md. Run before rv.
set -euo pipefail
cd "$(dirname "$0")/.."

for c in mia-pool-faktory mia-single-faktory mia-fair-faktory \
         mia-single-faktory-v2 mia-fair-faktory-v2 mia-orderbook-jing \
         mia-to-mia-faktory stx-to-stx-mia-faktory; do
  cat "contracts/$c.clar" "rendezvous/harnesses/$c.tests.clar" \
    > "rendezvous/contracts/$c.clar"
done

# PATCH 1 (both singles): DEPOSITOR -> the simnet deployer WALLET so the
# fuzzer can exercise initialize-pool/top-ups organically. It must stay a
# standard principal: a contract principal would create a fair<->single
# dependency cycle in clarinet's deployment ordering. The real contract-to-
# contract seed path (fair -> single) is covered by the vitest suites.
# NOTE: the v2 sed pins the full `-v2` suffix -- the v1 pattern would leave
# a dangling `-v2` on the wallet principal.
sed -i "s/'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22\.mia-fair-faktory'/'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM'/;s/'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22\.mia-fair-faktory)/'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)/" \
  rendezvous/contracts/mia-single-faktory.clar
sed -i "s/'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22\.mia-fair-faktory-v2/'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM/" \
  rendezvous/contracts/mia-single-faktory-v2.clar

# PATCH 2 (both singles): shorten the ~90-day lock so fuzz runs reach the
# unlock path organically (each simnet block is one burn block).
sed -i 's/(define-constant LOCK_PERIOD u12960)/(define-constant LOCK_PERIOD u25)/' \
  rendezvous/contracts/mia-single-faktory.clar \
  rendezvous/contracts/mia-single-faktory-v2.clar

# PATCH 3 (mia-pool-faktory): the pool starts opened so single-sided deposits
# can bootstrap it while fuzzing mia-single-faktory. The open/close gate itself
# is covered by the vitest unit tests.
sed -i 's/(define-data-var pool-opened bool false)/(define-data-var pool-opened bool true)/' \
  rendezvous/contracts/mia-pool-faktory.clar

# PATCH 5 (both fairs): initialize copies par from the LIVE ccd013 on mainnet,
# but the simnet copy of ccd013 deploys UN-initialized (ratio u0, disabled), so
# the real call chain would leave redemptions-enabled false and every fair
# property/invariant vacuously discarded (and clarinet/rv resolution of the
# unlisted ccd013 dependency flip-flops with Hiro rate limits). Freeze par at
# the mainnet-verified u1710 instead and drop the enabled probe -- the fuzzed
# contract then behaves exactly like the initialized mainnet deployment.
sed -i 's/(ratio (contract-call? CCD013 get-redemption-ratio))/(ratio u1710) ;; rv PATCH 5: mainnet-verified par (see rv-sync.sh)/;s/(and (contract-call? CCD013 is-redemption-enabled) (> ratio u0))/(> ratio u0)/' \
  rendezvous/contracts/mia-fair-faktory.clar \
  rendezvous/contracts/mia-fair-faktory-v2.clar

# PATCH 4 (requirements cache): the MIA v2 token's mint is auth-gated on
# mainnet, so the fuzzer's wallets could never obtain MIA. Append an open
# TEST-ONLY faucet to the cached copy used by this simnet-only project.
# (sBTC needs no faucet: clarinet's simnet pre-funds every wallet with 10 sBTC.)
if [ ! -d rendezvous/.cache/requirements ]; then
  (cd rendezvous && clarinet check >/dev/null 2>&1 || true)
fi
MIA_CACHE=rendezvous/.cache/requirements/SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2.clar
if [ -f "$MIA_CACHE" ] && ! grep -q rv-faucet "$MIA_CACHE"; then
  cat >> "$MIA_CACHE" <<'EOF'

;; rv TEST-ONLY faucet, appended by scripts/rv-sync.sh for the fuzzing simnet.
;; This modified copy lives only in rendezvous/.cache and is never deployed.
(define-public (rv-faucet (amount uint) (recipient principal))
  (ft-mint? miamicoin amount recipient))
EOF
fi

# PATCH 6 (requirements cache, ccd013): on mainnet ccd013 is initialized
# (par u1710) and pays redemptions out of the DAO rewards treasury, which
# refills only with real PoX cycles. The cached simnet copy deploys
# UN-initialized and its treasury calls fail DAO auth. Make the copy behave
# like the live one: (a) self-initialize at deploy (frozen mainnet par);
# (b) treat the ccd013 contract's OWN STX balance as the treasury (the
# mia-to-mia harness exposes rv-fund-treasury so fuzzer wallets stand in
# for cycle payouts); (c) pay redemptions from that balance directly.
CCD013_CACHE=rendezvous/.cache/requirements/SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia.clar
if [ ! -f "$CCD013_CACHE" ]; then
  (cd rendezvous && clarinet check >/dev/null 2>&1 || true)
fi
if [ -f "$CCD013_CACHE" ] && ! grep -q rv-ccd013-patch "$CCD013_CACHE"; then
  # (b) current balance = ccd013's own balance
  sed -i "s|(stx-get-balance 'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3)|(stx-get-balance 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia)|" "$CCD013_CACHE"
  # (c) pay from own balance instead of the DAO-gated treasury withdraw
  perl -0pi -e "s/\(try! \(contract-call\?\s*'SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH\.ccd002-treasury-mia-rewards-v3\s*withdraw-stx redemption-amount-ustx user-address\s*\)\)/(try! (as-contract? ((with-stx redemption-amount-ustx)) (try! (stx-transfer? redemption-amount-ustx tx-sender user-address))))/s" "$CCD013_CACHE"
  # (a) self-initialize at deploy with the mainnet-verified frozen par
  cat >> "$CCD013_CACHE" <<'EOF2'

;; rv-ccd013-patch: TEST-ONLY, appended by scripts/rv-sync.sh for the
;; fuzzing simnet. Mirrors the initialized mainnet state (par u1710).
(var-set redemption-ratio u1710)
(var-set redemptions-enabled true)
EOF2
fi

# PATCH 7 (both route machines): FASTPOOL (fastpool.btc on mainnet) -> the
# simnet deployer wallet so the fuzzer can reach the deposit legs and the
# beneficiary-exactness properties are checkable.
sed -i "s/'SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X/'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM/" \
  rendezvous/contracts/mia-to-mia-faktory.clar \
  rendezvous/contracts/stx-to-stx-mia-faktory.clar

echo "rendezvous/contracts synced (8 contracts, 7 test-only patches)"
