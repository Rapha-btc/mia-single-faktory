// verify-redeposit.js
// SELF-VERIFYING stxer mainnet-fork sim: the SAME address deposits into
// mia-single-faktory-v2 TWICE, then withdraws after the 90-day lock.
//
//   - deposit u60000, then deposit u80000 more from the same wallet
//   - entitlement accumulates to u140000 (map-set adds, never overwrites)
//   - advance 12,961 burn blocks -> withdraw pays exactly 60% of the
//     COMBINED position on both legs (dk:dx stays 1:1 while gated, so
//     sats-back == 60% of 140,000 and MIA-back == 60% of the summed
//     token-needed quotes), 40% locked forever
//   - second withdraw -> err u408
//
// Run: node simulations/verify-redeposit.js
import { uintCV, noneCV, standardPrincipalCV, deserializeCV, cvToString } from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const SBTC_WHALE = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40+ sBTC
const USER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // funded in Act 0

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const POOL_CID = `${DEPLOYER}.mia-pool-faktory`;
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory-v2`;

const DEP1 = 60_000n;
const DEP2 = 80_000n;
const TOTAL = DEP1 + DEP2; // 140,000

const plan = [];
const b = SimulationBuilder.new({ stacksNodeAPI: "http://77.42.3.101/stacks-api" });

function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({ contract_id: cid, function_name: fn, function_args: args });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(POOL_CID, code);
  plan.push({ kind: "eval", label, capture });
}

// ---- Act 0: fund the user with sBTC ----
call("fund: 140,000 sats to user", SBTC_WHALE, SBTC, "transfer",
  [uintCV(TOTAL), standardPrincipalCV(SBTC_WHALE), standardPrincipalCV(USER), noneCV()],
  /^\(ok /);
evalc("user MIA before anything", `(contract-call? '${MIA} get-balance '${USER})`, "mia0");

// ---- Act 1: two deposits from the same address ----
evalc("quote for first u60000", `(contract-call? '${SINGLE_CID} calculate-amounts-for-lp u${DEP1})`, "q1");
call("deposit #1 (u60000) -> ok", USER, SINGLE_CID, "deposit-sbtc-for-lp", [uintCV(DEP1)], /^\(ok /);
evalc("entitlement after #1", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${USER})`, "lp1");

evalc("quote for second u80000", `(contract-call? '${SINGLE_CID} calculate-amounts-for-lp u${DEP2})`, "q2");
call("deposit #2 (u80000, same address) -> ok", USER, SINGLE_CID, "deposit-sbtc-for-lp", [uintCV(DEP2)], /^\(ok /);
evalc("entitlement after #2 (accumulated)", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${USER})`, "lp2");
evalc("user sats after both (expect 0)", `(contract-call? '${SBTC} get-balance '${USER})`, "sbtc1");

// ---- Act 2: 90 days pass, single withdraw covers the combined position ----
b.addAdvanceBlocks({ bitcoin_blocks: 12961, stacks_blocks_per_bitcoin: 1, bitcoin_interval_secs: 1 });
plan.push({ kind: "advance", label: "advance 12,961 burn blocks" });

call("withdraw-lp-tokens -> ok (combined)", USER, SINGLE_CID, "withdraw-lp-tokens", [], /^\(ok /, "wd");
evalc("user sats after withdraw", `(contract-call? '${SBTC} get-balance '${USER})`, "sbtc2");
evalc("user MIA after withdraw", `(contract-call? '${MIA} get-balance '${USER})`, "mia2");
evalc("entitlement after withdraw (expect 0)", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${USER})`, "lp3");
call("second withdraw -> err u408", USER, SINGLE_CID, "withdraw-lp-tokens", [], "(err u408)");

// ---- run + assert ----
function decodeTx(s) {
  const r = s?.Result?.Transaction;
  if (!r) return { ok: false, str: "<no transaction result>" };
  if ("Err" in r) return { ok: false, str: `ENGINE-ERR: ${JSON.stringify(r.Err).slice(0, 200)}` };
  try { return { ok: true, str: cvToString(deserializeCV(r.Ok.result)) }; }
  catch (e) { return { ok: false, str: `decode-failed(${r.Ok.result}): ${e.message}` }; }
}
function decodeEval(s) {
  const r = s?.Result?.Eval;
  if (!r) return "<no eval result>";
  if (!("Ok" in r)) return `ERR: ${JSON.stringify(r.Err).slice(0, 200)}`;
  try { return cvToString(deserializeCV(r.Ok)); } catch { return r.Ok; }
}
const num = (s, key) => BigInt((String(s).match(new RegExp(`\\(${key} u(\\d+)\\)`)) || [])[1] ?? "-1");
const bare = (s) => BigInt((String(s).match(/u(\d+)/) || [])[1] ?? "-1");

async function main() {
  console.log("=== same-address redeposit + combined withdraw -- live-state sim ===\n");
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
      const ok = p.expect instanceof RegExp ? p.expect.test(d.str) : d.str === p.expect;
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 140)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 140)}`);
    } else if (p.kind === "advance") {
      console.log(`⏩ [${i}] ${p.label}`);
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  check("entitlement after #1 == 60,000", bare(captured.lp1), DEP1);
  check("entitlement ACCUMULATED to 140,000", bare(captured.lp2), TOTAL);
  check("both deposits pulled all 140,000 sats", bare(captured.sbtc1), 0n);

  // 60% of the combined position, both legs, exact
  const miaIn = num(captured.q1, "token-needed") + num(captured.q2, "token-needed");
  check("withdraw sats == 60% of combined (84,000)", bare(captured.sbtc2), (TOTAL * 60n) / 100n);
  check("withdraw MIA == 60% of combined MIA legs",
    bare(captured.mia2) - bare(captured.mia0), (miaIn * 60n) / 100n);
  check("entitlement cleared after withdraw", bare(captured.lp3), 0n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => { console.error(err); process.exit(1); });
