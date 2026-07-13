// verify-wrapper.js
// Self-verifying stxer mainnet-fork harness for stx-to-stx-wrapper: deploys
// the wrapper under SPV9K21 against the LIVE machine + fair book + ccd013,
// then proves the four claims that matter:
//
//   1. gates: only FASTPOOL (SP3KJB...) can run() - SP21...FFP and strangers
//      get u9100 (the machine would reject them anyway; fail fast + legible)
//   2. boomerang: a deposit that finds no fillable offer and no redemption
//      headroom comes straight back in the same tx (withdrawn == deposited)
//   3. THE LOOP: with the ccd013 rewards treasury funded, a 3,100 STX deposit
//      consumes 5,800 STX of freshly placed book offers across cycles -
//      capital recycles settle->redeem->settle - and the stranded 14 STX
//      (8,187 MIA escrow from 2026-07-13) finally comes home
//   4. finale: a run sized to the big live offer (5.3M MIA @ 8,444.5) clears
//      the whole book and leaves the machine empty: stx 0, mia 0
//
// Live-state assumptions (checked as baselines, cross-checks adapt):
//   - machine escrow ~8,187.134502 MIA, machine STX 0
//   - rewards-treasury redemption balance 0
//   - fair book holds one offer: 5,308,179 MIA asking 8,444.5 STX
//
// Run: node simulations/verify-wrapper.js
import fs from "fs";
import {
  uintCV,
  deserializeCV,
  cvToString,
  ClarityVersion,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

// --- actors (impersonated on the fork) ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22"; // deploys wrapper
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X"; // machine admin (~15k STX)
const SP21FFP = "SP21YTSM60CAY6D011EZVEVNKXVW8FVZE198XEFFP"; // rewards addr - must be rejected
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // no position
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA (2026-07-03)
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S"; // 801k STX - funds treasury

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const MACHINE_CID = `${DEPLOYER}.stx-to-stx-mia-faktory`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const WRAPPER_CID = `${DEPLOYER}.stx-to-stx-wrapper`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
// ccd013's get-redemption-current-balance is literally this contract's STX
// balance; its deposit-stx is the public top-up path we use on the fork.
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const PAR = 1710n; // uSTX per MIA (frozen in ccd013 + fair-v2)
const SCALE = 1_000_000n;
const parEquiv = (ustx) => (ustx * SCALE) / PAR; // uMIA acquired at par for ustx
const redeemPay = (umia) => (umia * PAR) / SCALE; // uSTX ccd013 pays for umia

// --- scenario amounts ---
const FUND_FASTPOOL = 30_000_000_000n; // FASTPOOL only holds ~11.58 STX live - fund him on the fork
const TREASURY_FUND = 40_000_000_000n; // 40,000 STX into the rewards treasury
const OFFER_A = { amount: 2_000_000_000_000n, ask: 3_000_000_000n }; // 2M MIA @ 3,000 (1500/1M)
const OFFER_B = { amount: 1_800_000_000_000n, ask: 2_800_000_000n }; // 1.8M MIA @ 2,800 (1555/1M)
const BOOMERANG = 1_000_000_000n; // 1,000 STX - can't fill the 8,444.5 live offer
const LOOP_DEPOSIT = 3_100_000_000n; // 3,100 STX - eats 5,800 STX of offers via loop
const FINALE = 20_000_000_000n; // covers the live book (~13,379 STX across 2 offers as of sim authoring)

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;

// ---- builder with a parallel assertion plan (same as verify-deployed) ----
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
// Act 0 -- deploy wrapper + live-state baselines
// =====================================================================
deploy("stx-to-stx-wrapper");
evalc("machine STX baseline", stxBal(MACHINE_CID), "machineStx0");
evalc("machine MIA escrow baseline", miaBal(MACHINE_CID), "machineMia0");
evalc("redemption balance baseline", `(contract-call? '${CCD013} get-redemption-current-balance)`, "redemption0");
evalc("fair book baseline", "(get-book-totals)", "book0");
evalc("fair surplus baseline", "(get-info)", "fairInfo0");
evalc("FASTPOOL STX baseline", stxBal(FASTPOOL), "fp0");
evalc("whale A STX baseline", stxBal(WHALE_A), "wa0");
evalc("whale B STX baseline", stxBal(WHALE_B), "wb0");

// FASTPOOL's live balance is ~11.58 STX (he swept his withdrawal onward),
// so stake him on the fork. fp0 is captured BEFORE this, so net math adjusts.
xfer("fund FASTPOOL with 30,000 STX (fork-only)", SETTLER, FASTPOOL, FUND_FASTPOOL);

// =====================================================================
// Act 1 -- gates: only FASTPOOL may run()
// =====================================================================
call("run(u0) from SP21...FFP -> err u9100", SP21FFP, WRAPPER_CID, "run", [uintCV(0n)], "(err u9100)");
call("run(u0) from stranger -> err u9100", STRANGER, WRAPPER_CID, "run", [uintCV(0n)], "(err u9100)");

// =====================================================================
// Act 2 -- no-op run on dry state: all cycles skip, nothing moves
// =====================================================================
call("run(u0) from FASTPOOL on dry state -> ok, all zeros moved", FASTPOOL, WRAPPER_CID, "run",
  [uintCV(0n)], /^\(ok /, "runDry");

// =====================================================================
// Act 3 -- boomerang: deposit too small for the live offer, treasury dry
// =====================================================================
call("run(1,000 STX) boomerangs the deposit", FASTPOOL, WRAPPER_CID, "run",
  [uintCV(BOOMERANG)], /^\(ok /, "runBoomerang");
evalc("machine STX after boomerang (0)", stxBal(MACHINE_CID), "machineStxAfterBoom");

// =====================================================================
// Act 4 -- fund the ccd013 rewards treasury (opens redemption headroom)
// =====================================================================
call("settler funds rewards treasury with 25,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(TREASURY_FUND)], "(ok true)");
evalc("redemption balance after funding", `(contract-call? '${CCD013} get-redemption-current-balance)`, "redemption1");

// =====================================================================
// Act 5 -- whales list two below-par offers cheaper than the live one
// =====================================================================
call("whale A offers 2M MIA @ 3,000 STX", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_A.amount), uintCV(OFFER_A.ask)], "(ok true)");
call("whale B offers 1.8M MIA @ 2,800 STX", WHALE_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_B.amount), uintCV(OFFER_B.ask)], "(ok true)");
evalc("book totals with 3 offers", "(get-book-totals)", "book1");

