// verify-stx-route.js
// SELF-VERIFYING stxer mainnet-fork harness for stx-to-stx-mia-faktory
// ("STX to STX") against the LIVE fair-v2 book and LIVE ccd013.
//
// ONE public function: settle-and-redeem(amount). amount > 0 = FASTPOOL
// (hardcoded fastpool.btc) feeds STX; amount = 0 = anyone re-triggers.
// Friedger's order: FIRST fill the book (machine keeps the par-equiv
// MIA), THEN claim STX from ccd013 (burn the MIA at the same par).
//
// Arc (treasury EMPTY on the fork at start):
//   A. guards; fastpool.btc funded with STX on the fork
//   B. deposit 5,000 STX -> settle leg sweeps the LIVE 1,742-STX book,
//      machine HOLDS the par-equiv MIA (treasury empty -> redeem waits)
//   C. bare re-trigger with nothing to do -> err u9002
//   D. cycle payout #1 -> one trigger burns the held MIA -> the SAME STX
//      returns minus exactly 1 uSTX of floor dust (round-trip parity)
//   E. FULLY ATOMIC: new 3,000-STX offer + funded treasury -> ONE trigger
//      does settle AND redeem: STX -> MIA -> STX inside a single tx
//   F. BOOK > escrow: 7,000-STX offer vs ~5,000 escrow -> frontier
//      partial consumes the escrow exactly, redeem refills it same tx
//   G. next trigger clears the remainder + redeems again (machine loops)
//   H. AUDIT R-1 dust regression (500 uMIA donation -> u9002, never
//      u13008); hatch guards; owner 1-STX withdrawal exact
//   I. final get-status reconciles every running total to the digit
//
// Run: node simulations/verify-stx-route.js
import fs from "node:fs";
import {
  ClarityVersion,
  uintCV,
  noneCV,
  standardPrincipalCV,
  contractPrincipalCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22"; // chavita.btc
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X"; // fastpool.btc (real)
const WHALE = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // funds fastpool STX + payouts
const MAKER_A = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M-MIA whale
const MAKER_B = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M-MIA whale
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // trigger caller, no position
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`; // LIVE
const ROUTE_CID = `${DEPLOYER}.stx-to-stx-mia-faktory`; // deployed by this sim

const RATIO = 1710n;
const SCALE = 1_000_000n;
const parEquivOf = (spent) => (spent * SCALE) / RATIO; // fair pays the settler this MIA
const redeemUstx = (umia) => (RATIO * umia) / SCALE; // ccd013 pays this STX for burned MIA

const PAYOUT = 20_000_000_000n; // simulated cycle payout: 20,000 STX
const STX_FUND = 30_000_000_000n; // whale -> fastpool.btc on the fork
const DEPOSIT = 5_000_000_000n; // fastpool's working capital: 5,000 STX

const OFFER_E = { amount: 2_000_000_000_000n, ask: 3_000_000_000n }; // 2M MIA @ 3,000 STX
const OFFER_F = { amount: 5_000_000_000_000n, ask: 7_000_000_000n }; // 5M MIA @ 7,000 STX
const WITHDRAW_STX = 1_000_000n;

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;

const plan = [];
const b = SimulationBuilder.new();

function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({ contract_id: cid, function_name: fn, function_args: args });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(FAIR_CID, code);
  plan.push({ kind: "eval", label, capture });
}

// =====================================================================
// Act A -- deploy, snapshot, fund fastpool.btc with STX, guards
// =====================================================================
b.withSender(DEPLOYER).addContractDeploy({
  contract_name: "stx-to-stx-mia-faktory",
  source_code: fs.readFileSync("./contracts/stx-to-stx-mia-faktory.clar", "utf8"),
  clarity_version: ClarityVersion.Clarity5,
});
plan.push({ kind: "deploy", label: "deploy stx-to-stx-mia-faktory" });

evalc("live ccd013 ratio (frozen u1710)", `(contract-call? '${CCD013} get-redemption-ratio)`, "ratio");
evalc("live ccd013 treasury (EMPTY between cycles)",
  `(contract-call? '${CCD013} get-redemption-current-balance)`, "treasury0");
evalc("LIVE book totals before the sweep", "(get-book-totals)", "totals0");
b.withSender(WHALE).addSTXTransfer({ recipient: FASTPOOL, amount: Number(STX_FUND) });
plan.push({ kind: "tx", label: "whale funds fastpool.btc with 30,000 STX (fork-only)", expect: /./ });

call("non-beneficiary deposit -> err u9000", STRANGER, ROUTE_CID,
  "settle-and-redeem", [uintCV(1_000_000n)], "(err u9000)");
call("re-trigger on empty machine -> err u9002", STRANGER, ROUTE_CID,
  "settle-and-redeem", [uintCV(0n)], "(err u9002)");

// =====================================================================
// Act B -- deposit 5,000 STX: settle sweeps the live book, MIA is HELD
// =====================================================================
call("fastpool deposits 5,000 STX -> settle sweeps LIVE book, redeem waits (treasury empty)",
  FASTPOOL, ROUTE_CID, "settle-and-redeem", [uintCV(DEPOSIT)], /^\(ok /, "depositB");
evalc("machine STX after sweep", stxBal(ROUTE_CID), "escB");
evalc("machine HOLDS the par-equiv MIA", miaBal(ROUTE_CID), "miaB");
evalc("live book empty after sweep", "(get-offer-count)", "countB");

call("re-trigger, nothing to do (book empty, treasury empty) -> err u9002",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], "(err u9002)");

// =====================================================================
// Act D -- payout #1: burn the held MIA, STX returns minus 1 uSTX dust
// =====================================================================
b.withSender(WHALE).addSTXTransfer({ recipient: REWARDS_TREASURY, amount: Number(PAYOUT) });
plan.push({ kind: "tx", label: "simulate cycle payout #1: 20,000 STX -> rewards treasury", expect: /./ });

call("stranger re-triggers -> redeem-only: held MIA burned, STX back",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], /^\(ok /, "crankD");
evalc("machine MIA back to 0", miaBal(ROUTE_CID), "miaD");
evalc("machine STX after round trip (5,000 STX minus dust)", stxBal(ROUTE_CID), "escD");

// =====================================================================
// Act E -- FULLY ATOMIC: offer + funded treasury -> one tx, both legs
// =====================================================================
call("maker A offers 2M MIA @ 3,000 STX (below par 3,420)", MAKER_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_E.amount), uintCV(OFFER_E.ask)], "(ok true)");
call("stranger re-triggers -> STX -> MIA -> STX in ONE tx",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], /^\(ok /, "crankE");
evalc("machine MIA still 0 (burned in the same tx)", miaBal(ROUTE_CID), "miaE");
evalc("machine STX after atomic loop", stxBal(ROUTE_CID), "escE");
evalc("stranger MIA still 0 (caller earns nothing)", miaBal(STRANGER), "K_mia");

