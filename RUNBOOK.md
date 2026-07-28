# Operator runbook: settling the fair book each reward cycle

For whoever settles `mia-fair-faktory-v2` with a Fast Pool reward tranche.
Written after cycle 139 stranded 3.23M MIA and lost 5,526.23 STX of headroom to
a bot. Read the invariant, then use solution 1.

Live numbers are from **2026-07-28**. Re-read them before acting.

---

## The invariant

> **Never let one settle pass buy more MIA than one redeem pass can burn.**

Everything below is a consequence of it.

Three facts collide:

| Fact | Where | Value |
|---|---|---|
| ccd013 burns at most 10M MIA per call | `ccd013.MAX_PER_TRANSACTION` | 10,000,000 MIA |
| The redemption ratio is frozen at init | `ccd013.redemption-ratio` | 1710, i.e. 0.00171 STX/MIA |
| `run` settles **before** it redeems | `stx-to-stx-mia-faktory-v2.run` | buy, then burn |

One redeem pass can therefore only ever return `10,000,000 x 0.00171 = 17,100
STX`. Feed a settle pass more than 17,100 STX of budget and it buys MIA the
very next line of code cannot burn. That surplus does not vanish - it sits in
the machine until the treasury refills a cycle later, and meanwhile the
headroom it should have consumed is free for anyone watching the mempool.

The machine's F-3 guard caps the settle budget by **treasury headroom in STX**.
That is the right guard for a different failure (buying MIA against a dry
treasury). It does not bound the **redeem-side** ceiling, which is denominated
in MIA.

## What cycle 139 actually did

