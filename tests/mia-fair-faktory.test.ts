import { Cl, getAddressFromPrivateKey } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";
import {
  cvUint,
  fundParEnvironment,
  miaBalance,
  mintMia,
  parEquivMia,
  parUstx,
  stxBalance,
} from "./helpers";

// The Clarinet.toml deployment is used: admin = simnet deployer. Everything is
// testable here except the seed-single-sided SUCCESS path, which requires the
// trio deployed under the fak.fun address (covered in full-flow.test.ts).
const FAIR = "mia-fair-faktory";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;
const wallet4 = accounts.get("wallet_4")!;
const wallet5 = accounts.get("wallet_5")!;

const ERR_UNAUTHORIZED = Cl.error(Cl.uint(13000));
const ERR_ALREADY_ENABLED = Cl.error(Cl.uint(13004));
const ERR_NOT_ENABLED = Cl.error(Cl.uint(13005));
const ERR_ABOVE_PAR = Cl.error(Cl.uint(13012));
const ERR_INVALID_OFFER = Cl.error(Cl.uint(13013));
const ERR_OFFER_NOT_FOUND = Cl.error(Cl.uint(13014));
const ERR_BOOK_FULL = Cl.error(Cl.uint(13015));
const ERR_HAS_OFFER = Cl.error(Cl.uint(13016));
const ERR_INSUFFICIENT_SURPLUS = Cl.error(Cl.uint(13017));

const MAX_PER_TRANSACTION = 10_000_000_000_000n; // 10M MIA in uMIA

const fairId = `${deployer}.${FAIR}`;
const sellers = [wallet1, wallet2, wallet3, wallet4];

function initialize() {
  fundParEnvironment(sellers);
  const res = simnet.callPublicFn(FAIR, "initialize", [], deployer);
  expect(res.result.type).toBe("ok");
}

function placeOffer(sender: string, amount: number | bigint, ask: number | bigint) {
  return simnet.callPublicFn(
    FAIR,
    "place-offer",
    [Cl.uint(amount), Cl.uint(ask)],
    sender,
  );
}

function offerBook(): { owner: string; amount: bigint; ustx: bigint }[] {
  const res = simnet.callReadOnlyFn(FAIR, "get-offer-book", [], deployer);
  return (res.result as any).value.map((r: any) => ({
    owner: r.value.owner.value,
    amount: r.value.amount.value,
    ustx: r.value.ustx.value,
  }));
}

function getInfo() {
  const res = simnet.callReadOnlyFn(FAIR, "get-info", [], deployer);
  const t = (res.result as any).value;
  return {
    enabled: t.enabled.type === "true",
    ratio: t["redemption-ratio"].value as bigint,
    totalSupply: t["total-supply"].value as bigint,
    totalSettled: t["total-settled"].value as bigint,
    totalSpent: t["total-spent"].value as bigint,
    surplusMia: t["surplus-mia"].value as bigint,
    offerCount: t["offer-count"].value as bigint,
  };
}

describe("initialize", () => {
  it("requires the admin", () => {
    fundParEnvironment(sellers);
    expect(simnet.callPublicFn(FAIR, "initialize", [], wallet1).result).toEqual(
      ERR_UNAUTHORIZED,
    );
  });

  it("fails without MIA supply (fresh simnet)", () => {
    const res = simnet.callPublicFn(FAIR, "initialize", [], deployer);
    // v1+v2 supply is 0 -> ERR_GETTING_TOTAL_SUPPLY
    expect(res.result).toEqual(Cl.error(Cl.uint(13002)));
  });

  it("computes ratio = treasury * 1e6 / (v1*1e6 + v2) and is one-shot", () => {
    initialize();
    const info = getInfo();
    expect(info.enabled).toBe(true);
    expect(info.totalSupply).toBe(1_200_000_000_000n);
    expect(info.ratio).toBe(1710n);

    expect(simnet.callPublicFn(FAIR, "initialize", [], deployer).result).toEqual(
      ERR_ALREADY_ENABLED,
    );
  });

  it("par scales linearly with the frozen ratio", () => {
    initialize();
    const par = simnet.callReadOnlyFn(
      FAIR,
      "get-par-ustx",
      [Cl.uint(1_000_000)],
      deployer,
    );
    expect(par.result).toEqual(Cl.uint(1710));
  });
});

