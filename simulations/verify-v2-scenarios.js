// verify-v2-scenarios.js
// Edge-scenario suite for stx-to-stx-mia-faktory-v2 on a mainnet fork -
// the states the happy-path harness (verify-v2-machine.js) doesn't reach:
//
//   S1 cycle-cap abuse: run-loops(u0, u99) - the guard unroll caps at 5,
//      absurd cycle counts are harmless no-ops
//   S2 parity: run(X) === run-loops(X, u1) on identical dry state
//   S3 partial treasury: headroom (2,000) smaller than both the deposit
//      and the cheapest ask - F-3 caps the settle to EXACTLY headroom via
//      fair-v2's frontier partial fill; nothing strands, book keeps the
//      remainder
//   S4 redeem-cap spillover: a 19,000 STX settle acquires ~11.1M MIA,
//      above the 10M-per-redeem cap, while the treasury drains mid-run -
//      the ONE state where v2 legitimately ends holding MIA. Conservation
//      must hold: deposited == withdrawn + par(escrow-left) +- dust
//   S5 donation sweep: naked STX sent to the machine is recovered by an
//      operator run(u0) even with a dry treasury
//   S6 withdraw gates: strangers get u9000 on withdraw-stx/withdraw-mia
//
// Run: node simulations/verify-v2-scenarios.js
import fs from "fs";
import {
  uintCV,
  deserializeCV,
  cvToString,
  ClarityVersion,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X";
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA
const WHALE_B = "SP22WH53NS94VR6N145ZX77BK4S0EWFBE41VW3Z6B"; // 739M MIA
const WHALE_C = "SP1MGH8BH1KRY49Z7EE5TY0JVKT6C3NT9RTVM8FND"; // 124M MIA
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const V2_CID = `${DEPLOYER}.stx-to-stx-mia-faktory-v2`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const PAR = 1710n;
const redeemPay = (umia) => (umia * PAR) / 1_000_000n;

const FUND_FASTPOOL = 25_000_000_000n;
const PARITY = 2_000_000_000n; // S2
const T1 = 2_000_000_000n; // S3 treasury: smaller than deposit AND cheapest ask
const S3_DEPOSIT = 3_000_000_000n;
const S3_OFFER = { amount: 2_000_000_000_000n, ask: 3_000_000_000n }; // 2M @ 3,000 (1500)
const T2 = 20_000_000_000n; // S4 treasury
// place-offer caps single offers at 10M MIA (u13013) - discovered by this
// suite - so the >10M-par-equiv settle needs TWO offers summed in one pass.
const S4_OFFER_1 = { amount: 7_000_000_000_000n, ask: 10_500_000_000n }; // 7M @ 10,500 (1500)
const S4_OFFER_2 = { amount: 7_000_000_000_000n, ask: 10_500_000_000n }; // 7M @ 10,500 (1500)
const S4_DEPOSIT = 21_100_000_000n; // settle capped at 20,000 headroom -> ~11.7M MIA > 10M redeem cap
const DONATION = 500_000_000n; // S5

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

// S0 -- deploy + baselines
deploy("stx-to-stx-mia-faktory-v2");
evalc("redemption balance baseline (expect 0)", `(contract-call? '${CCD013} get-redemption-current-balance)`, "redemption0");
evalc("book baseline", "(get-book-totals)", "book0");
xfer("fund FASTPOOL 25,000 STX (fork-only)", SETTLER, FASTPOOL, FUND_FASTPOOL);

// S1 -- absurd cycle count on dry state: harmless
call("S1 run-loops(u0, u99) dry -> ok zeros", FASTPOOL, V2_CID, "run-loops",
  [uintCV(0n), uintCV(99n)], /^\(ok /, "s1");

// S2 -- parity: run(X) vs run-loops(X, u1) on the same dry state
call("S2a run(2,000) dry -> boomerang", FASTPOOL, V2_CID, "run",
  [uintCV(PARITY)], /^\(ok /, "s2a");
call("S2b run-loops(2,000, u1) dry -> identical boomerang", FASTPOOL, V2_CID, "run-loops",
  [uintCV(PARITY), uintCV(1n)], /^\(ok /, "s2b");

// S3 -- partial treasury: headroom 2,000 < deposit 3,000 < ask 3,000
call("S3 fund treasury with only 2,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(T1)], "(ok true)");
call("S3 whale A offers 2M MIA @ 3,000 STX", WHALE_A, FAIR_CID, "place-offer",
  [uintCV(S3_OFFER.amount), uintCV(S3_OFFER.ask)], "(ok true)");
evalc("S3 book before", "(get-book-totals)", "s3bookBefore");
call("S3 run-loops(3,000, u5) vs 2,000 headroom", FASTPOOL, V2_CID, "run-loops",
  [uintCV(S3_DEPOSIT), uintCV(5n)], /^\(ok /, "s3");
evalc("S3 book after (delta == headroom spent)", "(get-book-totals)", "s3bookAfter");
evalc("S3 treasury drained to 0", `(contract-call? '${CCD013} get-redemption-current-balance)`, "s3treasury");
evalc("S3 machine STX (0)", stxBal(V2_CID), "s3stx");
evalc("S3 machine MIA (0 - everything acquired was redeemable)", miaBal(V2_CID), "s3mia");

// S4 -- redeem-cap spillover: settle above 10M MIA par-equiv, treasury drains
call("S4 fund treasury with 20,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(T2)], "(ok true)");
call("S4 whale C offers 7M MIA @ 10,500 STX", WHALE_C, FAIR_CID, "place-offer",
  [uintCV(S4_OFFER_1.amount), uintCV(S4_OFFER_1.ask)], "(ok true)");
call("S4 whale B offers 7M MIA @ 10,500 STX", WHALE_B, FAIR_CID, "place-offer",
  [uintCV(S4_OFFER_2.amount), uintCV(S4_OFFER_2.ask)], "(ok true)");
call("S4 run-loops(21,100, u3): settle > redeem cap, treasury drains mid-run", FASTPOOL, V2_CID,
  "run-loops", [uintCV(S4_DEPOSIT), uintCV(3n)], /^\(ok /, "s4");
evalc("S4 machine STX (0 - withdraw always fires)", stxBal(V2_CID), "s4stx");
evalc("S4 machine MIA (the legit leftover)", miaBal(V2_CID), "s4mia");
evalc("S4 treasury after (0)", `(contract-call? '${CCD013} get-redemption-current-balance)`, "s4treasury");

// S5 -- donation sweep with dry treasury (escrow present from S4)
xfer("S5 settler donates 500 STX to the machine", SETTLER, V2_CID, DONATION);
call("S5 run(u0) sweeps the donation, escrow untouched (treasury dry)", FASTPOOL, V2_CID,
  "run", [uintCV(0n)], /^\(ok /, "s5");
evalc("S5 machine STX (0 again)", stxBal(V2_CID), "s5stx");

// S6 -- withdraw gates
call("S6 stranger withdraw-stx -> err u9000", STRANGER, V2_CID, "withdraw-stx",
  [uintCV(1n)], "(err u9000)");
call("S6 stranger withdraw-mia -> err u9000", STRANGER, V2_CID, "withdraw-mia",
  [uintCV(1n)], "(err u9000)");

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
  console.log("=== stx-to-stx-mia-faktory-v2 -- edge-scenario suite ===\n");
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
      console.log(`${ok ? "✅" : "❌"} [${i}] ${p.label}\n        got ${d.str.slice(0, 170)}${ok ? "" : `\n        EXPECTED ${p.expect}`}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) captured[p.capture] = v;
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 150)}`);
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
  const near = (label, got, want, tol) => {
    const diff = got > want ? got - want : want - got;
    const ok = diff <= tol;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got} (want ${want} +-${tol})`);
    ok ? pass++ : fail++;
  };

  if (bare(captured.redemption0) !== 0n) {
    console.log(`⚠️  live treasury non-zero at baseline - dry-state scenarios weakened`);
  }

  // S1: absurd cycles, nothing moved
  check("S1: deposited u0", num(captured.s1, "deposited"), 0n);
  check("S1: withdrawn u0", num(captured.s1, "withdrawn"), 0n);

  // S2: parity - identical result tuples
  check("S2: run(X) == run-loops(X, u1) result", captured.s2a === captured.s2b, true);
  check("S2: boomerang exact", num(captured.s2a, "withdrawn"), PARITY);

  // S3: settle capped at headroom exactly; nothing strands
  const s3Spent = num(captured.s3bookBefore, "ustx") - num(captured.s3bookAfter, "ustx");
  near("S3: book shrank by the 2,000 headroom (partial-fill rounding)", s3Spent, T1, 10n);
  near("S3: withdrawn ~= deposited (capital conserved)", num(captured.s3, "withdrawn"), S3_DEPOSIT, 10n);
  // partial-fill rounding leaves sub-0.001-MIA dust (observed 584 uMIA)
  check("S3: stranded MIA is dust only (<= 1,000 uMIA)", num(captured.s3, "mia-escrow") <= 1000n, true);
  check("S3: treasury drained to 0", bare(captured.s3treasury), 0n);
  check("S3: machine STX 0", bare(captured.s3stx), 0n);
  check("S3: machine MIA dust only (<= 1,000 uMIA)", bare(captured.s3mia) <= 1000n, true);

  // S4: conservation with legit leftover escrow
  const s4Escrow = num(captured.s4, "mia-escrow");
  check("S4: leftover escrow exists (redeem cap + drained treasury)", s4Escrow > 0n, true);
  near("S4: deposited == withdrawn + par(escrow) (conservation)",
    num(captured.s4, "withdrawn") + redeemPay(s4Escrow), S4_DEPOSIT, 10n);
  check("S4: machine STX 0 (withdraw always fires)", bare(captured.s4stx), 0n);
  check("S4: machine MIA == result escrow", bare(captured.s4mia), s4Escrow);
  check("S4: treasury drained to 0", bare(captured.s4treasury), 0n);

  // S5: donation swept, escrow untouched
  check("S5: withdrawn == the 500 STX donation", num(captured.s5, "withdrawn"), DONATION);
  near("S5: escrow unchanged by the sweep", num(captured.s5, "mia-escrow"), s4Escrow, 1000n);
  check("S5: machine STX 0", bare(captured.s5stx), 0n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
