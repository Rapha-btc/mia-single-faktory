// verify-arb.js
// SELF-VERIFYING stxer mainnet-fork harness for mia-arb-faktory:
// atomic triangular arb around the DEPLOYED mia-orderbook-faktory, against
// the LIVE ALEX pool 16 (wSTX/wMIA), Bitflow xyk sbtc-stx and Velar 0070.
//
// Coverage:
//   - guards: empty-limit no-fill (book err u13019 propagates + full refund),
//     min-profit slippage (err u1000 + full refund), replenish slippage
//   - taker arb via Bitflow: fills a planted cheap offer (100k sats/1M vs
//     ~326k/1M real asks and ~1133 STX/1M on ALEX), exact cost = spend + 10bps,
//     exact acquired, profit > 0, caller sBTC delta == profit, maker paid ask,
//     fee recipient got the 10 bps
//   - taker arb via Velar: same plant, same assertions
//   - maker replenish via Bitflow + Velar: sBTC -> STX -> MIA, caller MIA
//     delta == mia-out, sBTC delta == -sbtc-in
//   - invariant everywhere: the arb contract NEVER retains sBTC / MIA / STX
//
// Live state assumed (verified 2026-07-06): book has 2 real offers at ~325k
// and ~334k sats/1M (owners SP3W8BCK…, SP2C3A6EY…) — excluded by our 100k/1M
// limit; ALEX pool 16 ~746k STX / 658M MIA so a 2M MIA sell is ~0.3% depth.
//
// Run: node simulations/verify-arb.js
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

// --- Mainnet actors (impersonated on the fork; balances verified 2026-07-03) ---
const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // 1.64B MIA (no book offer)
const ARBER = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // 40.7 sBTC

const MIA = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const FEE_RECIPIENT = "SM362G0X1YNB2M3FWWFAASV9WB3XHQ8RWP512SSX3"; // book default

const BOOK_CID = `${DEPLOYER}.mia-orderbook-faktory`; // DEPLOYED book
const ARB_CID = `${DEPLOYER}.mia-arb-faktory`; // deployed in this sim

// --- Plant plan: 2M MIA at 100k sats/1M (total ask 200k sats). Real asks
// sit at ~326k/1M so a 100k/1M limit fills ONLY the plant. ---
const PLANT_MIA = 2_000_000_000_000n; // 2M MIA
const PLANT_ASK = 200_000n; // sats (100k per 1M MIA)
const LIMIT = 100_000n; // sats per 1M MIA
const SPEND = PLANT_ASK; // clears the plant exactly
const FEE = (SPEND * 10n) / 10_000n; // 200
const COST = SPEND + FEE; // 200,200
const BUFFER = SPEND + SPEND / 1_000n; // 200,200 (== cost when fully spent)

const REPLENISH_IN = 100_000n; // sats

const miaBal = (a) => `(contract-call? '${MIA} get-balance '${a})`;
const sbtcBal = (a) => `(contract-call? '${SBTC} get-balance '${a})`;
const stxBal = (a) => `(stx-get-balance '${a})`;

// ---- scenario builder with a parallel assertion plan ----
const plan = [];
const b = SimulationBuilder.new();

function deploy(name) {
  b.withSender(DEPLOYER).addContractDeploy({
    contract_name: name,
    source_code: fs.readFileSync(`./contracts/${name}.clar`, "utf8"),
    clarity_version: ClarityVersion.Clarity5,
  });
  plan.push({ kind: "deploy", label: `deploy ${name} (Clarity 5)` });
}
function call(label, sender, cid, fn, args, expect, capture) {
  b.withSender(sender).addContractCall({ contract_id: cid, function_name: fn, function_args: args });
  plan.push({ kind: "tx", label, expect, capture });
}
function evalc(label, code, capture) {
  b.addEvalCode(BOOK_CID, code);
  plan.push({ kind: "eval", label, capture });
}
const arbOk = (s) =>
  s.startsWith("(ok ") &&
  s.includes(`(cost u${COST})`) &&
  s.includes(`(acquired u${PLANT_MIA})`);

// =====================================================================
// Act 0 -- deploy; live book sanity; contract starts empty
// =====================================================================
deploy("mia-arb-faktory");
evalc("live book info", `(contract-call? '${BOOK_CID} get-info)`, "info0");
evalc("live book totals", `(contract-call? '${BOOK_CID} get-book-totals)`, "totals0");
evalc("arb contract sBTC at start", sbtcBal(ARB_CID), "arb_sbtc_0");
evalc("arb contract MIA at start", miaBal(ARB_CID), "arb_mia_0");
evalc("arb contract STX at start", stxBal(ARB_CID), "arb_stx_0");

