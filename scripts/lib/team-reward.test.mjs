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
