# NemoIdo 安全说明（第一期）

范围：`src/NemoIdo.sol` USDT 金库。不铸造 NEMO，不涉及网站鉴权。

## 设计约束

- Solidity 0.8.28，CEI + `ReentrancyGuard` + `SafeERC20`
- 邀请链深度上限（默认 64，最大 128）
- 直推 bps + 最高团队档 ≤ 100%，避免单笔奖励超过入金
- `withdrawTreasury` 只能抽取 `balance - (totalAccrued - totalClaimed)`
- `import*` 仅 owner，且 `freezeImport` 后不可再写历史业绩
- `openSale` 必须已冻结导入
- 拒绝直接转入 ETH
- Ownable2Step 转移所有权

## 已知产品差异（相对现站 DB）

- 历史导入不补发奖励（有意）
- 链上实时入金按**当笔结算**：推荐人若在该笔之后才达到大使，不回补更早的直推（避免导入/回溯复杂性）
- 共建者 33 席、候选人标记、压缩业绩仍在网站侧；合约只提供未压缩伞下业绩

## 测试

```bash
forge test -vvv
forge test --match-contract NemoIdoInvariant
node --test scripts/lib/tree.test.mjs
```

覆盖：&lt;100U 无推广奖、直推 10%、3/6/9 极差、下级 6% 上级只拿 3%、未达大使不占档、导入不发奖、暂停、准备金不可抽空、自邀/成环、重入。

不变量：

- `reservedRewards() <= USDT.balanceOf(ido)`
- `sum(pendingOf(users)) == reservedRewards()`
- `treasuryWithdrawable() + reservedRewards() == balance`

## Slither

2026-09-03，`slither-analyzer 0.11.6`，对 `src/NemoIdo.sol`（排除 `lib/`）：

- 去掉 payable `receive`/`fallback` 后，**0 条**针对主合约的告警。
- 无 receive 时直接转 ETH 会失败（`test_rejectsEth`）。`selfdestruct` 强制送 ETH 无法拦截，属 EVM 限制。
- 对 `test/` 的命名约定、immutable、低级 call 等告警视为测试代码误报，不改。

复现：

```bash
slither src/NemoIdo.sol --exclude-dependencies --filter-paths lib/
```

## 主网上线前（不在第一期）

- 付费审计
- BSC USDT 地址与 owner 多签
- 导入脚本对生产库 dry-run 并抽样核对
- 暂停与 `closeSale` 演练
