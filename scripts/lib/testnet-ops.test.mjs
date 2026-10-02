import { test } from "node:test";
import assert from "node:assert/strict";
import { assertSafeReset, previewEnvUpdates } from "./testnet-ops.mjs";

const env = {
  BSC_TESTNET_USDT: "0x328DF52234Bd5EF600dBD8b3F2B1d2ea0b370B49",
  BSC_TESTNET_IDO: "0x8645627C8f7056dFaC1abB1e3ABa9c96222A9Fa5",
  BSC_TESTNET_REWARDS: "0x05C6c8b074b5b94D904b39F1bc4588c492ac9722",
  BSC_TESTNET_INTEREST: "0x2b471fd0F5E0DCedbCb8464a1A0331d27131C6a5",
  BSC_TESTNET_NFT: "0x5DA0f4c09C98Bd55360e1a73C89D4a2Caf7358c6",
  BSC_TESTNET_RPC: "https://bsc-testnet.publicnode.com",
  INDEX_START_BLOCK: "134418772",
  TEST_PRIVATE_KEY: "0xabc",
  DATABASE_URL: "postgresql://user:secret@ep-empty-king.example/neondb",
  CRON_SECRET: "secret",
};

test("reset refuses the production database and other chains", () => {
  const ok = assertSafeReset({
    databaseUrl: env.DATABASE_URL,
    chainId: 97,
    idoAddress: env.BSC_TESTNET_IDO,
  });
  assert.equal(ok.chainId, 97);
  assert.equal(ok.host, "ep-empty-king.example");
  assert.throws(
    () =>
      assertSafeReset({
        databaseUrl: "postgresql://user:secret@ep-autumn-cake-a1lzselp.example/neondb",
        chainId: 97,
        idoAddress: env.BSC_TESTNET_IDO,
      }),
    /正式库/,
  );
  assert.throws(
    () => assertSafeReset({ databaseUrl: env.DATABASE_URL, chainId: 56, idoAddress: env.BSC_TESTNET_IDO }),
    /97/,
  );
});

test("preview upload list contains only the new public testnet settings", () => {
  const updates = previewEnvUpdates(env);
  assert.equal(updates.NEXT_PUBLIC_CHAIN_NETWORK, "testnet");
  assert.equal(updates.NEXT_PUBLIC_BSC_TESTNET_IDO, "0x8645627C8f7056dFaC1abB1e3ABa9c96222A9Fa5");
  assert.equal(updates.INDEX_START_BLOCK, "134418772");
  assert.equal(updates.NEMO_RPC_URL, "https://bsc-testnet.publicnode.com");
  const blob = JSON.stringify(updates);
  assert.equal(blob.includes("TEST_PRIVATE_KEY"), false);
  assert.equal(blob.includes("secret"), false);
  assert.equal(blob.includes("DATABASE_URL"), false);
});
