// verify-route.js
// SELF-VERIFYING stxer mainnet-fork harness for mia-to-mia-faktory
// ("Miami to Miami") against the LIVE ccd013 redemption and the LIVE
// mia-fair-faktory-v2 book (3 real offers, ~1,742 STX total, 2026-07-05).
//
// ONE public function: redeem-and-settle(amount). amount > 0 = the
// whitehat (first depositor = fastpool.btc, locked in as beneficiary)
// feeds MIA v2; amount = 0 = anyone re-triggers. Redeem leg: machine MIA
// -> ccd013 burn at par -> STX escrows in the machine. Settle leg:
// machine STX -> fair-v2 book -> par-equiv MIA to the DEPOSITOR only.
//
// Happy-path arc (treasury starts EMPTY on the fork -- verified u0):
//   A. fastpool.btc (real BNS owner, funded with MIA on the fork)
//      deposits 10M MIA -> both legs skip quietly, MIA parks
//   B. cycle payout lands (20k STX -> ccd002-treasury-mia-rewards-v3 via
//      plain STX transfer); a STRANGER re-triggers ONCE: 10M MIA redeemed
//      for exactly 17,100 STX AND the live book swept in the same tx
//      (BOOK < STX: leftover STX stays escrowed)
//   C. new 1,400-STX offer -> stranger re-triggers the settle-only leg
//   D. hatch guards + owner's exact 1-STX withdrawal
//   E. second 10M deposit vs the 2,900-STX treasury remnant -> PARTIAL
//      redemption, residual MIA stays; owner withdraws 1,000 MIA
//   F. BOOK > STX: two makers stack 24,250 STX of offers against a
//      16,857-STX escrow; fastpool.btc itself re-triggers -> the escrow
//      is consumed EXACTLY (fair-v2 frontier partial fill), book keeps
//      the remainder
//   G. second cycle payout -> one trigger redeems the residual MIA AND
//      clears the book remainder in the same tx (machine loops)
//   H. final get-status reconciles every running total to the digit
//
// Expectations that depend on the live book are read IN-SIM and checked
// with fork-time arithmetic. Run: node simulations/verify-route.js
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
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X"; // fastpool.btc (real), the beneficiary
const WHALE = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B-MIA whale, funds fastpool on the fork
const MAKER_A = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M-MIA whale
const MAKER_B = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M-MIA whale
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM"; // re-trigger caller with no position
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`; // LIVE
const ROUTE_CID = `${DEPLOYER}.mia-to-mia-faktory`; // deployed by this sim

const RATIO = 1710n;
const SCALE = 1_000_000n;
const parEquivOf = (spent) => (spent * SCALE) / RATIO;

const PAYOUT = 20_000_000_000n; // each simulated cycle payout: 20,000 STX
const FUND = 21_000_000_000_000n; // 21M MIA moved whale -> fastpool.btc on the fork

// deposit 1: 10M MIA (the ccd013 per-tx cap) -> exactly 17,100 STX
const DEPOSIT_1 = 10_000_000_000_000n;
const USTX_1 = (RATIO * DEPOSIT_1) / SCALE; // 17,100,000,000

// act C offer: 1M MIA @ 1,400 STX (par would be 1,710)
const OFFER_C = { amount: 1_000_000_000_000n, ask: 1_400_000_000n };
const PAR_C = parEquivOf(OFFER_C.ask); // 818,713,450,292

// hatches
const WITHDRAW_STX = 1_000_000n; // 1 STX
const WITHDRAW_MIA = 1_000_000_000n; // 1,000 MIA

// deposit 2: 10M MIA vs the treasury REMNANT -> partial burn
const DEPOSIT_2 = 10_000_000_000_000n;
const TREASURY_REMNANT = PAYOUT - USTX_1; // 2,900 STX
const BURN_2 = (TREASURY_REMNANT * SCALE) / RATIO; // 1,695,906,432,748 uMIA
const RESIDUAL = DEPOSIT_2 - BURN_2 - WITHDRAW_MIA; // machine MIA before act G

// act F big book (BOOK > STX): cheapest first is B (1.55/M), then A (1.65/M)
const OFFER_F_B = { amount: 5_000_000_000_000n, ask: 7_750_000_000n }; // 5M @ 7,750
const OFFER_F_A = { amount: 10_000_000_000_000n, ask: 16_500_000_000n }; // 10M @ 16,500

// act G: redeem the residual, then clear the act-F remainder
const USTX_G = (RATIO * RESIDUAL) / SCALE; // 14,198.29 STX < 20,000 -> full burn

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
function payout(label) {
  b.withSender(WHALE).addSTXTransfer({ recipient: REWARDS_TREASURY, amount: Number(PAYOUT) });
  plan.push({ kind: "tx", label, expect: /./ });
}

// =====================================================================
// Act A -- deploy, snapshot the live world, fund fastpool.btc, park 10M
// =====================================================================
b.withSender(DEPLOYER).addContractDeploy({
  contract_name: "mia-to-mia-faktory",
  source_code: fs.readFileSync("./contracts/mia-to-mia-faktory.clar", "utf8"),
  clarity_version: ClarityVersion.Clarity5,
});
plan.push({ kind: "deploy", label: "deploy mia-to-mia-faktory" });

evalc("live ccd013 ratio (frozen u1710)",
  `(contract-call? '${CCD013} get-redemption-ratio)`, "ratio");
evalc("live ccd013 treasury (EMPTY between cycles)",
  `(contract-call? '${CCD013} get-redemption-current-balance)`, "treasury0");
evalc("LIVE book totals before the sweep", "(get-book-totals)", "totals0");

call("whale funds fastpool.btc with 21M MIA (fork-only)", WHALE, MIA, "transfer",
  [uintCV(FUND), standardPrincipalCV(WHALE), standardPrincipalCV(FASTPOOL), noneCV()], "(ok true)");
evalc("fastpool.btc MIA after funding", miaBal(FASTPOOL), "F_mia0");

call("re-trigger before any deposit -> err u9002 (nothing to do)", STRANGER, ROUTE_CID,
  "redeem-and-settle", [uintCV(0n)], "(err u9002)");
call("fastpool.btc deposits 10M MIA (treasury empty) -> redeemed none, settled none",
  FASTPOOL, ROUTE_CID, "redeem-and-settle", [uintCV(DEPOSIT_1)],
  "(ok (tuple (redeemed none) (settled none)))");
call("non-beneficiary depositor -> err u9000 (FASTPOOL hardcoded)", STRANGER, ROUTE_CID,
  "redeem-and-settle", [uintCV(1_000_000n)], "(err u9000)");
evalc("machine MIA escrow (10M parked)", miaBal(ROUTE_CID), "route_mia0");
call("re-trigger, nothing to do -> err u9002", STRANGER, ROUTE_CID,
  "redeem-and-settle", [uintCV(0n)], "(err u9002)");

// =====================================================================
// Act B -- payout #1; one re-trigger redeems AND sweeps (BOOK < STX)
// =====================================================================
payout("simulate cycle payout #1: 20,000 STX -> rewards treasury");
evalc("treasury after payout #1", `(contract-call? '${CCD013} get-redemption-current-balance)`, "treasury1");
evalc("fastpool MIA before sweep", miaBal(FASTPOOL), "F_mia1");

call("stranger re-triggers -> redeem 10M MIA (17,100 STX) + sweep the LIVE book",
  STRANGER, ROUTE_CID, "redeem-and-settle", [uintCV(0n)], /^\(ok /, "crank1");
evalc("machine STX escrow after sweep (BOOK < STX leftover)", stxBal(ROUTE_CID), "esc1");
evalc("machine MIA after sweep (0 -- all burned, par-equiv forwarded)", miaBal(ROUTE_CID), "route_mia1");
evalc("live book empty after sweep", "(get-offer-count)", "count1");
evalc("fastpool MIA after sweep", miaBal(FASTPOOL), "F_mia2");
evalc("stranger MIA after sweep (still 0 -- caller earns nothing)", miaBal(STRANGER), "K_mia1");

// =====================================================================
// Act C -- a fresh offer; stranger re-triggers the settle-only leg
// =====================================================================
call("maker A offers 1M MIA @ 1,400 STX (below par)", MAKER_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_C.amount), uintCV(OFFER_C.ask)], "(ok true)");
call("stranger re-triggers -> settle-only leg, exact tuple", STRANGER, ROUTE_CID,
  "redeem-and-settle", [uintCV(0n)],
  `(ok (tuple (redeemed none) (settled (some (tuple (acquired u${OFFER_C.amount}) (par-equiv u${PAR_C}) (spent u${OFFER_C.ask}) (surplus u${OFFER_C.amount - PAR_C}))))))`,
  "crank2");
