// verify-burn-and-run.js
// stxer mainnet-fork harness for mia-burn-and-run against the LIVE v2 machine.
//
// The scenario Friedger asked for: he burns exactly the MIA he withdrew from
// the machine on 2026-07-28 (withdraw-mia u3231715183625, burn 959,973), runs
// the machine with the full 17,100 STX per-pass ceiling, and the ccd013
// redemption treasury is funded to >= 17,100 STX so the pass can actually pay.
//
// Two acts, because the burn leg and the run leg compete for the same
// treasury:
//   A. treasury funded to EXACTLY 17,100 STX. The burn takes 5,526.232964 out
//      of it first, so the run leg only sees the remainder. Shows what the
//      literal "17,100 in the treasury" gets you.
//   B. treasury topped up so a FULL 17,100 pass is available AFTER the burn.
//      Drains whatever act A left in escrow and proves the machine ends clean.
//
// Live state at authoring (burn ~960,020):
//   - ccd013 redemption balance 0, ratio 1710, redemption-enabled true
//   - fair-v2 book: 34,270,999.305234 MIA asking 54,275.3936 STX (43 offers)
//   - machine v2: 0 STX, 0 MIA escrow
//   - FASTPOOL: 11.667164 STX, 3,231,716.020625 MIA
//
// Run: node simulations/verify-burn-and-run.js
import fs from "fs";
import {
  uintCV,
  deserializeCV,
  cvToString,
  ClarityVersion,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

// --- actors ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X"; // OPERATOR_ADMIN
const SP21FFP = "SP21YTSM60CAY6D011EZVEVNKXVW8FVZE198XEFFP"; // OPERATOR_REWARDS
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S"; // 3.8M STX funder

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const MACHINE_CID = `${DEPLOYER}.stx-to-stx-mia-faktory-v2`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const BAR_CID = `${DEPLOYER}.mia-burn-and-run`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const REWARDS_TREASURY =
  "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const PAR = 1710n;
const SCALE = 1_000_000n;
const redeemPay = (umia) => (umia * PAR) / SCALE; // uSTX ccd013 pays for umia

// --- scenario amounts ---
const WITHDRAWN_MIA = 3_231_715_183_625n; // exactly what he withdrew at burn 959,973
const RUN_USTX = 17_100_000_000n; // MAX_RUN_USTX - the per-pass ceiling
const BURN_VALUE = redeemPay(WITHDRAWN_MIA); // 5,526.232964 STX
const TREASURY_A = 17_100_000_000n; // act A: exactly 17,100 STX
const TREASURY_B = 30_000_000_000n; // act B: generous top-up
const FUND_FASTPOOL = 40_000_000_000n; // he holds 11.67 STX live

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;
const redemption = `(contract-call? '${CCD013} get-redemption-current-balance)`;
const plan_ = (who) => `(contract-call? '${BAR_CID} get-plan '${who})`;

const plan = [];
const b = SimulationBuilder.new();
function deploy(name) {
  b.withSender(DEPLOYER).addContractDeploy({
    contract_name: name,
    source_code: fs.readFileSync(`./contracts/${name}.clar`, "utf8"),
    clarity_version: ClarityVersion.Clarity5,
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
function xfer(label, sender, recipient, amount) {
  b.addSTXTransfer({ sender, recipient, amount: Number(amount) });
  plan.push({ kind: "tx", label, expect: () => true });
}

// =====================================================================
// Act 0 -- deploy + live baselines
// =====================================================================
deploy("mia-burn-and-run");
evalc("machine STX baseline", stxBal(MACHINE_CID), "machineStx0");
evalc("machine MIA escrow baseline", miaBal(MACHINE_CID), "machineMia0");
evalc("ccd013 redemption balance baseline", redemption, "redemption0");
evalc("fair book baseline", "(get-book-totals)", "book0");
evalc("FASTPOOL STX baseline", stxBal(FASTPOOL), "fpStx0");
evalc("FASTPOOL MIA baseline", miaBal(FASTPOOL), "fpMia0");

xfer("fund FASTPOOL with 40,000 STX (fork-only float)", SETTLER, FASTPOOL, FUND_FASTPOOL);

// =====================================================================
// Act 1 -- gates
// =====================================================================
call("burn-and-run above the 17,100 cap -> err u9100", FASTPOOL, BAR_CID, "burn-and-run",
  [uintCV(0n), uintCV(RUN_USTX + 1n), uintCV(1n)], "(err u9100)");
call("burn-and-run from a stranger -> machine rejects", STRANGER, BAR_CID, "burn-and-run",
  [uintCV(0n), uintCV(RUN_USTX), uintCV(1n)], /^\(err /, "strangerRun");

// =====================================================================
// Act 2 -- fund the redemption treasury to EXACTLY 17,100 STX
// =====================================================================
call("fund rewards treasury with 17,100 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(TREASURY_A)], "(ok true)");
evalc("redemption balance after funding (want 17,100 STX)", redemption, "redemptionA");
evalc("get-plan(FASTPOOL) before the run", plan_(FASTPOOL), "planA");

// =====================================================================
// Act 3 -- the run he asked for
// =====================================================================
call("burn-and-run(3,231,715.183625 MIA, 17,100 STX, 5 cycles)", FASTPOOL, BAR_CID, "burn-and-run",
  [uintCV(WITHDRAWN_MIA), uintCV(RUN_USTX), uintCV(5n)], /^\(ok /, "runA");
evalc("machine STX after A (want 0)", stxBal(MACHINE_CID), "machineStxA");
evalc("machine MIA escrow after A", miaBal(MACHINE_CID), "machineMiaA");
evalc("redemption balance after A", redemption, "redemptionA2");
evalc("FASTPOOL STX after A", stxBal(FASTPOOL), "fpStxA");
evalc("FASTPOOL MIA after A (want 0.837 leftover)", miaBal(FASTPOOL), "fpMiaA");
evalc("fair book after A", "(get-book-totals)", "bookA");

// =====================================================================
// Act 4 -- top the treasury up and run again (no MIA left to burn)
// =====================================================================
call("top rewards treasury up by 30,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(TREASURY_B)], "(ok true)");
evalc("redemption balance before B", redemption, "redemptionB");
evalc("get-plan(FASTPOOL) before B", plan_(FASTPOOL), "planB");
call("burn-and-run(0 MIA, 17,100 STX, 5 cycles) - run leg only", FASTPOOL, BAR_CID, "burn-and-run",
  [uintCV(0n), uintCV(RUN_USTX), uintCV(5n)], /^\(ok /, "runB");
evalc("machine STX after B (want 0)", stxBal(MACHINE_CID), "machineStxB");
evalc("machine MIA escrow after B", miaBal(MACHINE_CID), "machineMiaB");
evalc("FASTPOOL STX after B", stxBal(FASTPOOL), "fpStxB");
evalc("fair book after B", "(get-book-totals)", "bookB");

// ---- decode helpers ----
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
const stx = (u) => `${(Number(u) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 6 })} STX`;
const mia = (u) => `${(Number(u) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 6 })} MIA`;

async function main() {
  console.log("=== mia-burn-and-run -- stxer mainnet-fork harness ===\n");
  const sessionId = await b.run();
  const url = `https://stxer.xyz/simulations/mainnet/${sessionId}`;
  console.log(`Submitted. Fetching results...\n${url}\n`);

  const res = await getSimulationResult(sessionId);
  const c = {};
  let pass = 0, fail = 0;

  res.steps.forEach((s, i) => {
    const p = plan[i];
    if (!p) return;
    if (p.kind === "tx") {
      const d = decodeTx(s);
      if (p.capture) c[p.capture] = d.str;
      const ok =
        typeof p.expect === "function" ? p.expect(d.str) :
        p.expect instanceof RegExp ? p.expect.test(d.str) :
        d.str === p.expect;
      console.log(`${ok ? "PASS" : "FAIL"} [${i}] ${p.label}\n        got ${d.str.slice(0, 200)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) c[p.capture] = v;
      console.log(`info [${i}] ${p.label}: ${String(v).slice(0, 200)}`);
    } else if (p.kind === "deploy") {
      console.log(`deploy [${i}] ${p.label}`);
    }
  });

  console.log("\n--- ledger ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "PASS" : "FAIL"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  console.log(`burn value at par            ${stx(BURN_VALUE)}  (${mia(WITHDRAWN_MIA)} x 1710)`);
  console.log(`treasury funded in act A     ${stx(bare(c.redemptionA))}`);
  console.log(`treasury after act A         ${stx(bare(c.redemptionA2))}`);
  console.log(`FASTPOOL STX gained in A     ${stx(bare(c.fpStxA) - bare(c.fpStx0) - FUND_FASTPOOL)}`);
  console.log(`machine escrow left after A  ${mia(bare(c.machineMiaA))}`);
  console.log(`book before                  ${c.book0}`);
  console.log(`book after A                 ${c.bookA}`);
  console.log(`book after B                 ${c.bookB}`);
  console.log(`FASTPOOL STX gained total    ${stx(bare(c.fpStxB) - bare(c.fpStx0) - FUND_FASTPOOL)}`);

  check("act A: treasury started at exactly 17,100 STX", bare(c.redemptionA), bare(c.redemption0) + TREASURY_A);
  check("act A: FASTPOOL MIA fully burned (only pre-existing dust left)",
    bare(c.fpMiaA), bare(c.fpMia0) - WITHDRAWN_MIA);
  check("act A: machine holds no STX afterwards", bare(c.machineStxA), 0n);
  check("act B: machine holds no STX afterwards", bare(c.machineStxB), 0n);
  check("act B: machine escrow fully redeemed", bare(c.machineMiaB), 0n);
  const netGain = bare(c.fpStxB) - bare(c.fpStx0) - FUND_FASTPOOL;
  check("operator ends up ahead (net STX gain > 0)", netGain > 0n, true);

  console.log(`\n${pass} passed, ${fail} failed`);
  console.log(url);
}
main().catch((e) => { console.error(e); process.exit(1); });
