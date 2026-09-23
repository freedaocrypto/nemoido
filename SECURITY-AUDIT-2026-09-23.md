# nemoido 安全审计报告（链下网体结算版）

日期：2026-09-23  
版本：`localdev` 工作区，未提交  
类型：**内部代码审查**，不是付费第三方审计。主网上线前仍需外部审计。  
范围：`NemoIdo`、`NemoRewards`、`INemoRewards`、`NemoToken`、`NemoNFT`、`NemoNetworks`、`MockUSDT`，部署脚本，链下计算、Merkle、地址映射、导出和导入脚本。  
功能说明：[FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)  
上一版（链上遍历模块）的审查：[SECURITY-AUDIT.md](SECURITY-AUDIT.md)，结论不适用于本版。

---

## 1. 结论

**没有发现外部攻击者（非 Owner、非签名人）能盗取金库、越权铸币或冒领他人奖励的路径。** 重入锁、`disburse` 调用方限制、Merkle 双哈希叶子、EIP-712 域和 nonce、25% 全局帽、直推准备金锁定、NFT 灵魂绑定、NEMOKEY 禁转，在源码和测试中都成立。

**主要风险在特权角色：** 用户已经挣到的网体奖不受 Owner 保护。Owner 可以换掉奖励合约、在 timelock 期间抽空金库、少报 root 合计，任何一种都会让用户的网体领取失败。垫付签名是一把在线热钥匙，泄露后每天可以被取走全站垫付帽的额度。

| 级别 | 数量 |
|------|------|
| Critical | 0 |
| High | 1 |
| Medium | 3 |
| Low | 6 |
| Informational | 8 |

中危及以上的问题，以及大部分低危问题，都在 [test/audit/AuditPoc.t.sol](test/audit/AuditPoc.t.sol) 里有可运行的复现：

```bash
forge test --match-contract AuditPocTest -vv
```

这些测试断言的是**当前存在的问题行为**。修复之后对应的测试会失败，届时应改成断言修复后的行为。

---

## 2. 方法

1. 逐函数阅读合约，整理调用方权限、状态变化和资金流（见功能报告第 2–4 节）。
2. `forge test`：84 项通过（SimMarket 为旧模型，已跳过）。加上审计 PoC，共 93 项。
3. `forge coverage`：

| 文件 | 行 | 语句 | 分支 | 函数 |
|------|----|------|------|------|
| NemoIdo.sol | 88.72% | 79.71% | 43.84% | 87.23% |
| NemoRewards.sol | 91.20% | 82.56% | 43.90% | 88.24% |
| NemoToken.sol | 100% | 86.49% | 50.00% | 100% |
| NemoNFT.sol | 100% | 84.00% | 33.33% | 100% |
| NemoNetworks.sol | 72.97% | 72.73% | — | 75.00% |

4. 本机没有安装 Slither，没有做静态扫描。建议外部审计前补跑。
5. 本地 Anvil 实跑 300 个账户，验证了多叶子 proof、垫付后再领取、深浅链 gas。

严重度口径：**High** 表示用户资金可能损失或被永久卡住，前提是某个特权角色作恶或失误。**Medium** 表示在特定条件下出现资金不足或额度被滥用。**Low** 表示影响可用性，或需要多个前提同时成立。**Informational** 表示设计说明或最佳实践。

---

## 3. 高危

### H-1 Owner 可随时 `setRewards`，取走网体准备金，并让旧 root 无法领取

**位置：** `NemoIdo.setRewards`、`NemoIdo.disburse`

**成因：** `setRewards` 只检查非零地址，没有延迟，也没有一次性限制。`disburse(..., true)` 只锁直推准备金，而 `outstanding` 读的是**新**地址的返回值。

**影响：**

- Owner 把地址指向自己控制的合约后，可以用 `disburse(owner, 余额 − 直推准备金, true)` 取走当期 root 已承诺的网体准备金。
- 旧 `NemoRewards` 再调用 `disburse` 时会 `NotRewards`，已经生效的 root 全部无法领取。
- 正常升级奖励合约时，也会出现同样的「旧 root 作废」。

**PoC：** `test_H1_setRewardsDrainsTeamReserve`。root 承诺 500 USDT 后换地址，金库余额被提到只剩直推准备金，alice 领取时 revert `NotRewards`。

**建议：**

