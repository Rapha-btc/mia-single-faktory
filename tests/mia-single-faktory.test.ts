import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  cvUint,
  deployTrio,
  FAKFUN,
  fundParEnvironment,
  LOCK_PERIOD,
  miaBalance,
  mintMia,
  mintSbtc,
  sbtcBalance,
} from "./helpers";

// mia-single-faktory's DEPOSITOR is 'SPV9K21...mia-fair-faktory (a contract
// principal), and simnet cannot impersonate contract principals as tx-sender.
// So this suite deploys the trio under the fak.fun address and drives seeding
// through the REAL fair contract (settle -> seed-single-sided), like mainnet.
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;
const whitehat = accounts.get("wallet_8")!;

const ERR_UNAUTHORIZED = Cl.error(Cl.uint(403));
const ERR_NOT_STARTED = Cl.error(Cl.uint(404));
const ERR_INSUFFICIENT_AMOUNT = Cl.error(Cl.uint(406));
const ERR_STILL_LOCKED = Cl.error(Cl.uint(407));
const ERR_NO_DEPOSIT = Cl.error(Cl.uint(408));

let pool: string, single: string, fair: string, admin: string;

// End state of setup: fair holds surplus MIA; seed-single-sided(seedAmount)
// pushes it into the single-sided contract, anchoring the lock clock.
function setupSeeded(seedAmount: bigint) {
  ({ pool, single, fair, admin } = deployTrio());
  fundParEnvironment([wallet1, wallet2, wallet3]);
  expect(simnet.callPublicFn(fair, "initialize", [], admin).result.type).toBe("ok");

  // two below-par offers produce plenty of spread
  simnet.callPublicFn(fair, "place-offer", [Cl.uint(2_000_000), Cl.uint(1000)], wallet1);
  simnet.callPublicFn(fair, "place-offer", [Cl.uint(2_000_000), Cl.uint(1500)], wallet2);
  const settle = simnet.callPublicFn(fair, "settle-offers", [Cl.uint(2500)], whitehat);
  expect(settle.result.type).toBe("ok");
  // surplus = 4_000_000 - 2500*1e6/1710 = 4_000_000 - 1_461_988 = 2_538_012
  const res = simnet.callPublicFn(fair, "seed-single-sided", [Cl.uint(seedAmount)], admin);
  expect(res.result).toEqual(Cl.ok(Cl.bool(true)));
}

// pool reserves a=10_000 sats, b=1_000_000 uMIA, LP supply 10_000
function openPool() {
  mintSbtc(admin, 100_000_000);
  mintMia(admin, 10_000_000_000);
  const res = simnet.callPublicFn(
    pool,
    "initialize-pool",
    [Cl.uint(10_000), Cl.uint(990_000)],
    admin,
  );
  expect(res.result).toEqual(Cl.ok(Cl.bool(true)));
}

function poolInfo() {
  const t = (simnet.callReadOnlyFn(single, "get-pool-info", [], deployer).result as any)
    .value;
  return {
    creationBlock: t["creation-block"].value as bigint,
    started: t.started.type === "true",
    unlockBlock: t["unlock-block"].value as bigint,
    isUnlocked: t["is-unlocked"].type === "true",
    initialToken: t["initial-token"].value as bigint,
    tokenUsed: t["token-used"].value as bigint,
    totalLpTokens: t["total-lp-tokens"].value as bigint,
  };
}

const userLp = (who: string) =>
  cvUint(
    simnet.callReadOnlyFn(single, "get-user-lp-tokens", [Cl.principal(who)], deployer)
      .result,
  );

const lpBalance = (who: string) =>
  cvUint(
    simnet.callReadOnlyFn(pool, "get-balance", [Cl.principal(who)], deployer).result,
  );

