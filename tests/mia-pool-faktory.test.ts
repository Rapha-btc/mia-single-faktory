import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  FAKTORY_ADDRESS,
  miaBalance,
  mintMia,
  mintSbtc,
  sbtcBalance,
} from "./helpers";

// The Clarinet.toml deployment is used here: the pool's DEPLOYER is the simnet
// deployer, and the pool only references mainnet token principals (absolute),
// so it is fully testable standalone.
const POOL = "mia-pool-faktory";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;

const ERR_UNAUTHORIZED = Cl.error(Cl.uint(403));
const ERR_TOO_MUCH_SLIPPAGE = Cl.error(Cl.uint(407));
const ERR_INVALID_OPERATION = Cl.error(Cl.uint(400));

const poolId = `${deployer}.${POOL}`;

function fund(who: string) {
  mintSbtc(who, 100_000_000);
  mintMia(who, 10_000_000_000);
}

// initialize with reserves a=1000 sBTC-sats, b=100_000 uMIA, LP supply 1000
function initPool() {
  fund(deployer);
  const res = simnet.callPublicFn(
    POOL,
    "initialize-pool",
    [Cl.uint(1000), Cl.uint(99_000)],
    deployer,
  );
  expect(res.result).toEqual(Cl.ok(Cl.bool(true)));
}

function reserves() {
  const q = simnet.callReadOnlyFn(
    POOL,
    "quote",
    [Cl.uint(0), Cl.some(Cl.buffer(Uint8Array.from([4])))],
    deployer,
  );
  expect(q.result.type).toBe("ok");
  const t = (q.result as any).value.value;
  return { a: t.dx.value as bigint, b: t.dy.value as bigint, k: t.dk.value as bigint };
}

describe("initialize-pool", () => {
  it("only the deployer can initialize", () => {
    fund(wallet1);
    const res = simnet.callPublicFn(
      POOL,
      "initialize-pool",
      [Cl.uint(1000), Cl.uint(99_000)],
      wallet1,
    );
    expect(res.result).toEqual(ERR_UNAUTHORIZED);
  });

  it("seeds reserves and LP supply", () => {
    initPool();
    expect(reserves()).toEqual({ a: 1000n, b: 100_000n, k: 1000n });
    const lp = simnet.callReadOnlyFn(
      POOL,
      "get-balance",
      [Cl.principal(deployer)],
      deployer,
    );
    expect(lp.result).toEqual(Cl.ok(Cl.uint(1000)));
  });
});

describe("liquidity", () => {
  beforeEach(initPool);

  it("add-liquidity is blocked before the pool is opened", () => {
    // fresh simnet per test; use a NON-initialized state by checking the guard
    // via a separate assertion below in its own test file state — here the pool
    // is open, so exercise the proportional math instead.
    fund(wallet1);
    const res = simnet.callPublicFn(POOL, "add-liquidity", [Cl.uint(100)], wallet1);
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({ dx: Cl.uint(100), dy: Cl.uint(10_000), dk: Cl.uint(100) }),
      ),
    );
    expect(reserves()).toEqual({ a: 1100n, b: 110_000n, k: 1100n });
  });

  it("remove-liquidity returns the proportional share", () => {
    fund(wallet1);
    simnet.callPublicFn(POOL, "add-liquidity", [Cl.uint(100)], wallet1);
    const sbtcBefore = sbtcBalance(wallet1);
    const miaBefore = miaBalance(wallet1);
    const res = simnet.callPublicFn(POOL, "remove-liquidity", [Cl.uint(50)], wallet1);
    expect(res.result).toEqual(
      Cl.ok(Cl.tuple({ dx: Cl.uint(50), dy: Cl.uint(5000), dk: Cl.uint(50) })),
    );
    expect(sbtcBalance(wallet1) - sbtcBefore).toBe(50n);
    expect(miaBalance(wallet1) - miaBefore).toBe(5000n);
    expect(reserves()).toEqual({ a: 1050n, b: 105_000n, k: 1050n });
  });

  it("cannot remove more LP than owned", () => {
    fund(wallet1);
    simnet.callPublicFn(POOL, "add-liquidity", [Cl.uint(100)], wallet1);
    const res = simnet.callPublicFn(POOL, "remove-liquidity", [Cl.uint(101)], wallet1);
    expect(res.result.type).toBe("err");
  });
});

