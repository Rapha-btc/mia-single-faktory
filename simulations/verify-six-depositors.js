// verify-six-depositors.js
// SELF-VERIFYING stxer mainnet-fork sim from CURRENT live state:
//
//   1. SPV9K21 dusts six sBTC holders with 0.5 STX each in ONE tx via
//      SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.send-many-memo (they all
//      hold sats but ZERO STX, so they cannot even pay gas today)
//   2. each address calls deposit-sbtc-for-lp with its EXACT sBTC balance
//      (LP units are 1:1 with sats while the window is gated and dk == dx)
//   3. checks: every wallet drains to 0 sats, entitlement == balance,
//      pool price bit-identical afterwards, vault escrow debited by the
//      exact MIA sum
//
// Balances verified on-chain 2026-08-19 (see BALS below).
//
// Run: node simulations/verify-six-depositors.js
import {
  uintCV,
  bufferCV,
  listCV,
  tupleCV,
  standardPrincipalCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const SEND_MANY = "SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.send-many-memo";
const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const POOL_CID = `${DEPLOYER}.mia-pool-faktory`;
const SINGLE_CID = `${DEPLOYER}.mia-single-faktory-v2`;

// address -> live sats balance (each deposits exactly this)
const BALS = [
  ["SP1SFGRJ8R660527743WFCPPY1HS64VPGEYGTYYZ2", 20_890n],
  ["SPZENQ98WDG69B6JJD7YP9XQNGY5QYN4ZD29258W", 102_071n],
  ["SP1YT273ZNW9Q1Q3Q6JH4S6K2ZHAH0YBW19RAWMDP", 26_640n],
  ["SP18NFY4D0QMSTWEBZZ1SSTVKCYJFN3RJZ773KDM2", 95_082n],
  ["SP2MJ4R7NP3SNR61A6X1NZ2HTW0B0A4DZXABSWE4", 42_301n],
  ["SP1FT5PREZM9CHQ92VJG1WX1BRB8ENKHG87CH362H", 40_497n],
];
const TOTAL_SATS = BALS.reduce((a, [, v]) => a + v, 0n); // 327,481
const DUST = 500_000n; // 0.5 STX each

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

// ---- state before ----
evalc("reserves before", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res0");
evalc("vault escrow MIA before", `(contract-call? '${MIA} get-balance '${SINGLE_CID})`, "esc0");

// ---- Act 1: one-shot STX dust via send-many ----
call("send-many: 0.5 STX to each of the six -> ok", DEPLOYER,
  SEND_MANY, "send-many",
  [listCV(BALS.map(([to]) => tupleCV({
    to: standardPrincipalCV(to),
    ustx: uintCV(DUST),
    memo: bufferCV(new Uint8Array(0)),
  })))],
  /^\(ok /);
for (const [to] of BALS) {
  evalc(`STX dusted: ${to.slice(0, 8)}…`, `(stx-get-balance '${to})`, `stx-${to}`);
}

// ---- Act 2: each deposits their exact sBTC balance ----
for (const [addr, sats] of BALS) {
  call(`deposit-sbtc-for-lp(u${sats}) by ${addr.slice(0, 8)}… -> ok`, addr,
    SINGLE_CID, "deposit-sbtc-for-lp", [uintCV(sats)], /^\(ok /);
  evalc(`sats left ${addr.slice(0, 8)}… (expect 0)`,
    `(contract-call? '${SBTC} get-balance '${addr})`, `sbtc-${addr}`);
  evalc(`LP entitlement ${addr.slice(0, 8)}…`,
    `(contract-call? '${SINGLE_CID} get-user-lp-tokens '${addr})`, `lp-${addr}`);
}

// ---- state after ----
evalc("reserves after all six", `(contract-call? '${POOL_CID} get-reserves-quote)`, "res1");
evalc("vault escrow MIA after", `(contract-call? '${MIA} get-balance '${SINGLE_CID})`, "esc1");

// ---- Act 3: 90 days pass, all six withdraw ----
b.addAdvanceBlocks({ bitcoin_blocks: 12961, stacks_blocks_per_bitcoin: 1, bitcoin_interval_secs: 1 });
plan.push({ kind: "advance", label: "advance 12,961 burn blocks (~90 days)" });

for (const [addr, sats] of BALS) {
  call(`withdraw after unlock by ${addr.slice(0, 8)}… -> ok`, addr,
    SINGLE_CID, "withdraw-lp-tokens", [], /^\(ok /);
  evalc(`sats back ${addr.slice(0, 8)}…`,
    `(contract-call? '${SBTC} get-balance '${addr})`, `wsbtc-${addr}`);
  evalc(`MIA back ${addr.slice(0, 8)}…`,
    `(contract-call? '${MIA} get-balance '${addr})`, `wmia-${addr}`);
}

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
  console.log("=== six depositors: dust + max deposits -- live-state sim ===\n");
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
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  for (const [addr, sats] of BALS) {
    check(`${addr.slice(0, 8)}… dusted 0.5 STX`, bare(captured[`stx-${addr}`]), DUST);
    check(`${addr.slice(0, 8)}… sats drained to 0`, bare(captured[`sbtc-${addr}`]), 0n);
    check(`${addr.slice(0, 8)}… LP == balance`, bare(captured[`lp-${addr}`]), sats);
  }
  check("price unchanged across all six deposits",
    num(captured.res0, "dx") * num(captured.res1, "dy") ===
      num(captured.res1, "dx") * num(captured.res0, "dy"), true);
  check("pool sats grew by exactly the total (327,481)",
    num(captured.res1, "dx") - num(captured.res0, "dx"), TOTAL_SATS);
  // 90-day withdrawals: dk:dx stayed 1:1 (no swaps), so each depositor
  // gets back exactly 60% of the sats they put in (40% locked forever)
  for (const [addr, sats] of BALS) {
    check(`${addr.slice(0, 8)}… got back 60% of sats`,
      bare(captured[`wsbtc-${addr}`]), (sats * 60n) / 100n);
    check(`${addr.slice(0, 8)}… got MIA leg (> 0)`,
      bare(captured[`wmia-${addr}`]) > 0n, true);
  }

  const escrowDelta = bare(captured.esc0) - bare(captured.esc1);
  const dyDelta = num(captured.res1, "dy") - num(captured.res0, "dy");
  check("vault escrow debited exactly what the pool gained in MIA", escrowDelta, dyDelta);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
