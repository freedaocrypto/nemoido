#!/usr/bin/env node
/**
 * 实时把网体业绩写入 Postgres，不写进合约。
 * 1. 保持主合约金库目前的简单设计。
 * 2. 直推的奖励在合约上面用户可以直接提现。
 * 3. 网体的奖励由管理员每过 24 小时统一计算，手动或自动跑脚本发放一次并更新 root。
 *    网体业绩不做实时提现，但要实时计算并写入数据库，不写进合约。只有用户提现时才更新到合约。
 *
 *   DATABASE_URL=postgres://... IDO_ADDRESS=0x... RPC_URL=... \
 *     node scripts/index-rewards.mjs
 *   ... node scripts/index-rewards.mjs --follow
 */
import { createPublicClient, http, parseAbiItem, getAddress } from "viem";
import { accountRows, applyLog, formatIndexProgress, planChunk, sortLogs } from "./lib/reward-index.mjs";
import {
  ensureSchema,
  loadAccounts,
  loadCheckpoint,
  lockName,
  saveIndex,
  stateFromRows,
  tryLock,
  unlock,
} from "./lib/reward-db.mjs";

const IDO_EVENTS = [
  parseAbiItem("event Registered(address indexed account, bytes32 indexed code, address indexed referrer)"),
  parseAbiItem("event ReferrerBound(address indexed account, address indexed referrer)"),
  parseAbiItem("event UserImported(address indexed account, bytes32 indexed code)"),
  parseAbiItem("event ReferrerImported(address indexed account, address indexed referrer)"),
  parseAbiItem("event VolumeImported(address indexed account, uint256 selfVolume)"),
  parseAbiItem("event Contributed(address indexed account, uint256 amount, uint256 selfVolume, uint256 nemoAmount)"),
];
const REWARD_EVENTS = [
  parseAbiItem("event TeamClaimed(address indexed account, uint256 cumulative, uint256 paid)"),
];

function missingEnv() {
  const need = ["DATABASE_URL", "IDO_ADDRESS", "RPC_URL"].filter((name) => !process.env[name]);
  if (need.length === 0) return null;
  console.log(`索引未运行：缺少 ${need.join(", ")}。`);
  console.log("设置后再执行：node scripts/index-rewards.mjs");
  return need;
}

async function connect() {
  const { default: pg } = await import("pg");
  const client = new pg.Client({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.PGSSL === "disable" ? false : { rejectUnauthorized: false },
  });
  await client.connect();
  return client;
}

async function pullLogs(publicClient, address, events, fromBlock, toBlock) {
  const out = [];
  for (const event of events) {
    const logs = await publicClient.getLogs({ address, event, fromBlock, toBlock });
    for (const log of logs) {
      out.push({
        eventName: log.eventName,
        args: log.args,
        blockNumber: Number(log.blockNumber),
        logIndex: log.logIndex,
      });
    }
  }
  return out;
}

async function indexOnce(client, publicClient) {
  const chainId = await publicClient.getChainId();
  const ido = getAddress(process.env.IDO_ADDRESS);
  const rewards = process.env.REWARDS_ADDRESS ? getAddress(process.env.REWARDS_ADDRESS) : null;
  const confirmations = Number(process.env.CONFIRMATIONS ?? (chainId === 31337 ? 0 : 15));
  const head = await publicClient.getBlockNumber();
  const safeHead = head - BigInt(confirmations);
  if (safeHead < 0n) return { indexed: 0, lastBlock: 0 };

  const name = lockName(chainId, ido);
  if (!(await tryLock(client, name))) {
    console.log(`chain ${chainId} 已有索引或发布进程在跑，本次跳过。`);
    return { indexed: 0, lastBlock: 0 };
  }
  try {
    await ensureSchema(client);
    const checkpoint = await loadCheckpoint(client, chainId, ido);
    const startBlock = BigInt(process.env.START_BLOCK ?? 0);
    const chunkBlocks = BigInt(process.env.CHUNK_BLOCKS ?? 2000);
    let last = checkpoint ? BigInt(checkpoint.last_block) : null;
    if (!planChunk({ lastBlock: last, startBlock, safeHead, chunkBlocks })) {
      console.log(`chain ${chainId} caught up at block ${checkpoint?.last_block ?? startBlock}`);
      return { indexed: 0, lastBlock: Number(checkpoint?.last_block ?? startBlock) };
    }

    const stored = await loadAccounts(client, chainId, ido);
    const state = stateFromRows(stored);
    const origin = planChunk({ lastBlock: last, startBlock, safeHead, chunkBlocks }).from;
    const startedAt = Date.now();
    console.log(
      `chain ${chainId} 从区块 ${origin} 扫到 ${safeHead}，共 ${safeHead - origin + 1n} 个区块，每段 ${chunkBlocks}`,
    );
    let count = 0;
    for (;;) {
      const range = planChunk({ lastBlock: last, startBlock, safeHead, chunkBlocks });
      if (!range) break;
      console.log(`扫描 ${range.from}-${range.end}`);
      const logs = sortLogs([
        ...(await pullLogs(publicClient, ido, IDO_EVENTS, range.from, range.end)),
        ...(rewards ? await pullLogs(publicClient, rewards, REWARD_EVENTS, range.from, range.end) : []),
      ]);
      for (const log of logs) applyLog(state, log);
      count += logs.length;
      last = range.end;
      await saveIndex(client, {
        chainId,
        idoAddress: ido,
        rewardsAddress: rewards,
        lastBlock: Number(last),
        rows: accountRows(state),
      });
      console.log(
        formatIndexProgress({
          origin,
          safeHead,
          doneBlock: last,
          chunkLogs: logs.length,
          totalLogs: count,
          startedAt,
          now: Date.now(),
        }),
      );
    }
    console.log(`chain ${chainId} indexed ${count} logs through block ${last}`);
    return { indexed: count, lastBlock: Number(last) };
  } finally {
    await unlock(client, name);
  }
}

const absent = missingEnv();
if (absent) process.exit(0);

const follow = process.argv.includes("--follow");
const intervalMs = Number(process.env.INTERVAL_MS || 15_000);
const publicClient = createPublicClient({ transport: http(process.env.RPC_URL) });
const client = await connect();
try {
  do {
    await indexOnce(client, publicClient);
    if (follow) await new Promise((resolve) => setTimeout(resolve, intervalMs));
  } while (follow);
} finally {
  await client.end();
}