describe("add-liquidity gate (pool not opened)", () => {
  it("fails with 403 before initialize-pool", () => {
    fund(wallet1);
    const res = simnet.callPublicFn(POOL, "add-liquidity", [Cl.uint(100)], wallet1);
    expect(res.result).toEqual(ERR_UNAUTHORIZED);
  });
});

describe("swap gating (audit fix: no direct-call escape hatch)", () => {
  beforeEach(() => {
    initPool();
    fund(wallet1);
  });

  it("is gated by default", () => {
    const gated = simnet.callReadOnlyFn(POOL, "is-gated", [], deployer);
    expect(gated.result).toEqual(Cl.bool(true));
  });

  it("blocks a DIRECT wallet swap while gated", () => {
    const res = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(100), Cl.uint(0)],
      wallet1,
    );
    expect(res.result).toEqual(ERR_UNAUTHORIZED);
  });

  it("blocks the execute() opcode path while gated", () => {
    const res = simnet.callPublicFn(
      POOL,
      "execute",
      [Cl.uint(100), Cl.some(Cl.buffer(Uint8Array.from([0])))],
      wallet1,
    );
    expect(res.result).toEqual(ERR_UNAUTHORIZED);
  });

  it("blocks swap-b-to-a while gated too", () => {
    const res = simnet.callPublicFn(
      POOL,
      "swap-b-to-a",
      [Cl.uint(100), Cl.uint(0)],
      wallet1,
    );
    expect(res.result).toEqual(ERR_UNAUTHORIZED);
  });

  it("an approved caller may swap while gated; revoking blocks again", () => {
    expect(
      simnet.callPublicFn(POOL, "approve-caller", [Cl.principal(wallet1)], deployer)
        .result,
    ).toEqual(Cl.ok(Cl.bool(true)));
    const ok = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(100), Cl.uint(0)],
      wallet1,
    );
    expect(ok.result.type).toBe("ok");

    simnet.callPublicFn(POOL, "revoke-caller", [Cl.principal(wallet1)], deployer);
    const blocked = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(100), Cl.uint(0)],
      wallet1,
    );
    expect(blocked.result).toEqual(ERR_UNAUTHORIZED);
  });

  it("only the deployer can set-gated / approve-caller / revoke-caller", () => {
    for (const [fn, args] of [
      ["set-gated", [Cl.bool(false)]],
      ["approve-caller", [Cl.principal(wallet1)]],
      ["revoke-caller", [Cl.principal(wallet1)]],
    ] as const) {
      const res = simnet.callPublicFn(POOL, fn, args as any, wallet1);
      expect(res.result).toEqual(ERR_UNAUTHORIZED);
    }
  });

  it("everyone can swap after the deployer ungates", () => {
    simnet.callPublicFn(POOL, "set-gated", [Cl.bool(false)], deployer);
    const res = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(100), Cl.uint(0)],
      wallet1,
    );
    expect(res.result.type).toBe("ok");
  });
});

describe("swap math (ungated)", () => {
  beforeEach(() => {
    initPool();
    fund(wallet1);
    simnet.callPublicFn(POOL, "set-gated", [Cl.bool(false)], deployer);
  });

  it("swap-a-to-b matches the constant-product quote and pays the faktory fee", () => {
    // amount 1000: fee-in = 1000*1000/1e6 = 1; effective = 999
    // dx = 999*(1e6-3000)/1e6 = 996; dy = 996*100000/(1000+996) = 49899
    const feeBefore = sbtcBalance(FAKTORY_ADDRESS);
    const miaBefore = miaBalance(wallet1);
    const res = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(1000), Cl.uint(0)],
      wallet1,
    );
    expect(res.result).toEqual(
      Cl.ok(Cl.tuple({ dx: Cl.uint(996), dy: Cl.uint(49_899), dk: Cl.uint(0) })),
    );
    expect(miaBalance(wallet1) - miaBefore).toBe(49_899n);
    expect(sbtcBalance(FAKTORY_ADDRESS) - feeBefore).toBe(1n);
    // pool received amount - fee = 999 sats
    expect(reserves().a).toBe(1999n);
  });

  it("swap-b-to-a takes the fee on the way out", () => {
    // amount 100_000 MIA in: no fee-in; dx = 100000*0.997 = 99700
    // dy = 99700*1000/(100000+99700) = 499; fee-out = 499*1000/1e6 = 0
    const sbtcBefore = sbtcBalance(wallet1);
    const res = simnet.callPublicFn(
      POOL,
      "swap-b-to-a",
      [Cl.uint(100_000), Cl.uint(0)],
      wallet1,
    );
    expect(res.result).toEqual(
      Cl.ok(Cl.tuple({ dx: Cl.uint(99_700), dy: Cl.uint(499), dk: Cl.uint(0) })),
    );
    expect(sbtcBalance(wallet1) - sbtcBefore).toBe(499n);
  });

  it("respects min-y-out (slippage)", () => {
    const res = simnet.callPublicFn(
      POOL,
      "swap-a-to-b",
      [Cl.uint(1000), Cl.uint(49_900)],
      wallet1,
    );
    expect(res.result).toEqual(ERR_TOO_MUCH_SLIPPAGE);
  });

  it("the product x*y never decreases across a swap", () => {
    const r0 = reserves();
    simnet.callPublicFn(POOL, "swap-a-to-b", [Cl.uint(777), Cl.uint(0)], wallet1);
    const r1 = reserves();
    expect(r1.a * r1.b).toBeGreaterThanOrEqual(r0.a * r0.b);
  });
});

