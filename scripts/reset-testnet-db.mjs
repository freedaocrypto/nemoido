#!/usr/bin/env node
/**
 * 删除新测试网金库在测试库里的索引记录。
 * 只匹配 chain id 97 和 .env 里的 BSC_TESTNET_IDO。正式库、其他金库不动。
 * 默认只打印行数。--apply 才删除。
 *
 *   node scripts/reset-testnet-db.mjs
 *   node scripts/reset-testnet-db.mjs --apply
 */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { getAddress } from "viem";
import { assertSafeReset, TESTNET_CHAIN_ID } from "./lib/testnet-ops.mjs";

const ENV_FILE = process.env.NEMO_ENV_FILE || new URL("../.env", import.meta.url);

const TABLES = [
  {
    name: "nemo_team_proof",
    count: `SELECT count(*)::int AS n FROM nemo_team_proof WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
    delete: `DELETE FROM nemo_team_proof WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
  },
  {
    name: "nemo_team_root",
    count: `SELECT count(*)::int AS n FROM nemo_team_root WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
    delete: `DELETE FROM nemo_team_root WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
  },
  {
    name: "nemo_team_account",
    count: `SELECT count(*)::int AS n FROM nemo_team_account WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
    delete: `DELETE FROM nemo_team_account WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
  },
  {
    name: "nemo_indexer_state",
    count: `SELECT count(*)::int AS n FROM nemo_indexer_state WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
    delete: `DELETE FROM nemo_indexer_state WHERE chain_id = $1 AND lower(ido_address) = lower($2)`,
  },
  {
    name: "nemo_invite_cache",
    count: `SELECT count(*)::int AS n FROM nemo_invite_cache WHERE "chainId" = $1 AND lower("idoAddress") = lower($2)`,
    delete: `DELETE FROM nemo_invite_cache WHERE "chainId" = $1 AND lower("idoAddress") = lower($2)`,
  },
];

function readEnv(file) {
  const text = readFileSync(file, "utf8");
  const env = {};
  for (const line of text.split("\n")) {
    if (!line || line.startsWith("#") || !line.includes("=")) continue;
    const index = line.indexOf("=");
    env[line.slice(0, index)] = line.slice(index + 1).trim().replace(/^"|"$/g, "");
  }
  return env;
}

async function tableExists(client, name) {
  const { rows } = await client.query(`SELECT to_regclass($1) AS reg`, [`public.${name}`]);
  return Boolean(rows[0]?.reg);
}

export async function resetTestnetDb(client, { chainId, ido, apply }) {
  const counts = [];
  await client.query("BEGIN");
  try {
    for (const table of TABLES) {
      if (!(await tableExists(client, table.name))) {
        counts.push({ table: table.name, rows: 0, missing: true });
        continue;
      }
      if (apply) {
        const deleted = await client.query(table.delete, [chainId, ido]);
        counts.push({ table: table.name, rows: deleted.rowCount });
      } else {
        const selected = await client.query(table.count, [chainId, ido]);
        counts.push({ table: table.name, rows: selected.rows[0].n });
      }
    }
    if (apply) await client.query("COMMIT");
    else await client.query("ROLLBACK");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  }
  return counts;
}

async function main() {
  const apply = process.argv.includes("--apply");
  const env = readEnv(ENV_FILE);
  const databaseUrl = env.DATABASE_URL_UNPOOLED || env.DATABASE_URL;
  const { host, ido } = assertSafeReset({
    databaseUrl,
    chainId: TESTNET_CHAIN_ID,
    idoAddress: env.BSC_TESTNET_IDO,
  });
  const indexerIdo = env.IDO_ADDRESS ? getAddress(env.IDO_ADDRESS) : "";
  console.log(
    JSON.stringify({
      apply,
      host,
      chainId: TESTNET_CHAIN_ID,
      ido,
      indexerIdo: indexerIdo || null,
      indexerMatches: !indexerIdo || indexerIdo === ido,
    }),
  );
  if (indexerIdo && indexerIdo !== ido) {
    console.log("IDO_ADDRESS 仍指向另一份金库。这次只清除 BSC_TESTNET_IDO。索引脚本要改用这份新地址，否则还会去写旧记录。");
  }

  const { default: pg } = await import("pg");
  const client = new pg.Client({
    connectionString: databaseUrl,
    ssl: process.env.PGSSL === "disable" ? false : { rejectUnauthorized: false },
  });
  await client.connect();
  try {
    const counts = await resetTestnetDb(client, { chainId: TESTNET_CHAIN_ID, ido, apply });
    for (const row of counts) {
      console.log(`${row.table} ${row.missing ? "不存在" : apply ? "已删除" : "将删除"} ${row.rows}`);
    }
    if (!apply) console.log("dry-run。确认后加 --apply 才会删除。");
  } finally {
    await client.end();
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await main();
}