describe("place-offer validation", () => {
  it("rejects offers before initialize", () => {
    expect(placeOffer(wallet1, 1_000_000, 1000).result).toEqual(ERR_NOT_ENABLED);
  });

  it("rejects zero and oversized amounts", () => {
    initialize();
    expect(placeOffer(wallet1, 0, 1).result).toEqual(ERR_INVALID_OFFER);
    expect(
      placeOffer(wallet1, MAX_PER_TRANSACTION + 1n, 1000).result,
    ).toEqual(ERR_INVALID_OFFER);
  });

  it("rejects zero asks and asks above par", () => {
    initialize();
    expect(placeOffer(wallet1, 1_000_000, 0).result).toEqual(ERR_ABOVE_PAR);
    // par for 1_000_000 uMIA is 1710 uSTX
    expect(placeOffer(wallet1, 1_000_000, 1711).result).toEqual(ERR_ABOVE_PAR);
    expect(placeOffer(wallet1, 1_000_000, 1710).result.type).toBe("ok");
  });

  it("escrows the MIA with the contract", () => {
    initialize();
    const before = miaBalance(wallet1);
    placeOffer(wallet1, 1_000_000, 1000);
    expect(before - miaBalance(wallet1)).toBe(1_000_000n);
    expect(miaBalance(fairId)).toBe(1_000_000n);
  });

  it("one offer per wallet", () => {
    initialize();
    expect(placeOffer(wallet1, 1_000_000, 1000).result.type).toBe("ok");
    expect(placeOffer(wallet1, 500_000, 400).result).toEqual(ERR_HAS_OFFER);
  });
});

describe("offer book ordering", () => {
  beforeEach(initialize);

  it("keeps the book sorted ascending by price", () => {
    placeOffer(wallet1, 1_000_000, 1710); // price 0.00171 (par)
    placeOffer(wallet2, 1_000_000, 1000); // price 0.001  (cheapest)
    placeOffer(wallet3, 2_000_000, 3000); // price 0.0015
    expect(offerBook().map((o) => o.owner)).toEqual([wallet2, wallet3, wallet1]);
  });

  it("breaks price ties first-come-first-serve (DECISIONS.md D1)", () => {
    placeOffer(wallet2, 1_000_000, 1000);
    placeOffer(wallet3, 2_000_000, 3000);
    // wallet4 posts the SAME price as wallet2 -> must land AFTER wallet2
    placeOffer(wallet4, 1_000_000, 1000);
    expect(offerBook().map((o) => o.owner)).toEqual([wallet2, wallet4, wallet3]);
  });
});

describe("cancel-offer", () => {
  beforeEach(initialize);

  it("refunds the escrow and clears the book entry", () => {
    placeOffer(wallet1, 1_000_000, 1000);
    const before = miaBalance(wallet1);
    const res = simnet.callPublicFn(FAIR, "cancel-offer", [], wallet1);
    expect(res.result).toEqual(Cl.ok(Cl.bool(true)));
    expect(miaBalance(wallet1) - before).toBe(1_000_000n);
    expect(offerBook()).toEqual([]);
  });

  it("errors when the caller has no offer", () => {
    expect(simnet.callPublicFn(FAIR, "cancel-offer", [], wallet1).result).toEqual(
      ERR_OFFER_NOT_FOUND,
    );
  });
});

