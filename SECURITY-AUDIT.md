# nemoido 合约安全审计报告

> **历史版本。** 本文审查的是已删除的链上遍历团队模块（`NemoTeamReward`）。当前链下结算版本的审计见 [SECURITY-AUDIT-2026-09-23.md](SECURITY-AUDIT-2026-09-23.md)，功能说明见 [FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)。

日期：2026-09-18  
分支：`localdev`（阶段 1–5 完成后）  
审计类型：**内部代码审查**（结合独立阅读源码 + Cursor Security Review 子代理）。**不是**付费第三方审计，不能替代主网上线前的外部审计。  
范围：`NemoIdo`、`NemoToken`、`NemoNFT`、`NemoTeamReward`、`INemoTeamReward`，以及部署/测试对账。

参考架构：[ARCHITECTURE.md](ARCHITECTURE.md)

---

## 1. 结论

**未发现 Critical / High 级别的非信任方可盗库、铸币越权或跨用户提权路径。**

单笔 25% 奖励硬帽、团队回调 `_settling` 门禁、`contribute`/`claim` 重入锁、NFT 灵魂绑定、NEMOKEY 默认禁转、邀请树 O(1) 防环、`withdrawTreasury` 不能抽走准备金，这些控制在源码和单测上成立。

**主要风险在 Owner 信任边界：** 参数误配导致入金 revert、导入业绩进入 `qualOf` 从而影响后续真实 USDT 分配、Owner 可直接 mint NEMOKEY、`setTeamModule` 无实现校验。默认参数下（直推 10% + 团队最多约 11%）经济上落在 21% &lt; 25%。

| 级别 | 数量 |
|------|------|
| Critical | 0 |
| High | 0 |
| Medium | 5 |
| Low | 7 |
| Informational | 若干（见第 5 节） |

---

## 2. 方法

1. 通读阶段 1–5 四个合约及接口，核对 `contribute` / 模块回调 / claim / 导入路径。
2. 对照 `test/NemoIdo.security.t.sol`、`test/NemoIdo.team.t.sol`、invariant。
3. 跑 Cursor Security Review 子代理（全仓契约功能，不限于最新 diff）。
4. 不运行 Slither（本报告未复现 `docs/SECURITY.md` 中 2026-09-03 的扫描；该文档口径已过时）。

威胁模型：

- **非信任用户**：任意注册、入金、claim、自建邀请树。
- **恶意/被盗 Owner**：改参数、换模块、导入、mint、pause。
- **恶意团队模块**：在 Owner 已 `setTeamModule` 的前提下尽量超发或阻断入金。

---

## 3. 已验证的控制

| 领域 | 位置 | 结论 |
|------|------|------|
| 重入 | `NemoIdo.sol` `contribute`/`claim` + `test/NemoIdo.security.t.sol` | `nonReentrant`；USDT 回调再入 claim/contribute 被拒 |
| 团队回调 | `NemoIdo.sol:706-728`、`NemoTeamReward.sol:73` | `accrueTeam`/`addTeamVolume` 要求 `_settling && msg.sender==teamModule`；模块仅 vault 可调 |
| 单笔奖励帽 | `REWARD_CAP_BPS=2500`，`NemoIdo.sol:712-714` | 直推+本笔团队（含 overlay）&gt;25% 则整笔 revert；`GreedyTeamModule` 覆盖 |
| 金库会计 | `withdrawTreasury` / invariant | 不能抽走 `reservedRewards` |
| Soulbound / 锁转 | `NemoNFT.sol:57-58`、`NemoToken.sol:91-93` | NFT 禁转；NEMOKEY 默认锁，仅白名单 from 或 to |
| 防环 | `_bindReferrer` + import 测试 | `hasChildren` + `AlreadyBound` |
| 非 Owner 越权 | 全仓 | 未发现普通用户改他人奖励、mint 或绕过 `NotTeamModule` |

---

## 4. 发现

### M-1 Medium — `setDirectReferralBps` 与团队模块叠加可造成入金 DoS

**位置：** `NemoIdo.sol:403-408`、`646-653`、`712-714`