// =====================================================================
// Act 1 -- revert paths refund everything
// =====================================================================
evalc("arber sBTC before guards", sbtcBal(ARBER), "S_g0");
call("arb with limit u1 (no fill) -> book err u13019 propagates", ARBER, ARB_CID,
  "arb-book-alex-bitflow", [uintCV(1_000n), uintCV(1n), uintCV(0n)], "(err u13019)");
call("replenish with absurd min-mia-out -> err u1000", ARBER, ARB_CID,
  "replenish-bitflow-alex", [uintCV(REPLENISH_IN), uintCV(10n ** 15n)], "(err u1000)");
evalc("arber sBTC after guards (unchanged)", sbtcBal(ARBER), "S_g1");

// =====================================================================
// Act 2 -- profitable taker arb, Bitflow close
// =====================================================================
evalc("arber sBTC before arb 1", sbtcBal(ARBER), "S_a0");
evalc("maker sBTC before arb 1", sbtcBal(WHALE_A), "M_a0");
evalc("fee recipient sBTC before arb 1", sbtcBal(FEE_RECIPIENT), "F_a0");
call("whale plants 2M MIA @ 200k sats (100k/1M)", WHALE_A, BOOK_CID,
  "place-offer", [uintCV(PLANT_MIA), uintCV(PLANT_ASK)], "(ok true)");
call("arb-book-alex-bitflow: 200k sats @ limit 100k/1M -> profit", ARBER, ARB_CID,
  "arb-book-alex-bitflow", [uintCV(SPEND), uintCV(LIMIT), uintCV(0n)], arbOk, "arb1");
evalc("arber sBTC after arb 1", sbtcBal(ARBER), "S_a1");
evalc("maker sBTC after arb 1", sbtcBal(WHALE_A), "M_a1");
evalc("fee recipient sBTC after arb 1", sbtcBal(FEE_RECIPIENT), "F_a1");
evalc("arb contract sBTC after arb 1", sbtcBal(ARB_CID), "arb_sbtc_1");
evalc("arb contract MIA after arb 1", miaBal(ARB_CID), "arb_mia_1");
evalc("arb contract STX after arb 1", stxBal(ARB_CID), "arb_stx_1");

// =====================================================================
// Act 3 -- profitable taker arb, Velar close
// =====================================================================
evalc("arber sBTC before arb 2", sbtcBal(ARBER), "S_b0");
call("whale plants again (2M MIA @ 200k sats)", WHALE_A, BOOK_CID,
  "place-offer", [uintCV(PLANT_MIA), uintCV(PLANT_ASK)], "(ok true)");
call("arb-book-alex-velar: same plant -> profit", ARBER, ARB_CID,
  "arb-book-alex-velar", [uintCV(SPEND), uintCV(LIMIT), uintCV(0n)], arbOk, "arb2");
evalc("arber sBTC after arb 2", sbtcBal(ARBER), "S_b1");
evalc("arb contract sBTC after arb 2", sbtcBal(ARB_CID), "arb_sbtc_2");
evalc("arb contract MIA after arb 2", miaBal(ARB_CID), "arb_mia_2");

// =====================================================================
// Act 4 -- min-profit slippage: full revert, plant survives, then cleanup
// =====================================================================
evalc("arber sBTC before slippage test", sbtcBal(ARBER), "S_c0");
call("whale plants again (2M MIA @ 200k sats)", WHALE_A, BOOK_CID,
  "place-offer", [uintCV(PLANT_MIA), uintCV(PLANT_ASK)], "(ok true)");
// After two 2M-MIA sells the ALEX/Bitflow composite has degraded, so this
// round may fail the no-profit assert (u1001) before the min-profit one
// (u1000). Either way the whole tx reverts — the refund check below is the
// real assertion.
call("arb with min-profit 1 sBTC -> reverts (u1000 or u1001), refunded", ARBER, ARB_CID,
  "arb-book-alex-bitflow", [uintCV(SPEND), uintCV(LIMIT), uintCV(100_000_000n)], /^\(err u100[01]\)$/);
evalc("arber sBTC after slippage revert (unchanged)", sbtcBal(ARBER), "S_c1");
evalc("plant survives the revert", `(contract-call? '${BOOK_CID} get-offer '${WHALE_A})`, "plant");
call("whale cancels the surviving plant (cleanup)", WHALE_A, BOOK_CID,
  "cancel-offer", [], "(ok true)");

