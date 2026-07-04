// verify-v2.js
// SELF-VERIFYING stxer mainnet-fork harness for the v2 pair
// (mia-single-faktory-v2 + mia-fair-faktory-v2) against the LIVE pool.
//
// Mirrors the real v2 deployment path: the v1 trio is already on mainnet
// (2026-07-03), the pool is REUSED (uninitialized as of 2026-07-03, verified
// via get-reserves-quote = 0/0/0), so this sim deploys ONLY the two v2
// contracts under SPV9K21 and drives the live pool.
//
// v2-specific coverage on top of the v1 happy-path arc:
//   - frontier PARTIAL FILL: budget 4,800 STX fills C fully and consumes
//     exactly half of B; B's book record shrinks to {1.5M MIA, 2,100 STX};
//     A is untouched (strict price-time priority, no queue jumping)
//   - MICRO partial: budget u1 (1 uSTX) takes floor(1.5e12/2.1e9) = 714 uMIA
//     off B's remainder -- floor rounding means the maker is never paid
//     below their ask per-uMIA
//   - conservation: three settles (4,800 + 0.000001 + 8,099.999999 STX)
//     sum to EXACTLY the v1 single-settle totals: 12,900 STX / 9M MIA
//   - cancel-after-partial: a fourth offer is half-consumed, then cancelled;
//     the refund returns exactly the shrunken remainder
//   - escrow invariant: with the book empty, fair-v2's MIA balance ==
//     surplus-mia (no MIA stranded or double-counted by partial fills)
//   - get-book-totals read-only before/after each settle
//   - single-v2 DEPOSITOR: direct initialize-pool by the admin -> err u403;
//     only fair-v2's seed-single-sided may fund the vault
//
// NOTE: deployed as Clarity5 in the sim -- stxer 0.8.0 caps at Clarity5 and
// both sources only use Clarity-5 constructs (current-contract/as-contract?).
//
// Run: node simulations/verify-v2.js
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
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22"; // admin
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA + 0.10 sBTC (also depositor 2)
const WHALE_C = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M MIA
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S"; // whitehat, 801k STX free
const SBTC_WHALE = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40.7 sBTC (depositor 1)
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // no position

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const FAKTORY_FEE_ADDR = "SMH8FRN30ERW1SX26NJTJCKTDR3H27NRJ6W75WQE";

