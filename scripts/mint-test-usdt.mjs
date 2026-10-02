#!/usr/bin/env node
/**
 * 给 Sensitive 目录里的测试钱包铸造 MockUSDT。默认只打印。
 * 铸造交易由 .env 里的 TEST_PRIVATE_KEY 付 gas。MockUSDT.mint 是公开函数。
 *
 *   set -a && source .env && set +a
 *   node scripts/mint-test-usdt.mjs
 *   node scripts/mint-test-usdt.mjs --apply
 */
import { readFile } from "node:fs/promises";
import { createPublicClient, createWalletClient, getAddress, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const walletsFile = process.env.WALLETS_FILE || "/Users/jack/Documents/Sensitive/nemo-bsc-testnet-wallets.json";
const amount = BigInt(process.env.MINT_USDT || "100000") * 10n ** 18n;
const apply = process.argv.includes("--apply");

const need = ["BSC_TESTNET_RPC", "BSC_TESTNET_USDT", "TEST_PRIVATE_KEY"].filter((name) => !process.env[name]);
if (need.length) {
  console.log(`未铸造：缺少 ${need.join(", ")}。先 source .env。`);
  process.exit(0);
}

const doc = JSON.parse(await readFile(walletsFile, "utf8"));
const wallets = doc.wallets.map((row) => getAddress(row.address));
console.log(JSON.stringify({ wallets: wallets.length, each: amount.toString(), apply, usdt: process.env.BSC_TESTNET_USDT }));
if (!apply) {
  console.log("dry-run。确认后加 --apply 才会铸造。");
  process.exit(0);
}

const chain = {
  id: 97,
  name: "bsc-testnet",
  nativeCurrency: { name: "tBNB", symbol: "tBNB", decimals: 18 },
  rpcUrls: { default: { http: [process.env.BSC_TESTNET_RPC] } },
};
const account = privateKeyToAccount(process.env.TEST_PRIVATE_KEY);
const transport = http(process.env.BSC_TESTNET_RPC);
const publicClient = createPublicClient({ chain, transport });
const wallet = createWalletClient({ account, chain, transport });
const usdt = getAddress(process.env.BSC_TESTNET_USDT);
const abi = parseAbi(["function mint(address to, uint256 amount)"]);

for (const to of wallets) {
  const hash = await wallet.writeContract({ address: usdt, abi, functionName: "mint", args: [to, amount] });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`mint failed ${to} ${hash}`);
  console.log(`${to} ${hash}`);
}
console.log(`完成：${wallets.length} 个地址各 ${process.env.MINT_USDT || "100000"} USDT。`);
