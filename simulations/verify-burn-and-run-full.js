// verify-burn-and-run-full.js
// Companion to verify-burn-and-run.js: same actors, but the ccd013 treasury is
// funded FAR beyond what one pass needs, so the 5 cycles actually recycle and
// the limiting factor becomes the fair-v2 book rather than the treasury.
//
// Proves: burn + 5 loops in ONE tx eats the whole live book, the float comes
// home, and the surplus passes stay with fair-v2 instead of a racer. Also
// proves the extra loops past what the state supports are harmless.
//
// Run: node simulations/verify-burn-and-run-full.js
import fs from "fs";
import { uintCV, deserializeCV, cvToString, ClarityVersion } from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const FASTPOOL = "SP3KJBWTS3K562BF5NXWG5JC8W90HEG7WPYH5B97X";
const SETTLER = "SP1FJ0MY8M18KZF43E85WJN48SDXYS1EC4BCQW02S";

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const MACHINE_CID = `${DEPLOYER}.stx-to-stx-mia-faktory-v2`;
const FAIR_CID = `${DEPLOYER}.mia-fair-faktory-v2`;
const BAR_CID = `${DEPLOYER}.mia-burn-and-run`;
const CCD013 = "SP2PABAF9FTAJYNFZH93XENAJ8FVY99RRM50D2JG9.ccd013-burn-to-exit-mia";
const REWARDS_TREASURY = "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-rewards-v3";

// node simulations/verify-burn-and-run-full.js [umia]  (0 = skip the burn leg)
const BURN_MIA = process.argv[2] !== undefined ? BigInt(process.argv[2]) : 3_231_715_183_625n;
const RUN_USTX = 17_100_000_000n; // per-pass ceiling
const TREASURY_FUND = 100_000_000_000n; // 100,000 STX - deliberately way too much
const FUND_FASTPOOL = 40_000_000_000n;
const DUST_BOUND = 1_000_000n; // 1 MIA: rounding dust, not a stranded position

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;
const redemption = `(contract-call? '${CCD013} get-redemption-current-balance)`;

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

deploy("mia-burn-and-run");
evalc("book baseline", "(get-book-totals)", "book0");
evalc("fair surplus baseline", "(get-info)", "fair0");
evalc("machine STX baseline", stxBal(MACHINE_CID), "machineStx0");
evalc("machine MIA baseline", miaBal(MACHINE_CID), "machineMia0");
evalc("treasury baseline", redemption, "treasury0");
evalc("FASTPOOL STX baseline", stxBal(FASTPOOL), "fpStx0");
evalc("FASTPOOL MIA baseline", miaBal(FASTPOOL), "fpMia0");

xfer("fund FASTPOOL 40,000 STX (fork-only float)", SETTLER, FASTPOOL, FUND_FASTPOOL);
call("fund rewards treasury with 100,000 STX (deliberate overkill)", SETTLER, REWARDS_TREASURY,
  "deposit-stx", [uintCV(TREASURY_FUND)], "(ok true)");
evalc("treasury before the run", redemption, "treasury1");
evalc("get-plan(FASTPOOL)", `(contract-call? '${BAR_CID} get-plan '${FASTPOOL})`, "plan1");