// =====================================================================
// Act F -- BOOK > escrow: frontier partial consumes the escrow exactly,
// the redeem leg refills it in the same tx
// =====================================================================
call("maker B offers 5M MIA @ 7,000 STX (below par 8,550)", MAKER_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_F.amount), uintCV(OFFER_F.ask)], "(ok true)");
evalc("machine STX going into the big settle", stxBal(ROUTE_CID), "escF0");
call("stranger re-triggers -> escrow fully spent on the frontier + refilled by redeem",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], /^\(ok /, "crankF");
evalc("book keeps B's shrunken remainder (1 offer)", "(get-offer-count)", "countF");
evalc("B's remainder record", `(get-offer '${MAKER_B})`, "bRem");
evalc("machine STX refilled by the same-tx redeem", stxBal(ROUTE_CID), "escF1");
evalc("machine MIA 0 again", miaBal(ROUTE_CID), "miaF");

// =====================================================================
// Act G -- next trigger clears the remainder and redeems again
// =====================================================================
call("stranger re-triggers -> remainder cleared + redeemed (machine loops)",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], /^\(ok /, "crankG");
evalc("book empty at the end", "(get-offer-count)", "countG");
evalc("machine MIA 0 at the end", miaBal(ROUTE_CID), "miaG");
evalc("machine STX at the end", stxBal(ROUTE_CID), "escG");

// =====================================================================
// Act H -- R-1 dust regression + hatches
// =====================================================================
call("griefer donates 500 uMIA dust to the machine", MAKER_B, MIA, "transfer",
  [uintCV(500n), standardPrincipalCV(MAKER_B), contractPrincipalCV(DEPLOYER, "stx-to-stx-mia-faktory"), noneCV()],
  "(ok true)");
call("re-trigger with dust + non-empty treasury -> err u9002, NOT u13008",
  STRANGER, ROUTE_CID, "settle-and-redeem", [uintCV(0n)], "(err u9002)");
call("stranger withdraw-stx -> err u9000", STRANGER, ROUTE_CID, "withdraw-stx",
  [uintCV(WITHDRAW_STX)], "(err u9000)");