const POOL_CID = `${DEPLOYER}.mia-pool-faktory`; // LIVE, reused as-is
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory-v2`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;

const RATIO = 1710n;
const parEquivOf = (spent) => (spent * 1_000_000n) / RATIO;
// exact expected (ok ...) tuple for a settle (all our fills are below par)
function settleExpect(spent, acquired) {
  const p = parEquivOf(spent);
  return `(ok (tuple (acquired u${acquired}) (par-equiv u${p}) (spent u${spent}) (surplus u${acquired - p})))`;
}

// --- Offer plan (uMIA / uSTX), same book as the v1 sims ---
const OFFER_A = { amount: 4_000_000_000_000n, ask: 6_000_000_000n }; // 4M MIA @ 6,000 STX (1.500)
const OFFER_B = { amount: 3_000_000_000_000n, ask: 4_200_000_000n }; // 3M MIA @ 4,200 STX (1.400)
const OFFER_C = { amount: 2_000_000_000_000n, ask: 2_700_000_000n }; // 2M MIA @ 2,700 STX (1.350)
const BOOK_USTX = OFFER_A.ask + OFFER_B.ask + OFFER_C.ask; // 12,900 STX
const BOOK_MIA = OFFER_A.amount + OFFER_B.amount + OFFER_C.amount; // 9e12

// settle 1: fills C fully, then partial-fills B with the remaining 2,100 STX
const BUDGET_1 = 4_800_000_000n;
const B_PAID_1 = BUDGET_1 - OFFER_C.ask; // 2,100 STX into B
const B_TAKEN_1 = (OFFER_B.amount * B_PAID_1) / OFFER_B.ask; // 1.5e12 exactly
const SPENT_1 = BUDGET_1;
const ACQ_1 = OFFER_C.amount + B_TAKEN_1; // 3.5e12
const B_REM_1 = { amount: OFFER_B.amount - B_TAKEN_1, ustx: OFFER_B.ask - B_PAID_1 }; // {1.5e12, 2.1e9}

// settle 2: micro -- 1 uSTX off B's remainder, floor()'d taken
const BUDGET_2 = 1n;
const B_TAKEN_2 = (B_REM_1.amount * BUDGET_2) / B_REM_1.ustx; // 714
const B_REM_2 = { amount: B_REM_1.amount - B_TAKEN_2, ustx: B_REM_1.ustx - BUDGET_2 };

// settle 3: clears B's remainder + A (budget overshoots; spent is exact)
const BUDGET_3 = 13_000_000_000n;
const SPENT_3 = B_REM_2.ustx + OFFER_A.ask; // 8,099,999,999
const ACQ_3 = B_REM_2.amount + OFFER_A.amount; // 5,499,999,999,286

// cancel-after-partial episode: C re-offers, half is consumed, C cancels
const OFFER_C2 = { amount: 1_000_000_000_000n, ask: 1_400_000_000n }; // 1M MIA @ 1,400 STX
const BUDGET_4 = 700_000_000n; // half the ask
const C2_TAKEN = (OFFER_C2.amount * BUDGET_4) / OFFER_C2.ask; // 5e11 exactly
const C2_REM = { amount: OFFER_C2.amount - C2_TAKEN, ustx: OFFER_C2.ask - BUDGET_4 };

const TOTAL_SPENT = SPENT_1 + BUDGET_2 + SPENT_3 + BUDGET_4; // 13,600 STX
const TOTAL_SETTLED = ACQ_1 + B_TAKEN_2 + ACQ_3 + C2_TAKEN; // 9.5e12
const TOTAL_PAR_EQUIV =
  parEquivOf(SPENT_1) + parEquivOf(BUDGET_2) + parEquivOf(SPENT_3) + parEquivOf(BUDGET_4);
const TOTAL_SURPLUS = TOTAL_SETTLED - TOTAL_PAR_EQUIV; // ~1.546M MIA

// --- Pool seed: identical to the v1 sims (live pool is uninitialized) ---
const POOL_LOWEST = 100_000n;
const POOL_HIGHEST = 149_999_900_000n;
const SEED_AMOUNT = 1_200_000_000_000n; // 1.2M MIA into the vault (<= surplus)
const DEP1_LP = 50_000n;
const DEP2_LP = 100_000n;

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
// Act 1 -- deploy the v2 pair only (single first: fair-v2 cross-calls it)
// =====================================================================
deploy("mia-single-faktory-v2");
deploy("mia-fair-faktory-v2");

call("initialize by non-admin -> err u13000", STRANGER, FAIR_CID, "initialize", [], "(err u13000)");
call("initialize (admin) -> ok", DEPLOYER, FAIR_CID, "initialize", [], /^\(ok /);
evalc("par ratio (copied from live ccd013)", "(get-info)", "info0");
evalc("live ccd013 frozen ratio",
  "(contract-call? 'SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia get-redemption-ratio)",
  "ccd013ratio");
call("single-v2 initialize-pool by admin directly -> err u403 (DEPOSITOR = fair-v2 only)",
  DEPLOYER, SINGLE_CID, "initialize-pool", [uintCV(1_000_000n)], "(err u403)");

// =====================================================================
// Act 2 -- whales place the same below-par book (C cheapest)
// =====================================================================
call("offer above par -> err u13012", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(1_000_000_000_000n), uintCV(10_000_000_000n)], "(err u13012)");
call("whale A offers 4M MIA @ 6,000 STX", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(ok true)");
call("whale A duplicate offer -> err u13016", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(1_000_000n), uintCV(1_000n)], "(err u13016)");
call("whale B offers 3M MIA @ 4,200 STX", WHALE_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_B.amount), uintCV(OFFER_B.ask)], "(ok true)");
call("whale C offers 2M MIA @ 2,700 STX", WHALE_C, FAIR_CID, "place-offer",
  [uintCV(OFFER_C.amount), uintCV(OFFER_C.ask)], "(ok true)");
evalc("book sorted cheapest-first (C,B,A)", "(get-offer-book)", "book");
evalc("get-book-totals (12,900 STX / 9M MIA)", "(get-book-totals)", "totals0");
evalc("escrowed MIA in fair-v2 (9M)", miaBal(FAIR_CID), "fairEscrow");

evalc("whale A STX before", stxBal(WHALE_A), "A_stx_before");
evalc("whale B STX before", stxBal(WHALE_B), "B_stx_before");
evalc("whale C STX before", stxBal(WHALE_C), "C_stx_before");
evalc("settler MIA before", miaBal(SETTLER), "S_mia_before");

// =====================================================================
// Act 3 -- partial fill, micro fill, sweep: 3 settles == v1's single settle
// =====================================================================
call("settle 1: budget 4,800 STX -> C full + HALF of B (frontier partial)",
  SETTLER, FAIR_CID, "settle-offers", [uintCV(BUDGET_1)],
  settleExpect(SPENT_1, ACQ_1), "settle1");
evalc("book after settle 1 (B remainder + A)", "(get-offer-book)", "book1");
evalc("B's shrunken record {1.5M MIA, 2,100 STX}",
  `(get-offer '${WHALE_B})`, "bRem1");
evalc("A untouched (strict priority, no queue jump)",
  `(get-offer '${WHALE_A})`, "aRec1");
evalc("book count after settle 1 (2)", "(get-offer-count)", "count1");
evalc("get-book-totals after settle 1 (8,100 STX / 5.5M MIA)", "(get-book-totals)", "totals1");

call("settle 2: budget u1 -> micro partial, 714 uMIA off B (floor rounding)",
  SETTLER, FAIR_CID, "settle-offers", [uintCV(BUDGET_2)],
  settleExpect(BUDGET_2, B_TAKEN_2), "settle2");
evalc("B's record after micro fill", `(get-offer '${WHALE_B})`, "bRem2");

call("settle 3: budget 13,000 STX -> clears B remainder + A, spent is exact",
  SETTLER, FAIR_CID, "settle-offers", [uintCV(BUDGET_3)],
  settleExpect(SPENT_3, ACQ_3), "settle3");
evalc("book empty after settle 3", "(get-offer-count)", "count3");
evalc("whale A STX after", stxBal(WHALE_A), "A_stx_after");
evalc("whale B STX after", stxBal(WHALE_B), "B_stx_after");

// cancel-after-partial: C re-offers 1M @ 1,400, half consumed, then cancelled
evalc("whale C MIA before re-offer", miaBal(WHALE_C), "C_mia_before2");
call("whale C re-offers 1M MIA @ 1,400 STX", WHALE_C, FAIR_CID, "place-offer",
  [uintCV(OFFER_C2.amount), uintCV(OFFER_C2.ask)], "(ok true)");
call("settle 4: budget 700 STX -> half of C's new offer",
  SETTLER, FAIR_CID, "settle-offers", [uintCV(BUDGET_4)],
  settleExpect(BUDGET_4, C2_TAKEN), "settle4");
evalc("C's shrunken record {0.5M MIA, 700 STX}", `(get-offer '${WHALE_C})`, "cRem");
call("whale C cancels the remainder -> refund of the SHRUNKEN amount",
  WHALE_C, FAIR_CID, "cancel-offer", [], "(ok true)");
evalc("whale C MIA after cancel", miaBal(WHALE_C), "C_mia_after2");
evalc("whale C STX after", stxBal(WHALE_C), "C_stx_after");
evalc("settler MIA after", miaBal(SETTLER), "S_mia_after");
evalc("book empty after cancel", "(get-offer-count)", "count4");
evalc("fair-v2 info after all settles", "(get-info)", "info1");
evalc("fair-v2 MIA balance (== surplus-mia, escrow invariant)", miaBal(FAIR_CID), "fairBalEnd");

// =====================================================================
// Act 4 -- fund admin, init the LIVE pool (gated), seed the vault
// =====================================================================
call("settler funds admin with 150k MIA", SETTLER, MIA, "transfer",
  [uintCV(POOL_LOWEST + POOL_HIGHEST), standardPrincipalCV(SETTLER), standardPrincipalCV(DEPLOYER),
   noneCV()], "(ok true)");
call("sBTC whale funds admin with 150k sats", SBTC_WHALE, SBTC, "transfer",
  [uintCV(150_000n), standardPrincipalCV(SBTC_WHALE), standardPrincipalCV(DEPLOYER),
   noneCV()], "(ok true)");
call("LIVE pool.initialize-pool (100k sats / 150k MIA, swaps stay gated)", DEPLOYER, POOL_CID,
  "initialize-pool", [uintCV(POOL_LOWEST), uintCV(POOL_HIGHEST)], "(ok true)");

call("deposit before seed -> err", SBTC_WHALE, SINGLE_CID, "deposit-sbtc-for-lp",
  [uintCV(DEP1_LP)], (s) => s.startsWith("(err"));

call("seed vault beyond surplus -> err u13017", DEPLOYER, FAIR_CID, "seed-single-sided",
  [uintCV(9_000_000_000_000n)], "(err u13017)");
call("seed vault with 1.2M MIA of the spread (fair-v2 -> single-v2)", DEPLOYER, FAIR_CID,
  "seed-single-sided", [uintCV(SEED_AMOUNT)], "(ok true)");
evalc("vault MIA after seed (1.2M)", miaBal(SINGLE_CID), "vaultSeed");

// =====================================================================
// Act 5 -- community deposits sBTC single-sided; inline guards
// =====================================================================
call("gated direct swap -> err u403", SBTC_WHALE, POOL_CID, "swap-a-to-b",
  [uintCV(10_000n), uintCV(0n)], "(err u403)");
call("dust deposit (lp=19) -> err u406", SBTC_WHALE, SINGLE_CID, "deposit-sbtc-for-lp",
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
evalc("LP locked in single-v2 forever",
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
  console.log("=== mia v2 pair (partial fill) -- self-verifying stxer harness ===\n");
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

  // par snapshot
  const ratio = num(captured.info0, "redemption-ratio");
  check("our par == live ccd013 frozen ratio", ratio, bare(captured.ccd013ratio));
  check("par is the DAO's canonical 1710", ratio, RATIO);

  // book + totals before settling
  const order = [WHALE_C, WHALE_B, WHALE_A].map((w) => String(captured.book).indexOf(w));
  check("book order C < B < A", order[0] > -1 && order[0] < order[1] && order[1] < order[2], true);
  check("book totals ustx (12,900 STX)", num(captured.totals0, "ustx"), BOOK_USTX);
  check("book totals amount (9M MIA)", num(captured.totals0, "amount"), BOOK_MIA);
  check("escrow == book amount", bare(captured.fairEscrow), BOOK_MIA);

  // settle 1: frontier partial on B
  check("B remainder amount (1.5M MIA)", num(captured.bRem1, "amount"), B_REM_1.amount);
  check("B remainder ustx (2,100 STX)", num(captured.bRem1, "ustx"), B_REM_1.ustx);
  check("A untouched amount", num(captured.aRec1, "amount"), OFFER_A.amount);
  check("A untouched ustx", num(captured.aRec1, "ustx"), OFFER_A.ask);
  check("book count after settle 1", bare(captured.count1), 2n);
  check("book totals ustx after settle 1", num(captured.totals1, "ustx"), B_REM_1.ustx + OFFER_A.ask);
  check("book totals amount after settle 1", num(captured.totals1, "amount"), B_REM_1.amount + OFFER_A.amount);

  // settle 2: micro fill, floor'd taken
  check("micro fill took 714 uMIA for 1 uSTX", B_TAKEN_2, 714n);
  check("B record after micro (amount)", num(captured.bRem2, "amount"), B_REM_2.amount);
  check("B record after micro (ustx)", num(captured.bRem2, "ustx"), B_REM_2.ustx);

  // conservation: 3 settles == v1's single 12,900-STX settle
  check("settles 1+2+3 spent == 12,900 STX", SPENT_1 + BUDGET_2 + SPENT_3, BOOK_USTX);
  check("settles 1+2+3 acquired == 9M MIA", ACQ_1 + B_TAKEN_2 + ACQ_3, BOOK_MIA);
  check("book empty after settle 3", bare(captured.count3), 0n);

  // makers were paid their FULL asks across split fills
  check("whale A STX delta == ask", bare(captured.A_stx_after) - bare(captured.A_stx_before), OFFER_A.ask);
  check("whale B STX delta == ask (across 3 settles)", bare(captured.B_stx_after) - bare(captured.B_stx_before), OFFER_B.ask);
  check("whale C STX delta == ask + 700 STX partial", bare(captured.C_stx_after) - bare(captured.C_stx_before), OFFER_C.ask + BUDGET_4);

  // cancel-after-partial: refund is exactly the shrunken remainder
  check("C remainder amount (0.5M MIA)", num(captured.cRem, "amount"), C2_REM.amount);
  check("C remainder ustx (700 STX)", num(captured.cRem, "ustx"), C2_REM.ustx);
  check("C MIA delta == -(consumed half)", bare(captured.C_mia_before2) - bare(captured.C_mia_after2), C2_TAKEN);
  check("book empty after cancel", bare(captured.count4), 0n);

  // settler received the par-equivalent of every uSTX spent
  check("settler MIA delta == sum of par-equivs",
    bare(captured.S_mia_after) - bare(captured.S_mia_before), TOTAL_PAR_EQUIV);

  // contract accounting + escrow invariant
  check("total-spent (13,600 STX)", num(captured.info1, "total-spent"), TOTAL_SPENT);
  check("total-settled (9.5M MIA)", num(captured.info1, "total-settled"), TOTAL_SETTLED);
  check("surplus-mia == settled - par-equivs", num(captured.info1, "surplus-mia"), TOTAL_SURPLUS);
  check("fair-v2 MIA balance == surplus-mia (nothing stranded)", bare(captured.fairBalEnd), TOTAL_SURPLUS);

  // vault accounting (same numbers as v1 sims; live pool freshly initialized)
  check("vault seeded with 1.2M MIA", bare(captured.vaultSeed), SEED_AMOUNT);
  check("vault MIA after deposits (975k)", bare(captured.vaultAfterDeps), SEED_AMOUNT - 75_000_000_000n - 150_000_000_000n);
  check("dep1 entitlement == 50k LP", bare(captured.dep1lp), DEP1_LP);
  check("dep1 entitlement cleared after exit", bare(captured.dep1lpAfter), 0n);

  const feeDelta = bare(captured.fee_after) - bare(captured.fee_before);
  check("faktory fee >= 20 sats (buy leg exact + sell leg)", feeDelta >= 20n, true);

  check("LP locked in single-v2 == 120,000", bare(captured.lockedLp), DEP1_LP + DEP2_LP - (DEP1_LP * 60n) / 100n);

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
