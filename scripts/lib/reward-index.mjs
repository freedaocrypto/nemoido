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