describe("seeding via mia-fair-faktory (the only DEPOSITOR)", () => {
  it("initialize-pool is barred for anyone but the DEPOSITOR contract", () => {
    ({ pool, single, fair, admin } = deployTrio());
    mintMia(wallet1, 1_000_000);
    expect(
      simnet.callPublicFn(single, "initialize-pool", [Cl.uint(1)], wallet1).result,
    ).toEqual(ERR_UNAUTHORIZED);
    // even the fak.fun admin wallet itself cannot seed directly
    mintMia(admin, 1_000_000);
    expect(
      simnet.callPublicFn(single, "initialize-pool", [Cl.uint(1)], admin).result,
    ).toEqual(ERR_UNAUTHORIZED);
  });

  it("seed anchors the clock once and accumulates MIA on top-ups", () => {
    setupSeeded(1_000_000n);
    const first = poolInfo();
    expect(first.started).toBe(true);
    expect(first.initialToken).toBe(1_000_000n);
    expect(first.unlockBlock).toBe(first.creationBlock + BigInt(LOCK_PERIOD));
    expect(miaBalance(single)).toBe(1_000_000n);

    simnet.mineEmptyBurnBlocks(100);
    // top-up: clock must NOT move
    const res = simnet.callPublicFn(fair, "seed-single-sided", [Cl.uint(500_000)], admin);
    expect(res.result).toEqual(Cl.ok(Cl.bool(true)));
    const second = poolInfo();
    expect(second.creationBlock).toBe(first.creationBlock);
    expect(second.initialToken).toBe(1_500_000n);
    expect(miaBalance(single)).toBe(1_500_000n);
  });
});

describe("deposit-sbtc-for-lp", () => {
  beforeEach(() => {
    setupSeeded(2_000_000n);
    openPool();
    mintSbtc(wallet3, 1_000_000);
  });

  it("pairs community sBTC with the seeded MIA at pool ratio", () => {
    // lp 1000 on reserves {a:10_000, b:1_000_000, k:10_000}
    // -> sbtc-needed 1000, token-needed 100_000
    const sbtcBefore = sbtcBalance(wallet3);
    const res = simnet.callPublicFn(
      single,
      "deposit-sbtc-for-lp",
      [Cl.uint(1000)],
      wallet3,
    );
    expect(res.result).toEqual(Cl.ok(Cl.uint(1000)));
    expect(sbtcBefore - sbtcBalance(wallet3)).toBe(1000n);
    expect(userLp(wallet3)).toBe(1000n);
    // the LP sits with the single-sided contract, not the user
    expect(lpBalance(single)).toBe(1000n);
    expect(lpBalance(wallet3)).toBe(0n);
    const info = poolInfo();
    expect(info.totalLpTokens).toBe(1000n);
    expect(info.tokenUsed).toBe(100_000n);
    // seeded MIA decreased
    expect(miaBalance(single)).toBe(2_000_000n - 100_000n);
  });

  it("multiple deposits accumulate per user", () => {
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(500)], wallet3);
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(300)], wallet3);
    expect(userLp(wallet3)).toBe(800n);
  });

  it("zero LP request is rejected", () => {
    const res = simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(0)], wallet3);
    // calculate-amounts-for-lp fails -> ERR_CALC_AMOUNTS wraps as u410
    expect(res.result).toEqual(Cl.error(Cl.uint(410)));
  });

  it("fails once the seeded MIA is exhausted", () => {
    // 2_000_000 uMIA seeded covers at most lp 20_000 at 100 uMIA per uLP
    const res = simnet.callPublicFn(
      single,
      "deposit-sbtc-for-lp",
      [Cl.uint(20_001)],
      wallet3,
    );
    expect(res.result.type).toBe("err");
    // and the successful maximum still works
    mintSbtc(wallet3, 100_000_000);
    const ok = simnet.callPublicFn(
      single,
      "deposit-sbtc-for-lp",
      [Cl.uint(20_000)],
      wallet3,
    );
    expect(ok.result).toEqual(Cl.ok(Cl.uint(20_000)));
    expect(miaBalance(single)).toBe(0n);
  });
});

describe("deposit before the offering starts", () => {
  it("errors with ERR_NOT_STARTED when the single-sided holds MIA but was never seeded", () => {
    ({ pool, single, fair, admin } = deployTrio());
    fundParEnvironment([wallet1, wallet2, wallet3]);
    openPool();
    // hand the contract MIA out-of-band so the pool pairing itself would work
    mintMia(single, 10_000_000);
    mintSbtc(wallet3, 1_000_000);
    const res = simnet.callPublicFn(
      single,
      "deposit-sbtc-for-lp",
      [Cl.uint(1000)],
      wallet3,
    );
    expect(res.result).toEqual(ERR_NOT_STARTED);
  });
});