describe("settle-offers (permissionless whitehat)", () => {
  beforeEach(() => {
    initialize();
    placeOffer(wallet1, 1_000_000, 1710); // at par
    placeOffer(wallet2, 1_000_000, 1000); // cheapest
    placeOffer(wallet3, 2_000_000, 3000); // second
  });

  it("fills cheapest-first within budget; spread stays as surplus", () => {
    const w2Stx = stxBalance(wallet2);
    const settlerMiaBefore = miaBalance(wallet5);
    const res = simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(1500)], wallet5);

    // only wallet2's 1000 ask is affordable within 1500
    const spent = 1000n;
    const acquired = 1_000_000n;
    const parEquiv = parEquivMia(spent); // 1000*1e6/1710 = 584795
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({
          spent: Cl.uint(spent),
          acquired: Cl.uint(acquired),
          "par-equiv": Cl.uint(parEquiv),
          surplus: Cl.uint(acquired - parEquiv),
        }),
      ),
    );
    // seller got paid from the settler's own STX
    expect(stxBalance(wallet2) - w2Stx).toBe(spent);
    // the settler bought MIA at par (above market) -- whitehat, no profit
    expect(miaBalance(wallet5) - settlerMiaBefore).toBe(parEquiv);
    // spread accumulates in the contract
    expect(getInfo().surplusMia).toBe(acquired - parEquiv);
    expect(getInfo().offerCount).toBe(2n);
    expect(offerBook().map((o) => o.owner)).toEqual([wallet3, wallet1]);
  });

  it("can fill a later affordable offer when the next-cheapest is too big (documents skip behavior)", () => {
    // budget 3000: fills wallet2 (1000), skips wallet3 (ask 3000 > 2000 left),
    // then fills wallet1 (1710 <= 2000)
    const res = simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(3000)], wallet5);
    const spent = 1000n + 1710n;
    const acquired = 2_000_000n;
    const parEquiv = parEquivMia(spent);
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({
          spent: Cl.uint(spent),
          acquired: Cl.uint(acquired),
          "par-equiv": Cl.uint(parEquiv),
          surplus: Cl.uint(acquired - parEquiv),
        }),
      ),
    );
    expect(offerBook().map((o) => o.owner)).toEqual([wallet3]);
  });

  it("settling at par yields (almost) no surplus", () => {
    // only wallet1's offer is AT par; give it the exact budget by settling with
    // budget 1710 after the cheaper ones are cancelled
    simnet.callPublicFn(FAIR, "cancel-offer", [], wallet2);
    simnet.callPublicFn(FAIR, "cancel-offer", [], wallet3);
    const res = simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(1710)], wallet5);
    const parEquiv = parEquivMia(1710n); // 1710*1e6/1710 = 1_000_000 exactly
    expect(parEquiv).toBe(1_000_000n);
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({
          spent: Cl.uint(1710),
          acquired: Cl.uint(1_000_000),
          "par-equiv": Cl.uint(1_000_000),
          surplus: Cl.uint(0),
        }),
      ),
    );
  });

  it("a zero budget settles nothing", () => {
    const res = simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(0)], wallet5);
    expect(res.result).toEqual(
      Cl.ok(
        Cl.tuple({
          spent: Cl.uint(0),
          acquired: Cl.uint(0),
          "par-equiv": Cl.uint(0),
          surplus: Cl.uint(0),
        }),
      ),
    );
    expect(getInfo().offerCount).toBe(3n);
  });

  it("a settler's own offer is kept, not filled (self-transfer would abort)", () => {
    // wallet2 owns the cheapest offer AND settles: their own offer must be
    // skipped while others still fill
    const res = simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(3000)], wallet2);
    expect(res.result.type).toBe("ok");
    const owners = offerBook().map((o) => o.owner);
    expect(owners).toContain(wallet2);
    // budget 3000: skips own 1000-ask, fills wallet3's 3000-ask instead
    expect(owners).not.toContain(wallet3);
  });

  it("escrow accounting: contract MIA = open offers + surplus", () => {
    simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(1500)], wallet5);
    const info = getInfo();
    const bookTotal = offerBook().reduce((s, o) => s + o.amount, 0n);
    expect(miaBalance(fairId)).toBe(bookTotal + info.surplusMia);
  });
});

describe("settle-offers before initialize", () => {
  it("errors with ERR_NOT_ENABLED", () => {
    expect(
      simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(1000)], wallet5).result,
    ).toEqual(ERR_NOT_ENABLED);
  });
});

