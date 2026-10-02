/** Classic differential + 60k overlay. Mirrors the former on-chain NemoTeamReward. */

export const UNIT = 10n ** 18n;
export const BPS = 10_000n;
export const OVERLAY_BPS = 1_000n;
export const TOP_BPS = 1_000n;
export const DIRECT_BPS = 1_000n;
export const MIN_REFERRAL = 100n * UNIT;

export const TIERS = [
  [500n * UNIT, 300n],
  [2_000n * UNIT, 500n],
  [10_000n * UNIT, 700n],
  [30_000n * UNIT, 900n],
  [60_000n * UNIT, 1_000n],
];

export function bpsForQual(qual) {
  let rate = 0n;
  for (const [vol, bps] of TIERS) {
    if (qual >= vol) rate = bps;
  }
  return rate;
}

export function createState() {
  return {
    self: new Map(),
    team: new Map(),
    referrer: new Map(),
    teamRewards: new Map(),
    direct: new Map(),
  };
}

function get(map, key) {
  return map.get(key) ?? 0n;
}

export function bind(state, account, referrer) {
  state.referrer.set(account, referrer || null);
}

/** Historical self volume. Does not pay direct or team rewards and does not bump uplines. */
export function seedSelf(state, account, amount) {
  state.self.set(account, BigInt(amount));
}

/**
 * Apply one deposit. Qualification is read before this deposit is added to upline volume.
 * The depositor's own tier does not compress upline (prevBps starts at 0).
 */
export function contribute(state, account, amount, opts = {}) {
  const directBps = opts.directBps ?? DIRECT_BPS;
  const minReferral = opts.minReferral ?? MIN_REFERRAL;
  state.self.set(account, get(state.self, account) + amount);

  const ref = state.referrer.get(account) || null;
  let directPaid = 0n;
  if (ref && amount >= minReferral) {
    directPaid = (amount * directBps) / BPS;
    if (directPaid > 0n) state.direct.set(ref, get(state.direct, ref) + directPaid);
  }

  let prev = 0n;
  let cursor = ref;
  let dNode = null;
  let dTeam = 0n;
  let overlayAncestor = null;
  const deltas = [];

  while (cursor) {
    const qual = get(state.self, cursor) + get(state.team, cursor);
    const rate = bpsForQual(qual);
    let reward = 0n;
    if (rate > prev) {
      reward = (amount * (rate - prev)) / BPS;
      if (reward > 0n) {
        state.teamRewards.set(cursor, get(state.teamRewards, cursor) + reward);
        deltas.push({ account: cursor, amount: reward, kind: "diff" });
      }
      prev = rate;
    }
    if (rate === TOP_BPS) {
      if (!dNode) {
        dNode = cursor;
        dTeam = reward;
      } else if (!overlayAncestor) {
        overlayAncestor = cursor;
      }
    }
    state.team.set(cursor, get(state.team, cursor) + amount);
    cursor = state.referrer.get(cursor) || null;
  }

  let overlay = 0n;
  if (overlayAncestor && dTeam > 0n) {
    overlay = (dTeam * OVERLAY_BPS) / BPS;
    if (overlay > 0n) {
      state.teamRewards.set(overlayAncestor, get(state.teamRewards, overlayAncestor) + overlay);
      deltas.push({ account: overlayAncestor, amount: overlay, kind: "overlay" });
    }
  }

  return { directTo: ref, directPaid, deltas, overlayTo: overlay > 0n ? overlayAncestor : null, overlay };
}

export function teamOf(state, account) {
  return get(state.teamRewards, account);
}

export function directOf(state, account) {
  return get(state.direct, account);
}
