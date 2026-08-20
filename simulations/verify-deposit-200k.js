// verify-deposit-200k.js
// SELF-VERIFYING stxer mainnet-fork sim from CURRENT live state
// (pool initialized at 18,000 sats / 86,882.58 MIA, vault seeded with the
// full 6,548,921.83 MIA surplus, swaps still gated - all done on mainnet
// 2026-08-19):
//
//   - SP3H6X...RXW2 holds 200,000 sats and wants max LP:
//     deposit-sbtc-for-lp(u200000) - LP units track the sats side 1:1
//   - verify the deposit pulls exactly 200,000 sats + ~965,362 MIA from the
//     escrow at the frozen price
//   - early withdraw -> err u407
//   - advance 12,961 burn blocks (~90 days) -> withdraw ok: 60% of LP
//     removed, both legs paid, 40% locked forever, second withdraw u408
//   - then the admin opens the gates and a swap clears (preview of step 4)
//
// Run: node simulations/verify-deposit-200k.js
import {
  uintCV,
  boolCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const USER = "SP3H6XX8W8MC3DXFN7H4D95X993D29XW5RGEJRXW2"; // 200k sats
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const POOL_CID = `${DEPLOYER}.mia-pool-faktory`;
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory-v2`;

const DEP_LP = 200_000n; // = 200,000 sats while dk:dx is 1:1

const plan = [];
const b = SimulationBuilder.new({ stacksNodeAPI: "http://77.42.3.101/stacks-api" });

function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({
    contract_id: cid,
    function_name: fn,
    function_args: args,
  });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(POOL_CID, code);
  plan.push({ kind: "eval", label, capture });
}

// ---- current live state ----
evalc("reserves now", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res0");
evalc("gated now", `(contract-call? '${POOL_CID} is-gated)`, "gated0");
evalc("user sats now", `(contract-call? '${SBTC} get-balance '${USER})`, "uSbtc0");
evalc("user MIA now", `(contract-call? '${MIA} get-balance '${USER})`, "uMia0");
evalc("LP quote for u200000", `(contract-call? '${SINGLE_CID} calculate-amounts-for-lp u${DEP_LP})`, "quote0");

// ---- the deposit ----
call("deposit-sbtc-for-lp(u200000) -> ok", USER,
  SINGLE_CID, "deposit-sbtc-for-lp", [uintCV(DEP_LP)], /^\(ok /, "dep0");
evalc("user sats after deposit", `(contract-call? '${SBTC} get-balance '${USER})`, "uSbtc1");
evalc("reserves after deposit", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res1");
evalc("user LP entitlement", `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${USER})`, "lp0");

// ---- locked until the 90-day mark ----
call("withdraw before unlock -> err u407", USER,
  SINGLE_CID, "withdraw-lp-tokens", [], "(err u407)");

b.addAdvanceBlocks({ bitcoin_blocks: 12961, stacks_blocks_per_bitcoin: 1, bitcoin_interval_secs: 1 });
plan.push({ kind: "advance", label: "advance 12,961 burn blocks (~90 days)" });

evalc("vault unlocked?", `(get is-unlocked (contract-call? '${SINGLE_CID} get-pool-info))`, "unlocked1");
call("withdraw-lp-tokens after unlock -> ok", USER,
  SINGLE_CID, "withdraw-lp-tokens", [], /^\(ok /, "wd1");
evalc("user sats after withdraw", `(contract-call? '${SBTC} get-balance '${USER})`, "uSbtc2");
evalc("user MIA after withdraw", `(contract-call? '${MIA} get-balance '${USER})`, "uMia2");
call("second withdraw -> err u408", USER,
  SINGLE_CID, "withdraw-lp-tokens", [], "(err u408)");

// ---- opening preview ----
call("set-gated(false) by stranger -> err u403", STRANGER,
  POOL_CID, "set-gated", [boolCV(false)], "(err u403)");
call("set-gated(false) by deployer -> ok", DEPLOYER,
  POOL_CID, "set-gated", [boolCV(false)], /^\(ok /);
// 10k MIA in: enough that the sats leg is nonzero (1 MIA would round to 0
// and the sBTC transfer rejects zero amounts)
call("swap-b-to-a after opening -> ok", USER,
  POOL_CID, "swap-b-to-a", [uintCV(10_000_000_000n), uintCV(0n)], /^\(ok /);

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
const bare = (s) => BigInt((String(s).match(/u(\d+)/) || [])[1] ?? "-1");

async function main() {
  console.log("=== 200k-sat deposit + 90-day withdraw -- live-state sim ===\n");
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
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 160)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 200)}`);
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

  check("deposit pulled exactly 200,000 sats",
    bare(captured.uSbtc0) - bare(captured.uSbtc1), DEP_LP);
  check("quote sbtc-needed == 200,000", num(captured.quote0, "sbtc-needed"), DEP_LP);
  check("price unchanged by the deposit",
    num(captured.res0, "dx") * num(captured.res1, "dy") ===
      num(captured.res1, "dx") * num(captured.res0, "dy"), true);
  // withdraw-lp-tokens returns (ok user-lp); the 60/40 split is proven by
  // the exact balance deltas (dk:dx stayed 1:1 all window, so sats == LP)
  check("withdraw paid back exactly 60% of the sats leg",
    bare(captured.uSbtc2) - bare(captured.uSbtc1), (DEP_LP * 60n) / 100n);
  check("withdraw paid back exactly 60% of the MIA leg",
    bare(captured.uMia2) - bare(captured.uMia0),
    (num(captured.quote0, "token-needed") * 60n) / 100n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
