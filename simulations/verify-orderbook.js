// verify-orderbook.js
// SELF-VERIFYING stxer mainnet-fork harness for mia-orderbook-jing:
// a 50-deep MIA-v2 sell book priced in sBTC with marketable-limit takers.
//
// Coverage:
//   - guards: below min-deposit, zero ask, duplicate offer, amend with no
//     offer, non-admin set-min-deposit, no-fill revert (limit below book)
//   - sort: book stays cheapest-first through place, reprice-amend (moves to
//     front), add-amend (moves to back)
//   - market-order 1: fills C fully + HALF of B (frontier partial at B's own
//     ratio), A untouched; 10 bps fee on top; maker/taker/fee sBTC deltas
//   - market-order 2: limit 220k/1M fills B's remainder, STOPS below A (250k)
//     even with 5M sats of spend left -- true limit behavior
//   - dust: spend u1 takes floor'd uMIA off A, fee floors to u0
//   - self-offer skip: taker with only their own offer in the book -> no-fill
//   - cancel-after-partial refunds exactly the shrunken remainder
//   - escrow invariant: contract MIA balance == book totals at every stage,
//     and 0 when the book empties
//
// Run: node simulations/verify-orderbook.js
import fs from "node:fs";
import {
  ClarityVersion,
  uintCV,
  boolCV,
  noneCV,
  someCV,
  standardPrincipalCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

// --- Mainnet actors (impersonated on the fork; balances verified 2026-07-03) ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22"; // admin
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA + 0.10 sBTC
const WHALE_C = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M MIA
const TAKER = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40.7 sBTC
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // no position

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const FEE_RECIPIENT = "SM362G0X1YNB2M3FWWFAASV9WB3XHQ8RWP512SSX3"; // contract default

const BOOK_CID = `${DEPLOYER}.mia-orderbook-jing`;

// --- Offer plan (uMIA / sats). ~200k sats per 1M MIA is near current mkt ---
const OFFER_A = { amount: 4_000_000_000_000n, ask: 900_000n }; // 4M MIA @ 225k/1M
const OFFER_B = { amount: 3_000_000_000_000n, ask: 630_000n }; // 3M MIA @ 210k/1M
const OFFER_C = { amount: 2_000_000_000_000n, ask: 400_000n }; // 2M MIA @ 200k/1M

// A amends: reprice-only to 760k sats (190k/1M -> cheapest), then add-amend
// +1M MIA with total ask 1.25M sats (250k/1M -> priciest)
const A_REPRICE = 760_000n;
const A_ADD = 1_000_000_000_000n;
const A_FINAL = { amount: OFFER_A.amount + A_ADD, ask: 1_250_000n }; // 5M @ 250k/1M

// market-order 1: fills C fully + half of B; limit 220k/1M excludes A
const SPEND_1 = OFFER_C.ask + 315_000n; // 715,000 sats
const LIMIT_1 = 220_000n;
const B_TAKEN = (OFFER_B.amount * 315_000n) / OFFER_B.ask; // 1.5e12 exactly
const ACQ_1 = OFFER_C.amount + B_TAKEN; // 3.5e12
const FEE_1 = (SPEND_1 * 10n) / 10_000n; // 715
const B_REM = { amount: OFFER_B.amount - B_TAKEN, btc: OFFER_B.ask - 315_000n }; // {1.5e12, 315k}

// market-order 2: big spend, same limit -> only B's remainder fills, A blocked
const SPEND_2 = 5_000_000n;
const SPENT_2 = B_REM.btc; // 315,000
const ACQ_2 = B_REM.amount; // 1.5e12
const FEE_2 = (SPENT_2 * 10n) / 10_000n; // 315

// dust order: 1 sat off A at its own ratio; fee floors to 0
const DUST_TAKEN = (A_FINAL.amount * 1n) / A_FINAL.ask; // 4,000,000 uMIA
const A_REM = { amount: A_FINAL.amount - DUST_TAKEN, btc: A_FINAL.ask - 1n };

// self-offer episode: B re-offers into the empty book, then market-orders
const OFFER_B2 = { amount: 1_000_000_000_000n, ask: 300_000n };

const MIN_DEPOSIT_0 = 100_000_000_000n; // 100k MIA (contract default)
const MIN_DEPOSIT_1 = 200_000_000_000n; // admin raises to 200k MIA

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const sbtcBal = (a) => `(contract-call? '${SBTC} get-balance '${a})`;

// ---- scenario builder with a parallel assertion plan ----
const plan = [];
const b = SimulationBuilder.new();
const src = (n) => fs.readFileSync(`./contracts/${n}.clar`, "utf8");

function deploy(name) {
  b.withSender(DEPLOYER).addContractDeploy({
    contract_name: name,
    source_code: src(name),
    clarity_version: ClarityVersion.Clarity5,
  });
  plan.push({ kind: "deploy", label: `deploy ${name}` });
}
function call(label, sender, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({ contract_id: BOOK_CID, function_name: fn, function_args: args });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(BOOK_CID, code);
  plan.push({ kind: "eval", label, capture });
}
// expect-fn for market-order returns: check each tuple key numerically
const orderExpect = (spent, acquired, fee) => (s) =>
  s.startsWith("(ok ") &&
  s.includes(`(spent u${spent})`) &&
  s.includes(`(acquired u${acquired})`) &&
  s.includes(`(fee u${fee})`);

// =====================================================================
// Act 1 -- deploy; live at once (no initialize); guards
// =====================================================================
deploy("mia-orderbook-jing");
evalc("get-info at deploy", "(get-info)", "info0");

call("offer below min-deposit (50k MIA) -> err u13018", WHALE_A, "place-offer",
  [uintCV(50_000_000_000n), uintCV(100_000n)], "(err u13018)");
call("offer with zero ask -> err u13013", WHALE_A, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(0n)], "(err u13013)");
call("poison ask above MAX_ASK -> err u13013 (overflow-DoS guard)", WHALE_A, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(2_000_000_000_000_000n)], "(err u13013)");
call("market-order limit above MAX_ASK -> err u13013", TAKER, "market-order",
  [uintCV(1_000n), uintCV(2_000_000_000_000_000n)], "(err u13013)");