1. `setRewards` 只允许设置一次；或者加 timelock（例如 ≥ 7 天），在旧 root 的 `outstanding` 为 0 前不允许切换。
2. `disburse` 的锁定额同时读取「旧 rewards 的 outstanding」，或者由金库自己记录承诺额，不依赖外部合约的返回值。
3. Owner 用多签 + timelock 托管。

---

## 4. 中危

### M-1 待生效 root 不进准备金，timelock 期间金库可以被抽空

**位置：** `NemoIdo.reservedRewards`、`NemoRewards.submitRoot`、`NemoRewards.activateRoot`

**成因：** `reservedRewards = 直推准备金 + outstanding`，不包括 `pendingCumulative`。`activateRoot` 只检查 25% 帽，不检查金库余额是否足够。

**影响：** Owner 在 `submitRoot` 之后、`activateRoot` 之前调用 `withdrawTreasury` 提走全部可提金额，root 仍然能生效，但用户领取时 `InsufficientTreasury`。挑战窗本来是给用户审核的时间，现在反而成了抽库窗口。

**PoC：** `test_M1_pendingRootIsUnfunded`

**建议：** 把 `pendingCumulative − rootPaid` 计入准备金（取它和当期 `outstanding` 中较大的那个）；`activateRoot` 要求 `balance ≥ 直推准备金 + 新 outstanding`。

### M-2 `submitRoot` 的 `cumulative` 与叶子无关，少报会让准备金不足

**位置：** `NemoRewards.submitRoot`、`outstanding`、`_attribute`

**成因：** 合约无法从 root 反推出叶子之和，`committed` 完全由 Owner 申报。`outstanding = committed − rootPaid`，当 `rootPaid` 超过 `committed` 时取 0。Merkle 领取调用 `disburse(..., true)`，只锁直推准备金，所以超出 `committed` 的叶子是从「可抽库余额」里付的。

**影响：**

- 少报：准备金偏低，Owner 可以合法抽库，后来的领取人 `InsufficientTreasury`。
- 多报：`outstanding` 永远到不了 0，多出来的部分长期锁在金库。只影响 Owner 自己，但会误导对账。

**PoC：** `test_M2_underDeclaredCumulativeLeavesClaimsUnfunded`。两片叶子合计 800 USDT，申报 1 USDT，抽库后 alice 领取失败。

**建议：**

1. 链下发布叶子 JSON（`contentHash` 对应的内容），监控脚本独立复算合计，不一致时发起挑战。
2. 合约侧：`claim` 时要求 `rootPaid + span ≤ committed`，超出就 revert。这样少报会先让领取失败并暴露出来，而不是悄悄花掉可抽库余额。
3. 与 M-1 一起修：准备金按 `committed` 锁定，并在生效时检查余额。

### M-3 垫付签名人是单把热钥匙，泄露后按日帽被持续取款

**位置：** `NemoRewards.claimAdvance`、`setAdvanceSigner`、`script/Deploy.s.sol`

**成因：** 垫付只验证签名，不要求账户有入金，也不要求当期有 root。单账户帽按自然日重置，全站日帽是唯一的全局闸门。部署脚本在没有设置 `ADVANCE_SIGNER` 时，默认用部署账户。

**影响：**

- 签名钥匙泄露后，攻击者可以给任意女巫地址签名，每天取走最多全站日帽（主网 100,000 USDT），直到 Owner 调用 `setAdvanceSigner`。上限还受 25% 总帽约束。
- 已付款计入 `totalTeamPaid`。下一期 root 的合计必须 ≥ 这个值，否则 `submitRoot` 被拒绝，正常结算也会被卡住。
- 实现和计划原文有偏差：计划写的是「单账户**本期**垫付上限」，实现是按**自然日**重置。只要签名服务愿意签，一个账户每天都能再垫一次。

**PoC：** `test_M3_advanceSignerPaysWithoutRoot`。没有任何 root 的情况下，20 个从未入金的地址各取走 1,000 USDT；之后用 1 USDT 的合计提交 root 会被拒绝。

**建议：**

1. 签名钥匙放 HSM / KMS，签名服务只对「链下账本余额 ≥ 累计额」的账户签发，并单独设置限流和告警。
2. 合约侧可以要求 `cumulative ≤ rootAttributed[account] + 单账户帽`（按 root 期计，而不是按天）。这样即使钥匙泄露，每个账户在每期里也只能多拿一个帽的额度。
3. 部署时强制要求显式设置 `ADVANCE_SIGNER`，不要回落到部署账户。
4. 链上监控 `AdvanceClaimed`，异常时立即 `setAdvanceSigner`。