describe("withdraw-lp-tokens (60/40 split)", () => {
  beforeEach(() => {
    setupSeeded(2_000_000n);
    openPool();
    mintSbtc(wallet3, 1_000_000);
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(1000)], wallet3);
  });

  it("is locked for ~90 days of burn blocks", () => {
    const res = simnet.callPublicFn(single, "withdraw-lp-tokens", [], wallet3);
    expect(res.result).toEqual(ERR_STILL_LOCKED);
  });

  it("after unlock the user removes 60% and the rest stays locked forever", () => {
    simnet.mineEmptyBurnBlocks(LOCK_PERIOD + 1);
    expect(poolInfo().isUnlocked).toBe(true);

    // reserves after deposit: a=11_000, b=1_100_000, k=11_000
    // remove 600 LP -> dx = 600*11_000/11_000 = 600 sats, dy = 60_000 uMIA
    const sbtcBefore = sbtcBalance(wallet3);
    const miaBefore = miaBalance(wallet3);
    const res = simnet.callPublicFn(single, "withdraw-lp-tokens", [], wallet3);
    expect(res.result).toEqual(Cl.ok(Cl.uint(1000)));

    expect(sbtcBalance(wallet3) - sbtcBefore).toBe(600n);
    expect(miaBalance(wallet3) - miaBefore).toBe(60_000n);

    // 40% of the LP remains with the contract, unattributed
    expect(lpBalance(single)).toBe(400n);
    expect(userLp(wallet3)).toBe(0n);
    expect(poolInfo().totalLpTokens).toBe(0n);

    // the entitlement is settled: withdrawing again fails
    expect(
      simnet.callPublicFn(single, "withdraw-lp-tokens", [], wallet3).result,
    ).toEqual(ERR_NO_DEPOSIT);
  });

  it("errors for users without a deposit", () => {
    simnet.mineEmptyBurnBlocks(LOCK_PERIOD + 1);
    expect(
      simnet.callPublicFn(single, "withdraw-lp-tokens", [], wallet2).result,
    ).toEqual(ERR_NO_DEPOSIT);
  });
});

// documents the audit finding: a 1-uLP entitlement floors 60% to 0 and the
// withdrawal aborts inside the pool (ft-burn? u0 -> err u1) -> dust is stuck
describe("dust entitlement (audit finding)", () => {
  it("a 1-uLP position cannot be withdrawn", () => {
    setupSeeded(2_000_000n);
    openPool();
    mintSbtc(wallet3, 1_000_000);
    simnet.callPublicFn(single, "deposit-sbtc-for-lp", [Cl.uint(1)], wallet3);
    expect(userLp(wallet3)).toBe(1n);
    simnet.mineEmptyBurnBlocks(LOCK_PERIOD + 1);
    const res = simnet.callPublicFn(single, "withdraw-lp-tokens", [], wallet3);
    expect(res.result).toEqual(Cl.error(Cl.uint(1)));
  });
});

describe("read-onlys", () => {
  it("get-config points at the wired principals", () => {
    ({ pool, single, fair, admin } = deployTrio());
    const t = (simnet.callReadOnlyFn(single, "get-config", [], deployer).result as any)
      .value;
    expect(t.pool.value).toBe(pool);
    expect(t.depositor.value).toBe(fair);
  });

  it("quotes lp pricing straight from the pool", () => {
    setupSeeded(2_000_000n);
    openPool();
    const res = simnet.callReadOnlyFn(
      single,
      "calculate-amounts-for-lp",
      [Cl.uint(1000)],
      deployer,
    );
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({
          "sbtc-needed": Cl.uint(1000),
          "token-needed": Cl.uint(100_000),
        }),
      ),
    );
    expect(
      simnet.callReadOnlyFn(single, "calculate-amounts-for-lp", [Cl.uint(0)], deployer)
        .result,
    ).toEqual(ERR_INSUFFICIENT_AMOUNT);
  });
});