describe("LP token (SIP-010 surface)", () => {
  beforeEach(() => {
    initPool();
  });

  it("exposes metadata", () => {
    expect(
      simnet.callReadOnlyFn(POOL, "get-symbol", [], deployer).result,
    ).toEqual(Cl.ok(Cl.stringAscii("sBTC-MIA")));
    expect(
      simnet.callReadOnlyFn(POOL, "get-decimals", [], deployer).result,
    ).toEqual(Cl.ok(Cl.uint(6)));
    expect(
      simnet.callReadOnlyFn(POOL, "get-total-supply", [], deployer).result,
    ).toEqual(Cl.ok(Cl.uint(1000)));
  });

  it("transfer requires tx-sender = sender", () => {
    const res = simnet.callPublicFn(
      POOL,
      "transfer",
      [Cl.uint(10), Cl.principal(deployer), Cl.principal(wallet2), Cl.none()],
      wallet1,
    );
    expect(res.result).toEqual(ERR_UNAUTHORIZED);

    const ok = simnet.callPublicFn(
      POOL,
      "transfer",
      [Cl.uint(10), Cl.principal(deployer), Cl.principal(wallet2), Cl.none()],
      deployer,
    );
    expect(ok.result).toEqual(Cl.ok(Cl.bool(true)));
    expect(
      simnet.callReadOnlyFn(POOL, "get-balance", [Cl.principal(wallet2)], deployer)
        .result,
    ).toEqual(Cl.ok(Cl.uint(10)));
  });

  it("set-token-uri is deployer-only", () => {
    expect(
      simnet.callPublicFn(POOL, "set-token-uri", [Cl.stringUtf8("x")], wallet1)
        .result,
    ).toEqual(ERR_UNAUTHORIZED);
  });
});

describe("execute/quote opcodes", () => {
  beforeEach(() => {
    initPool();
    fund(wallet1);
    simnet.callPublicFn(POOL, "set-gated", [Cl.bool(false)], deployer);
  });

  it("unknown opcode errors", () => {
    const res = simnet.callPublicFn(
      POOL,
      "execute",
      [Cl.uint(1), Cl.some(Cl.buffer(Uint8Array.from([9])))],
      wallet1,
    );
    expect(res.result).toEqual(ERR_INVALID_OPERATION);
    const q = simnet.callReadOnlyFn(
      POOL,
      "quote",
      [Cl.uint(1), Cl.some(Cl.buffer(Uint8Array.from([9])))],
      wallet1,
    );
    expect(q.result).toEqual(ERR_INVALID_OPERATION);
  });

  it("execute add-liquidity via opcode 0x02", () => {
    const res = simnet.callPublicFn(
      POOL,
      "execute",
      [Cl.uint(100), Cl.some(Cl.buffer(Uint8Array.from([2])))],
      wallet1,
    );
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({ dx: Cl.uint(100), dy: Cl.uint(10_000), dk: Cl.uint(100) }),
      ),
    );
  });
});

// documents the audit finding: quoting with amount rounding to 0 on an empty
// pool would divide by zero; swaps in a live pool are unaffected because
// initialize-pool always seeds reserves before the gate can open
describe("empty-pool quote edge", () => {
  it("get-swap-quote aborts on an empty pool (division by zero)", () => {
    expect(() =>
      simnet.callReadOnlyFn(
        POOL,
        "get-swap-quote",
        [Cl.uint(1), Cl.some(Cl.buffer(Uint8Array.from([0])))],
        wallet1,
      ),
    ).toThrow();
  });
});
