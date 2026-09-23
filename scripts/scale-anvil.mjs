#!/usr/bin/env node
/**
 * Hundreds of real deposits against a deployed vault.
 *
 * Local (chain 31337), after `bash scripts/local-up.sh`:
 *   node scripts/scale-anvil.mjs
 *
 * BSC testnet, after a funded deploy (this file does not invent a broadcast):
 *   RPC_URL=$BSC_TESTNET_RPC PRIVATE_KEY=0x... CHAIN_ID=97 \
 *     IDO_ADDRESS=0x... USDT_ADDRESS=0x... REWARDS_ADDRESS=0x... \
 *     node scripts/scale-anvil.mjs
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  toBytes,
  getAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bind, contribute, createState } from "./lib/team-reward.mjs";
import { buildMerkle, leafHash } from "./lib/merkle.mjs";
import { codeToBytes32 } from "./lib/tree.mjs";

const UNIT = 10n ** 18n;
const N = 300;
const ANVIL_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

const idoAbi = parseAbi([
  "function register(bytes32 code, bytes32 referrerCode)",
  "function contribute(uint256 amount)",
  "function getAccount(address) view returns ((address referrer, bytes32 inviteCode, uint256 selfVolume, uint256 directRewards, uint256 claimed, bool registered))",
  "function totalContributed() view returns (uint256)",
  "function totalDirectAccrued() view returns (uint256)",
  "function saleOpen() view returns (bool)",
  "function rewards() view returns (address)",
]);
const usdtAbi = parseAbi([
  "function mint(address to, uint256 amount)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const rewardsAbi = parseAbi([
  "function submitRoot(bytes32 root, bytes32 contentHash, uint256 cumulative)",
  "function activateRoot()",
  "function claim(uint256 cumulative, bytes32[] proof)",
  "function claimAdvance(uint256 cumulative, uint256 deadline, bytes signature)",
  "function claimed(address) view returns (uint256)",
  "function advancePerAccountCap() view returns (uint256)",
  "function rootTimelock() view returns (uint256)",
  "function outstanding() view returns (uint256)",
]);

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

function actorKey(i) {
  return keccak256(toBytes(`nemo-scale:${i}`));
}

function codeOf(i) {
  return i === 0 ? "ROOTANVL" : `N${1_000_000 + i}`;
}

function loadBroadcast(chainId) {
  const path = resolve(`broadcast/DeployLocal.s.sol/${chainId}/run-latest.json`);
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
  const found = {};
  for (const tx of data.transactions || []) {
    if (tx.contractName && tx.contractAddress) found[tx.contractName] = getAddress(tx.contractAddress);
  }
  return found;
}

function clientFor(account, chain, transport) {
  return createWalletClient({ account, chain, transport });
}

async function send(wallet, publicClient, abi, address, functionName, args) {
  const hash = await wallet.writeContract({ address, abi, functionName, args });
  const receipt = await publicClient.waitForTransactionReceipt({ hash, pollingInterval: 50 });
  if (receipt.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  return receipt;
}

const rpc = process.env.RPC_URL || arg("--rpc", "http://127.0.0.1:8545");
const transport = http(rpc);
const probe = createPublicClient({ transport });
const chainId = Number(process.env.CHAIN_ID || (await probe.getChainId()));
const chain = {
  id: chainId,
  name: chainId === 97 ? "bscTestnet" : "local",
  nativeCurrency: { name: "ETH", symbol: chainId === 97 ? "tBNB" : "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
};
const publicClient = createPublicClient({ chain, transport, pollingInterval: 50 });
const broadcast = loadBroadcast(chainId);
function pickAddress(envName, fallback) {
  const value = process.env[envName] || fallback || "";
  return value ? getAddress(value) : "";
}
const ido = pickAddress("IDO_ADDRESS", broadcast.NemoIdo);
const usdt = pickAddress("USDT_ADDRESS", broadcast.MockUSDT);
const rewardsAddr = pickAddress("REWARDS_ADDRESS", broadcast.NemoRewards);
const ownerPk = process.env.PRIVATE_KEY || ANVIL_KEY;
const owner = privateKeyToAccount(ownerPk.startsWith("0x") ? ownerPk : `0x${ownerPk}`);
const ownerWallet = clientFor(owner, chain, transport);

if (!ido || !usdt || !rewardsAddr) {
  console.error("Missing IDO_ADDRESS / USDT_ADDRESS / REWARDS_ADDRESS and no local broadcast file.");
  process.exit(1);
}

const saleOpen = await publicClient.readContract({ address: ido, abi: idoAbi, functionName: "saleOpen" });
if (!saleOpen) {
  console.error("Sale is closed. Run scripts/local-up.sh (or seed) before this script.");
  process.exit(1);
}

const rootAcc = await publicClient.readContract({
  address: ido,
  abi: idoAbi,
  functionName: "getAccount",
  args: [owner.address],
});
if (!rootAcc.registered) {
  console.error("Deployer is not registered. Seed ROOTANVL first.");
  process.exit(1);
}

console.log(`chain ${chainId} ido ${ido} rewards ${rewardsAddr} root ${owner.address}`);

const actors = [];
for (let i = 1; i < N; i++) {
  const account = privateKeyToAccount(actorKey(i));
  actors.push({ i, account, wallet: clientFor(account, chain, transport) });
}

async function fund(address) {
  if (chainId === 31337) {
    await publicClient.request({
      method: "anvil_setBalance",
      params: [address, "0x3635C9ADC5DEA00000"],
    });
    return;
  }
  const hash = await ownerWallet.sendTransaction({ to: address, value: 2n * 10n ** 16n });
  const receipt = await publicClient.waitForTransactionReceipt({ hash, pollingInterval: 50 });
  if (receipt.status !== "success") throw new Error(`fund failed ${address}`);
}

const state = createState();
bind(state, owner.address, null);
const deposits = [];

async function registerActor(actor, parentIndex) {
  await fund(actor.account.address);
  await send(actor.wallet, publicClient, usdtAbi, usdt, "mint", [actor.account.address, 200_000n * UNIT]);
  await send(actor.wallet, publicClient, usdtAbi, usdt, "approve", [ido, 2n ** 256n - 1n]);
  await send(actor.wallet, publicClient, idoAbi, ido, "register", [
    codeToBytes32(codeOf(actor.i)),
    codeToBytes32(codeOf(parentIndex)),
  ]);
  const parent = parentIndex === 0 ? owner.address : actors[parentIndex - 1].account.address;
  bind(state, actor.account.address, parent);
}

console.log(`registering ${N - 1} accounts`);
for (const actor of actors) {
  if (actor.i <= 20) await registerActor(actor, 0);
  else if (actor.i < 60) await registerActor(actor, actor.i - 1);
  else await registerActor(actor, 1 + (actor.i % 20));
  if (actor.i % 50 === 0) console.log(`  registered ${actor.i}`);
}

async function pay(who, wallet, amount) {
  const receipt = await send(wallet, publicClient, idoAbi, ido, "contribute", [amount]);
  contribute(state, who, amount);
  deposits.push({ who, amount, gas: receipt.gasUsed });
  return receipt.gasUsed;
}

await fund(owner.address);
await send(ownerWallet, publicClient, usdtAbi, usdt, "mint", [owner.address, 200_000n * UNIT]);
await send(ownerWallet, publicClient, usdtAbi, usdt, "approve", [ido, 2n ** 256n - 1n]);

const a21 = actors[20];
const a2 = actors[1];
const a59 = actors[58];
const a3 = actors[2];
await pay(a21.account.address, a21.wallet, 500n * UNIT);
const shallowGas = await pay(a2.account.address, a2.wallet, 1000n * UNIT);
const deepGas = await pay(a59.account.address, a59.wallet, 1000n * UNIT);
const gap = shallowGas > deepGas ? shallowGas - deepGas : deepGas - shallowGas;
console.log(`contribute gas shallow=${shallowGas} deep=${deepGas} gap=${gap}`);
if (gap >= 80_000n) {
  console.error("deep and shallow contribute gas diverged");
  process.exit(1);
}

await pay(a3.account.address, a3.wallet, 50n * UNIT);
const rootAfter = await publicClient.readContract({
  address: ido,
  abi: idoAbi,
  functionName: "getAccount",
  args: [owner.address],
});
if (rootAfter.directRewards !== 100n * UNIT) {
  console.error(`root direct ${rootAfter.directRewards} != 100 USDT`);
  process.exit(1);
}

const sized = [
  [actors[3], 500n * UNIT],
  [actors[4], 2_000n * UNIT],
  [actors[5], 10_000n * UNIT],
  [actors[6], 30_000n * UNIT],
];
for (const [actor, amount] of sized) {
  await pay(actor.account.address, actor.wallet, amount);
}
await pay(owner.address, ownerWallet, 60_000n * UNIT);

for (const actor of actors) {
  if (actor.i === 59 || actor.i === 2 || actor.i === 21 || actor.i < 8) continue;
  const amount = 100n * UNIT + BigInt(actor.i % 5) * 100n * UNIT;
  await pay(actor.account.address, actor.wallet, amount);
}

const deepAccount = await publicClient.readContract({
  address: ido,
  abi: idoAbi,
  functionName: "getAccount",
  args: [a59.account.address],
});
const parent58 = await publicClient.readContract({
  address: ido,
  abi: idoAbi,
  functionName: "getAccount",
  args: [actors[57].account.address],
});
const total = await publicClient.readContract({ address: ido, abi: idoAbi, functionName: "totalContributed" });
if (deepAccount.selfVolume !== 1000n * UNIT) throw new Error("actor 59 self volume");
if (parent58.directRewards !== 100n * UNIT) throw new Error("actor 58 direct");
if (total <= 300n * 100n * UNIT) throw new Error("total contributed too small");

const entries = [];
for (const [account, cumulative] of state.teamRewards) {
  if (cumulative > 0n) entries.push({ account, cumulative });
}
entries.sort((a, b) => a.account.toLowerCase().localeCompare(b.account.toLowerCase()));
if (entries.length === 0) throw new Error("calculator produced no team rewards");

const tree = buildMerkle(entries);
const teamSum = entries.reduce((s, e) => s + e.cumulative, 0n);
const direct = await publicClient.readContract({
  address: ido,
  abi: idoAbi,
  functionName: "totalDirectAccrued",
});
const cap = (total * 2500n) / 10_000n;
if (direct + teamSum > cap) {
  throw new Error(`team ${teamSum} + direct ${direct} exceeds cap ${cap}`);
}

const contentHash = keccak256(toBytes(JSON.stringify(entries.map((e) => [e.account, e.cumulative.toString()]))));

const capPer = await publicClient.readContract({
  address: rewardsAddr,
  abi: rewardsAbi,
  functionName: "advancePerAccountCap",
});
const advanceEntry = entries.find(
  (e) => e.cumulative <= capPer && e.account.toLowerCase() !== owner.address.toLowerCase(),
);
const claimEntry = entries.find((e) => e !== advanceEntry);

async function proofFor(entry) {
  const leaf = leafHash(entry.account, entry.cumulative);
  const proof = tree.proofs.get(leaf);
  if (!proof) throw new Error(`missing proof for ${entry.account}`);
  return proof;
}

if (advanceEntry) {
  const user = actors.find((a) => a.account.address.toLowerCase() === advanceEntry.account.toLowerCase());
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const signature = await owner.signTypedData({
    domain: { name: "NemoRewards", version: "1", chainId, verifyingContract: rewardsAddr },
    types: {
      Advance: [
        { name: "account", type: "address" },
        { name: "cumulative", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Advance",
    message: { account: advanceEntry.account, cumulative: advanceEntry.cumulative, nonce: 0n, deadline },
  });
  const before = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [advanceEntry.account],
  });
  await send(user.wallet, publicClient, rewardsAbi, rewardsAddr, "claimAdvance", [
    advanceEntry.cumulative,
    deadline,
    signature,
  ]);
  const mid = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [advanceEntry.account],
  });
  if (mid - before !== advanceEntry.cumulative) {
    throw new Error(`advance paid ${mid - before}, expected ${advanceEntry.cumulative}`);
  }
  console.log(`advance paid ${advanceEntry.cumulative} to ${advanceEntry.account}`);
}

await send(ownerWallet, publicClient, rewardsAbi, rewardsAddr, "submitRoot", [tree.root, contentHash, teamSum]);

const timelock = await publicClient.readContract({
  address: rewardsAddr,
  abi: rewardsAbi,
  functionName: "rootTimelock",
});
if (chainId !== 31337) {
  console.log(`root submitted. timelock is ${timelock}s; not waiting on a public network.`);
  console.log("deposits ok; activateRoot + merkle claim were not sent.");
  process.exit(0);
}
await publicClient.request({ method: "evm_increaseTime", params: [Number(timelock)] });
await publicClient.request({ method: "evm_mine", params: [] });
await send(ownerWallet, publicClient, rewardsAbi, rewardsAddr, "activateRoot", []);

if (advanceEntry) {
  const user = actors.find((a) => a.account.address.toLowerCase() === advanceEntry.account.toLowerCase());
  const beforeClaim = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [advanceEntry.account],
  });
  await send(user.wallet, publicClient, rewardsAbi, rewardsAddr, "claim", [
    advanceEntry.cumulative,
    await proofFor(advanceEntry),
  ]);
  const after = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [advanceEntry.account],
  });
  if (after !== beforeClaim) throw new Error("merkle claim double-paid an advance");
  console.log(`claim after advance paid 0 more for ${advanceEntry.account}`);
}

if (claimEntry) {
  const user = actors.find((a) => a.account.address.toLowerCase() === claimEntry.account.toLowerCase());
  const wallet = user ? user.wallet : ownerWallet;
  const before = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [claimEntry.account],
  });
  await send(wallet, publicClient, rewardsAbi, rewardsAddr, "claim", [claimEntry.cumulative, await proofFor(claimEntry)]);
  const after = await publicClient.readContract({
    address: usdt,
    abi: usdtAbi,
    functionName: "balanceOf",
    args: [claimEntry.account],
  });
  if (after - before !== claimEntry.cumulative) {
    throw new Error(`claim paid ${after - before}, expected ${claimEntry.cumulative}`);
  }
  console.log(`merkle claim ok for ${claimEntry.account} (${claimEntry.cumulative})`);
}

const outstanding = await publicClient.readContract({
  address: rewardsAddr,
  abi: rewardsAbi,
  functionName: "outstanding",
});
console.log(
  JSON.stringify({
    accounts: N,
    deposits: deposits.length,
    teamAccounts: entries.length,
    teamSum: teamSum.toString(),
    outstanding: outstanding.toString(),
    shallowGas: shallowGas.toString(),
    deepGas: deepGas.toString(),
  }),
);
