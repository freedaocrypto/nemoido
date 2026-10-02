import { test } from "node:test";
import assert from "node:assert/strict";
import { applyLog, accountRows, emptyIndexState, formatDuration, formatIndexProgress, planChunk } from "./reward-index.mjs";

const A = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const B = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const UNIT = 10n ** 18n;

test("imported self does not pay team until a later deposit", () => {
  const state = emptyIndexState();
  applyLog(state, { eventName: "UserImported", args: { account: A } });
  applyLog(state, { eventName: "UserImported", args: { account: B } });
  applyLog(state, { eventName: "ReferrerImported", args: { account: B, referrer: A } });
  applyLog(state, { eventName: "VolumeImported", args: { account: A, selfVolume: 10_000n * UNIT } });
  const before = accountRows(state).find((r) => r.wallet === A);
  assert.equal(before.teamRewardWei, 0n);
  assert.equal(before.selfWei, 10_000n * UNIT);

  applyLog(state, { eventName: "Contributed", args: { account: B, amount: 1_000n * UNIT } });
  const after = Object.fromEntries(accountRows(state).map((r) => [r.wallet, r]));
  assert.equal(after[A].teamRewardWei, 70n * UNIT);
  assert.equal(after[A].directWei, 100n * UNIT);
  assert.equal(after[A].teamWei, 1_000n * UNIT);
});

test("planChunk starts at START_BLOCK and stops at the safe head", () => {
  assert.deepEqual(planChunk({ lastBlock: null, startBlock: 100n, safeHead: 250n, chunkBlocks: 2000n }), {
    from: 100n,
    end: 250n,
  });
  assert.deepEqual(planChunk({ lastBlock: 100n, startBlock: 100n, safeHead: 5000n, chunkBlocks: 2000n }), {
    from: 101n,
    end: 2100n,
  });
  assert.equal(planChunk({ lastBlock: 5000n, startBlock: 0n, safeHead: 5000n, chunkBlocks: 2000n }), null);
});

test("progress line reports percent and remaining time from blocks already scanned", () => {
  assert.equal(formatDuration(0), "0秒");
  assert.equal(formatDuration(59_600), "1分0秒");
  assert.equal(formatDuration(3_661_000), "1小时1分1秒");
  const line = formatIndexProgress({
    origin: 100n,
    safeHead: 5099n,
    doneBlock: 2099n,
    chunkLogs: 2,
    totalLogs: 5,
    startedAt: 1_000,
    now: 9_000,
  });
  assert.match(line, /进度 2099\/5099 40\.0%/);
  assert.match(line, /本段 2 条  累计 5 条/);
  assert.match(line, /已用 8秒  预计剩余 12秒/);
  const pending = formatIndexProgress({
    origin: 100n,
    safeHead: 200n,
    doneBlock: 100n,
    chunkLogs: 0,
    totalLogs: 0,
    startedAt: 1_000,
    now: 1_000,
  });
  assert.match(pending, /预计剩余 计算中/);
});

test("claim records the cumulative already withdrawn", () => {
  const state = emptyIndexState();
  applyLog(state, { eventName: "Registered", args: { account: A, referrer: null } });
  applyLog(state, {
    eventName: "TeamClaimed",
    args: { account: A, cumulative: 30n * UNIT, paid: 30n * UNIT },
  });
  assert.equal(accountRows(state)[0].claimedWei, 30n * UNIT);
});
