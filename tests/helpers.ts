import { Cl, ClarityValue } from "@stacks/transactions";
import { readFileSync } from "node:fs";

// ---- mainnet principals baked into the contracts ----
export const MIA_V2 =
  "SP1H1733V5MZ3SZ9XRW9FKYGEZT0JDGEB8Y634C7R.miamicoin-token-v2";
export const MIA_V1 =
  "SP466FNC0P7JWTNM2R9T199QRZN1MYEDTAR0KP27.miamicoin-token";
export const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
export const TREASURY =
  "SP8A9HZ3PKST0S42VM9523Z9NV42SZ026V4K39WH.ccd002-treasury-mia-mining-v3";
export const FAKTORY_ADDRESS = "SMH8FRN30ERW1SX26NJTJCKTDR3H27NRJ6W75WQE";

// the fak.fun deployer the contracts are written for; the full-flow suites
// deploy the trio under this address so DEPOSITOR / SINGLE_SIDED line up
export const FAKFUN = "SPV9K21TBFAK4KNRJXF5DFP8N7W46G4V9RCJDC22";

export const LOCK_PERIOD = 12960;

// ---- funding helpers (simnet-only console commands) ----
export const mintMia = (recipient: string, amount: number | bigint) =>
  simnet.executeCommand(`::mint_ft ${MIA_V2}.miamicoin ${recipient} ${amount}`);

export const mintMiaV1 = (recipient: string, amount: number | bigint) =>
  simnet.executeCommand(`::mint_ft ${MIA_V1}.miamicoin ${recipient} ${amount}`);

export const mintSbtc = (recipient: string, amount: number | bigint) =>
  simnet.executeCommand(`::mint_ft ${SBTC}.sbtc-token ${recipient} ${amount}`);

export const mintStx = (recipient: string, amount: number | bigint) =>
  simnet.executeCommand(`::mint_stx ${recipient} ${amount}`);

// ---- balance readers ----
export const miaBalance = (who: string): bigint =>
  cvUint(
    simnet.callReadOnlyFn(
      MIA_V2,
      "get-balance",
      [Cl.principal(who)],
      simnet.deployer,
    ).result,
  );

export const sbtcBalance = (who: string): bigint =>
  cvUint(
    simnet.callReadOnlyFn(
      SBTC,
      "get-balance",
      [Cl.principal(who)],
      simnet.deployer,
    ).result,
  );

export const stxBalance = (who: string): bigint =>
  simnet.getAssetsMap().get("STX")?.get(who) ?? 0n;

// unwrap (ok uint) or plain uint clarity values to bigint
export function cvUint(cv: ClarityValue): bigint {
  if (cv.type === "ok") return cvUint(cv.value);
  if (cv.type === "uint") return cv.value;
  throw new Error(`expected uint-ish CV, got ${Cl.prettyPrint(cv)}`);
}

// ---- full-flow environment: the trio deployed under the fak.fun address ----
export function deployTrio() {
  for (const name of [
    "mia-pool-faktory",
    "mia-single-faktory",
    "mia-fair-faktory",
  ]) {
    const src = readFileSync(`contracts/${name}.clar`, "utf-8");
    simnet.deployContract(name, src, { clarityVersion: 6 }, FAKFUN);
  }
  return {
    pool: `${FAKFUN}.mia-pool-faktory`,
    single: `${FAKFUN}.mia-single-faktory`,
    fair: `${FAKFUN}.mia-fair-faktory`,
    admin: FAKFUN,
  };
}

// Standard fair-faktory environment: MIA supply exists and the mining treasury
// is funded so `initialize` computes ratio = 1710 (the mainnet par).
// supply: v1 200_000 (x 1e6) + v2 1_000_000_000_000 = 1.2e12 uMIA
// treasury: 2_052_000_000 uSTX -> ratio = 2.052e9 * 1e6 / 1.2e12 = 1710
export const RATIO = 1710n;

export function fundParEnvironment(wallets: string[]) {
  mintMiaV1(wallets[0], 200_000);
  const total = 1_000_000_000_000n;
  const each = total / BigInt(wallets.length);
  const remainder = total - each * BigInt(wallets.length);
  for (const w of wallets) mintMia(w, each);
  if (remainder > 0n) mintMia(wallets[0], remainder);
  mintStx(TREASURY, 2_052_000_000);
}

export const parUstx = (uMia: bigint | number): bigint =>
  (RATIO * BigInt(uMia)) / 1_000_000n;

export const parEquivMia = (uStx: bigint | number): bigint =>
  (BigInt(uStx) * 1_000_000n) / RATIO;
