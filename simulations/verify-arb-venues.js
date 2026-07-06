// verify-arb-venues.js — race the FULL circle (200k sats -> book MIA ->
// ALEX STX -> sBTC) across four leg-3 venues, each on its OWN fresh fork so
// the pools are identical at the start of every run:
//   bitflow  arb-book-alex-bitflow  (mia-arb-faktory)
//   velar    arb-book-alex-velar    (mia-arb-faktory)
//   dlmm     arb-book-alex-dlmm     (mia-arb-dlmm-sim: direct stx-sbtc bps-15)
//   dlmm2    arb-book-alex-dlmm2    (mia-arb-dlmm-sim: 2-hop via USDCx bps-10)
//
// Run: node simulations/verify-arb-venues.js
import fs from "node:fs";
import {
  ClarityVersion,
  uintCV,
  deserializeCV,
  cvToString,
} from "@stacks/transactions";
import { SimulationBuilder, getSimulationResult } from "stxer";

const DEPLOYER = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const WHALE_A = "SP3HXJJMJQ06GNAZ8XWDN1QM48JEDC6PP6W3YZPZJ"; // MIA maker
const ARBER = "SP2C7BCAP2NH3EYWCCVHJ6K0DMZBXDFKQ56KR7QN2"; // sBTC caller

const BOOK_CID = `${DEPLOYER}.mia-orderbook-faktory`;
const PLANT_MIA = 2_000_000_000_000n; // 2M MIA
const PLANT_ASK = 200_000n; // 200k sats (100k/1M)
const LIMIT = 100_000n;

const VENUES = [
  { key: "bitflow", contract: "mia-arb-faktory", src: "./contracts/mia-arb-faktory.clar", fn: "arb-book-alex-bitflow" },
  { key: "velar", contract: "mia-arb-faktory", src: "./contracts/mia-arb-faktory.clar", fn: "arb-book-alex-velar" },
  { key: "dlmm-direct", contract: "mia-arb-faktory", src: "./contracts/mia-arb-faktory.clar", fn: "arb-book-alex-dlmm" },
  { key: "dlmm-2hop", contract: "mia-arb-dlmm-sim", src: "./simulations/mia-arb-dlmm-sim.clar", fn: "arb-book-alex-dlmm2" },
];

function decodeTx(s) {
  const r = s?.Result?.Transaction;
  if (!r) return "<none>";
  if ("Err" in r) return `ENGINE-ERR: ${JSON.stringify(r.Err).slice(0, 200)}`;
  try { return cvToString(deserializeCV(r.Ok.result)); } catch (e) { return `decode-failed: ${e.message}`; }
}
const num = (s, key) => BigInt((String(s).match(new RegExp(`\\(${key} u(\\d+)\\)`)) || [])[1] ?? "-1");

async function raceOne(v) {
  const b = SimulationBuilder.new();
  b.withSender(DEPLOYER).addContractDeploy({
    contract_name: v.contract,
    source_code: fs.readFileSync(v.src, "utf8"),
    clarity_version: ClarityVersion.Clarity5,
  });
  b.withSender(WHALE_A).addContractCall({
    contract_id: BOOK_CID, function_name: "place-offer",
    function_args: [uintCV(PLANT_MIA), uintCV(PLANT_ASK)],
  });
  b.withSender(ARBER).addContractCall({
    contract_id: `${DEPLOYER}.${v.contract}`, function_name: v.fn,
    function_args: [uintCV(PLANT_ASK), uintCV(LIMIT), uintCV(0n)],
  });
  const sid = await b.run();
  const res = await getSimulationResult(sid);
  const arb = decodeTx(res.steps[2]);
  return {
    key: v.key,
    url: `https://stxer.xyz/simulations/mainnet/${sid}`,
    raw: arb.slice(0, 220),
    cost: num(arb, "cost"),
    sbtcOut: num(arb, "sbtc-out"),
    profit: num(arb, "profit"),
  };
}

const results = [];
for (const v of VENUES) {
  process.stdout.write(`racing ${v.key}... `);
  const r = await raceOne(v);
  console.log(r.profit >= 0n ? `profit ${r.profit}` : r.raw);
  results.push(r);
}

console.log("\n=== FULL CIRCLE: 200,000 sats in (cost incl. 10 bps fee = 200,200) ===");
results.sort((a, b) => (b.sbtcOut > a.sbtcOut ? 1 : -1));
for (const r of results) {
  console.log(
    `${r.key.padEnd(12)} sbtc-out ${String(r.sbtcOut).padStart(8)}  profit ${String(r.profit).padStart(8)}  ${r.url}`,
  );
}
