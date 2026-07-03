import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import {
  cvUint,
  deployTrio,
  fundParEnvironment,
  LOCK_PERIOD,
  miaBalance,
  mintSbtc,
  parEquivMia,
  sbtcBalance,
  stxBalance,
} from "./helpers";

// The whole story, end to end, exactly as the README tells it:
// exit auction -> whitehat settle -> spread seeds the single-sided ->
// community pairs sBTC -> gate opens -> 90 days -> 60/40 unlock.
const accounts = simnet.getAccounts();
const seller1 = accounts.get("wallet_1")!;
const seller2 = accounts.get("wallet_2")!;
const lp1 = accounts.get("wallet_3")!;
const lp2 = accounts.get("wallet_4")!;
const trader = accounts.get("wallet_5")!;
const whitehat = accounts.get("wallet_8")!;

it("runs the whitehat exit auction into a locked sBTC market", () => {
  const { pool, single, fair, admin } = deployTrio();
  fundParEnvironment([seller1, seller2]);

  // --- 1. the exit auction opens at par 1710 ---
  expect(simnet.callPublicFn(fair, "initialize", [], admin).result.type).toBe("ok");

  // sellers who want out early name below-par prices
  simnet.callPublicFn(fair, "place-offer", [Cl.uint(5_000_000), Cl.uint(4000)], seller1);
  simnet.callPublicFn(fair, "place-offer", [Cl.uint(3_000_000), Cl.uint(4000)], seller2);

  // --- 2. a whitehat settles the book with their own STX ---
  const whitehatStx = stxBalance(whitehat);
  const whitehatMia = miaBalance(whitehat);
  const res = simnet.callPublicFn(fair, "settle-offers", [Cl.uint(8000)], whitehat);
  expect(res.result.type).toBe("ok");

  const spent = 8000n;
  const parEquiv = parEquivMia(spent); // 8000e6/1710 = 4_678_362
  // the whitehat paid 8000 uSTX and got only the par-equivalent -- no profit
  expect(whitehatStx - stxBalance(whitehat)).toBe(spent);
  expect(miaBalance(whitehat) - whitehatMia).toBe(parEquiv);

  const surplus = 8_000_000n - parEquiv; // 3_321_638 spread retained
  expect(miaBalance(fair)).toBe(surplus);

  // --- 3. the spread seeds the single-sided offering ---
  expect(
    simnet.callPublicFn(fair, "seed-single-sided", [Cl.uint(surplus)], admin).result,
  ).toEqual(Cl.ok(Cl.bool(true)));
  expect(miaBalance(single)).toBe(surplus);

  // --- 4. fak.fun opens the (gated) pool ---
  mintSbtc(admin, 1_000_000);
  simnet.executeCommand(
    `::mint_ft SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2.miamicoin ${admin} 100000000`,
  );
  expect(
    simnet.callPublicFn(pool, "initialize-pool", [Cl.uint(10_000), Cl.uint(990_000)], admin)
      .result.type,
  ).toBe("ok");

  // nobody can move the price while the offering runs -- not even directly
  mintSbtc(trader, 1_000_000);
  expect(
    simnet.callPublicFn(pool, "swap-a-to-b", [Cl.uint(1000), Cl.uint(0)], trader).result,
  ).toEqual(Cl.error(Cl.uint(403)));

  // --- 5. the community pairs sBTC single-sided ---
  mintSbtc(lp1, 1_000_000);
  mintSbtc(lp2, 1_000_000);
  expect(
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(10_000)], lp1).result,
  ).toEqual(Cl.ok(Cl.uint(10_000)));
  expect(
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(5_000)], lp2).result,
  ).toEqual(Cl.ok(Cl.uint(5_000)));

  // --- 6. after the entry window the admin opens swaps ---
  simnet.callPublicFn(pool, "set-gated", [Cl.bool(false)], admin);
  expect(
    simnet.callPublicFn(pool, "swap-a-to-b", [Cl.uint(1000), Cl.uint(0)], trader).result
      .type,
  ).toBe("ok");

  // --- 7. ~90 days later: unlock, keep 60%, 40% stays forever ---
  simnet.mineEmptyBurnBlocks(LOCK_PERIOD + 1);

  const lp1Sbtc = sbtcBalance(lp1);
  const lp1Mia = miaBalance(lp1);
  expect(simnet.callPublicFn(single, "withdraw-lp-tokens", [], lp1).result).toEqual(
    Cl.ok(Cl.uint(10_000)),
  );
  expect(sbtcBalance(lp1)).toBeGreaterThan(lp1Sbtc);
  expect(miaBalance(lp1)).toBeGreaterThan(lp1Mia);

  expect(simnet.callPublicFn(single, "withdraw-lp-tokens", [], lp2).result).toEqual(
    Cl.ok(Cl.uint(5_000)),
  );

  // 40% of each entitlement (4000 + 2000 uLP) is locked in the pool forever
  const lockedLp = cvUint(
    simnet.callReadOnlyFn(pool, "get-balance", [Cl.principal(single)], admin).result,
  );
  expect(lockedLp).toBe(6_000n);
  // and nothing is attributed to anyone anymore
  expect(
    cvUint(
      simnet.callReadOnlyFn(single, "get-user-lp-tokens", [Cl.principal(lp1)], admin)
        .result,
    ),
  ).toBe(0n);

  // nothing ever returns to the accumulator
  expect(miaBalance(fair)).toBe(0n);
});