evalc("fastpool MIA after stranger's settle", miaBal(FASTPOOL), "F_mia3");
evalc("machine STX escrow after settle", stxBal(ROUTE_CID), "esc2");
call("re-trigger, nothing to do again -> err u9002", STRANGER, ROUTE_CID,
  "redeem-and-settle", [uintCV(0n)], "(err u9002)");

// =====================================================================
// Act D -- emergency hatches: guards + exact owner withdrawal
// =====================================================================
call("stranger withdraw-stx -> err u9000", STRANGER, ROUTE_CID, "withdraw-stx",
  [uintCV(WITHDRAW_STX)], "(err u9000)");
call("stranger withdraw-mia -> err u9000", STRANGER, ROUTE_CID, "withdraw-mia",
  [uintCV(1n)], "(err u9000)");
evalc("fastpool STX before withdraw", stxBal(FASTPOOL), "F_stx0");
call("owner withdraws 1 STX", FASTPOOL, ROUTE_CID, "withdraw-stx",
  [uintCV(WITHDRAW_STX)], "(ok true)");
evalc("fastpool STX after withdraw", stxBal(FASTPOOL), "F_stx1");
evalc("machine STX after withdraw", stxBal(ROUTE_CID), "esc2b");

// =====================================================================
// Act E -- PARTIAL redemption: 10M more MIA vs the 2,900-STX remnant
// =====================================================================
call("deposit 10M more -> redeem capped at the treasury remnant, book empty",
  FASTPOOL, ROUTE_CID, "redeem-and-settle", [uintCV(DEPOSIT_2)], /^\(ok /, "deposit2");
evalc("treasury drained to 0", `(contract-call? '${CCD013} get-redemption-current-balance)`, "treasury2");
evalc("machine MIA residual (unburned part of deposit 2)", miaBal(ROUTE_CID), "route_mia2");
evalc("machine STX after deposit 2", stxBal(ROUTE_CID), "esc3");
call("owner withdraws 1,000 MIA of the residual", FASTPOOL, ROUTE_CID, "withdraw-mia",
  [uintCV(WITHDRAW_MIA)], "(ok true)");

// =====================================================================
// Act F -- BOOK > STX: 24,250 STX of offers vs a 16,857-STX escrow;
// fastpool.btc itself re-triggers; escrow consumed EXACTLY (partial fill)
// =====================================================================
call("maker B offers 5M MIA @ 7,750 STX (1.55/M, cheapest)", MAKER_B, FAIR_CID, "place-offer",
  [uintCV(OFFER_F_B.amount), uintCV(OFFER_F_B.ask)], "(ok true)");
call("maker A offers 10M MIA @ 16,500 STX (1.65/M)", MAKER_A, FAIR_CID, "place-offer",
  [uintCV(OFFER_F_A.amount), uintCV(OFFER_F_A.ask)], "(ok true)");
evalc("book totals before big settle", "(get-book-totals)", "totalsF");
evalc("fastpool MIA before big settle", miaBal(FASTPOOL), "F_mia4");

call("fastpool.btc re-triggers -> escrow fully consumed, frontier partial on A",
  FASTPOOL, ROUTE_CID, "redeem-and-settle", [uintCV(0n)], /^\(ok /, "crank3");
evalc("machine STX escrow == 0 (BOOK > STX)", stxBal(ROUTE_CID), "esc4");
evalc("book keeps A's shrunken remainder (1 offer)", "(get-offer-count)", "countF");
evalc("A's remainder record", `(get-offer '${MAKER_A})`, "aRem");
evalc("fastpool MIA after big settle", miaBal(FASTPOOL), "F_mia5");

// =====================================================================
// Act G -- payout #2: one trigger redeems the residual AND clears the
// book remainder in the same tx (the machine loops)
// =====================================================================
payout("simulate cycle payout #2: 20,000 STX -> rewards treasury");
call("stranger re-triggers -> residual MIA redeemed + A's remainder cleared",
  STRANGER, ROUTE_CID, "redeem-and-settle", [uintCV(0n)], /^\(ok /, "crank4");
evalc("book empty at the end", "(get-offer-count)", "countG");
evalc("machine MIA at the end (0 -- everything routed)", miaBal(ROUTE_CID), "route_miaG");
evalc("treasury remnant after payout #2 redemption",
  `(contract-call? '${CCD013} get-redemption-current-balance)`, "treasury3");
evalc("fastpool MIA at the end", miaBal(FASTPOOL), "F_mia6");

// =====================================================================
// Act H -- AUDIT R-1 regression: a 500-uMIA dust donation must NOT brick
// re-triggers while the treasury still holds STX (redeem skips quietly)
// =====================================================================
call("griefer donates 500 uMIA dust to the machine", MAKER_B, MIA, "transfer",
  [uintCV(500n), standardPrincipalCV(MAKER_B), contractPrincipalCV(DEPLOYER, "mia-to-mia-faktory"), noneCV()],
  "(ok true)");
call("re-trigger with dust + non-empty treasury -> err u9002, NOT u13008",
  STRANGER, ROUTE_CID, "redeem-and-settle", [uintCV(0n)], "(err u9002)");
evalc("machine get-status (final accounting)",
  `(contract-call? '${ROUTE_CID} get-status)`, "status");

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
  console.log("=== mia-to-mia-faktory (Miami to Miami) -- self-verifying stxer harness ===\n");
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

  // preconditions on the fork
  check("ccd013 ratio is the frozen u1710", bare(captured.ratio), RATIO);
  check("ccd013 treasury starts empty (between cycles)", bare(captured.treasury0), 0n);
  check("fastpool.btc funded with enough MIA v2", bare(captured.F_mia0) >= DEPOSIT_1 + DEPOSIT_2, true);
  check("deposit 1 parked in full", bare(captured.route_mia0), DEPOSIT_1);
  check("payout #1 landed in the treasury", bare(captured.treasury1), PAYOUT);

  // Act B: redeem exact + live-book sweep exact (BOOK < STX)
  const bookUstx = num(captured.totals0, "ustx");
  const bookMia = num(captured.totals0, "amount");
  const par1 = parEquivOf(bookUstx);
  check("sweep redeemed umia == 10M MIA", num(captured.crank1, "umia"), DEPOSIT_1);
  check("sweep redeemed ustx == 17,100 STX", num(captured.crank1, "ustx"), USTX_1);
  check("sweep v1 leg untouched", num(captured.crank1, "mia-v1"), 0n);
  check("sweep spent == live book ustx", num(captured.crank1, "spent"), bookUstx);
  check("sweep acquired == live book amount", num(captured.crank1, "acquired"), bookMia);
  check("sweep par-equiv == spent*1e6/1710", num(captured.crank1, "par-equiv"), par1);
  check("book empty after sweep", bare(captured.count1), 0n);
  check("BOOK < STX: leftover escrow == 17,100 STX - spent", bare(captured.esc1), USTX_1 - bookUstx);
  check("machine MIA fully burned+forwarded", bare(captured.route_mia1), 0n);
  check("fastpool MIA delta == par-equiv", bare(captured.F_mia2) - bare(captured.F_mia1), par1);
  check("stranger MIA still zero", bare(captured.K_mia1), 0n);

  // Act C: settle-only, depositor credited, escrow debited exactly
  check("fastpool MIA delta == par-equiv of stranger's settle", bare(captured.F_mia3) - bare(captured.F_mia2), PAR_C);
  check("escrow decreased by exactly the offer's ask", bare(captured.esc1) - bare(captured.esc2), OFFER_C.ask);

  // Act D: hatch exactness
  check("owner STX delta == 1 STX withdrawn", bare(captured.F_stx1) - bare(captured.F_stx0), WITHDRAW_STX);
  check("escrow decreased by the withdrawal", bare(captured.esc2) - bare(captured.esc2b), WITHDRAW_STX);

  // Act E: partial redemption against the treasury remnant
  check("deposit2 redeemed ustx == treasury remnant (2,900 STX)",
    num(captured.deposit2, "ustx"), TREASURY_REMNANT);
  check("deposit2 burned umia == remnant*1e6/1710", num(captured.deposit2, "umia"), BURN_2);
  check("deposit2 settled none (book empty)", String(captured.deposit2).includes("(settled none)"), true);
  check("treasury drained to zero", bare(captured.treasury2), 0n);
  check("residual MIA stays escrowed", bare(captured.route_mia2), DEPOSIT_2 - BURN_2);
  check("escrow grew by the remnant", bare(captured.esc3) - bare(captured.esc2b), TREASURY_REMNANT);

  // Act F: BOOK > STX -- escrow consumed exactly, frontier partial on A
  const escF = bare(captured.esc3); // escrow going into the big settle
  const bPaid = OFFER_F_B.ask;
  const aPaid = escF - bPaid; // remainder of the budget into A
  const aTaken = (OFFER_F_A.amount * aPaid) / OFFER_F_A.ask; // floor
  const parF = parEquivOf(escF);
  check("big book totals == B + A", num(captured.totalsF, "ustx"), OFFER_F_B.ask + OFFER_F_A.ask);
  check("crank3 redeemed none (treasury dry)", String(captured.crank3).includes("(redeemed none)"), true);
  check("crank3 spent == ENTIRE escrow (frontier partial)", num(captured.crank3, "spent"), escF);
  check("crank3 acquired == B full + A partial", num(captured.crank3, "acquired"), OFFER_F_B.amount + aTaken);
  check("BOOK > STX: escrow drained to 0", bare(captured.esc4), 0n);
  check("book keeps exactly A's remainder", bare(captured.countF), 1n);
  check("A remainder amount", num(captured.aRem, "amount"), OFFER_F_A.amount - aTaken);
  check("A remainder ustx", num(captured.aRem, "ustx"), OFFER_F_A.ask - aPaid);
  check("fastpool MIA delta == par-equiv of the whole escrow",
    bare(captured.F_mia5) - bare(captured.F_mia4), parF);

  // Act G: payout #2 -> redeem residual + clear the remainder in one tx
  const aRemUstx = OFFER_F_A.ask - aPaid;
  const parG = parEquivOf(aRemUstx);
  check("crank4 redeemed umia == residual", num(captured.crank4, "umia"), RESIDUAL);
  check("crank4 redeemed ustx == residual at par", num(captured.crank4, "ustx"), USTX_G);
  check("crank4 spent == A's remainder ask", num(captured.crank4, "spent"), aRemUstx);
  check("crank4 acquired == A's remainder amount", num(captured.crank4, "acquired"), OFFER_F_A.amount - aTaken);
  check("book empty at the end", bare(captured.countG), 0n);
  check("machine MIA at the end == 0", bare(captured.route_miaG), 0n);
  check("treasury remnant after payout #2", bare(captured.treasury3), PAYOUT - USTX_G);
  check("fastpool MIA delta (act G) == par-equiv of remainder",
    bare(captured.F_mia6) - bare(captured.F_mia5), parG);

  // Act H: final accounting reconciles to the digit
  const totalReceived = USTX_1 + TREASURY_REMNANT + USTX_G;
  const totalSpent = bookUstx + OFFER_C.ask + escF + aRemUstx;
  check("total-redeemed-umia", num(captured.status, "total-redeemed-umia"), DEPOSIT_1 + BURN_2 + RESIDUAL);
  check("total-stx-received", num(captured.status, "total-stx-received"), totalReceived);
  check("total-stx-spent", num(captured.status, "total-stx-spent"), totalSpent);
  check("total-mia-returned", num(captured.status, "total-mia-returned"), par1 + PAR_C + parF + parG);
  check("status stx-escrow == received - spent - withdrawn",
    num(captured.status, "stx-escrow"), totalReceived - totalSpent - WITHDRAW_STX);
  check("status mia-escrow == only the 500-uMIA dust donation", num(captured.status, "mia-escrow"), 500n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
