#!/usr/bin/env bash
# Build the rendezvous/ fuzzing project: each contract copy = the real source
# + the matching fuzzing harness from rendezvous/harnesses/ (rendezvous 1.x
# expects tests INSIDE the contract), with the TEST-ONLY patches documented in
# rendezvous/README.md. Run before rv.
set -euo pipefail
cd "$(dirname "$0")/.."

for c in mia-pool-faktory mia-single-faktory mia-fair-faktory; do
  cat "contracts/$c.clar" "rendezvous/harnesses/$c.tests.clar" \
    > "rendezvous/contracts/$c.clar"
done

# PATCH 1 (mia-single-faktory): DEPOSITOR -> the simnet deployer WALLET so the
# fuzzer can exercise initialize-pool/top-ups organically. It must stay a
# standard principal: a contract principal would create a fair<->single
# dependency cycle in clarinet's deployment ordering. The real contract-to-
# contract seed path (fair -> single) is covered by the vitest suites.
sed -i "s/'SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22\.mia-fair-faktory/'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM/" \
  rendezvous/contracts/mia-single-faktory.clar

# PATCH 2 (mia-single-faktory): shorten the ~90-day lock so fuzz runs reach the
# unlock path organically (each simnet block is one burn block).
sed -i 's/(define-constant LOCK_PERIOD u12960)/(define-constant LOCK_PERIOD u25)/' \
  rendezvous/contracts/mia-single-faktory.clar

# PATCH 3 (mia-pool-faktory): the pool starts opened so single-sided deposits
# can bootstrap it while fuzzing mia-single-faktory. The open/close gate itself
# is covered by the vitest unit tests.
sed -i 's/(define-data-var pool-opened bool false)/(define-data-var pool-opened bool true)/' \
  rendezvous/contracts/mia-pool-faktory.clar

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

echo "rendezvous/contracts synced (3 contracts, 4 test-only patches)"
