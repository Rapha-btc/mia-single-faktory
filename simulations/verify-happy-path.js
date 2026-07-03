// verify-happy-path.js
// SELF-VERIFYING stxer mainnet-fork harness for the mia-single-faktory trio.
//
// The full arc, against REAL mainnet state (real MIA whales, real sBTC, live
// MIA supply + mining treasury for the par snapshot):
//
//   1. deploy pool -> single -> fair under SPV9K21 (F-6 address coupling)
//   2. fair.initialize          -> par copied from LIVE ccd013 (frozen u1710)
//   3. three MIA whales place below-par offers (9M MIA total), book sorts
//      cheapest-first
//   4. a whitehat settler (STX-rich) settles the whole book for 12,900 STX:
//      sellers get their asks, settler gets par-equiv MIA, the below-par
//      SPREAD stays in the contract
//   5. admin seeds the pool (100k sats / 150k MIA, swaps stay GATED) and
//      seeds the single-sided vault with 1.2M MIA of the spread
//   6. community deposits sBTC single-sided (50k + 100k sats), pairing at the
//      frozen ratio; guards proven inline (dust u406, gated swap u403,
//      early withdraw u407)
//   7. admin opens the gate -> a buyer swaps sBTC->MIA (exact 0.1% faktory
//      fee assert) and the settler arbs MIA->sBTC
//   8. advance 12,960 burn blocks (~90d) -> depositor exits with 60% of LP,
//      the other 40% provably stays locked in the single contract
//
// NOTE: deployed as Clarity5 in the sim -- stxer 0.8.0 (latest) caps at
// Clarity5, and all three sources only use Clarity-5 constructs
// (current-contract / as-contract?), so behaviour is identical to the
// Clarity-6 manifest.
//
// Run: node simulations/verify-happy-path.js
import fs from "node:fs";
import {
  ClarityVersion,
  uintCV,
  boolCV,
  noneCV,
  standardPrincipalCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

// --- Mainnet actors (impersonated on the fork; balances verified 2026-07-03) ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22"; // admin, 274 STX free
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA + 0.10 sBTC (also depositor 2)
const WHALE_C = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M MIA
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S"; // whitehat, 801k STX free
const SBTC_WHALE = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40.7 sBTC (depositor 1)
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // no position

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const FAKTORY_FEE_ADDR = "SMH8FRN30ERW1SX26NJTJCKTDR3H27NRJ6W75WQE";

const POOL_CID = `${DEPLOYER}.mia-pool-faktory`;
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory`;

// --- Offer plan (uMIA / uSTX). All asks well below par (~1.71 STX per kMIA). ---
const OFFER_A = { amount: 4_000_000_000_000n, ask: 6_000_000_000n }; // 4M MIA @ 6,000 STX (1.500)
const OFFER_B = { amount: 3_000_000_000_000n, ask: 4_200_000_000n }; // 3M MIA @ 4,200 STX (1.400)
const OFFER_C = { amount: 2_000_000_000_000n, ask: 2_700_000_000n }; // 2M MIA @ 2,700 STX (1.350)
const TOTAL_ACQUIRED = OFFER_A.amount + OFFER_B.amount + OFFER_C.amount; // 9e12
const TOTAL_SPENT = OFFER_A.ask + OFFER_B.ask + OFFER_C.ask; // 12,900 STX
const SETTLE_BUDGET = 13_000_000_000n;

// --- Pool seed: 100,000 sats vs 150k MIA (~150M MIA/BTC, market-ish) ---
const POOL_LOWEST = 100_000n; // first add: 100,000 sats + 100,000 uMIA
const POOL_HIGHEST = 149_999_900_000n; // MIA top-up -> reserves 100,000 / 150e9
const SEED_AMOUNT = 1_200_000_000_000n; // 1.2M MIA into the vault (<= spread)

// deposits (lp-amount denominated; pool starts at supply 100,000 LP)
const DEP1_LP = 50_000n; // -> 50,000 sats + 75k MIA from vault
const DEP2_LP = 100_000n; // -> 100,000 sats + 150k MIA from vault

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const sbtcBal = (a) => `(contract-call? '${SBTC} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;

// ---- scenario builder with a parallel assertion plan ----
const plan = [];
const b = SimulationBuilder.new();
const src = (n) => fs.readFileSync(`./contracts/${n}.clar`, "utf8");

function deploy(name) {
  b.withSender(DEPLOYER).addContractDeploy({
    contract_name: name,
    source_code: src(name),
    clarity_version: ClarityVersion.Clarity5, // stxer max; sources are C5-compatible
  });
  plan.push({ kind: "deploy", label: `deploy ${name}` });
}
// expect: exact string, RegExp, or fn(str)=>bool. capture: stash decoded result.
function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({ contract_id: cid, function_name: fn, function_args: args });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(FAIR_CID, code);
  plan.push({ kind: "eval", label, capture });
}
function advance(n) {
  b.addAdvanceBlocks({ bitcoin_blocks: n, stacks_blocks_per_bitcoin: 1, bitcoin_interval_secs: 1 });
  plan.push({ kind: "advance", label: `advance ${n} burn blocks` });
}

// =====================================================================
// Act 1 -- deploy + par snapshot
// =====================================================================
deploy("mia-pool-faktory");
deploy("mia-single-faktory");
deploy("mia-fair-faktory");

call("initialize by non-admin -> err u13000", STRANGER, FAIR_CID, "initialize", [], "(err u13000)");
call("initialize (admin) -> ok", DEPLOYER, FAIR_CID, "initialize", [], /^\(ok /);
evalc("par ratio (copied from live ccd013)", "(get-info)", "info0");
evalc("live ccd013 frozen ratio",
  "(contract-call? 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia get-redemption-ratio)",
  "ccd013ratio");

// =====================================================================
// Act 2 -- MIA whales place below-par offers (A first, C cheapest)
// =====================================================================
call("offer above par -> err u13012", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(1_000_000_000_000n), uintCV(10_000_000_000n)], "(err u13012)"); // 10 STX/kMIA >> par
call("whale A offers 4M MIA @ 6,000 STX", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(ok true)");
call("whale A duplicate offer -> err u13016", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(1_000_000n), uintCV(1_000n)], "(err u13016)");
call("whale B offers 3M MIA @ 4,200 STX", WHALE_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_B.amount), uintCV(OFFER_B.ask)], "(ok true)");
call("whale C offers 2M MIA @ 2,700 STX", WHALE_C, FAIR_CID, "place-offer",
  [uintCV(OFFER_C.amount), uintCV(OFFER_C.ask)], "(ok true)");