---

## 5. 低危

### L-1 垫付过的金额在用户提交证明前一直占着准备金

`claimAdvance` 不动 `rootPaid`。下一期 root 把这部分算进 `committed` 后，要等用户本人调用 `claim` 才会从 `outstanding` 里扣掉。用户不来领，这部分就一直多锁；`claim` 只能由本人调用，别人无法代劳。

- PoC：`test_L1_prepaidStaysReservedUntilUserClaims`（垫付 300 后 root 生效，`outstanding` 仍是 300）。
- 建议：增加 `attributeFor(account, cumulative, proof)`，允许任何人为别人入账（只入账、不转账）；或者在垫付时就记录「待归因」额度，生效时统一扣减。

### L-2 直推比例调到 25% 会挤掉全部网体奖

`setDirectReferralBps` 上限是 2500。调满后，任何网体 root 都会 `CapExceeded`。

- PoC：`test_L2_directAtCapStarvesTeam`
- 建议：把上限降到 1000–1500，或者在文档里写明直推 + 网体预期峰值。

### L-3 挑战由 Owner 裁决，挑战者可以反复拖延

合约不判断 root 对错：`dismissChallenge` 没收押金，`cancelPending` 退押金。挑战者被驳回后可以在 eta 之前再次挑战，每次成本是一份押金。eta 过后，只要还有未处理的挑战，root 就不能生效，直到 Owner 再次驳回。`submitRoot` 覆盖待生效的 root 会重置计时。

- PoC：`test_L3_ownerDecidesChallenge`
- 影响：这不是一套去信任的争议机制，而是「公开 + 多签可撤销」。用户能得到的保护是可观测性，不是裁决权。
- 建议：文档里如实说明；Owner 用多签；把 `dismissChallenge` 的依据（复算差异报告）公开。

### L-4 `NemoRewards` 没有暂停开关，金库 `pause` 挡不住网体领取

`disburse` 不受 `whenNotPaused` 约束。出现 root 错误、签名泄露等紧急情况时，只能换签名人或换 rewards 地址，而后者会触发 H-1 的问题。

- PoC：`test_L4_pauseDoesNotStopTeamClaims`
- 建议：`NemoRewards` 继承 `Pausable`，`claim` / `claimAdvance` 加 `whenNotPaused`；或者让 `disburse` 跟随金库的暂停状态。

### L-5 NEMOKEY 达到 CAP 或被暂停后，所有入金都会 revert

入金路径会同步 mint NEMOKEY。按默认 1U → 100 枚，累计约 1,000 万 USDT 就会撞到 10 亿 CAP；Owner 自己 mint 活动库存、或者调大 `setTokensPerUsdt`，都会让这一天提前到来。`NemoToken.pause` 也会让入金全部失败。

- PoC：`test_L5_tokenCapBlocksDeposits`；已有 `test_capExceededRevertsContribute`
- 建议：mint 数量裁到剩余额度，或在 CAP 用尽时跳过 mint；对 Owner mint 设置单独上限。

### L-6 NFT 按枚循环铸造，超大额单笔入金可能超出 gas 上限

每 500U 一次 `_mint`。6 万 U 约 120 次，实测约 341 万 gas；上百万 U 的单笔会接近或超过区块上限，只能拆笔。攻击者无法借此影响别人，因为 gas 由入金者本人承担。

- 建议：前端限制单笔金额；后续改用 ERC721A 或按「一枚 NFT + 数量」记账。

---

## 6. 信息级

