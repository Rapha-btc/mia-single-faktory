import { Cl } from "@stacks/transactions";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const MIA_V2 = "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const FAKFUN = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";
const TREASURY =
  "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-mining-v3";

describe("simnet mechanics", () => {
  it("mints MIA and sBTC to standard and contract principals", () => {
    console.log(
      "mia->wallet:",
      simnet.executeCommand(`::mint_ft ${MIA_V2}.miamicoin ${simnet.deployer} 1000000`),
    );
    console.log(
      "sbtc->wallet:",
      simnet.executeCommand(`::mint_ft ${SBTC}.sbtc-token ${simnet.deployer} 1000000`),
    );
    console.log(
      "mia->contract-principal:",
      simnet.executeCommand(
        `::mint_ft ${MIA_V2}.miamicoin ${FAKFUN}.mia-fair-faktory 1000000`,
      ),
    );
    const supply = simnet.callReadOnlyFn(MIA_V2, "get-total-supply", [], simnet.deployer);
    console.log("mia supply:", Cl.prettyPrint(supply.result));
  });

  it("funds the mining treasury with STX", () => {
    console.log(
      "stx->treasury:",
      simnet.executeCommand(`::mint_stx ${TREASURY} 2052000000`),
    );
    const bal = simnet.execute(`(stx-account '${TREASURY})`);
    console.log("treasury account:", Cl.prettyPrint(bal.result));
  });

  it("does NOT support contract principals as tx-sender (why tests deploy the trio under the fak.fun address)", () => {
    expect(() =>
      simnet.callPublicFn(
        MIA_V2,
        "transfer",
        [
          Cl.uint(100),
          Cl.principal(`${FAKFUN}.mia-fair-faktory`),
          Cl.principal(simnet.deployer),
          Cl.none(),
        ],
        `${FAKFUN}.mia-fair-faktory`,
      ),
    ).toThrow(/Invalid sender/);
  });

  it("mines burn blocks", () => {
    const before = simnet.burnBlockHeight;
    simnet.mineEmptyBurnBlocks(100);
    console.log("burn height:", before, "->", simnet.burnBlockHeight);
    expect(simnet.burnBlockHeight).toBeGreaterThanOrEqual(before + 100);
  });

  it("deploys the contracts under the fak.fun deployer as Clarity 6", () => {
    for (const name of ["mia-pool-faktory", "mia-single-faktory", "mia-fair-faktory"]) {
      const src = readFileSync(`contracts/${name}.clar`, "utf-8");
      const res = simnet.deployContract(name, src, { clarityVersion: 6 }, FAKFUN);
      console.log(`deploy ${name}:`, Cl.prettyPrint(res.result));
    }
    const gated = simnet.callReadOnlyFn(
      `${FAKFUN}.mia-pool-faktory`,
      "is-gated",
      [],
      simnet.deployer,
    );
    expect(gated.result).toEqual(Cl.bool(true));
  });
});
