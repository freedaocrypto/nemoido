#!/usr/bin/env node
/**
 * Batch-import records from import-data.json into a deployed NemoIdo.
 *
 *   IDO_ADDRESS=0x... RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=0x... \
 *     node scripts/import-onchain.mjs --in import-data.json
 *   ... node scripts/import-onchain.mjs --apply
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { codeToBytes32, chunk } from "./lib/tree.mjs";

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

const apply = process.argv.includes("--apply");
const inPath = resolve(arg("--in", "import-data.json"));
const batchSize = Number(arg("--batch", "40"));
const data = JSON.parse(readFileSync(inPath, "utf8"));

if (!data.ok || !Array.isArray(data.records)) {
  console.error("import file is not ok=true; run export first");
  process.exit(1);
}

const records = data.records;
console.log(`records=${records.length} batch=${batchSize} apply=${apply}`);
console.log(data.stats);

if (!apply) {
  const maxDepth = data.stats?.maxDepth ?? 0;
  console.log(`dry-run ok. maxDepth=${maxDepth}. Re-run with --apply to send txs.`);
  process.exit(0);
}

const { createWalletClient, createPublicClient, http, parseAbi } = await import("viem");
const { privateKeyToAccount } = await import("viem/accounts");

const rpc = process.env.RPC_URL || "http://127.0.0.1:8545";
const ido = process.env.IDO_ADDRESS;
const pk = process.env.PRIVATE_KEY;
if (!ido || !pk) {
  console.error("Need IDO_ADDRESS and PRIVATE_KEY");
  process.exit(1);
}

const account = privateKeyToAccount(pk.startsWith("0x") ? pk : `0x${pk}`);
const chain = {
  id: Number(process.env.CHAIN_ID || 31337),
  name: "local",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
};

const abi = parseAbi([
  "function importUsers(address[] wallets, bytes32[] codes)",
  "function importReferrers(address[] wallets, address[] referrers)",
  "function importVolumes(address[] wallets, uint256[] selfVolumes, uint256[] teamVolumes)",
  "function freezeImport()",
  "function importFrozen() view returns (bool)",
  "function getAccount(address) view returns ((address referrer, bytes32 inviteCode, uint256 selfVolume, uint256 teamVolume, uint256 directRewards, uint256 teamRewards, uint256 claimed, bool registered))",
]);

const transport = http(rpc);
const wallet = createWalletClient({ account, chain, transport });
const publicClient = createPublicClient({ chain, transport });

function unpackAccount(acc) {
  if (acc && typeof acc === "object" && acc.selfVolume !== undefined) {
    return acc;
  }
  const [
    referrer,
    inviteCode,
    selfVolume,
    teamVolume,
    directRewards,
    teamRewards,
    claimed,
    registered,
  ] = Array.isArray(acc) ? acc : [];
  return {
    referrer,
    inviteCode,
    selfVolume,
    teamVolume,
    directRewards,
    teamRewards,
    claimed,
    registered,
  };
}

async function send(functionName, args) {
  const hash = await wallet.writeContract({
    address: ido,
    abi,
    functionName,
    args,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new Error(`${functionName} failed: ${hash}`);
  }
  console.log(`${functionName} ${hash}`);
}

const alreadyFrozen = await publicClient.readContract({
  address: ido,
  abi,
  functionName: "importFrozen",
});

if (alreadyFrozen) {
  console.log("import already frozen; skipping write txs, verifying on-chain state");
} else {
  for (const batch of chunk(records, batchSize)) {
    await send("importUsers", [
      batch.map((r) => r.wallet),
      batch.map((r) => codeToBytes32(r.inviteCode)),
    ]);
  }

  const withRef = records.filter((r) => r.referrer);
  for (const batch of chunk(withRef, batchSize)) {
    await send("importReferrers", [
      batch.map((r) => r.wallet),
      batch.map((r) => r.referrer),
    ]);
  }

  const withVol = records.filter((r) => r.selfWei !== "0" || r.teamWei !== "0");
  for (const batch of chunk(withVol, batchSize)) {
    await send("importVolumes", [
      batch.map((r) => r.wallet),
      batch.map((r) => BigInt(r.selfWei)),
      batch.map((r) => BigInt(r.teamWei)),
    ]);
  }

  if (process.argv.includes("--freeze")) {
    await send("freezeImport", []);
  }
}

const sample = records.slice(0, Math.min(5, records.length));
for (const r of sample) {
  const acc = unpackAccount(
    await publicClient.readContract({
      address: ido,
      abi,
      functionName: "getAccount",
      args: [r.wallet],
    }),
  );
  console.log("verify", r.wallet, {
    registered: acc.registered,
    self: acc.selfVolume?.toString?.() ?? String(acc.selfVolume),
    team: acc.teamVolume?.toString?.() ?? String(acc.teamVolume),
    referrer: acc.referrer,
  });
}

console.log("import complete");
