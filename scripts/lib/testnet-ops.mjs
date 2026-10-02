import { getAddress } from "viem";

export const TESTNET_CHAIN_ID = 97;
const PRODUCTION_DB_HOST = "ep-autumn-cake";

const PREVIEW_SOURCES = [
  ["NEXT_PUBLIC_CHAIN_NETWORK", () => "testnet"],
  ["NEXT_PUBLIC_NEMO_NETWORK", () => "bscTestnet"],
  ["NEXT_PUBLIC_BSC_TESTNET_USDT", (env) => getAddress(required(env, "BSC_TESTNET_USDT"))],
  ["NEXT_PUBLIC_BSC_TESTNET_IDO", (env) => getAddress(required(env, "BSC_TESTNET_IDO"))],
  ["NEXT_PUBLIC_BSC_TESTNET_REWARDS", (env) => getAddress(required(env, "BSC_TESTNET_REWARDS"))],
  ["NEXT_PUBLIC_BSC_TESTNET_INTEREST", (env) => getAddress(required(env, "BSC_TESTNET_INTEREST"))],
  ["NEXT_PUBLIC_BSC_TESTNET_NFT", (env) => getAddress(required(env, "BSC_TESTNET_NFT"))],
  ["INDEX_START_BLOCK", (env) => startBlock(env)],
  ["NEMO_RPC_URL", (env) => rpcUrl(env)],
];

function required(env, key) {
  const value = (env[key] || "").trim();
  if (!value) throw new Error(`缺少 ${key}`);
  return value;
}

function startBlock(env) {
  const value = (env.INDEX_START_BLOCK || env.START_BLOCK || "").trim();
  if (!/^[1-9]\d*$/.test(value)) throw new Error("INDEX_START_BLOCK 必须是大于 0 的整数");
  return value;
}

function rpcUrl(env) {
  const value = required(env, "BSC_TESTNET_RPC");
  if (!value.startsWith("https://")) throw new Error("BSC_TESTNET_RPC 必须是 https 地址");
  return value;
}

export function databaseHost(databaseUrl) {
  return new URL(databaseUrl.replace(/^postgresql:/, "http:")).hostname;
}

/** Refuse production and any chain other than BSC testnet. */
export function assertSafeReset({ databaseUrl, chainId, idoAddress }) {
  if (!databaseUrl) throw new Error("缺少 DATABASE_URL");
  if (Number(chainId) !== TESTNET_CHAIN_ID) {
    throw new Error(`只允许重置 BSC 测试网 chain id ${TESTNET_CHAIN_ID}`);
  }
  const host = databaseHost(databaseUrl);
  if (host.includes(PRODUCTION_DB_HOST)) throw new Error("这是正式库，已拒绝重置");
  const ido = getAddress(idoAddress);
  return { host, ido, chainId: TESTNET_CHAIN_ID };
}

/** Preview-only public contract settings. Secrets stay out of this list. */
export function previewEnvUpdates(env) {
  const updates = {};
  for (const [name, read] of PREVIEW_SOURCES) updates[name] = read(env);
  return updates;
}