evalc("book sorted cheapest-first (C,B,A)", "(get-offer-book)", "book");
evalc("escrowed MIA in fair (9M)", miaBal(FAIR_CID), "fairEscrow");

// seller STX snapshots (no further txs from them until after settle)
evalc("whale A STX before", stxBal(WHALE_A), "A_stx_before");
evalc("whale B STX before", stxBal(WHALE_B), "B_stx_before");
evalc("whale C STX before", stxBal(WHALE_C), "C_stx_before");
evalc("settler MIA before", miaBal(SETTLER), "S_mia_before");

// =====================================================================
// Act 3 -- whitehat settles the whole book (~9M MIA for 12,900 STX)
// =====================================================================
call("settler settles book (budget 13,000 STX)", SETTLER, FAIR_CID, "settle-offers",
  [uintCV(SETTLE_BUDGET)],
  new RegExp(`^\\(ok \\(tuple \\(acquired u${TOTAL_ACQUIRED}\\) \\(par-equiv u\\d+\\) \\(spent u${TOTAL_SPENT}\\) \\(surplus u\\d+\\)\\)\\)$`),
  "settleResult");
evalc("whale A STX after", stxBal(WHALE_A), "A_stx_after");
evalc("whale B STX after", stxBal(WHALE_B), "B_stx_after");
evalc("whale C STX after", stxBal(WHALE_C), "C_stx_after");
evalc("settler MIA after", miaBal(SETTLER), "S_mia_after");
evalc("book empty after settle", "(get-offer-count)", "bookCount");
evalc("fair info after settle (surplus-mia)", "(get-info)", "info1");