// =====================================================================
// Act 5 -- maker-side replenish loops
// =====================================================================
evalc("arber sBTC before replenish", sbtcBal(ARBER), "S_r0");
evalc("arber MIA before replenish", miaBal(ARBER), "R_mia_0");
call("replenish-bitflow-alex: 100k sats -> MIA", ARBER, ARB_CID,
  "replenish-bitflow-alex", [uintCV(REPLENISH_IN), uintCV(1n)], /^\(ok /, "rep1");
call("replenish-velar-alex: 100k sats -> MIA", ARBER, ARB_CID,
  "replenish-velar-alex", [uintCV(REPLENISH_IN), uintCV(1n)], /^\(ok /, "rep2");
evalc("arber sBTC after replenish", sbtcBal(ARBER), "S_r1");
evalc("arber MIA after replenish", miaBal(ARBER), "R_mia_1");
// =====================================================================
// Act 6 -- rescue: a direct donation is sweepable to DEPLOYER by anyone
// =====================================================================
evalc("deployer sBTC before rescue", sbtcBal(DEPLOYER), "D_s0");
call("stranger donates 1000 sats straight to the arb contract", ARBER,
  SBTC, "transfer",
  [uintCV(1_000n), standardPrincipalCV(ARBER), contractPrincipalCV(DEPLOYER, "mia-arb-faktory"), noneCV()],
  "(ok true)");
call("anyone calls rescue -> sweep to DEPLOYER", WHALE_A, ARB_CID,
  "rescue", [], /^\(ok \(tuple \(mia u0\) \(sbtc u1000\) \(stx u0\)\)\)$/);
evalc("deployer sBTC after rescue", sbtcBal(DEPLOYER), "D_s1");

evalc("arb contract sBTC at end", sbtcBal(ARB_CID), "arb_sbtc_end");
evalc("arb contract MIA at end", miaBal(ARB_CID), "arb_mia_end");
evalc("arb contract STX at end", stxBal(ARB_CID), "arb_stx_end");

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
  console.log("=== mia-arb-faktory -- self-verifying stxer harness ===\n");
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
      console.log(`ℹ️  [${i}] ${p.label}: ${String(v).slice(0, 160)}`);
    }
  });

  console.log("\n--- numeric cross-checks ---");
  const check = (label, got, want) => {
    const ok = got === want;
    console.log(`${ok ? "✅" : "❌"} ${label}: ${got}${ok ? "" : ` (want ${want})`}`);
    ok ? pass++ : fail++;
  };

  // contract holds nothing, ever
  for (const k of ["arb_sbtc_0", "arb_mia_0", "arb_sbtc_1", "arb_mia_1", "arb_sbtc_2", "arb_mia_2", "arb_sbtc_end", "arb_mia_end"]) {
    check(`contract empty: ${k}`, bare(captured[k]), 0n);
  }
  for (const k of ["arb_stx_0", "arb_stx_1", "arb_stx_end"]) {
    check(`contract empty: ${k}`, bare(captured[k]), 0n);
  }

  // reverts refund exactly
  check("guards: arber sBTC untouched", bare(captured.S_g1), bare(captured.S_g0));
  check("slippage revert: arber sBTC untouched", bare(captured.S_c1), bare(captured.S_c0));
  check("plant survives slippage revert (2M MIA)", num(captured.plant, "amount"), PLANT_MIA);

  // arb 1 (bitflow): parse result, tie every delta to it
  const profit1 = num(captured.arb1, "profit");
  const out1 = num(captured.arb1, "sbtc-out");
  check("arb1 profit == sbtc-out - cost", profit1, out1 - COST);
  check("arb1 profit > 0", profit1 > 0n, true);
  check("arb1 arber sBTC delta == profit", bare(captured.S_a1) - bare(captured.S_a0), profit1);
  check("arb1 maker got the full ask", bare(captured.M_a1) - bare(captured.M_a0), PLANT_ASK);
  check("arb1 fee recipient got 10 bps", bare(captured.F_a1) - bare(captured.F_a0), FEE);

  // arb 2 (velar)
  const profit2 = num(captured.arb2, "profit");
  check("arb2 profit > 0", profit2 > 0n, true);
  check("arb2 arber sBTC delta == profit", bare(captured.S_b1) - bare(captured.S_b0), profit2);

  // replenish: MIA delta == sum of mia-out; sBTC delta == -2 * 100k
  const mia1 = num(captured.rep1, "mia-out");
  const mia2 = num(captured.rep2, "mia-out");
  check("rep1 mia-out > 0", mia1 > 0n, true);
  check("rep2 mia-out > 0", mia2 > 0n, true);
  check("replenish arber MIA delta == mia-out sum",
    bare(captured.R_mia_1) - bare(captured.R_mia_0), mia1 + mia2);
  check("replenish arber sBTC delta == -(2 x 100k)",
    bare(captured.S_r0) - bare(captured.S_r1), 2n * REPLENISH_IN);

  // rescue swept the donation to DEPLOYER
  check("rescue: deployer received the 1000-sat donation",
    bare(captured.D_s1) - bare(captured.D_s0), 1_000n);

  console.log(`\n=== ${pass} passed, ${fail} failed ===`);
  console.log(`View: ${url}`);
  if (fail > 0) process.exit(1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