`setDirectReferralBps` 只检查 `bps ≤ 2500`，不再与模块最大产出做联合校验。`setTeamTiers` 仍按金库旧三档表做 `_assertRewardCap`，**约束不到** `NemoTeamReward`。

默认模块单笔团队+overlay 约 11%。若 Owner 把直推调到 20% 或 25%，有推荐人的 ≥100U 入金会在 `accrueTeam` 处 `RewardBpsTooHigh`，销售对这部分用户永久失败（USDT 不会入账，因为整笔回滚）。

**修复：** `setDirectReferralBps` 联合预留模块上限（建议按 1100 bps）；或部署 checklist 写死「直推 + 团队 + overlay ≤ 25%」。产品若希望超帽时截断而非 revert，需另做决策。

---

### M-2 Medium — `importVolumes` 写入的业绩会进入 `qualOf`，影响后续真实 USDT 团队奖

**位置：** `NemoIdo.sol:535-550`、`205-209`；`NemoTeamReward.sol:81-86`

导入不记账奖励（符合产品），但 `selfVolume`/`teamVolume` 会持久进入 `qualOf`。模块按 bump 前 qual 发极差。被盗或恶意 Owner 可给某地址写入 6 万虚高业绩，开售后该地址按 10% 档吃后来者的真实 USDT（仍受 25% 帽约束）。

**修复：** 导入量做 Merkle/签名证明；或 import 业绩仅展示、不参与 `qualOf`；至少开售前链下审计 + 监控 `VolumeImported`。

---

### M-3 Medium — `NemoToken` Owner 可无成本 mint，稀释 IDO 凭证

**位置：** `NemoToken.sol:56-64`

`mint` 允许 `minter`（金库）或 `owner()`。CAP 为 10 亿。入金按需铸造，Owner 另铸不消耗 USDT。密钥失陷可稀释按贡献应得的 NEMOKEY 比例。

**修复：** 去掉 Owner mint，或限制为活动钱包 + 额度/时间锁；主网固定 CAP 与 emission。

---

### M-4 Medium — `setTeamModule` 无接口校验：入金 DoS 或伞下业绩停更

**位置：** `NemoIdo.sol:461-466`、`646-656`

- revert 模块：整笔 `contribute` 失败（已有测试）。
- 空实现模块：不走 `_bumpAncestorTeam`，若模块不调 `addTeamVolume`，上级 `teamVolume` 永久偏低。
- 指向 EOA：无 code，入金失败。

仅 Owner 可设。误配置或密钥失陷即可停售或破坏极差。

**修复：** 实现白名单或 interface 探测；规范要求模块必须 bump 整条上级；关键操作走 timelock。

---

### M-5 Medium — 超 25% 时硬 revert，治理误配会变成可用性事故

**位置：** `NemoIdo.sol:712-714`

这是防超发的安全优先选择，与 M-1 重叠，侧重运营：换模块、改档位、提高直推后，可能出现大面积入金失败，而不是「截断奖励继续入金」。

**修复：** 文档化硬约束；上线 checklist；若产品允许，改为 clip 团队奖（需明确会计规则）。

---

### L-1 Low — NFT 按枚循环 mint，大额入金有 gas 上限风险

**位置：** `NemoNFT.sol:43-49`、`NemoIdo.sol:670-679`

每 500U 一枚，一笔循环 `_mint`。6 万 U ≈ 120 枚，测试可过；更大单笔或「导入巨额 `selfVolume` 后第一笔补铸」可能顶满区块 gas，表现为该用户无法入金。

**修复：** 批量 mint / ERC721A；或对单笔 `count` 设上限并允许多笔补齐。

---

### L-2 Low — 不变量测试未挂团队模块

**位置：** `test/NemoIdo.invariant.t.sol`

Handler 默认 `teamModule=0`，只走直推。准备金守恒在无团队奖时成立，**未**覆盖 overlay / 多跳 `accrueTeam`。

**修复：** 增加挂 `NemoTeamReward` 的 invariant profile。

---

### L-3 Low — `quote()` 与实发 `tokensFor()` 双轨

**位置：** `NemoIdo.sol:273-296`、`658-662`

前端若仍展示 `quote()`，用户会以为周递减 + 1000U 加送已生效，实际按 `tokensPerUsdt` 铸造。属预期管理，不是盗库。