// =====================================================================
// Act 4 -- fund admin, seed the pool (gated), seed the vault
// =====================================================================
call("settler funds admin with 150k MIA", SETTLER, MIA, "transfer",
  [uintCV(POOL_LOWEST + POOL_HIGHEST), standardPrincipalCV(SETTLER), standardPrincipalCV(DEPLOYER),
   noneCV()], "(ok true)");
call("sBTC whale funds admin with 150k sats", SBTC_WHALE, SBTC, "transfer",
  [uintCV(150_000n), standardPrincipalCV(SBTC_WHALE), standardPrincipalCV(DEPLOYER),
   noneCV()], "(ok true)");
call("pool.initialize-pool (100k sats / 150k MIA, swaps stay gated)", DEPLOYER, POOL_CID,
  "initialize-pool", [uintCV(POOL_LOWEST), uintCV(POOL_HIGHEST)], "(ok true)");

// deposit before vault is seeded -> aborts (vault has no MIA yet)
call("deposit before seed -> err", SBTC_WHALE, SINGLE_CID, "deposit-sbtc-for-lp",
  [uintCV(DEP1_LP)], (s) => s.startsWith("(err"));

call("seed vault beyond surplus -> err u13017", DEPLOYER, FAIR_CID, "seed-single-sided",
  [uintCV(9_000_000_000_000n)], "(err u13017)");
call("seed vault with 1.2M MIA of the spread", DEPLOYER, FAIR_CID, "seed-single-sided",
  [uintCV(SEED_AMOUNT)], "(ok true)");
evalc("vault MIA after seed (1.2M)", miaBal(SINGLE_CID), "vaultSeed");

// =====================================================================
// Act 5 -- community deposits sBTC single-sided; inline guards
// =====================================================================
call("gated direct swap -> err u403 (F-1 fix)", SBTC_WHALE, POOL_CID, "swap-a-to-b",
  [uintCV(10_000n), uintCV(0n)], "(err u403)");
call("dust deposit (lp=19) -> err u406 (F-3 guard)", SBTC_WHALE, SINGLE_CID, "deposit-sbtc-for-lp",
  [uintCV(19n)], "(err u406)");
call("depositor 1: 50k-LP single-sided deposit", SBTC_WHALE, SINGLE_CID, "deposit-sbtc-for-lp",
  [uintCV(DEP1_LP)], `(ok u${DEP1_LP})`);
call("depositor 2: 100k-LP single-sided deposit", WHALE_B, SINGLE_CID, "deposit-sbtc-for-lp",
  [uintCV(DEP2_LP)], `(ok u${DEP2_LP})`);