[`0x491e1f6c...`](https://explorer.hiro.so/txid/0x491e1f6cfb6114f91927b85085212ae4b91b27500e08cdba2ca75a9cfef63381?chain=mainnet)

```
send-many          22,626.232964 STX  -> rewards treasury   (same block)
run(u22626232964)
  settle  spends   22,626.232964 STX  -> 5 sellers
          receives 13,231,715.18 MIA  (par-equiv; 3.62M surplus stays in the book)
  redeem  burns    10,000,000.00 MIA  <- capped here
          receives 17,100.00 STX
  finish  withdraws 17,100.00 STX
  leaves            3,231,715.18 MIA  stranded
```

Two blocks later `SP3XKN0MQ...` called `redeem-mia` and took the exact
remaining 5,526.232964 STX of treasury. Nobody lost money - the ratio is
frozen, so the stranded MIA is still worth exactly 5,526.232964 STX - but a
mempool racer got par without ever queueing, which is the specific thing this
book exists to prevent.

**22,626.23 STX of budget was 1.32x the 17,100 ceiling. The overshoot is the
stranded amount, exactly.**

---

## Solution 1 (recommended): the `burn-and-run` bundle

`contracts/mia-burn-and-run.clar`. One transaction:

```clarity
(contract-call? .mia-burn-and-run burn-and-run
  umia      ;; your full MIA balance
  u17100000000
  u4)
```

```
1. redeem-mia(umia)          burns your leftover, pays you, shrinks the treasury
2. run-loops(17,100, cycles) settles and redeems the book in capped passes
```

### Why the constants never need recomputing

Burning first is what makes `RUN_USTX` a **constant rather than a calculation**.
After the burn, the treasury is short by exactly the par value of what you
burned, so the machine's own F-3 guard - `budget = min(balance, headroom)` -
holds pass 1 under the ceiling without being told anything. And passes 2+ are
self-capping regardless: the machine's balance is by then exactly the
redemption proceeds of one capped pass, which cannot exceed 17,100.

Residue-free for **any** tranche size. Traced against a 22,626.23 STX tranche
with 3,231,716.02 MIA in hand:

| step | treasury before | action | treasury after |
|---|---|---|---|
| burn | 22,626.232964 | 3,231,716.02 MIA -> 5,526.234395 STX to you | 17,099.998569 |
| pass 1 | 17,099.998569 | settle 17,099.998569 -> 9,999,999.16 MIA, burn all | **0** |
| pass 2-4 | 0 | no-op through `(ok none)` | 0 |

You deposit 17,100.00 and withdraw 17,100.00 - the float comes back in the same
transaction. Machine empty, treasury empty, one block, nothing to snipe.

Against a larger tranche it just uses more passes: pass 1 takes 17,100, pass 2
takes 17,100, and the last partial pass takes whatever is left. Never a residue,
because `ustx` is pinned at the ceiling.

### The three things to get right

1. **`ustx` must be `<= u17100000000`.** The contract asserts it
   (`ERR_ABOVE_CAP u9100`). Over the cap is the cycle-139 bug again.
2. **Call it from the address holding the MIA**, and have 17,100 STX of float
   in that same address. `redeem-mia` burns from `tx-sender` and the machine's
   `is-operator` check reads `tx-sender`, so one address does both legs. Today
   the rollover MIA sits at `SP3KJBWTS3K...` (admin) while the tranche arrives
   at `SP21YTS...` (rewards) - both are operators, so either works, but the
   MIA and the float have to be in whichever one you call from.
3. **Call it after the `send-many`, in the same block.** With a dry treasury
   the burn leg reverts with `u13008` and takes the whole transaction with it.
   Failing loudly is correct here, but it does mean ordering matters.

`cycles` can always be 4 or 5. Over-asking is free: a pass with no headroom
left no-ops through `(ok none)` on both legs at the cost of a few reads, and
`run-loops` has no `NOTHING_TO_DO` assert - only `settle-and-redeem` does.

`get-plan(who)` returns the exact arguments to pass, read off live state.

### Deploy notes

- Clarity **5**. Version byte 6 is rejected by mainnet nodes.
- No custody, no `as-contract`: this contract never holds MIA or STX. If it is
  superseded there is nothing to migrate out of it.
- Post-conditions: the caller sends MIA (burn) and STX (deposit) and receives
  both back. Leather's originator mode covers the whole bundle; for other
  wallets, deny mode needs the caller's two outflows listed explicitly.

---

## Solution 2: no new contract, two transactions

Identical arithmetic, split across two signatures:

```
1. ccd013.redeem-mia(u3231716020625)              burns your leftover, pays you
2. machine.run-loops(u17100000000, u4)            settles the book
```

`redeem-mia` reads `tx-sender` and `miamicoin-token-v2.burn` asserts
`(is-eq tx-sender owner)`, so leg 1 needs no contract at all - it burns from
your wallet and pays your wallet.

The only thing you give up is atomicity, and that is precisely what was
exploited in cycle 139: between your two transactions another sender's
`redeem-mia` can be mined against the headroom leg 1 just freed. Use this if
deploying is not worth it for one cycle; otherwise use solution 1.

## Solution 3: park the MIA in the machine and size the deposit

No new contract and one transaction, at the cost of hand-computed arguments.

**Step 1, any time.** There is no `deposit-mia` function and none is needed -
`try-redeem` reads `(get-balance current-contract)`, so an ordinary SIP-010
transfer to the machine principal is the deposit:

```
contract   SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2
function   transfer
args       amount    u3231715183625
           sender    <your address>
           recipient SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22.stx-to-stx-mia-faktory-v2
           memo      none
```

This touches no treasury, so there is nothing to race. `withdraw-mia` pays
whichever operator calls it, so it is not a one-way door. Once the MIA is in
the machine it stops mattering which operator address calls `run-loops` -
`finish` pays the caller.

**Step 2, tranche day.** The deposit now has to absorb the parked MIA:

```
deposit_cap = 17,100 STX - par(MIA already in the machine)
par(umia)   = floor(umia * 1710 / 1_000_000)
```

| MIA parked in the machine | `run-loops` deposit | machine holds after pass 1 |
|---|---|---|
| 0 | u17100000000 (17,100.000000 STX) | 10,000,000.000000 MIA |
| 3,231,715.183625 | **u11573767036** (11,573.767036 STX) | 9,999,999.999999 MIA |
| 3,231,716.020625 | u11573765604 (11,573.765604 STX) | 9,999,999.999572 MIA |

**Round down. Always.** One microSTX over the cap and the settle buys
10,000,000.000584 MIA, the redeem stops at 10,000,000, and you have stranded
MIA again. Under-shooting costs nothing - later passes sweep whatever headroom
is left.

This works, but every cycle needs a fresh calculation against whatever MIA is
parked. Solution 1 exists so that number is always 17,100.

---

## Picking `cycles`

```
cycles = ceil(treasury_ustx / 17,100 STX)     capped at 5 by the machine
```

| Tranche in the treasury | cycles |
|---|---|
| up to 17,100 | 1 |
| 17,100 - 34,200 | 2 |
| 34,200 - 51,300 | 3 |
| 51,300 - 68,400 | 4 |

You only ever need 17,100 STX of float regardless of the cycle count, because
each pass returns its redemption proceeds to the machine before the next pass
spends them.

## Verify afterwards

```clarity
;; all three should read 0
(contract-call? .stx-to-stx-mia-faktory-v2 get-status)   ;; stx-escrow, mia-escrow
(contract-call? CCD013 get-redemption-current-balance)   ;; treasury
```

Non-zero `mia-escrow` means a pass was oversized: that MIA is safe and worth
exactly `par(mia-escrow)`, but it is waiting on the next tranche and the
headroom it should have used is exposed.

## Live state, 2026-07-28

| | |
|---|---|
| Fair book | 34,270,999.31 MIA asking 54,275.39 STX (7.4% avg below par) |
| Full sweep would need | 4 passes / 54,275.39 STX of treasury |
| Rewards treasury | 0 STX (drained cycle 139) |
| Machine escrow | 0 STX, 0 MIA |
| Rollover MIA | 3,231,716.020625 at `SP3KJBWTS3K...` |
| Accumulated surplus | 4,594,429.99 MIA, earmarked for single-sided seeding |
| Lifetime | 26,664,946.34 MIA cleared, 37,740.58 STX to sellers |

The book is **not** swept. The binding constraint is the treasury, not the
offers: a ~22,600 STX tranche clears about 13.2M par-equiv, so the book needs
roughly two and a half more tranches at this size.

## The fix that retires all of this

Cap the settle budget inside `try-settle` instead of asking the operator to:

```clarity
(budget (min balance headroom (- (par MAX_PER_TRANSACTION) (par held-mia))))
```

Then `run-loops(anything, 5)` is residue-free by construction, no bundle is
needed, and the guard covers every caller rather than only the ones going
through the fak.fun UI - which is where it lives today
(`MiaExitPage.tsx`, `MAX_RUN_USTX`), and which does nothing for an operator
calling the contract directly, as they should be able to.
