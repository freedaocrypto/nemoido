import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  UNIT,
  bpsForQual,
  bind,
  contribute,
  createState,
  directOf,
  teamOf,
} from "./team-reward.mjs";

const golden = JSON.parse(readFileSync(new URL("../fixtures/team-golden.json", import.meta.url), "utf8"));
const u = (n) => BigInt(n) * UNIT;

function assertUnits(actual, expected) {
  for (const [k, v] of Object.entries(expected)) {
    assert.equal(actual(k).toString(), (BigInt(v) * UNIT).toString(), k);
  }
}

test("bps boundaries", () => {
  assert.equal(bpsForQual(u(499)), 0n);
  assert.equal(bpsForQual(u(500)), 300n);
  assert.equal(bpsForQual(u(2000)), 500n);
  assert.equal(bpsForQual(u(10000)), 700n);
  assert.equal(bpsForQual(u(30000)), 900n);
  assert.equal(bpsForQual(u(60000)), 1000n);
});

test("self 10k then direct 1000 pays 10 percent direct and 7 percent team", () => {
  const s = createState();
  bind(s, "bob", null);
  bind(s, "carol", "bob");
  contribute(s, "bob", u(10_000));
  assert.equal(directOf(s, "bob"), 0n);
  assert.equal(teamOf(s, "bob"), 0n);
  assert.equal(bpsForQual(s.self.get("bob") + (s.team.get("bob") ?? 0n)), 700n);

  const tx = contribute(s, "carol", u(1000));
  assert.equal(tx.directTo, "bob");
  assert.equal(tx.directPaid, u(100));
  assert.equal(directOf(s, "bob"), u(100));
  assert.equal(teamOf(s, "bob"), u(70));
});

test("golden self500 then recruit 1000", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  contribute(s, "alice", u(500));
  contribute(s, "bob", u(1000));
  const g = golden.cases[0];
  assertUnits((k) => directOf(s, k), g.direct);
  assertUnits((k) => teamOf(s, k), g.team);
});

test("golden self 30k then recruit 10k", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  contribute(s, "alice", u(30_000));
  contribute(s, "bob", u(10_000));
  const g = golden.cases[1];
  assertUnits((k) => directOf(s, k), g.direct);
  assertUnits((k) => teamOf(s, k), g.team);
});

test("golden ABCD", () => {
  const s = createState();
  for (const [who, ref] of [
    ["alice", null],
    ["bob", "alice"],
    ["carol", "bob"],
    ["dave", "carol"],
  ]) {
    bind(s, who, ref);
  }
  contribute(s, "alice", u(10_000));
  contribute(s, "bob", u(10_000));
  assert.equal(teamOf(s, "alice"), u(700));
  contribute(s, "carol", u(10_000));
  assert.equal(teamOf(s, "bob"), u(700));
  assert.equal(teamOf(s, "alice"), u(700));
  const { self, team } = s;
  const qual = self.get("alice") + team.get("alice");
  assert.equal(bpsForQual(qual), 900n);
  contribute(s, "dave", u(10_000));
  const g = golden.cases[2];
  assertUnits((k) => directOf(s, k), g.direct);
  assertUnits((k) => teamOf(s, k), g.team);
});

test("golden two max-tier overlay is 21 percent", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  bind(s, "carol", "bob");
  contribute(s, "alice", u(60_000));
  contribute(s, "bob", u(60_000));
  const before = teamOf(s, "alice") + directOf(s, "bob") + teamOf(s, "bob");
  const tx = contribute(s, "carol", u(10_000));
  const g = golden.cases[3];
  assertUnits((k) => directOf(s, k), g.direct);
  assertUnits((k) => teamOf(s, k), g.team);
  const spent = tx.directPaid + tx.deltas.reduce((a, d) => a + d.amount, 0n);
  assert.equal(spent, u(g.lastTxTeamPlusDirect));
  assert.equal(teamOf(s, "alice") - u(6000), u(100));
  assert.ok(before >= 0n);
});

