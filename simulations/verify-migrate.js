// verify-migrate.js
// stxer mainnet-fork harness for stx-to-stx-migrate: deploys v2 + migrate
// under SPV9K21 against the LIVE v1 machine (which really holds the
// 8,187.134502 MIA "14 STX" escrow) and proves the one-tx lifecycle:
//
//   old settle-and-redeem(u0)  -> escrow burns, ~14 STX lands in v1
//   old withdraw-stx           -> the 14 STX reaches fastpool.btc
//   v2 run-loops(14 + extra)   -> eats the live book, withdraws remainder
//
// plus: a stranger's migrate call reverts wholesale (v2 gate), and the
// SP21 operator can use the helper safely after the escrow is drained
// (recovered u0 path).
//
// Run: node simulations/verify-migrate.js
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
const SP21FFP = "SP21YTSM60CAY6D011EZVEVNKXVW8FVZE198XEFFP";
const STRANGER = "SP102V8P0F7JX67ARQ77WEA3D3CFB5XW39REDT0AM";
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const OLD_CID = `${DEPLOYER}.stx-to-stx-mia-faktory`;
const V2_CID = `${DEPLOYER}.stx-to-stx-mia-faktory-v2`;
const MIGRATE_CID = `${DEPLOYER}.stx-to-stx-migrate`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

const PAR = 1710n;
const redeemPay = (umia) => (umia * PAR) / 1_000_000n;

const FUND_FASTPOOL = 20_000_000_000n;
const FUND_SP21 = 5_000_000_000n;
const TREASURY_FUND = 25_000_000_000n;
const EXTRA = 4_000_000_000n; // 4,000 STX: 5 cycles x ~4,014 covers the ~13.4k live book
const SP21_EXTRA = 1_000_000_000n;

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

// Act 0 -- deploys, baselines, funding
deploy("stx-to-stx-mia-faktory-v2");
deploy("stx-to-stx-migrate");
evalc("OLD machine MIA escrow (the 14 STX)", miaBal(OLD_CID), "oldMia0");
evalc("OLD machine STX", stxBal(OLD_CID), "oldStx0");
evalc("live book baseline", "(get-book-totals)", "book0");
evalc("FASTPOOL STX baseline", stxBal(FASTPOOL), "fp0");
xfer("fund FASTPOOL 20,000 STX (fork-only)", SETTLER, FASTPOOL, FUND_FASTPOOL);
xfer("fund SP21 5,000 STX (fork-only)", SETTLER, SP21FFP, FUND_SP21);

// Act 1 -- strangers revert wholesale at the v2 gate, on both entry points
call("migrate by stranger -> err u9000 (v2 gate, all reverted)", STRANGER, MIGRATE_CID,
  "migrate-and-run", [uintCV(0n), uintCV(5n)], "(err u9000)");
call("churn-and-run by stranger -> err u9000 (v2 gate)", STRANGER, MIGRATE_CID,
  "churn-and-run", [uintCV(0n), uintCV(5n)], "(err u9000)");

// Act 2 -- tranche lands
call("fund rewards treasury with 25,000 STX", SETTLER, REWARDS_TREASURY, "deposit-stx",
  [uintCV(TREASURY_FUND)], "(ok true)");

// Act 3 -- SP21 churn-and-run: escrow redeems and PARKS in the old
// machine (no withdraw leg), v2 eats book with fresh capital - atomic.
call("SP21 churn-and-run(1,000 STX, u5): escrow parks + v2 runs", SP21FFP, MIGRATE_CID,
  "churn-and-run", [uintCV(SP21_EXTRA), uintCV(5n)], /^\(ok /, "churn");
evalc("OLD machine STX after churn (parked ~14)", stxBal(OLD_CID), "oldStxParked");
evalc("OLD machine MIA after churn (0)", miaBal(OLD_CID), "oldMiaParked");

// Act 4 -- fastpool.btc collects the parked 14 + finishes the book
call("fastpool.btc migrate-and-run(4,000 STX, u5)", FASTPOOL, MIGRATE_CID,
  "migrate-and-run", [uintCV(EXTRA), uintCV(5n)], /^\(ok /, "migrate");
evalc("OLD machine MIA after (0 - escrow burned)", miaBal(OLD_CID), "oldMia1");
evalc("OLD machine STX after (0 - withdrawn)", stxBal(OLD_CID), "oldStx1");
evalc("v2 machine STX after (0)", stxBal(V2_CID), "v2Stx1");
evalc("v2 machine MIA after (0)", miaBal(V2_CID), "v2Mia1");
evalc("book after migrate run", "(get-book-totals)", "book1");
evalc("FASTPOOL STX after", stxBal(FASTPOOL), "fp1");

// Act 5 -- SP21 after everything is drained: old-parked u0, deposit boomerangs
call("SP21 churn-and-run(1,000 STX, u5) after drain - old-parked u0", SP21FFP, MIGRATE_CID,
  "churn-and-run", [uintCV(SP21_EXTRA), uintCV(5n)], /^\(ok /, "sp21run");
evalc("v2 machine STX final (0)", stxBal(V2_CID), "v2Stx2");

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
  console.log("=== stx-to-stx-migrate -- one-tx v1 harvest + v2 run ===\n");
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

  const oldMia0 = bare(captured.oldMia0); // live escrow, 8,187.134502 MIA expected
  const expectedRecovery = redeemPay(oldMia0); // ~13,999,999 uSTX

  // SP21's churn: the escrow redeemed and PARKED in the old machine
  check("churn: old-parked == redeemPay(old escrow)",
    num(captured.churn, "old-parked"), expectedRecovery);
  check("old machine STX parked after churn", bare(captured.oldStxParked), expectedRecovery);
  check("old machine MIA == 0 after churn", bare(captured.oldMiaParked), 0n);
  // fastpool's migrate then collects it; its own churn step may cycle the
  // parked STX through the remaining book first, so allow floor dust.
  const recovered = num(captured.migrate, "recovered");
  const recDiff = recovered > expectedRecovery ? recovered - expectedRecovery : expectedRecovery - recovered;
  check("migrate: recovered within 10 uSTX of the parked 14", recDiff <= 10n, true);
  check("OLD machine MIA == 0 (escrow burned)", bare(captured.oldMia1), 0n);
  check("OLD machine STX == 0 (withdrawn same tx)", bare(captured.oldStx1), 0n);
  check("v2 machine STX == 0 after", bare(captured.v2Stx1), 0n);
  check("v2 machine MIA == 0 after", bare(captured.v2Mia1), 0n);
  check("book consumed by the migrate run (ustx == 0)", num(captured.book1, "ustx"), 0n);

  // conservation: FASTPOOL nets ~ +14 STX (recovery) minus per-redeem floor
  // dust across the run's cycles (<= ~10 uSTX), minus nothing else.
  const fpNet = bare(captured.fp1) - bare(captured.fp0) - FUND_FASTPOOL;
  check("FASTPOOL net >= recovery - 20 uSTX dust", fpNet >= expectedRecovery - 20n, true);
  console.log(`   (FASTPOOL net: ${fpNet} uSTX ~= the recovered 14 STX)`);

  // SP21 path: recovered u0, deposit conserved
  check("SP21 post-drain: old-parked == u0", num(captured.sp21run, "old-parked"), 0n);
  check("v2 machine STX == 0 at the end", bare(captured.v2Stx2), 0n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