evalc("fastpool STX before withdraw", stxBal(FASTPOOL), "F_stx0");
call("owner withdraws 1 STX", FASTPOOL, ROUTE_CID, "withdraw-stx", [uintCV(WITHDRAW_STX)], "(ok true)");
evalc("fastpool STX after withdraw", stxBal(FASTPOOL), "F_stx1");
evalc("machine get-status (final accounting)", `(contract-call? '${ROUTE_CID} get-status)`, "status");

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
  console.log("=== stx-to-stx-mia-faktory (STX to STX) -- self-verifying stxer harness ===\n");
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
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 200)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
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

  // preconditions
  check("ccd013 ratio is the frozen u1710", bare(captured.ratio), RATIO);
  check("ccd013 treasury starts empty", bare(captured.treasury0), 0n);

  // Act B: settle sweeps the live book, MIA held, redeem waits
  const bookUstx = num(captured.totals0, "ustx");
  const bookMia = num(captured.totals0, "amount");
  const par1 = parEquivOf(bookUstx);
  check("deposit spent == live book ustx", num(captured.depositB, "spent"), bookUstx);
  check("deposit acquired == live book amount", num(captured.depositB, "acquired"), bookMia);
  check("deposit redeemed none (treasury empty)", String(captured.depositB).includes("(redeemed none)"), true);
  check("machine holds exactly the par-equiv MIA", bare(captured.miaB), par1);
  check("machine STX == deposit - spent", bare(captured.escB), DEPOSIT - bookUstx);
  check("book empty after sweep", bare(captured.countB), 0n);

  // Act D: redeem-only round trip, exactly 1 uSTX of floor dust
  const ustxD = redeemUstx(par1);
  check("crankD settled none (book empty)", String(captured.crankD).includes("(settled none)"), true);
  check("crankD burned the held MIA", num(captured.crankD, "umia"), par1);
  check("crankD STX back == floor(par1*1710/1e6)", num(captured.crankD, "ustx"), ustxD);
  check("round-trip dust == spent - returned <= 1 uSTX", bookUstx - ustxD <= 1n, true);
  check("machine MIA back to 0", bare(captured.miaD), 0n);
  check("machine STX == deposit - dust", bare(captured.escD), DEPOSIT - (bookUstx - ustxD));

  // Act E: fully atomic STX -> MIA -> STX in one tx
  const parE = parEquivOf(OFFER_E.ask);
  const ustxE = redeemUstx(parE);
  check("crankE spent == offer ask", num(captured.crankE, "spent"), OFFER_E.ask);
  check("crankE acquired == offer amount", num(captured.crankE, "acquired"), OFFER_E.amount);
  check("crankE burned the par-equiv in the SAME tx", num(captured.crankE, "umia"), parE);
  check("crankE STX back in the SAME tx", num(captured.crankE, "ustx"), ustxE);
  check("machine MIA still 0 (atomic)", bare(captured.miaE), 0n);
  check("machine STX after atomic loop", bare(captured.escE), bare(captured.escD) - (OFFER_E.ask - ustxE));
  check("stranger earned nothing", bare(captured.K_mia), 0n);

  // Act F: BOOK > escrow -- frontier partial spends the escrow exactly
  const escF0 = bare(captured.escF0);
  const takenF = (OFFER_F.amount * escF0) / OFFER_F.ask;
  const parF = parEquivOf(escF0);
  const ustxF = redeemUstx(parF);
  check("crankF spent == ENTIRE escrow (frontier partial)", num(captured.crankF, "spent"), escF0);
  check("crankF acquired == floor pro-rata of B", num(captured.crankF, "acquired"), takenF);
  check("crankF redeemed the par-equiv same tx", num(captured.crankF, "umia"), parF);
  check("book keeps exactly B's remainder", bare(captured.countF), 1n);
  check("B remainder amount", num(captured.bRem, "amount"), OFFER_F.amount - takenF);
  check("B remainder ustx", num(captured.bRem, "ustx"), OFFER_F.ask - escF0);
  check("machine STX refilled by the same-tx redeem", bare(captured.escF1), ustxF);
  check("machine MIA 0 again", bare(captured.miaF), 0n);

  // Act G: remainder cleared, machine loops
  const remUstx = OFFER_F.ask - escF0;
  const remMia = OFFER_F.amount - takenF;
  const parG = parEquivOf(remUstx);
  const ustxG = redeemUstx(parG);
  check("crankG spent == remainder ask", num(captured.crankG, "spent"), remUstx);
  check("crankG acquired == remainder amount", num(captured.crankG, "acquired"), remMia);
  check("crankG redeemed same tx", num(captured.crankG, "umia"), parG);
  check("book empty at the end", bare(captured.countG), 0n);
  check("machine MIA 0 at the end", bare(captured.miaG), 0n);
  check("machine STX at the end", bare(captured.escG), bare(captured.escF1) - (remUstx - ustxG));

  // Act H: hatch exactness
  check("owner STX delta == 1 STX withdrawn", bare(captured.F_stx1) - bare(captured.F_stx0), WITHDRAW_STX);

  // final accounting reconciles to the digit
  const totalSpent = bookUstx + OFFER_E.ask + escF0 + remUstx;
  const totalAcquired = par1 + parE + parF + parG;
  const totalReceived = ustxD + ustxE + ustxF + ustxG;
  check("total-stx-spent", num(captured.status, "total-stx-spent"), totalSpent);
  check("total-mia-acquired", num(captured.status, "total-mia-acquired"), totalAcquired);
  check("total-redeemed-umia == every acquired uMIA burned",
    num(captured.status, "total-redeemed-umia"), totalAcquired);
  check("total-stx-received", num(captured.status, "total-stx-received"), totalReceived);
  check("whole-life round-trip dust <= 1 uSTX per loop (4 loops)",
    totalSpent - totalReceived <= 4n, true);
  check("status stx-escrow == deposit - dust - withdrawn",
    num(captured.status, "stx-escrow"), DEPOSIT - (totalSpent - totalReceived) - WITHDRAW_STX);
  check("status mia-escrow == only the 500-uMIA dust donation",
    num(captured.status, "mia-escrow"), 500n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