test("golden overlay pays nearest max tier", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  bind(s, "carol", "bob");
  bind(s, "dave", "carol");
  contribute(s, "alice", u(60_000));
  contribute(s, "bob", u(60_000));
  contribute(s, "carol", u(60_000));
  const aliceBefore = teamOf(s, "alice");
  const bobBefore = teamOf(s, "bob");
  const carolBefore = teamOf(s, "carol");
  contribute(s, "dave", u(10_000));
  assert.equal(directOf(s, "carol"), u(1000));
  assert.equal(teamOf(s, "carol") - carolBefore, u(1000));
  assert.equal(teamOf(s, "bob") - bobBefore, u(100));
  assert.equal(teamOf(s, "alice") - aliceBefore, 0n);
});

test("qualified referrer earns direct and team on a 50 deposit", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  contribute(s, "alice", u(100));
  const atFloor = contribute(s, "bob", u(50));
  assert.equal(atFloor.directPaid, u(5));
  assert.equal(directOf(s, "alice"), u(5));
  assert.equal(teamOf(s, "alice"), 0n);
  assert.equal(s.team.get("alice"), u(50));

  contribute(s, "alice", u(400));
  const atTier = contribute(s, "bob", u(50));
  assert.equal(atTier.directPaid, u(5));
  assert.equal(teamOf(s, "alice"), (u(50) * 300n) / 10_000n);
});

test("unqualified referrer earns nothing and the gap moves up", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  bind(s, "carol", "bob");
  contribute(s, "alice", u(500));
  contribute(s, "bob", u(50));
  const tx = contribute(s, "carol", u(100));
  assert.equal(tx.directTo, "bob");
  assert.equal(tx.directPaid, 0n);
  assert.equal(directOf(s, "bob"), 0n);
  assert.equal(directOf(s, "alice"), u(5));
  assert.equal(teamOf(s, "bob"), 0n);
  assert.equal(teamOf(s, "alice"), (u(150) * 300n) / 10_000n);
  assert.equal(s.team.get("bob"), u(100));
});

test("crossing 100 does not backfill earlier downline deposits", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  contribute(s, "alice", u(50));
  contribute(s, "bob", u(1_000));
  assert.equal(directOf(s, "alice"), 0n);
  assert.equal(teamOf(s, "alice"), 0n);
  contribute(s, "alice", u(50));
  assert.equal(directOf(s, "alice"), 0n);
  assert.equal(teamOf(s, "alice"), 0n);
  contribute(s, "bob", u(100));
  assert.equal(directOf(s, "alice"), u(10));
  assert.equal(teamOf(s, "alice"), (u(100) * 300n) / 10_000n);
  assert.equal(s.team.get("alice"), u(1_100));
});

test("zero self with a huge downline takes no differential and no overlay", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  bind(s, "carol", "bob");
  bind(s, "dave", "bob");
  contribute(s, "alice", u(60_000));
  contribute(s, "carol", u(60_000));
  assert.equal(teamOf(s, "bob"), 0n);
  assert.equal(s.team.get("bob"), u(60_000));
  const before = teamOf(s, "alice");
  const tx = contribute(s, "dave", u(1_000));
  assert.equal(tx.directPaid, 0n);
  assert.equal(teamOf(s, "bob"), 0n);
  assert.equal(teamOf(s, "alice") - before, u(100));
  assert.equal(tx.overlay, 0n);
});

test("single max tier has no overlay", () => {
  const s = createState();
  bind(s, "alice", null);
  bind(s, "bob", "alice");
  contribute(s, "alice", u(60_000));
  contribute(s, "bob", u(10_000));
  const g = golden.cases[5];
  assertUnits((k) => directOf(s, k), g.direct);
  assertUnits((k) => teamOf(s, k), g.team);
});
