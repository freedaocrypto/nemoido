import { test } from "node:test";
import assert from "node:assert/strict";
import { applyLog, accountRows, emptyIndexState, planChunk } from "./reward-index.mjs";

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

test("claim records the cumulative already withdrawn", () => {
  const state = emptyIndexState();
  applyLog(state, { eventName: "Registered", args: { account: A, referrer: null } });
  applyLog(state, {
    eventName: "TeamClaimed",
    args: { account: A, cumulative: 30n * UNIT, paid: 30n * UNIT },
  });
  assert.equal(accountRows(state)[0].claimedWei, 30n * UNIT);
});