- **I-1 Owner 权限集中。** 金库 Owner 可以抽走全部非准备金余额、改铸币汇率、导入任意本人业绩；NemoToken Owner 可以直接 mint、改 minter；NemoNFT Owner 可以改 minter 后任意铸造 NFT。这是 IDO 模型的前提，但必须由多签 + timelock 持有。
- **I-2 邀请码可以被抢注。** 注册时选的码可能被人在内存池里抢先，受害者交易会 `CodeTaken`。不会偷走下级，因为下级只能绑定已经注册成功的码。
- **I-3 `registerAndContribute` 对已注册账户会静默忽略传入的邀请码。** 前端应先查注册状态，避免用户以为已经绑上级。
- **I-4 USDT 精度假设为 18 位。** BSC USDT 符合。部署到其他链前必须复核 `minIdo`、`NFT_UNIT`、`tokensFor`。
- **I-5 `quote()`、`tokensPer100`、`setNemoSchedule` 是历史函数，不影响铸币。** 前端不要把它当成实发数量。
- **I-6 `MockUSDT.mint` 任何人都能调用。** 只在本地和测试网部署；主网参数写死真实 USDT，`Deploy.s.sol` 不会部署 Mock。
- **I-7 部署脚本在 `OWNER ≠ 部署者` 时不调用 `setRewards`，NEMOKEY / NFT 的所有权转移要等新 Owner `acceptOwnership`。** 部署完成前 `rewards = 0`，网体领取不可用。需要在上线清单里逐项核对。
- **I-8 链下风险。**
  - 计算器必须按（区块号，logIndex）处理事件，只使用已最终确认的区块，防止重组后 root 与链上不一致。
  - 导入的历史业绩是否计入资格，是业务口径，必须和运营确认后写进计算器，并在叶子 JSON 里公开。
  - `contentHash` 对应的叶子 JSON 必须公开（IPFS 或官网），否则没人能复算、也就没人能挑战。
  - 测试网模拟地址由公开字符串派生，没有人持有私钥，这些地址上的奖励无法领取。这是预期行为，只影响测试网。
  - 签名服务必须鉴权，并做请求限流。

---

## 7. 已确认有效的控制

| 控制 | 结论 |
|------|------|
| 重入 | `contribute` / `claim` / `disburse` / 奖励 `claim` 都有 `nonReentrant`；USDT 用 SafeERC20 |
| `disburse` 调用方 | 仅 `rewards` 地址（风险见 H-1） |
| 直推准备金 | `withdrawTreasury` 和 `disburse` 都不能动；invariant 测试 2048 次调用未破坏 |
| 25% 帽 | 常量；root 提交、生效、每次付款都检查 |
| Merkle | OZ 双哈希叶子，防第二原像；排序配对与 JS 构建器一致，Anvil 多叶子验证通过 |
| 累计领取 | 重复领取 `NothingToClaim`；垫付后再领取不双付（单测 + Anvil） |
| EIP-712 | 域含 chainId 和合约地址；账户绑定 `msg.sender`；nonce 递增；deadline；SignatureChecker 支持合约钱包 |
| 网络参数 | 两个合约的构造函数都校验 chainId；主网部署需要 `ALLOW_MAINNET=true` |
| 邀请防环 | O(1) `hasChildren`；导入同样经过 `_bindReferrer` |
| NFT / NEMOKEY | NFT 禁止转移；NEMOKEY 默认禁转，白名单放行 |
| gas | 入金不再遍历邀请链，深浅链 gas 相同（270,271） |

---

## 8. 建议补的测试

- 零地址、长度不匹配、参数越界等 revert 分支（当前分支覆盖率约 44%）。
- 多期 root：累计额递增、某账户叶子下降、跨期垫付。
- 垫付：过期、重放、错签名人、跨日重置、全站日帽。
- `submitRoot` 覆盖已被挑战的待生效 root 时退押金。
- 修复 H-1 / M-1 / M-2 后，把对应 PoC 改成断言修复后的行为。
- Deploy 脚本的 fork 测试（`OWNER ≠ 部署者` 的路径）。

---

## 9. 主网上线前检查清单

- [ ] 修复或书面接受 H-1、M-1、M-2、M-3
- [ ] 金库、奖励合约、NEMOKEY、NFT 的 Owner 转到多签，并接入 timelock；完成 `acceptOwnership`
- [ ] `setRewards` 改为只能设置一次，或加延迟
- [ ] 垫付签名钥匙放 HSM / KMS，签名服务鉴权和限流；显式设置 `ADVANCE_SIGNER`
- [ ] `NemoRewards` 增加暂停开关
- [ ] 叶子 JSON 公开发布；独立复算与挑战监控上线
- [ ] 计算器只读已最终确认的区块；导入业绩是否计入资格已书面确认
- [ ] 前端限制单笔金额（NFT gas）；监控 NEMOKEY 剩余额度
- [ ] 补跑 Slither；完成外部付费审计
