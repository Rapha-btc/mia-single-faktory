// verify-v2-machine.js
// Self-verifying stxer mainnet-fork harness for stx-to-stx-mia-faktory-v2.
// Deploys v2 under SPV9K21 against the LIVE fair book + ccd013 and proves
// each fix:
//
//   F-1 operator allowlist: SP21..FFP (rewards addr) deposits, loops and
//       receives the withdraw - the exact thing v1 forbade. Strangers get
//       u9000 on run() and on deposits.
//   F-2 atomic run(): deposit -> up to 5 cycles -> withdraw-to-caller in
//       one tx; a 3,100 STX deposit consumes 5,800 STX of offers by
//       recycling through redemption; machine ends 0 STX / 0 MIA.
//   F-3 treasury guard: with a DRY treasury a deposit boomerangs exactly
//       (settle skipped even though the live book has offers - v1 would
//       have stranded it as MIA escrow), and a bare trigger fails honestly
//       with u9002 NOTHING_TO_DO.
//   F-4 withdrawals pay the calling operator (SP21 receives its own run's
//       remainder).
//   F-5 settle-and-redeem is deposit-free (permissionless bare trigger
//       only) - capital enters exclusively via run().
//
// Drift-proofing: exact-math acts run AFTER a cleanup run clears whatever
// the live book holds, so expectations depend only on offers this sim
// places. Live-book-sized amounts (CLEANUP) have margin over the ~13,400
// STX of live asks seen at authoring time.
//
// Run: node simulations/verify-v2-machine.js
import fs from "fs";
import {
  uintCV,
  deserializeCV,
  cvToString,
  ClarityVersion,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

// --- actors (impersonated on the fork) ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X"; // operator 1 (admin)
const SP21FFP = "SP21YTSM60CAY6D011EZVEVNKXVW8FVZE198XEFFP"; // operator 2 (rewards)
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S"; // ~800k STX

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const V2_CID = `${DEPLOYER}.stx-to-stx-mia-faktory-v2`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const PAR = 1710n;
const SCALE = 1_000_000n;
const parEquiv = (ustx) => (ustx * SCALE) / PAR;
const redeemPay = (umia) => (umia * PAR) / SCALE;

// --- scenario amounts ---
const FUND_FASTPOOL = 40_000_000_000n; // FASTPOOL holds ~11.58 STX live
const FUND_SP21 = 10_000_000_000n; // rewards addr operates the loop act
const TREASURY_FUND = 60_000_000_000n; // covers cleanup + loop redemptions
const DRY_DEPOSIT = 2_000_000_000n; // F-3 boomerang against dry treasury
const CLEANUP = 30_000_000_000n; // clears the live book (~13.4k at authoring)
const OFFER_A = { amount: 2_000_000_000_000n, ask: 3_000_000_000n }; // 2M @ 3,000
const OFFER_B = { amount: 1_800_000_000_000n, ask: 2_800_000_000n }; // 1.8M @ 2,800
const LOOP_DEPOSIT = 3_100_000_000n; // eats 5,800 of offers via the loop

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;

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
// Act 0 -- deploy v2 + baselines + fork funding
// =====================================================================
deploy("stx-to-stx-mia-faktory-v2");
evalc("live book baseline", "(get-book-totals)", "book0");
evalc("redemption balance baseline (expect 0)", `(contract-call? '${CCD013} get-redemption-current-balance)`, "redemption0");
evalc("SP21 STX baseline", stxBal(SP21FFP), "sp21_0");
xfer("fund FASTPOOL 40,000 STX (fork-only)", SETTLER, FASTPOOL, FUND_FASTPOOL);
xfer("fund SP21..FFP 10,000 STX (fork-only)", SETTLER, SP21FFP, FUND_SP21);

// =====================================================================
// Act 1 -- gates (F-1): strangers rejected everywhere it matters
// =====================================================================
call("run(u0) from stranger -> err u9000", STRANGER, V2_CID, "run", [uintCV(0n)], "(err u9000)");
call("run-loops(u0,u5) from stranger -> err u9000", STRANGER, V2_CID, "run-loops",
  [uintCV(0n), uintCV(5n)], "(err u9000)");
// F-5: settle-and-redeem has NO deposit parameter anymore - capital only
// enters through run(). The bare trigger stays permissionless.

// =====================================================================
// Act 2 -- F-3 guard on a DRY treasury
// =====================================================================
// v1 would have spent this on the live book and stranded it as MIA.
// v2 skips the settle (headroom 0) and boomerangs the deposit exactly.
call("run(2,000 STX) vs dry treasury -> exact boomerang", FASTPOOL, V2_CID, "run",
  [uintCV(DRY_DEPOSIT)], /^\(ok /, "runDry");
// and the honest assert: bare trigger with nothing possible -> u9002
call("bare trigger vs dry treasury -> err u9002", STRANGER, V2_CID,
  "settle-and-redeem", [], "(err u9002)");
evalc("machine STX after dry acts (0)", stxBal(V2_CID), "v2StxDry");
evalc("machine MIA after dry acts (0)", miaBal(V2_CID), "v2MiaDry");

// =====================================================================
// Act 3 -- open redemption headroom, then clear the live book
// =====================================================================
call("settler funds rewards treasury with 60,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(TREASURY_FUND)], "(ok true)");
call("cleanup run-loops(30,000 STX, u5) clears the live book", FASTPOOL, V2_CID, "run-loops",
  [uintCV(CLEANUP), uintCV(5n)], /^\(ok /, "runCleanup");
evalc("book after cleanup (empty)", "(get-book-totals)", "book1");
evalc("machine STX after cleanup (0)", stxBal(V2_CID), "v2StxClean");
evalc("machine MIA after cleanup (0)", miaBal(V2_CID), "v2MiaClean");
evalc("fair surplus after cleanup (loop baseline)", "(get-info)", "fairInfo1");

// =====================================================================
// Act 4 -- controlled offers, then the LOOP driven by SP21..FFP
// =====================================================================
call("whale A offers 2M MIA @ 3,000 STX", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(ok true)");
call("whale B offers 1.8M MIA @ 2,800 STX", WHALE_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_B.amount), uintCV(OFFER_B.ask)], "(ok true)");
evalc("whale A STX before", stxBal(WHALE_A), "wa0");
evalc("whale B STX before", stxBal(WHALE_B), "wb0");
evalc("SP21 STX before loop", stxBal(SP21FFP), "sp21_1");
call("SP21..FFP run-loops(3,100 STX, u5) eats both offers (F-1 + F-2b + F-4)", SP21FFP, V2_CID, "run-loops",
  [uintCV(LOOP_DEPOSIT), uintCV(5n)], /^\(ok /, "runLoop");
evalc("SP21 STX after loop", stxBal(SP21FFP), "sp21_2");
evalc("whale A STX after", stxBal(WHALE_A), "wa1");
evalc("whale B STX after", stxBal(WHALE_B), "wb1");
evalc("machine STX after loop (0)", stxBal(V2_CID), "v2StxLoop");
evalc("machine MIA after loop (0)", miaBal(V2_CID), "v2MiaLoop");
evalc("fair surplus after loop", "(get-info)", "fairInfo2");
evalc("book after loop (empty again)", "(get-book-totals)", "book2");
evalc("v2 machine status", `(contract-call? '${V2_CID} get-status)`, "status");

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

async function main() {
  console.log("=== stx-to-stx-mia-faktory-v2 -- self-verifying stxer harness ===\n");
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
        typeof p.expect === "function" ? p.expect(d.str) :
        p.expect instanceof RegExp ? p.expect.test(d.str) :
        d.str === p.expect;
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 180)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 160)}`);
    } else if (p.kind === "deploy") {
      console.log(`📦 [${i}] ${p.label}`);
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  const redemption0 = bare(captured.redemption0);
  if (redemption0 !== 0n) {
    console.log(`⚠️  live redemption balance non-zero (${redemption0}) - F-3 dry checks are weaker`);
  }

  // F-3: exact boomerang on dry treasury, regardless of live book contents
  check("F-3 dry run: withdrawn == deposited (settle skipped)",
    num(captured.runDry, "withdrawn"), DRY_DEPOSIT);
  check("F-3 dry run: zero MIA acquired", num(captured.runDry, "mia-escrow"), 0n);
  check("machine clean after dry acts (STX)", bare(captured.v2StxDry), 0n);
  check("machine clean after dry acts (MIA)", bare(captured.v2MiaDry), 0n);

  // cleanup: live book fully consumed, machine clean, deposit conserved
  check("cleanup: book empty after", num(captured.book1, "ustx"), 0n);
  check("cleanup: machine STX == 0", bare(captured.v2StxClean), 0n);
  check("cleanup: machine MIA == 0", bare(captured.v2MiaClean), 0n);
  const cleanupIn = num(captured.runCleanup, "deposited");
  const cleanupOut = num(captured.runCleanup, "withdrawn");
  check("cleanup: withdrawn within 10 uSTX of deposited (floor dust only)",
    cleanupIn - cleanupOut < 10n && cleanupOut <= cleanupIn, true);

  // the loop, exact: book contained ONLY our two offers
  const pay1 = redeemPay(parEquiv(OFFER_A.ask));
  const pay2 = redeemPay(parEquiv(OFFER_B.ask));
  const wantLoop = LOOP_DEPOSIT - OFFER_A.ask - OFFER_B.ask + pay1 + pay2;
  check("loop: deposited == 3,100 STX", num(captured.runLoop, "deposited"), LOOP_DEPOSIT);
  check("loop: withdrawn == exact recycle math", num(captured.runLoop, "withdrawn"), wantLoop);
  check("loop: zero MIA left in machine (result)", num(captured.runLoop, "mia-escrow"), 0n);
  check("loop: machine STX == 0 after", bare(captured.v2StxLoop), 0n);
  check("loop: machine MIA == 0 after", bare(captured.v2MiaLoop), 0n);
  check("loop: whale A received exactly its ask", bare(captured.wa1) - bare(captured.wa0), OFFER_A.ask);
  check("loop: whale B received exactly its ask", bare(captured.wb1) - bare(captured.wb0), OFFER_B.ask);
  check("loop: book empty after", num(captured.book2, "ustx"), 0n);

  // F-1 + F-4: SP21 drove the loop AND received the withdraw
  check("SP21 net == withdrawn - deposited (paid as caller)",
    bare(captured.sp21_2) - bare(captured.sp21_1), wantLoop - LOOP_DEPOSIT);

  // surplus: fair gained our two spreads during the loop window. +-2 uMIA
  // tolerance: per-call floor(spent*1e6/1710) in the contract vs the
  // per-offer replica here can differ by 1 in the last micro-MIA.
  const surplusDelta =
    (OFFER_A.amount - parEquiv(OFFER_A.ask)) + (OFFER_B.amount - parEquiv(OFFER_B.ask));
  const surplusGot = num(captured.fairInfo2, "surplus-mia") - num(captured.fairInfo1, "surplus-mia");
  const surplusDiff = surplusGot > surplusDelta ? surplusGot - surplusDelta : surplusDelta - surplusGot;
  check("loop: fair surplus grew by the two spreads (+-2 uMIA)", surplusDiff <= 2n, true);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