**修复：** 废弃或明确标注 `quote` 为历史视图；UI 只读 `tokensFor`。

---

### L-4 Low — 金库旧三档 `teamTiers` 易误导

**位置：** `NemoIdo.sol:84-85`、`223-238`、`440-449`

`setTeamTiers` 仍校验直推+旧最高档 ≤ 25%，但结算已完全交给模块。运维可能改错表却看不见发奖变化。

**修复：** 废弃视图或标明「仅展示、不结算」。

---

### L-5 Low — localdev 周数学若误部署到非 56 链会按 30 区块当一周

**位置：** `NemoIdo.sol:162-169`、`258-260`

只拦截 BSC 主网。BSC 测试网 / 其他 L1 仍可部署本分支。`quote` 会错，实发汇率不受影响。

**修复：** 发主网前强制改回 timestamp 周；CI 拒绝带 `LocaldevNotForMainnet` 的字节码上 56。

---

### L-6 Low — NemoNFT 无 pause

铸币只经金库 `minter`。紧急停售靠 `NemoIdo.pause`。NFT 合约本身不能单独停 mint（除非改 minter）。可接受，但 Owner 若把 minter 改到恶意地址可无限铸灵魂绑定 NFT（无经济提现权）。

---

### L-7 Low — `setMinter` 可被 Owner 随时改指向

Token / NFT 的 minter 均可改为任意非零地址。失陷后可脱离金库按需铸 NEMOKEY（仍受 CAP）或无限铸 NFT。

**修复：** minter 一次设定或 timelock。

---

## 5. 设计知情项（不单独成漏洞）

| 项 | 说明 |
|----|------|
| 直推不再要求大使门槛 | `_settleDirect` 不看 `selfVolume`。零自投推荐人可拿 10%。利于刷推荐，不破 25% 帽 |
| 团队奖只走模块 | `teamModule!=0` 时金库不内置极差 |
| 奖励整除粉尘 | 除法向下取整，余数留在金库，Owner 可作 treasury 抽走（在 reserved 之外） |
| 邀请 walk 不截 depth | 深度只在绑定检查；100 层 gas 偏高但可接受 |
| USDT 先转入再回调 | 失败则整笔回滚；成功则模块在已入账状态下记账 |
| 白名单 `to` | 任意持仓可转入被 allowlist 的地址。误把 DEX 配进名单会打开该方向流动性 |
| `withdrawUnsoldNemo` | 按需 mint 后金库通常无库存，只回收误转到金库的 NEMOKEY |
| SimMarket | 仍 skip，未回归新极差 |
| `docs/SECURITY.md` | 仍写 5 亿预铸、直推+团队 ≤100%、旧 3/6/9 档，**已过时** |

导入脚本 `maxDepth=64` 与合约默认 `maxReferralDepth=100` 不一致，属运维问题。

---

## 6. 建议上线清单

1. 外部付费审计（本报告不够）。
2. Owner 多签 + 对 `setTeamModule` / `setDirectReferralBps` / `mint` / `import*` 加 timelock。
3. `setDirectReferralBps` 与模块 11% 预算联合校验（修 M-1）。
4. 明确导入业绩是否进入结算资格（修 M-2）。
5. 去掉或限额 Owner mint（修 M-3）。
6. 还原 `weekDuration = 7 days` 与 timestamp `currentWeek()`，删除 `chainid==56` 守卫（或仅主网构建使用）。
7. 更新 `docs/SECURITY.md` 与前端：CAP 10 亿、按需 mint、直推无大使门槛、25% 帽、团队模块架构。
8. 给挂载 `NemoTeamReward` 的路径补 invariant。
9. BSC USDT（18 位）地址与 mint 汇率最终定稿后再开售。

---

## 7. 测试证据

本审查时 `forge test` 基线：约 **91 通过 / 1 跳过**（SimMarket）。  
覆盖直推、ABCD 极差、双 10% overlay 21%、greedy 模块超帽 revert、模块 revert 阻断入金、重入、准备金不可抽空。  
**未覆盖：** 直推 20%+模块的 DoS PoC（M-1 逻辑上成立，建议补测）、带模块的 invariant、超大 NFT 补铸。
