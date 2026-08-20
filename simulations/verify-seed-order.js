// verify-seed-order.js
// SELF-VERIFYING stxer mainnet-fork sim for the LIVE pool-seeding runbook,
// end to end, with the exact uints planned for mainnet:
//
//   0. fund SPV9K21 (holds 0 sats / 0 MIA on mainnet as of 2026-08-19)
//   1. mia-pool-faktory.initialize-pool(u18000, u86882562000)
//      -> ratio at Alex market: 909.4685 MIA/STX x 188.42 sats/STX
//         = 4.82681 MIA/sat = 207,177 sats per 1M MIA
//   2. mia-fair-faktory-v2.seed-single-sided(u6548921827191)  (full surplus)
//   3. community deposit-sbtc-for-lp pairs at the FROZEN ratio
//   4. set-gated(false) -> swapping opens
//
// Safety claims verified along the way:
//   - before initialize-pool: add-liquidity reverts (pool-opened gate) and
//     a stranger cannot initialize
//   - after initialize-pool: swaps revert for EVERYONE (gated=true, no
//     approved callers, no direct-wallet escape hatch) -> nobody can move
//     the ratio during the single-sided window
//   - a stranger's direct add-liquidity is ratio-neutral (price unchanged)
//   - deposit-sbtc-for-lp works while gated and pairs at the seeded price
//   - withdraw-lp-tokens before the 12,960-block unlock -> err u407
//   - after set-gated(false): a swap goes through
//
// Run: node simulations/verify-seed-order.js
import {
  uintCV,
  boolCV,
  noneCV,
  standardPrincipalCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const WHALE_MIA = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const SBTC_WHALE = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40+ sBTC
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const POOL_CID = `${DEPLOYER}.mia-pool-faktory`;
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory-v2`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;

// --- the exact planned mainnet numbers ---
const LOWEST = 18_000n; // sats
const HIGHEST = 86_882_562_000n; // micro-MIA top-up
const DY_TOTAL = LOWEST + HIGHEST; // 86,882,580,000 micro = 86,882.58 MIA
const SURPLUS = 6_548_921_827_191n; // full captured spread (live on-chain)
const DEP_LP = 100_000n; // community LP purchase during the window

const plan = [];
const b = SimulationBuilder.new();

function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({
    contract_id: cid,
    function_name: fn,
    function_args: args,
  });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(FAIR_CID, code);
  plan.push({ kind: "eval", label, capture });
}

// ============ Act 0: fund the deployer ============
call("fund: whale sends 86,882.58 MIA to deployer", WHALE_MIA, MIA, "transfer",
  [uintCV(DY_TOTAL), standardPrincipalCV(WHALE_MIA), standardPrincipalCV(DEPLOYER), noneCV()],
  /^\(ok /);
call("fund: whale sends 18,000 sats to deployer", SBTC_WHALE, SBTC, "transfer",
  [uintCV(LOWEST), standardPrincipalCV(SBTC_WHALE), standardPrincipalCV(DEPLOYER), noneCV()],
  /^\(ok /);

// ============ Act 1: pool sealed before init ============
call("add-liquidity before init -> err u403", STRANGER,
  POOL_CID, "add-liquidity", [uintCV(1000n)], "(err u403)");
call("initialize-pool by stranger -> err u403", STRANGER,
  POOL_CID, "initialize-pool", [uintCV(LOWEST), uintCV(HIGHEST)], "(err u403)");

// ============ Act 2: the real init, ratio at market ============
call("initialize-pool(u18000, u86882562000) -> ok", DEPLOYER,
  POOL_CID, "initialize-pool", [uintCV(LOWEST), uintCV(HIGHEST)], /^\(ok /);
evalc("reserves after init", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res0");
evalc("gated?", `(contract-call? '${POOL_CID} is-gated)`, "gated0");

// swaps dead for everyone while gated
call("gated swap-a-to-b (stranger) -> err u403", SBTC_WHALE,
  POOL_CID, "swap-a-to-b", [uintCV(1000n), uintCV(0n)], "(err u403)");
call("gated swap-b-to-a (whale) -> err u403", WHALE_MIA,
  POOL_CID, "swap-b-to-a", [uintCV(1_000_000n), uintCV(0n)], "(err u403)");

// ============ Act 3: seed the vault from the fair book ============
call("seed-single-sided by stranger -> err u13000", STRANGER,
  FAIR_CID, "seed-single-sided", [uintCV(1n)], "(err u13000)");
call("seed-single-sided(u6548921827191) by admin -> ok", DEPLOYER,
  FAIR_CID, "seed-single-sided", [uintCV(SURPLUS)], /^\(ok /);
evalc("vault state after seed", `(contract-call? '${SINGLE_CID} get-pool-info)`, "vault0");
evalc("fair-v2 surplus after seed", `(get surplus-mia (contract-call? '${FAIR_CID} get-info))`, "surplus0");

// ============ Act 4: community pairing while gated ============
evalc("LP quote for u100000", `(contract-call? '${SINGLE_CID} calculate-amounts-for-lp u${DEP_LP})`, "quote0");
call("deposit-sbtc-for-lp(u100000) -> ok", SBTC_WHALE,
  SINGLE_CID, "deposit-sbtc-for-lp", [uintCV(DEP_LP)], /^\(ok /);
evalc("reserves after community deposit", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res1");

// a stranger's direct proportional add cannot move the price either
call("fund: MIA to stranger", WHALE_MIA, MIA, "transfer",
  [uintCV(50_000_000_000n), standardPrincipalCV(WHALE_MIA), standardPrincipalCV(STRANGER), noneCV()],
  /^\(ok /);
call("fund: sats to stranger", SBTC_WHALE, SBTC, "transfer",
  [uintCV(100_000n), standardPrincipalCV(SBTC_WHALE), standardPrincipalCV(STRANGER), noneCV()],
  /^\(ok /);
call("direct add-liquidity by stranger -> ok (ratio-neutral)", STRANGER,
  POOL_CID, "add-liquidity", [uintCV(5_000n)], /^\(ok /);
evalc("reserves after stranger add", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res2");

// ============ Act 5: LP locked, then gates open ============
call("withdraw-lp-tokens before unlock -> err u407", SBTC_WHALE,
  SINGLE_CID, "withdraw-lp-tokens", [], "(err u407)");

call("set-gated(false) by stranger -> err u403", STRANGER,
  POOL_CID, "set-gated", [boolCV(false)], "(err u403)");
call("set-gated(false) by deployer -> ok", DEPLOYER,
  POOL_CID, "set-gated", [boolCV(false)], /^\(ok /);
call("swap-a-to-b after opening -> ok", SBTC_WHALE,
  POOL_CID, "swap-a-to-b", [uintCV(1000n), uintCV(0n)], /^\(ok /, "swapOut");
evalc("reserves after first open swap", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res3");

// ============ Act 6: 90 days pass, depositor withdraws ============
// LOCK_PERIOD is 12,960 burn blocks; jump past it. (result loop ignores
// unknown plan kinds, so the advance step only needs index alignment)
b.addAdvanceBlocks({ bitcoin_blocks: 12961, stacks_blocks_per_bitcoin: 1, bitcoin_interval_secs: 1 });
plan.push({ kind: "advance", label: "advance 12,961 burn blocks (~90 days)" });

evalc("vault unlocked?", `(get is-unlocked (contract-call? '${SINGLE_CID} get-pool-info))`, "unlocked1");
evalc("depositor sBTC before withdraw", `(contract-call? '${SBTC} get-balance '${SBTC_WHALE})`, "wSbtc0");
evalc("depositor MIA before withdraw", `(contract-call? '${MIA} get-balance '${SBTC_WHALE})`, "wMia0");

call("withdraw-lp-tokens after unlock -> ok", SBTC_WHALE,
  SINGLE_CID, "withdraw-lp-tokens", [], /^\(ok /, "wd1");
evalc("depositor sBTC after withdraw", `(contract-call? '${SBTC} get-balance '${SBTC_WHALE})`, "wSbtc1");
evalc("depositor MIA after withdraw", `(contract-call? '${MIA} get-balance '${SBTC_WHALE})`, "wMia1");

call("second withdraw -> err u408 (nothing left)", SBTC_WHALE,
  SINGLE_CID, "withdraw-lp-tokens", [], "(err u408)");

// ============ run + assert ============
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

async function main() {
  console.log("=== seed-order runbook -- self-verifying stxer harness ===\n");
  const sessionId = await b.run();
  const url = `https://stxer.xyz/simulations/mainnet/${sessionId}`;
  console.log(`Submitted. Fetching results...\n${url}\n`);

  const res = await getSimulationResult(sessionId);
  const captured = {};
  let pass = 0, fail = 0;

  res.steps.forEach((s, i) => {
    const p = plan[i];
    if (!p) return;
    if (p.kind === "tx") {
      const d = decodeTx(s);
      if (p.capture) captured[p.capture] = d.str;
      const ok =
        p.expect instanceof RegExp ? p.expect.test(d.str) : d.str === p.expect;
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 160)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 200)}`);
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  // init landed the exact planned reserves
  check("dx after init == 18,000 sats", num(captured.res0, "dx"), LOWEST);
  check("dy after init == 86,882,580,000 micro", num(captured.res0, "dy"), DY_TOTAL);

  // vault took the whole surplus, fair book fully drained
  check("vault initial-token == full surplus", num(captured.vault0, "initial-token"), SURPLUS);
  check("fair-v2 surplus-mia after seed == 0", BigInt((String(captured.surplus0).match(/u(\d+)/) || [])[1] ?? "-1"), 0n);

  // price invariance across the whole gated window (exact rational compare:
  // dx0 * dyN == dyO * dxN)
  const priceEq = (a, b2) =>
    num(captured[a], "dx") * num(captured[b2], "dy") ===
    num(captured[b2], "dx") * num(captured[a], "dy");
  check("price unchanged after community deposit", priceEq("res0", "res1"), true);
  check("price unchanged after stranger add", priceEq("res0", "res2"), true);

  // withdraw after the 90-day lock: 60% of the 100k LP entitlement removed,
  // both legs paid out, and the entitlement fully cleared afterwards
  const bareN = (x) => BigInt((String(x).match(/u(\d+)/) || [])[1] ?? "-1");
  check("vault reports unlocked after advance", String(captured.unlocked1).includes("true"), true);
  check("withdraw paid sBTC (delta > 0)", bareN(captured.wSbtc1) > bareN(captured.wSbtc0), true);
  check("withdraw paid MIA (delta > 0)", bareN(captured.wMia1) > bareN(captured.wMia0), true);
  check("withdraw removed 60% of LP", num(captured.wd1, "lp-removed"), (DEP_LP * 60n) / 100n);
  check("40% of LP locked forever", num(captured.wd1, "lp-locked-forever"), DEP_LP - (DEP_LP * 60n) / 100n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