describe("seed-single-sided", () => {
  beforeEach(() => {
    initialize();
    placeOffer(wallet2, 1_000_000, 1000);
    simnet.callPublicFn(FAIR, "settle-offers", [Cl.uint(1000)], wallet5);
  });

  it("requires the admin", () => {
    expect(
      simnet.callPublicFn(FAIR, "seed-single-sided", [Cl.uint(1)], wallet1).result,
    ).toEqual(ERR_UNAUTHORIZED);
  });

  it("cannot seed more than the retained surplus", () => {
    const surplus = getInfo().surplusMia;
    expect(
      simnet.callPublicFn(
        FAIR,
        "seed-single-sided",
        [Cl.uint(surplus + 1n)],
        deployer,
      ).result,
    ).toEqual(ERR_INSUFFICIENT_SURPLUS);
  });

  it("fails at THIS deployment address (documents the SPV9K21 deploy coupling)", () => {
    // .mia-single-faktory's DEPOSITOR is the fak.fun mia-fair-faktory, not the
    // simnet deployer's -> the ST-deployed fair contract can never seed it.
    // The success path lives in full-flow.test.ts.
    const res = simnet.callPublicFn(
      FAIR,
      "seed-single-sided",
      [Cl.uint(getInfo().surplusMia)],
      deployer,
    );
    expect(res.result).toEqual(Cl.error(Cl.uint(403)));
  });
});

describe("book-full eviction (MAX_OFFERS = 50)", () => {
  const extraWallets: string[] = Array.from({ length: 52 }, (_, i) =>
    getAddressFromPrivateKey(
      `${(i + 1).toString(16).padStart(64, "0")}01`,
      "testnet",
    ),
  );

  beforeEach(() => {
    initialize();
    // fill the book with 50 offers at DISTINCT prices: ask = 1000 + i on
    // 1_000_000 uMIA -> the worst (priciest) is ask 1049
    extraWallets.slice(0, 50).forEach((w, i) => {
      mintMia(w, 2_000_000);
      expect(placeOffer(w, 1_000_000, 1000 + i).result.type).toBe("ok");
    });
    expect(getInfo().offerCount).toBe(50n);
  });

  it("a strictly cheaper newcomer evicts (and refunds) the worst offer", () => {
    const worstOwner = extraWallets[49];
    const worstBefore = miaBalance(worstOwner);
    const newcomer = extraWallets[50];
    mintMia(newcomer, 2_000_000);
    expect(placeOffer(newcomer, 1_000_000, 999).result.type).toBe("ok");

    const book = offerBook();
    expect(book.length).toBe(50);
    // newcomer is now the cheapest; the evicted owner got the escrow back
    expect(book[0].owner).toBe(newcomer);
    expect(book.map((o) => o.owner)).not.toContain(worstOwner);
    expect(miaBalance(worstOwner) - worstBefore).toBe(1_000_000n);
  });

  it("an equal-priced newcomer does NOT evict (FIFO on ties)", () => {
    const newcomer = extraWallets[51];
    mintMia(newcomer, 2_000_000);
    // same price as the worst resting offer -> rejected
    expect(placeOffer(newcomer, 1_000_000, 1049).result).toEqual(ERR_BOOK_FULL);
  });
});

describe("set-admin", () => {
  it("only the admin can hand over", () => {
    expect(
      simnet.callPublicFn(FAIR, "set-admin", [Cl.principal(wallet1)], wallet1)
        .result,
    ).toEqual(ERR_UNAUTHORIZED);
    expect(
      simnet.callPublicFn(FAIR, "set-admin", [Cl.principal(wallet1)], deployer)
        .result,
    ).toEqual(Cl.ok(Cl.bool(true)));
    // old admin is out
    fundParEnvironment(sellers);
    expect(simnet.callPublicFn(FAIR, "initialize", [], deployer).result).toEqual(
      ERR_UNAUTHORIZED,
    );
    expect(simnet.callPublicFn(FAIR, "initialize", [], wallet1).result.type).toBe(
      "ok",
    );
  });
});
