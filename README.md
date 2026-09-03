# nemoido — NEMO IDO（BSC USDT 金库）

第一期：BSC 上的 `$NEMO` IDO **USDT 金库合约**。只收 USDT、记账投入/身份、结算直推与团队极差，用户自行 `claim` USDT。**不铸造 NEMO**（代币仍按现站 `pending_ido` 后续发放）。

仓库：独立 Foundry 项目。网站整合（FreeDao `life_sol`）为第二期。

## 规则（默认，管理员可改）

| 项 | 默认 |
|----|------|
| 直推 | 10%（推荐人本人 ≥ 100U 大使） |
| 入金 &lt; 100U | 计入业绩，**无**直推/团队奖 |
| 身份 | 探索者 &lt;100 / 大使 ≥100 / 合伙人 ≥1000 / 共建者业绩口径：本人≥1000 且伞下≥3万 |
| 团队极差 | 伞下 3000U→3%，10000U→6%，30000U→9% |
| 叠加 | 直推 10% + 团队极差 |
| 伞下业绩 | 未压缩的全部下级本人投入（不含自己） |

极差：先把本笔记入整条上级 `teamVolume`，再从直推人往上按档位差额发放。例：我 9%、下级 6% → 该下级伞下的达标入金，下级拿 6%，我拿 3%。

历史数据只导入地址、邀请码、邀请关系、已确认业绩，**不补发**奖励。直推 + 最高团队档合计不超过 100%，避免准备金被参数改穿。

## 命令

```bash
# 依赖（OpenZeppelin v5.4.0 + forge-std）
bash scripts/install-deps.sh

forge build
forge test -vvv
forge test --match-contract NemoIdoInvariant
forge fmt

# 本地 Anvil（另开终端）
anvil --chain-id 31337
bash scripts/local-up.sh
# 部署 MockUSDT + NemoIdo，种根邀请码 ROOTANVL
```

BSC 部署（第二期/主网前再执行）：

```bash
USDT_ADDRESS=0x55d398326f99059fF775485246999027B3197955 \
OWNER=0x... \
PRIVATE_KEY=0x... \
forge script script/Deploy.s.sol:Deploy --rpc-url $BSC_RPC_URL --broadcast
```

## 历史导入

1. 从 FreeDao 库导出（只读 `nomad_users` + 已确认订单）：

```bash
DATABASE_URL=postgres://... node scripts/export-freedao.mjs --out import-data.json
# 或离线 JSON：
node scripts/export-freedao.mjs --in scripts/fixtures/sample-users.json --out import-data.json
```

2. dry-run，再上链（须在 `freezeImport` 之前，owner 账户）：

```bash
npm install
IDO_ADDRESS=0x... RPC_URL=http://127.0.0.1:8545 PRIVATE_KEY=0x... \
  node scripts/import-onchain.mjs --in import-data.json          # dry-run
IDO_ADDRESS=0x... RPC_URL=... PRIVATE_KEY=0x... \
  node scripts/import-onchain.mjs --in import-data.json --apply --freeze
```

导入后：`openSale()`，用户 `approve` USDT 后 `contribute` / `registerAndContribute`。

## 合约入口

- `register(code, referrerCode)` / `bindReferrer(referrerCode)`（仅未绑定）
- `contribute(amount)` / `registerAndContribute`
- `claim()`
- 管理员：`freezeImport`、`openSale`、`closeSale`、`pause`、参数 setter、`withdrawTreasury`（不能抽走 `reservedRewards`）
- 导入：`importUsers` / `importReferrers` / `importVolumes`

邀请码：1–32 位大写字母或数字，链上 `bytes32` ASCII 左对齐。兼容现站 8 位码与本地 `ROOTANVL`。

## 本地账户（Anvil 默认助记词，禁止用于主网）

`test test test test test test test test test test test junk`

| 账户 | 地址 |
|------|------|
| #0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| #1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| #2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |

## 安全

见 [docs/SECURITY.md](docs/SECURITY.md)。第一期含单测、模糊、不变量与 Slither；主网部署前需独立审计。

## Git 作者

本仓库提交身份固定为 **`freedaocrypto <jackoelv@freedao.life>`**（[`.gitconfig`](.gitconfig)）。克隆后执行一次：

```bash
bash scripts/setup-git-author.sh
```
