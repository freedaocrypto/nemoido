# BSC 测试网从头再部署

旧的五个合约地址作废。这次会新铸一份 MockUSDT，金库、NEMOKEY、NFT、奖励、周息全是新地址。部署账户是 `.env` 里的 `TEST_PRIVATE_KEY`，它会成为五个合约的 owner。

不要跑 `scripts/scale-network.sh`。它部署后会自动打几百笔入金。

部署必须用已经带 `setImageURI` 的这份源码。图片地址用固定文件，不用带 `dpl_` 的 `/_next/image`。

不要调用 `endIdo`。

下面每一步都在 `/Users/jack/git/github/nemoido`。部署脚本会自动更新 `.env`，再按这份 `.env` 清测试库、导入、开售，最后把公开地址上传到 Vercel Preview。无需复制日志里的地址、区块或 publisher 地址。要求 Node.js 22.16+（支持 `util.parseEnv`），Foundry 在 `~/.foundry/bin`。

## 1. 编译

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd /Users/jack/git/github/nemoido
npm install
forge build
```

## 2. 预览部署

已有 `.env` 必须配置 `BSC_TESTNET_RPC`、`TEST_PRIVATE_KEY` 和测试数据库连接；脚本不会替你选择数据库或修改连接串。`TEST_PRIVATE_KEY` 对应地址需要测试 BNB。

```bash
npm run deploy:testnet
```

预览核对 RPC chainId 97、部署账户、publisher 是否需要生成，不广播、不改 `.env`。如果配置了不同的 `OWNER`，脚本拒绝本流程，避免后续权限不匹配。

## 3. 部署并自动写回 `.env`

```bash
npm run deploy:testnet -- --apply
```

脚本执行 `Deploy.s.sol:Deploy`，固定 `NETWORK=bscTestnet` 和 NFT 图片地址，部署六个新合约。仅在部署成功、本次 broadcast 产物有效、六笔创建回执链上成功且金库关联和五个 Owner 均正确后写回 `.env`：

- 六个 `BSC_TESTNET_*` 地址
- `INDEX_START_BLOCK` 和 `START_BLOCK`：六笔创建交易中最早区块，保证不漏初始事件
- `IDO_ADDRESS`、`REWARDS_ADDRESS`：与同批测试网地址一致
- `RPC_URL=BSC_TESTNET_RPC`、`CHAIN_ID=97`、`NETWORK=bscTestnet`、`NFT_IMAGE_URI`
- `PUBLISHER_ADDRESS`：自动从 publisher 私钥推导

已有 `PUBLISHER_PRIVATE_KEY` 保留；为空时自动生成独立私钥并写入 `.env`，不会在终端打印。它必须与部署私钥不同。`DATABASE_URL`、`DATABASE_URL_UNPOOLED`、`TEST_PRIVATE_KEY` 及其他原配置不变。

`.env` 原子替换，权限设为600；原文件备份为 `.env.backup-时间戳`，备份同样600且被git忽略。备份包含秘密，不要上传。

如果广播中途失败，脚本不会覆盖 `.env`。先检查 Foundry broadcast 记录并恢复失败交易，不要直接重复 `--apply` 生成另一套合约。若部署已成功、仅写回失败，可从当前 `broadcast/Deploy.s.sol/97/run-latest.json` 恢复配置：

```bash
npm run deploy:testnet -- --sync
```

`--sync` 不广播，但必须确认 run-latest 就是要恢复的这批部署；它会重新核对回执、Owner和金库关联。

## 4. 自动核对配置

部署脚本已核对两套地址和起始区块，可额外只打印公开值：

```bash
node --env-file=.env -e 'console.log({ ido: process.env.BSC_TESTNET_IDO, indexer: process.env.IDO_ADDRESS, start: process.env.START_BLOCK, indexStart: process.env.INDEX_START_BLOCK })'
```

`DATABASE_URL` 必须仍是测试库 `ep-empty-king`。正式库主机名含 `ep-autumn-cake`，清库脚本会拒绝。部署脚本不改数据库连接。

## 5. 重置这份新金库的测试库记录

只删 chain id 97、并且金库等于当前 `BSC_TESTNET_IDO` 的行：`nemo_team_proof`、`nemo_team_root`、`nemo_team_account`、`nemo_indexer_state`、`nemo_invite_cache`。旧金库的行留着。不删周息边界，不算业绩，不改链上数据。

先预览行数：

```bash
npm run reset:testnet-db
```

输出里的 `ido` 必须是第 4 步的新金库，`indexerMatches` 必须是 `true`，`host` 必须是测试库。再删除：

```bash
npm run reset:testnet-db -- --apply
```

这一步必须在导入之前。导入脚本也读 `.env` 里的新地址；地址还是旧的就会写进旧金库。

## 6. 导入前面那 30 个地址

来源是 FreeDao 生产库，经 `scripts/import-prod-to-testnet.mjs` 导出再上链。只写邀请码、上级和本人业绩，不铸 NEMOKEY、不铸 NFT、不发直推。导入业绩不进上级伞下，也不产生网体奖。

`docs/bsc-testnet-deposits.csv` 是旧合约上的测试入金，不要导入。

```bash
npm run import:testnet
```

预览里 `records` 必须是 30，并且和 `docs/bsc-testnet-imports.csv` 对得上，再执行：

```bash
npm run import:testnet -- --apply
```

## 7. 自动设置独立 publisher

无需手填地址，脚本直接读取 `.env` 两把私钥和奖励合约地址，核对 chainId、Owner及两套奖励地址一致。先预览，再执行；已设置正确时不重复发送交易。

```bash
npm run publisher:testnet
npm run publisher:testnet -- --apply
```

执行后核对链上 `publisher()` 等于 `.env` 中私钥推导地址，并同步 `PUBLISHER_ADDRESS`。

## 8. 冻结并开售

导入成功之后再跑。这一步会 `freezeImport`，然后 `openSale`。

```bash
npm run import:testnet -- --open
```

核对 `importFrozen() == true`，`saleOpen() == true`。

## 9. 给测试钱包铸新的 MockUSDT

新 MockUSDT 和旧测试币不是同一份。脚本读取 `/Users/jack/Documents/Sensitive/nemo-bsc-testnet-wallets.json` 里的地址，不使用里面的私钥。每个地址铸 100,000 USDT。Gas 由 `.env` 的 `TEST_PRIVATE_KEY` 支付，收款地址自己不用出 gas。

先打印地址：

```bash
npm run mint:test-usdt
```

脚本固定优先读取仓库 `.env`，忽略终端残留的合约地址和部署私钥，并核对当前金库 `usdt()`。数量和 `BSC_TESTNET_USDT` 对得上后再铸造：

```bash
npm run mint:test-usdt -- --apply
```

每笔铸币会核对成功回执、目标代币及余额增加100,000；最后输出每个账户余额。若核对中途失败，先检查已成功地址，不要盲目整批重跑。这些地址以后自己入金时，钱包里还要有测试网 BNB。

## 10. 把公开地址上传到 Vercel Preview

只写 Preview。不上传私钥、数据库连接串、`CRON_SECRET`，也不改 Production。脚本从 `.env` 的 `BSC_TESTNET_*` 生成这些值：

- `NEXT_PUBLIC_CHAIN_NETWORK=testnet`
- `NEXT_PUBLIC_NEMO_NETWORK=bscTestnet`
- `NEXT_PUBLIC_BSC_TESTNET_USDT`、`NEXT_PUBLIC_BSC_TESTNET_IDO`、`NEXT_PUBLIC_BSC_TESTNET_REWARDS`、`NEXT_PUBLIC_BSC_TESTNET_INTEREST`、`NEXT_PUBLIC_BSC_TESTNET_NFT`
- `INDEX_START_BLOCK`
- `NEMO_RPC_URL`

先打印将要写入的值：

```bash
npm run vercel:testnet-preview
```

地址和起始区块与第 4 步一致后再上传：

```bash
npm run vercel:testnet-preview -- --apply
```

`NEXT_PUBLIC_` 是构建时写进前端的。上传之后还要重新部署 Preview，已上线的页面才会换合约。放在开售之后，避免页面先指向还不能入金的金库。

Preview 上的 `DATABASE_URL` 必须仍是测试库 `ep-empty-king`。这个脚本不改它。

本地 Next 还要改 FreeDao `.env.local` 里同一组 `NEXT_PUBLIC_BSC_TESTNET_*` 和 `INDEX_START_BLOCK`。不改的话，本机页面仍连旧金库。

网体索引不要挂在 Preview 上。Vercel 定时任务只对 Production 生效。主网上线时再把 `GET /api/cron/index-rewards` 写进 `vercel.json`，频率用每小时。

## 11. 本地索引，再用币安钱包测

登录地址必须等于钱包当前账户。开售后用新 USDT 入金，看 NEMOKEY、NFT 张数和直推。旧合约上的持仓不会出现。

网体业绩在本地跑，从 `START_BLOCK` 往后扫当前 `IDO_ADDRESS`：

```bash
CHUNK_BLOCKS=50000 npm run index:rewards
```

页面上的「待结算」要等这次索引写完才有数。领取还要另一次发布。npm 命令自动读取仓库 `.env`，配置优先于终端遗留值。发布子进程只保留 `PUBLISHER_PRIVATE_KEY`，自动移除其他私钥，不用另开终端或source：

```bash
npm run publish:root
npm run publish:root -- --apply
```

第一次 `--apply` 会把库里累计的网体奖一次付清，不是只付最新一笔。金库里的 USDT 要够付未领直推加上这次新增的网体奖。

## 顺序执行速查

以下广播、清库和上传命令由你在终端执行；预览输出不对时不要执行紧随其后的 `--apply`。

```bash
cd /Users/jack/git/github/nemoido
export PATH="$HOME/.foundry/bin:$PATH"
npm install
forge build
npm run deploy:testnet
npm run deploy:testnet -- --apply
npm run reset:testnet-db
npm run reset:testnet-db -- --apply
npm run import:testnet
npm run import:testnet -- --apply
npm run publisher:testnet
npm run publisher:testnet -- --apply
npm run import:testnet -- --open
npm run mint:test-usdt
npm run mint:test-usdt -- --apply
npm run vercel:testnet-preview
npm run vercel:testnet-preview -- --apply
```

随后重新部署 FreeDao 的 Vercel Preview，让公开配置进入新构建。部署目标域名及本地 FreeDao `.env.local` 是另一个项目的配置，不由本次 nemoido 部署脚本自动覆盖。完成测试入金后：

```bash
CHUNK_BLOCKS=50000 npm run index:rewards
npm run publish:root
npm run publish:root -- --apply
```

root明细核对请使用 `npm run verify:root -- <发布输出的明细文件>`。导入预览必须确认30条符合当前生产库；数量变化时不要盲目套用历史30条。全程不调用 `scale-network.sh` 或 `endIdo`。
