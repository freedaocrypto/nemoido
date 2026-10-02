# BSC 测试网从头再部署

旧的五个合约地址作废。这次会新铸一份 MockUSDT，金库、NEMOKEY、NFT、奖励、周息全是新地址。部署账户是 `.env` 里的 `TEST_PRIVATE_KEY`，它会成为五个合约的 owner。

不要跑 `scripts/scale-network.sh`。它部署后会自动打几百笔入金。

部署必须用已经带 `setImageURI` 的这份源码。图片地址用固定文件，不用带 `dpl_` 的 `/_next/image`。

不要调用 `endIdo`。

## 1. 编译

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd /Users/jack/git/github/nemoido
npm install
forge build
```

## 2. 另开一个干净终端，生成发布私钥

不要用 `TEST_PRIVATE_KEY`。这把私钥只留给以后的 `publish:root --apply`，不要和 `PRIVATE_KEY` 放进同一个会执行发布的环境。

```bash
cast wallet new
```

记下地址和私钥。

## 3. 部署

```bash
set -a && source .env && set +a
export NETWORK=bscTestnet
export NFT_IMAGE_URI=https://test.freedao.life/media/nomad/rwa-nft-pass.webp
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BSC_TESTNET_RPC" \
  --private-key "$TEST_PRIVATE_KEY" \
  --broadcast -vv
```

日志里会有 USDT、NEMOKEY、NemoNFT、NemoIdo、NemoRewards、NemoNftInterest。写回 `.env`：

- `BSC_TESTNET_USDT`
- `BSC_TESTNET_NEMOKEY`
- `BSC_TESTNET_NFT`
- `BSC_TESTNET_IDO`
- `BSC_TESTNET_REWARDS`
- `BSC_TESTNET_INTEREST`

再记下部署交易的区块号，后面填 `INDEX_START_BLOCK`。

## 4. 导入前面那 30 个地址

来源是 FreeDao 生产库，经 `scripts/import-prod-to-testnet.mjs` 导出再上链。只写邀请码、上级和本人业绩，不铸 NEMOKEY、不铸 NFT、不发直推。

`docs/bsc-testnet-deposits.csv` 是旧合约上的测试入金，不要导入。

```bash
set -a && source .env && set +a
npm run import:testnet
```

预览里 `records` 必须是 30，并且和 `docs/bsc-testnet-imports.csv` 对得上，再执行：

```bash
npm run import:testnet -- --apply
```

## 5. 换成单独的 publisher

部署时 publisher 等于 owner。不换的话，发布脚本无法用单独的 `PUBLISHER_PRIVATE_KEY`。

```bash
cast send "$BSC_TESTNET_REWARDS" "setPublisher(address)" 0x新发布地址 \
  --rpc-url "$BSC_TESTNET_RPC" --private-key "$TEST_PRIVATE_KEY"
cast call "$BSC_TESTNET_REWARDS" "publisher()(address)" --rpc-url "$BSC_TESTNET_RPC"
```

返回值必须是第 2 步的新地址。

## 6. 冻结并开售

导入成功之后再跑。这一步会 `freezeImport`，然后 `openSale`。

```bash
npm run import:testnet -- --open
```

核对 `importFrozen() == true`，`saleOpen() == true`。

## 7. 给币安钱包铸新的 MockUSDT

新 MockUSDT 和旧测试币不是同一份。`mint` 是公开函数。钱包里还要有测试网 BNB 付 gas。

```bash
cast send "$BSC_TESTNET_USDT" "mint(address,uint256)" 0x币安钱包地址 100000ether \
  --rpc-url "$BSC_TESTNET_RPC" --private-key "$TEST_PRIVATE_KEY"
```

## 8. 网站环境

把 FreeDao `life_dev` 部署到 `test.freedao.life` 的 Vercel 环境改成新地址，然后重新部署。`NEXT_PUBLIC_` 和 `INDEX_START_BLOCK` 都要在构建前写上。

- `NEXT_PUBLIC_CHAIN_NETWORK=testnet`
- `NEXT_PUBLIC_BSC_TESTNET_USDT`
- `NEXT_PUBLIC_BSC_TESTNET_IDO`
- `NEXT_PUBLIC_BSC_TESTNET_REWARDS`
- `NEXT_PUBLIC_BSC_TESTNET_INTEREST`
- `NEXT_PUBLIC_BSC_TESTNET_NFT`
- `INDEX_START_BLOCK` = 第 3 步的部署区块号
- `DATABASE_URL_UNPOOLED` = 测试库的直连地址（索引用它加锁；池化连接加不上会话锁）

网体索引不要挂在 Preview 上。Vercel 定时任务只对 Production 生效，测试网这次不注册。主网上线时再把 `GET /api/cron/index-rewards` 写进 `vercel.json`。

测试网业绩在本地跑 `npm run index:rewards`。接口仍然要求 `NEXT_PUBLIC_CHAIN_NETWORK=testnet`、金库、奖励地址和 `INDEX_START_BLOCK`，从部署区块往后扫入金，写入同一份数据库的 `nemo_team_account`。不发布 root，也不动用户的 USDT。没填 `INDEX_START_BLOCK` 时接口返回 503，不会从区块 0 扫。

## 9. 币安钱包手动测

登录地址必须等于钱包当前账户。开售后用新 USDT 入金，看 NEMOKEY、NFT 张数和直推。旧合约上的持仓不会出现。

网体奖要等索引跑过，并且之后用 `PUBLISHER_PRIVATE_KEY` 执行 `publish:root --apply`，才领得到。发布用一个干净终端，只设置 `PUBLISHER_PRIVATE_KEY`，不要同时留着 `PRIVATE_KEY`。