evalc("dep1 LP entitlement", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${SBTC_WHALE})`, "dep1lp");
evalc("vault MIA after deposits (975k left)", miaBal(SINGLE_CID), "vaultAfterDeps");
call("withdraw before unlock -> err u407", SBTC_WHALE, SINGLE_CID, "withdraw-lp-tokens", [], "(err u407)");

// =====================================================================
// Act 6 -- open the gate, trade both directions
// =====================================================================
evalc("faktory fee addr sBTC before", sbtcBal(FAKTORY_FEE_ADDR), "fee_before");
call("admin opens the gate (set-gated false)", DEPLOYER, POOL_CID, "set-gated",
  [boolCV(false)], "(ok true)");
call("buyer swaps 20k sats -> MIA", SBTC_WHALE, POOL_CID, "swap-a-to-b",
  [uintCV(20_000n), uintCV(0n)], /^\(ok \(tuple /, "buySwap");
call("settler arbs 1M MIA -> sBTC", SETTLER, POOL_CID, "swap-b-to-a",
  [uintCV(1_000_000_000_000n), uintCV(0n)], /^\(ok \(tuple /, "sellSwap");
evalc("faktory fee addr sBTC after", sbtcBal(FAKTORY_FEE_ADDR), "fee_after");
evalc("pool reserves after trading", `(contract-call? '${POOL_CID} get-reserves-quote)`, "reserves");

// =====================================================================
// Act 7 -- ~90 days pass, depositor 1 exits 60/40
// =====================================================================
advance(12_961);
evalc("dep1 sBTC before withdraw", sbtcBal(SBTC_WHALE), "d1_sbtc_before");
call("stranger withdraw (no deposit) -> err u408", STRANGER, SINGLE_CID, "withdraw-lp-tokens", [], "(err u408)");
call("depositor 1 withdraws after unlock", SBTC_WHALE, SINGLE_CID, "withdraw-lp-tokens", [],
  `(ok u${DEP1_LP})`);
call("depositor 1 double-withdraw -> err u408", SBTC_WHALE, SINGLE_CID, "withdraw-lp-tokens", [], "(err u408)");
evalc("dep1 sBTC after withdraw", sbtcBal(SBTC_WHALE), "d1_sbtc_after");
evalc("dep1 entitlement cleared", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${SBTC_WHALE})`, "dep1lpAfter");
evalc("LP locked in single forever (120k = dep1's 40% + dep2's 150k... )",
  `(contract-call? '${POOL_CID} get-balance '${SINGLE_CID})`, "lockedLp");

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
  console.log("=== mia-single-faktory HAPPY PATH -- self-verifying stxer harness ===\n");
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
    } else if (p.kind === "advance") {
      console.log(`⏩ [${i}] ${p.label}`);
    }
  });

  // ---- numeric cross-checks ----
  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  // par math: par-equiv = floor(spent * 1e6 / ratio); surplus = acquired - par-equiv
  const ratio = num(captured.info0, "redemption-ratio");
  const parEquiv = num(captured.settleResult, "par-equiv");
  const surplus = num(captured.settleResult, "surplus");
  check("our par == live ccd013 frozen ratio", ratio, bare(captured.ccd013ratio));
  check("par is the DAO's canonical 1710", ratio, 1710n);
  check("par-equiv == floor(spent*1e6/ratio)", parEquiv, (TOTAL_SPENT * 1_000_000n) / ratio);
  check("surplus == acquired - par-equiv", surplus, TOTAL_ACQUIRED - parEquiv);
  check("surplus recorded in contract info", num(captured.info1, "surplus-mia"), surplus);

  // sellers got exactly their asks; settler got exactly par-equiv MIA
  check("whale A STX delta == ask", bare(captured.A_stx_after) - bare(captured.A_stx_before), OFFER_A.ask);
  check("whale B STX delta == ask", bare(captured.B_stx_after) - bare(captured.B_stx_before), OFFER_B.ask);
  check("whale C STX delta == ask", bare(captured.C_stx_after) - bare(captured.C_stx_before), OFFER_C.ask);
  check("settler MIA delta == par-equiv", bare(captured.S_mia_after) - bare(captured.S_mia_before), parEquiv);

  // book ordering: cheapest-first C, B, A
  const order = [WHALE_C, WHALE_B, WHALE_A].map((w) => String(captured.book).indexOf(w));
  check("book order C < B < A", order[0] > -1 && order[0] < order[1] && order[1] < order[2], true);
  check("book empty after settle", bare(captured.bookCount), 0n);

  // vault accounting
  check("vault seeded with 1.2M MIA", bare(captured.vaultSeed), SEED_AMOUNT);
  check("vault MIA after deposits (975k)", bare(captured.vaultAfterDeps), SEED_AMOUNT - 75_000_000_000n - 150_000_000_000n);
  check("dep1 entitlement == 50k LP", bare(captured.dep1lp), DEP1_LP);
  check("dep1 entitlement cleared after exit", bare(captured.dep1lpAfter), 0n);

  // faktory fee: buyer paid 0.1% of 20,000 sats = 20 sats in; arb sell fee also lands there
  const feeDelta = bare(captured.fee_after) - bare(captured.fee_before);
  check("faktory fee >= 20 sats (buy leg exact + sell leg)", feeDelta >= 20n, true);

  // the 40% stays: single held 150k LP (50k+100k), withdrew 60% of 50k = 30k -> 120k
  check("LP locked in single == 120,000", bare(captured.lockedLp), DEP1_LP + DEP2_LP - (DEP1_LP * 60n) / 100n);

  // depositor got real sBTC back on exit
  const d1delta = bare(captured.d1_sbtc_after) - bare(captured.d1_sbtc_before);
  check("dep1 received sBTC on withdraw (> 0)", d1delta > 0n, true);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