call(`burn-and-run(${BURN_MIA} uMIA, 17,100 STX, 5 cycles)`, FASTPOOL, BAR_CID, "burn-and-run",
  [uintCV(BURN_MIA), uintCV(RUN_USTX), uintCV(5n)], /^\(ok /, "run");

evalc("book after (want 0 ustx - fully consumed)", "(get-book-totals)", "book1");
evalc("fair surplus after", "(get-info)", "fair1");
evalc("machine STX after (want 0)", stxBal(MACHINE_CID), "machineStx1");
evalc("machine MIA after (dust only)", miaBal(MACHINE_CID), "machineMia1");
evalc("treasury after", redemption, "treasury2");
evalc("FASTPOOL STX after", stxBal(FASTPOOL), "fpStx1");
evalc("FASTPOOL MIA after", miaBal(FASTPOOL), "fpMia1");

function decodeTx(s) {
  const r = s?.Result?.Transaction;
  if (!r) return { ok: false, str: "<no transaction result>" };
  if ("Err" in r) return { ok: false, str: `ENGINE-ERR: ${JSON.stringify(r.Err).slice(0, 200)}` };
  try { return { ok: true, str: cvToString(deserializeCV(r.Ok.result)) }; }
  catch (e) { return { ok: false, str: `decode-failed: ${e.message}` }; }
}
function decodeEval(s) {
  const r = s?.Result?.Eval;
  if (!r) return "<no eval result>";
  if (!("Ok" in r)) return `ERR: ${JSON.stringify(r.Err).slice(0, 200)}`;
  try { return cvToString(deserializeCV(r.Ok)); } catch { return r.Ok; }
}
const num = (s, k) => BigInt((String(s).match(new RegExp(`\\(${k} u(\\d+)\\)`)) || [])[1] ?? "-1");
const bare = (s) => BigInt((String(s).match(/u(\d+)/) || [])[1] ?? "-1");
const stx = (u) => `${(Number(u) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 6 })} STX`;
const mia = (u) => `${(Number(u) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 6 })} MIA`;

async function main() {
  console.log("=== mia-burn-and-run -- fat treasury, 5 loops ===\n");
  const sessionId = await b.run();
  const url = `https://stxer.xyz/simulations/mainnet/${sessionId}`;
  console.log(`${url}\n`);

  const res = await getSimulationResult(sessionId);
  const c = {};
  let pass = 0, fail = 0;

  res.steps.forEach((s, i) => {
    const p = plan[i];
    if (!p) return;
    if (p.kind === "tx") {
      const d = decodeTx(s);
      if (p.capture) c[p.capture] = d.str;
      const ok = typeof p.expect === "function" ? p.expect(d.str)
        : p.expect instanceof RegExp ? p.expect.test(d.str) : d.str === p.expect;
      console.log(`${ok ? "PASS" : "FAIL"} [${i}] ${p.label}\n        got ${d.str.slice(0, 200)}`);
      ok ? pass++ : fail++;
    } else if (p.kind === "eval") {
      const v = decodeEval(s);
      if (p.capture) c[p.capture] = v;
      console.log(`info [${i}] ${p.label}: ${String(v).slice(0, 200)}`);
    } else console.log(`deploy [${i}] ${p.label}`);
  });

  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "PASS" : "FAIL"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  const bookSpent = num(c.book0, "ustx") - num(c.book1, "ustx");
  const treasuryDrain = bare(c.treasury1) - bare(c.treasury2);
  const fpGain = bare(c.fpStx1) - bare(c.fpStx0) - FUND_FASTPOOL;
  const surplusGain = num(c.fair1, "surplus-mia") - num(c.fair0, "surplus-mia");

  console.log("\n--- ledger ---");
  console.log(`treasury funded            ${stx(bare(c.treasury1))}`);
  console.log(`book consumed              ${stx(bookSpent)} of offers`);
  console.log(`passes implied             ${(Number(bookSpent) / Number(RUN_USTX)).toFixed(2)} x 17,100 STX`);
  console.log(`treasury drained           ${stx(treasuryDrain)}`);
  console.log(`treasury left over         ${stx(bare(c.treasury2))}`);
  console.log(`FASTPOOL net STX           ${stx(fpGain)}`);
  console.log(`fair-v2 surplus gained     ${mia(surplusGain)}`);
  console.log(`machine dust left          ${mia(bare(c.machineMia1))}`);

  check("book fully consumed", num(c.book1, "ustx"), 0n);
  check("machine holds no STX", bare(c.machineStx1), 0n);
  check("machine MIA is dust only (< 1 MIA)", bare(c.machineMia1) < DUST_BOUND, true);
  check("FASTPOOL MIA burned", bare(c.fpMia1), bare(c.fpMia0) - BURN_MIA);
  const expectedGain = (BURN_MIA * 1710n) / 1_000_000n;
  check("net gain == burn proceeds (within 1000 uSTX of par)",
    fpGain >= expectedGain - 1000n && fpGain <= expectedGain + 1000n, true);
  check("treasury not exhausted (overkill funding held up)", bare(c.treasury2) > 0n, true);
  check("more than one pass ran", bookSpent > RUN_USTX, true);

  console.log(`\n${pass} passed, ${fail} failed`);
  console.log(url);
}
main().catch((e) => { console.error(e); process.exit(1); });