call("change-offer with no resting offer -> err u13014", STRANGER, "change-offer",
  [noneCV(), uintCV(1_000n)], "(err u13014)");
call("set-min-deposit by non-admin -> err u13000", STRANGER, "set-min-deposit",
  [uintCV(1n)], "(err u13000)");

// =====================================================================
// Act 2 -- whales build the book; sort + amend semantics
// =====================================================================
call("whale A offers 4M MIA @ 900k sats (225k/1M)", WHALE_A, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(ok true)");
call("whale A duplicate offer -> err u13016", WHALE_A, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(err u13016)");
call("whale B offers 3M MIA @ 630k sats (210k/1M)", WHALE_B, "place-offer",
  [uintCV(OFFER_B.amount), uintCV(OFFER_B.ask)], "(ok true)");
call("whale C offers 2M MIA @ 400k sats (200k/1M)", WHALE_C, "place-offer",
  [uintCV(OFFER_C.amount), uintCV(OFFER_C.ask)], "(ok true)");
evalc("book sorted cheapest-first (C,B,A)", "(get-offer-book)", "book0");
evalc("book totals (1.93M sats / 9M MIA)", "(get-book-totals)", "totals0");
evalc("escrowed MIA == book amount", miaBal(BOOK_CID), "escrow0");

call("A reprice change-offer (none, 760k) -> now cheapest", WHALE_A, "change-offer",
  [noneCV(), uintCV(A_REPRICE)], "(ok true)");
evalc("book order after reprice (A,C,B)", "(get-offer-book)", "book1");
call("A add change-offer (+1M MIA, total ask 1.25M) -> now priciest", WHALE_A, "change-offer",
  [someCV(uintCV(A_ADD)), uintCV(A_FINAL.ask)], "(ok true)");
evalc("book order after add-amend (C,B,A)", "(get-offer-book)", "book2");
evalc("A's record (5M MIA / 1.25M sats)", `(get-offer '${WHALE_A})`, "aRec");
evalc("escrow after add-amend (10M MIA)", miaBal(BOOK_CID), "escrow1");

call("admin raises min-deposit to 200k MIA", DEPLOYER, "set-min-deposit",
  [uintCV(MIN_DEPOSIT_1)], /^\(ok /);
call("new offer below raised min (150k) -> err u13018", STRANGER, "place-offer",
  [uintCV(150_000_000_000n), uintCV(100_000n)], "(err u13018)");

// =====================================================================
// Act 3 -- takers: limit below book, crossing orders, dust, fees
// =====================================================================
evalc("taker sBTC before", sbtcBal(TAKER), "T_sbtc_before");
evalc("taker MIA before", miaBal(TAKER), "T_mia_before");
evalc("fee recipient sBTC before", sbtcBal(FEE_RECIPIENT), "F_sbtc_before");
evalc("whale A sBTC before", sbtcBal(WHALE_A), "A_sbtc_before");
evalc("whale B sBTC before", sbtcBal(WHALE_B), "B_sbtc_before");
evalc("whale C sBTC before", sbtcBal(WHALE_C), "C_sbtc_before");

call("market-order with limit below best ask -> err u13019 (no fill)", TAKER,
  "market-order", [uintCV(1_000_000n), uintCV(100_000n)], "(err u13019)");

call("market-order 1: 715k sats @ limit 220k/1M -> C full + half of B", TAKER,
  "market-order", [uintCV(SPEND_1), uintCV(LIMIT_1)],
  orderExpect(SPEND_1, ACQ_1, FEE_1), "order1");
evalc("B's shrunken record {1.5M MIA, 315k sats}", `(get-offer '${WHALE_B})`, "bRem");
evalc("book count after order 1 (2)", "(get-offer-count)", "count1");
evalc("book totals after order 1", "(get-book-totals)", "totals1");

call("market-order 2: 5M sats, SAME limit -> fills B remainder, STOPS below A", TAKER,
  "market-order", [uintCV(SPEND_2), uintCV(LIMIT_1)],
  orderExpect(SPENT_2, ACQ_2, FEE_2), "order2");
evalc("book after order 2 (A only)", "(get-offer-book)", "book3");

call("dust order: 1 sat @ open limit -> 4 MIA off A, fee u0", TAKER,
  "market-order", [uintCV(1n), uintCV(999_999_999n)],
  orderExpect(1n, DUST_TAKEN, 0n), "orderDust");
evalc("A's record after dust", `(get-offer '${WHALE_A})`, "aRem");

call("whale A cancels -> refund of the shrunken remainder", WHALE_A, "cancel-offer",
  [], "(ok true)");
evalc("book empty after cancel", "(get-offer-count)", "count2");
evalc("escrow empty after cancel (invariant)", miaBal(BOOK_CID), "escrowEnd");

evalc("taker sBTC after", sbtcBal(TAKER), "T_sbtc_after");
evalc("taker MIA after", miaBal(TAKER), "T_mia_after");
evalc("fee recipient sBTC after", sbtcBal(FEE_RECIPIENT), "F_sbtc_after");
evalc("whale A sBTC after", sbtcBal(WHALE_A), "A_sbtc_after");
evalc("whale B sBTC after", sbtcBal(WHALE_B), "B_sbtc_after");
evalc("whale C sBTC after", sbtcBal(WHALE_C), "C_sbtc_after");

// =====================================================================
// Act 4 -- self-offer skip: a maker can't fill (or pay) themselves
// =====================================================================
call("whale B re-offers 1M MIA @ 300k sats", WHALE_B, "place-offer",
  [uintCV(OFFER_B2.amount), uintCV(OFFER_B2.ask)], "(ok true)");
call("B market-orders against a book holding ONLY B's own offer -> no fill", WHALE_B,
  "market-order", [uintCV(OFFER_B2.ask), uintCV(999_999_999n)], "(err u13019)");
call("whale B cancels", WHALE_B, "cancel-offer", [], "(ok true)");
evalc("book + escrow empty at end", miaBal(BOOK_CID), "escrowFinal");

// =====================================================================
// Act 5 -- pause: gates place/change/market-order, NEVER cancel
// =====================================================================
call("whale C places 1M MIA @ 250k sats (pre-pause)", WHALE_C, "place-offer",
  [uintCV(1_000_000_000_000n), uintCV(250_000n)], "(ok true)");
call("set-paused by non-admin -> err u13000", STRANGER, "set-paused",
  [boolCV(true)], "(err u13000)");
call("admin pauses", DEPLOYER, "set-paused", [boolCV(true)], /^\(ok /);
call("place-offer while paused -> err u13020", WHALE_A, "place-offer",
  [uintCV(1_000_000_000_000n), uintCV(300_000n)], "(err u13020)");
call("change-offer while paused -> err u13020", WHALE_C, "change-offer",
  [noneCV(), uintCV(240_000n)], "(err u13020)");
call("market-order while paused -> err u13020", TAKER, "market-order",
  [uintCV(250_000n), uintCV(999_999_999n)], "(err u13020)");
call("cancel-offer while paused -> STILL WORKS (refund)", WHALE_C, "cancel-offer",
  [], "(ok true)");
call("admin unpauses", DEPLOYER, "set-paused", [boolCV(false)], /^\(ok /);
evalc("escrow empty after paused-cancel", miaBal(BOOK_CID), "escrowPause");

// =====================================================================
// Run + verify
// =====================================================================
function decodeTx(s) {
  const r = s?.Result?.Transaction;
  if (!r) return { ok: false, str: "<no transaction result>" };
  if ("Err" in r) return { ok: false, str: `ENGINE-ERR: ${JSON.stringify(r.Err).slice(0, 200)}` };
  try {
    return { ok: true, str: cvToString(deserializeCV(r.Ok.result)) };
  } catch (e) {
    return { ok: false, str: `decode-failed(${r.Ok.result}): ${e.message}` };
  }
}
function decodeEval(s) {
  const r = s?.Result?.Eval;
  if (!r) return "<no eval result>";
  if (!("Ok" in r)) return `ERR: ${JSON.stringify(r.Err).slice(0, 200)}`;
  try {
    return cvToString(deserializeCV(r.Ok));
  } catch {
    return r.Ok;
  }
}
const num = (s, key) => BigInt((String(s).match(new RegExp(`\\(${key} u(\\d+)\\)`)) || [])[1] ?? "-1");
const bare = (s) => BigInt((String(s).match(/u(\d+)/) || [])[1] ?? "-1");

async function main() {
  console.log("=== mia-orderbook-jing -- self-verifying stxer harness ===\n");
  const sessionId = await b.run();
  const url = `https://stxer.xyz/simulations/mainnet/${sessionId}`;
  console.log(`Submitted. Fetching results...\n${url}\n`);

  const res = await getSimulationResult(sessionId);
  const captured = {};
  let pass = 0, fail = 0;

  res.steps.forEach((s, i) => {
    const p = plan[i];
    if (!p) return;
    if (p.kind === "deploy") {
      const ok = !("Err" in (s?.Result?.Transaction || {}));
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "tx") {
      const d = decodeTx(s);
      if (p.capture) captured[p.capture] = d.str;
      const ok =
        typeof p.expect === "function" ? p.expect(d.str) :
        p.expect instanceof RegExp ? p.expect.test(d.str) :
        d.str === p.expect;
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 160)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 180)}`);
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  // deploy-time config
  check("min-deposit default 100k MIA", num(captured.info0, "min-deposit"), MIN_DEPOSIT_0);
  check("fee-bps 10", num(captured.info0, "fee-bps"), 10n);

  // book sorting through place + amends
  const order0 = [WHALE_C, WHALE_B, WHALE_A].map((w) => String(captured.book0).indexOf(w));
  check("book order C < B < A", order0[0] > -1 && order0[0] < order0[1] && order0[1] < order0[2], true);
  check("book totals sats", num(captured.totals0, "btc"), OFFER_A.ask + OFFER_B.ask + OFFER_C.ask);
  check("book totals MIA (9M)", num(captured.totals0, "amount"), OFFER_A.amount + OFFER_B.amount + OFFER_C.amount);
  check("escrow == book amount", bare(captured.escrow0), OFFER_A.amount + OFFER_B.amount + OFFER_C.amount);

  const order1 = [WHALE_A, WHALE_C, WHALE_B].map((w) => String(captured.book1).indexOf(w));
  check("after reprice: A < C < B", order1[0] > -1 && order1[0] < order1[1] && order1[1] < order1[2], true);
  const order2 = [WHALE_C, WHALE_B, WHALE_A].map((w) => String(captured.book2).indexOf(w));
  check("after add-amend: C < B < A", order2[0] > -1 && order2[0] < order2[1] && order2[1] < order2[2], true);
  check("A record amount (5M MIA)", num(captured.aRec, "amount"), A_FINAL.amount);
  check("A record ask (1.25M sats)", num(captured.aRec, "btc"), A_FINAL.ask);
  check("escrow after add-amend (10M MIA)", bare(captured.escrow1),
    A_FINAL.amount + OFFER_B.amount + OFFER_C.amount);

  // order 1: frontier partial at B's own ratio
  check("B remainder amount (1.5M MIA)", num(captured.bRem, "amount"), B_REM.amount);
  check("B remainder sats (315k)", num(captured.bRem, "btc"), B_REM.btc);
  check("book count after order 1", bare(captured.count1), 2n);
  check("book totals sats after order 1", num(captured.totals1, "btc"), B_REM.btc + A_FINAL.ask);

  // order 2: limit stops below A despite 5M sats of headroom
  check("A survives order 2 (limit respected)",
    String(captured.book3).includes(WHALE_A) && !String(captured.book3).includes(WHALE_B), true);

  // dust: floor'd taken, fee 0
  check("A after dust: amount", num(captured.aRem, "amount"), A_REM.amount);
  check("A after dust: sats", num(captured.aRem, "btc"), A_REM.btc);

  // cancel refunds the remainder; escrow invariant holds
  check("book empty after A cancel", bare(captured.count2), 0n);
  check("escrow empty after A cancel", bare(captured.escrowEnd), 0n);
  check("escrow empty at very end", bare(captured.escrowFinal), 0n);

  // sBTC conservation: taker paid spends + fees; makers got exact asks
  const spentAll = SPEND_1 + SPENT_2 + 1n;
  const feeAll = FEE_1 + FEE_2;
  check("taker sBTC delta == -(spent + fees)",
    bare(captured.T_sbtc_before) - bare(captured.T_sbtc_after), spentAll + feeAll);
  check("taker MIA delta == acquired total",
    bare(captured.T_mia_after) - bare(captured.T_mia_before), ACQ_1 + ACQ_2 + DUST_TAKEN);
  check("fee recipient delta == fees", bare(captured.F_sbtc_after) - bare(captured.F_sbtc_before), feeAll);
  check("whale A sBTC delta == 1 sat (dust fill)",
    bare(captured.A_sbtc_after) - bare(captured.A_sbtc_before), 1n);
  check("whale B sBTC delta == full ask across 2 fills",
    bare(captured.B_sbtc_after) - bare(captured.B_sbtc_before), OFFER_B.ask);
  check("whale C sBTC delta == full ask",
    bare(captured.C_sbtc_after) - bare(captured.C_sbtc_before), OFFER_C.ask);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
