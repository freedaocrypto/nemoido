import { getAddress } from "viem";
import { bind, contribute, createState, seedSelf } from "./team-reward.mjs";

function addr(value) {
  if (!value || value === "0x0000000000000000000000000000000000000000") return null;
  return getAddress(value);
}

function key(account) {
  return getAddress(account);
}

/**
 * Replay one decoded vault/rewards log into calculator state.
 * Import volumes are stored as self only. Team rewards start on later deposits.
 * `claimed` is filled from TeamClaimed and is not part of the calculator.
 */
export function applyLog(state, log) {
  const name = log.eventName;
  if (name === "Registered" || name === "UserImported") {
    const account = key(log.args.account);
    if (!state.referrer.has(account)) bind(state, account, null);
    const referrer = name === "Registered" ? addr(log.args.referrer) : null;
    if (referrer) bind(state, account, referrer);
    return;
  }
  if (name === "ReferrerBound" || name === "ReferrerImported") {
    bind(state, key(log.args.account), addr(log.args.referrer));
    return;
  }
  if (name === "VolumeImported") {
    const account = key(log.args.account);
    if (!state.referrer.has(account)) bind(state, account, null);
    seedSelf(state, account, log.args.selfVolume);
    return;
  }
  if (name === "Contributed") {
    const account = key(log.args.account);
    if (!state.referrer.has(account)) bind(state, account, null);
    contribute(state, account, BigInt(log.args.amount));
    return;
  }
  if (name === "TeamClaimed") {
    const account = key(log.args.account);
    const cumulative = BigInt(log.args.cumulative);
    const prev = state.claimed.get(account) ?? 0n;
    if (cumulative > prev) state.claimed.set(account, cumulative);
  }
}

export function emptyIndexState() {
  const state = createState();
  state.claimed = new Map();
  return state;
}

export function accountRows(state) {
  const wallets = new Set([
    ...state.self.keys(),
    ...state.team.keys(),
    ...state.referrer.keys(),
    ...state.teamRewards.keys(),
    ...state.direct.keys(),
    ...state.claimed.keys(),
  ]);
  return [...wallets].map((wallet) => ({
    wallet,
    referrer: state.referrer.get(wallet) || null,
    selfWei: state.self.get(wallet) ?? 0n,
    teamWei: state.team.get(wallet) ?? 0n,
    teamRewardWei: state.teamRewards.get(wallet) ?? 0n,
    directWei: state.direct.get(wallet) ?? 0n,
    claimedWei: state.claimed.get(wallet) ?? 0n,
  }));
}

export function sortLogs(logs) {
  return logs.slice().sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
}

/** Next inclusive block range. `lastBlock === null` means no checkpoint yet, so start at `startBlock`. */
export function planChunk({ lastBlock, startBlock, safeHead, chunkBlocks }) {
  const from = lastBlock == null ? startBlock : lastBlock + 1n;
  if (from > safeHead) return null;
  const size = chunkBlocks < 1n ? 1n : chunkBlocks;
  const end = from + size - 1n > safeHead ? safeHead : from + size - 1n;
  return { from, end };
}

/** Whole seconds, for progress lines. */
export function formatDuration(ms) {
  const total = Math.max(0, Math.round(Number(ms) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  if (hours > 0) return `${hours}小时${minutes}分${seconds}秒`;
  if (minutes > 0) return `${minutes}分${seconds}秒`;
  return `${seconds}秒`;
}

/**
 * One progress line after a chunk is saved.
 * ETA uses blocks finished in this run divided by wall time, so it includes RPC and database writes.
 */
export function formatIndexProgress({ origin, safeHead, doneBlock, chunkLogs, totalLogs, startedAt, now }) {
  const span = safeHead >= origin ? safeHead - origin + 1n : 0n;
  const rawDone = doneBlock >= origin ? doneBlock - origin + 1n : 0n;
  const done = rawDone > span ? span : rawDone;
  const percent = span === 0n ? 100 : Number((done * 1000n) / span) / 10;
  const elapsed = Math.max(0, now - startedAt);
  const left = safeHead > doneBlock ? safeHead - doneBlock : 0n;
  let eta = "计算中";
  if (left === 0n) eta = "0秒";
  else if (elapsed > 0 && done > 0n) eta = formatDuration((elapsed * Number(left)) / Number(done));
  return `进度 ${doneBlock}/${safeHead} ${percent.toFixed(1)}%  本段 ${chunkLogs} 条  累计 ${totalLogs} 条  已用 ${formatDuration(elapsed)}  预计剩余 ${eta}`;
}