// =====================================================================
// Act 6 -- THE LOOP: 3,100 STX consumes both fresh offers (5,800 STX)
// =====================================================================
call("run(3,100 STX) loops through both offers", FASTPOOL, WRAPPER_CID, "run",
  [uintCV(LOOP_DEPOSIT)], /^\(ok /, "runLoop");
evalc("machine STX after loop (0)", stxBal(MACHINE_CID), "machineStxAfterLoop");
evalc("machine MIA after loop (0 - everything redeemed)", miaBal(MACHINE_CID), "machineMiaAfterLoop");
evalc("whale A STX after", stxBal(WHALE_A), "wa1");
evalc("whale B STX after", stxBal(WHALE_B), "wb1");
evalc("fair surplus after loop", "(get-info)", "fairInfo1");
evalc("book totals after loop (only live offer left)", "(get-book-totals)", "book2");

// =====================================================================
// Act 7 -- finale: clear the big live offer, machine ends empty
// =====================================================================
call("run(20,000 STX) clears the live offers", FASTPOOL, WRAPPER_CID, "run",
  [uintCV(FINALE)], /^\(ok /, "runFinale");
evalc("book totals after finale (empty)", "(get-book-totals)", "book3");
evalc("machine STX final (0)", stxBal(MACHINE_CID), "machineStxFinal");
evalc("machine MIA final (0)", miaBal(MACHINE_CID), "machineMiaFinal");
evalc("FASTPOOL STX final", stxBal(FASTPOOL), "fpFinal");

// ---- decode helpers (same as verify-deployed) ----
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
  console.log("=== stx-to-stx-wrapper -- self-verifying stxer harness ===\n");
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

  // ---- numeric cross-checks (exact contract math, BigInt floors) ----
  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  const machineMia0 = bare(captured.machineMia0); // live escrow (8,187.134502 MIA expected)
  const redemption0 = bare(captured.redemption0);

  // Act 2: with a dry treasury, the u0 run moves nothing
  if (redemption0 === 0n) {
    check("dry run: deposited u0", num(captured.runDry, "deposited"), 0n);
    check("dry run: withdrawn u0", num(captured.runDry, "withdrawn"), 0n);
    check("dry run: escrow untouched", num(captured.runDry, "mia-escrow"), machineMia0);
  } else {
    console.log(`⚠️  redemption balance non-zero at baseline (${redemption0}) - dry-run checks skipped`);
  }

  // Act 3: boomerang - deposit comes straight back, machine ends at 0 STX
  // (exact equality only holds with a dry treasury; otherwise the run also
  // redeems the old escrow and withdrawn > deposited)
  if (redemption0 === 0n) {
    check("boomerang: withdrawn == deposited", num(captured.runBoomerang, "withdrawn"),
      num(captured.runBoomerang, "deposited"));
  } else {
    check("boomerang: withdrawn >= deposited",
      num(captured.runBoomerang, "withdrawn") >= num(captured.runBoomerang, "deposited"), true);
  }
  check("boomerang: machine STX == 0 after", bare(captured.machineStxAfterBoom), 0n);

  // Act 4: treasury funded
  check("redemption balance == baseline + 25,000 STX", bare(captured.redemption1), redemption0 + TREASURY_FUND);

  // Act 6: the loop. Exact replay of machine math:
  //   cycle1: settle A (budget 3,100 >= 3,000), redeem (old escrow + parEquiv(A))
  //   cycle2: settle B (recycled budget >= 2,800), redeem parEquiv(B)
  //   cycles 3-5: no-op (remaining < live 8,444.5 ask)
  const escrowCycle1 = machineMia0 + parEquiv(OFFER_A.ask);
  const pay1 = redeemPay(escrowCycle1);
  const pay2 = redeemPay(parEquiv(OFFER_B.ask));
  const loopWithdrawn = LOOP_DEPOSIT - OFFER_A.ask - OFFER_B.ask + pay1 + pay2;
  check("loop: deposited == 3,100 STX", num(captured.runLoop, "deposited"), LOOP_DEPOSIT);
  check("loop: withdrawn == deposit - asks + redemptions (incl. the old 14 STX)",
    num(captured.runLoop, "withdrawn"), loopWithdrawn);
  check("loop: machine MIA escrow == 0 in run result", num(captured.runLoop, "mia-escrow"), 0n);
  check("loop: machine STX == 0 after", bare(captured.machineStxAfterLoop), 0n);
  check("loop: machine MIA == 0 after", bare(captured.machineMiaAfterLoop), 0n);
  check("loop: whale A received exactly its ask", bare(captured.wa1) - bare(captured.wa0), OFFER_A.ask);
  check("loop: whale B received exactly its ask", bare(captured.wb1) - bare(captured.wb0), OFFER_B.ask);

  // surplus accounting: fair-v2 gained (acquired - par-equiv) for both offers
  const surplusDelta =
    (OFFER_A.amount - parEquiv(OFFER_A.ask)) + (OFFER_B.amount - parEquiv(OFFER_B.ask));
  check("loop: fair surplus grew by exactly the two spreads",
    num(captured.fairInfo1, "surplus-mia") - num(captured.fairInfo0, "surplus-mia"), surplusDelta);

  // Act 7: finale - book empty, machine empty
  check("finale: book fully consumed (ustx == 0)", num(captured.book3, "ustx"), 0n);
  check("finale: machine STX == 0", bare(captured.machineStxFinal), 0n);
  check("finale: machine MIA == 0", bare(captured.machineMiaFinal), 0n);

  // Whole-session conservation for FASTPOOL: every run returned its deposit
  // plus redemption profit; net (minus the fork-only 30k funding) is the
  // old-escrow redemption (+14 STX). Sanity: FASTPOOL never lost principal.
  const fpDelta = bare(captured.fpFinal) - bare(captured.fp0) - FUND_FASTPOOL;
  check("FASTPOOL net (excl. fork funding) >= the recovered 14 STX",
    fpDelta >= redeemPay(machineMia0), true);
  console.log(`   (FASTPOOL net across all runs: ${fpDelta} uSTX)`);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
