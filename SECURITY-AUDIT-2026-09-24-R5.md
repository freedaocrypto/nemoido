# nemoido 安全审计报告（第五版，简化后全面复审）

> **历史版本。** 已被 [SECURITY-AUDIT-2026-09-24-R6.md](SECURITY-AUDIT-2026-09-24-R6.md) 取代。本文部分条目在发出后被标注为已修，但端到端验证、Slither 和本轮新发现的问题见 R6。

日期：2026-09-24  
代码状态：提交 `11e8efd` 加上工作区全部未提交改动（分支 `localdev`）  
取代：[SECURITY-AUDIT-2026-09-24-R4.md](SECURITY-AUDIT-2026-09-24-R4.md)（简版）。R3、R2、第一版保留为历史，未改写  
配套功能报告：[FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)  
复现测试：`test/audit/AuditPocR5.t.sol`（本版新增 7 项），`test/audit/AuditPoc.t.sol`（R3 复现，已随修复更新）

---

## 0. 结论

本版把 R3 的两项高危都处理掉了：更换奖励合约现在要等一段延迟，发布 root 可以用单独的 publisher 地址。资金路径上没有发现能让普通用户多领、少付或卡死金库的问题。直推奖和网体奖依然受 25% 帽约束，直推准备金在任何路径下都不会被 Owner 或奖励合约动用。

还剩下的问题分三类：

1. **一项中危需要上线前处理。** 部署后 publisher 默认就是 Owner，并且单次增量上限 `maxRootIncrease` 默认是 0（不限）。发布私钥一旦泄露，攻击者可以在同一个区块里发布一棵给自己记账的树并立即领走，一直领到 25% 帽为止（R5-M1）。只需在部署或上线时设置一个上限，合约不用改。
2. **链下三项已修。** 账户、root、proof 按金库地址区分（M-4）。索引器支持 `START_BLOCK`、分段写检查点，并和发布器共用一把库锁（L-6）。发布时先写未生效的 proof，核对 `publisher()` 后再上链（L-7）。还没有连真实 Postgres 跑通整条链路。
3. **四项低危、若干提示**，以及 Owner 权限清单。Owner 权限按项目方意见列为「已知并接受」，不作为上线阻断项。

| 等级 | 数量 | 编号 |
|------|------|------|
| 高 | 0 | — |
| 中 | 1 | R5-M1 发布私钥与增量上限。R5-M2 已修 |
| 低 | 4 | R5-L1 至 R5-L4。R5-L5、R5-L6 已修 |
| 提示 | 7 | R5-I1 至 R5-I7 |
| 已知并接受（Owner 权限） | 11 | A-1 至 A-11 |

主网上线仍需要外部审计。本轮没有运行 Slither，本机未安装；也没有广播测试网或主网。

---

## 1. 范围与方法

**合约**

| 文件 | 说明 |
|------|------|
| `src/NemoIdo.sol` | 金库：入金、邀请、直推、铸币、导入、补发 NFT、奖励地址延迟切换、结束 IDO |
| `src/NemoRewards.sol` | 网体奖累计 Merkle root，发布即生效 |
| `src/NemoNftInterest.sol` | NFT 周息，按周分版本，设有全站和单户上限 |
| `src/NemoToken.sol` | NEMOKEY，CAP 10 亿枚，默认不可转 |
| `src/NemoNFT.sol` | 灵魂绑定 NFT，铸币地址只能设置一次 |
| `src/network/NemoNetworks.sol` | 三套网络参数 |
| `src/INemoRewards.sol`、`src/INemoNftInterest.sol` | 接口 |
| `script/Deploy.s.sol` | 部署脚本 |

**链下：** `scripts/publish-root.mjs`、`scripts/verify-root.mjs`、`scripts/index-rewards.mjs`、`scripts/lock-interest-boundary.mjs`，以及 `scripts/lib/` 下的 `reward-db`、`reward-index`、`team-reward`、`merkle`、`interest-week`。

**方法**

- 逐行复读全部合约和上面的链下脚本。
- 对照 R3 的每一项，用测试确认现状。
- 新发现的问题都写了复现测试。
- 跑了全量 Forge、覆盖率、JS 单测，以及 300 个账户的本地 Anvil 实跑。

**判定原则（项目方已确认）**

- 合约保持简单，工作尽量放到链下，只要不影响用户入金、直推实时提现和网体提现。
- Merkle root 只作为事后增信：社区用脚本核对，对不上时在链下解决，合约不阻拦。
- Owner 权限保留，在报告里列出，默认接受。

---

## 2. 测试与实测

| 项 | 结果 |
|----|------|
| `forge test` | 119 项通过，1 项跳过（SimMarket 大规模模拟，按设计跳过），0 失败 |
| JS 单测 `node --test scripts/lib/*.test.mjs` | 21 项通过 |
| 覆盖率（行 / 分支） | NemoIdo 88.6% / 41.5%；NemoRewards 100% / 53.9%；NemoNftInterest 98.5% / 64.3%；NemoToken 100% / 45.5%；NemoNFT 100% / 42.9%；合计 84.3% / 47.3% |
| 300 账户 Anvil 实跑（`scripts/scale-network.sh`） | 部署、299 笔入金、58 个账户有网体奖（合计 11,507.5U）、`publishRoot` 发布、多叶子 proof 领取 11U 成功。1000U 入金 gas 深链浅链都是 329,747 |
| Slither | 未运行（本机未安装） |
| BSC 测试网 / 主网 | 未广播 |

入金 gas 比 R3 时的 270,271 高了约 6 万，这是每笔入金多调用一次周息合约 `settle` 的开销（R5-I5）。

---

## 3. R3 问题的现状

每一项都用 `test/audit/AuditPoc.t.sol` 或 `AuditPocR5.t.sol` 核对过。

| R3 编号 | 问题 | 现状 | 证据 |
|---------|------|------|------|
| H-1 | Owner 立即换奖励地址，放掉网体准备金 | **已修。** 首次 `setRewards` 立即生效，之后必须 `proposeRewards`，等 `rewardsDelay`（本地 60 秒、测试网 1 小时、主网 24 小时）后 `acceptRewards`，期间可以 `cancelRewards`。延迟到期后 Owner 仍能换，列入 A-3 | `test_H1_setRewardsDrainsTeamReserve` |
| H-2 | 发布 root 要用 Owner 私钥 | **已修，但默认配置没用上。** 新增 `publisher`，Owner 可以另设。部署脚本没有另设，默认仍是 Owner；也没有设置增量上限。见 R5-M1 | `test_H2_rootPublisherIsFullOwner`，`test_R5_M1_*` |
| M-1 | 待生效 root 没有准备金 | **结构上已消除。** root 发布即生效，`outstanding` 立刻计入准备金。链下已算出、尚未发布的网体奖仍没有链上准备金，列入 A-1 | `test_M1_pendingRootIsUnfunded` |
| M-2 | `cumulative` 由发布者申报，合约不核对 | **未改，已接受。** 由 `verify-root.mjs` 事后核对。列入 A-2 | `test_M2_underDeclaredCumulativeLeavesClaimsUnfunded` |
| M-3 | 每日提交重置 24 小时等待 | **已修。** 没有待生效状态 | `test_M3_republishStaysClaimable` |
| M-4 | 数据库不区分金库地址 | **已修。** 三张业务表主键含 `ido_address`，读写都带金库地址。见 R5-M2 | `scripts/lib/reward-db.test.mjs` |
| M-5 | 入金、周息、手动铸币共用 CAP | **部分缓解。** NFT 最多 1 万张，周息总额最多 5000 万枚，正常运营时发行量不会碰到 10 亿枚。Owner 手动铸币仍可铸满 CAP，届时入金和领息都会失败，列入 A-6 | `test_M5_*`，`test_L4_*` |
| L-1 | 直推调到 25% 时网体奖没有额度 | 未改，属于参数选择，列入 A-4 | `test_L1_directAtCapStarvesTeam` |
| L-2 | 链上挑战由 Owner 裁决 | **已删除。** 没有押金挑战 | `test_L2_noOnChainChallenge` |
| L-3 | 暂停挡不住网体提现 | **已修。** `disburse` 加了 `whenNotPaused` | `test_L3_pauseStopsTeamClaims` |
| L-4 | CAP 满后入金全部失败 | 同 M-5 | `test_L4_tokenCapBlocksDeposits` |
| L-5 | 发布脚本失败时的提示 | 已处理：缺少环境变量时只打印说明 | 代码复读 |
| L-6 | 索引器没有起始区块、分段检查点和并发锁 | **已修。** `START_BLOCK`、每段写检查点、`pg_try_advisory_lock`。见 R5-L5 | `planChunk` 测试 |
| L-7 | 先发交易、后写 proof | **已修。** 先写未生效 proof，核对 publisher 后再上链。见 R5-L6 | `publish-root.mjs` |
| L-8 | 补发 NFT 无上限、NFT 铸币地址可换 | **已修。** 补发不得超过导入张数；`setMinter` 只能调一次 | `test_L8_*` |
| L-9 | 第一次关售就永久停息 | **已修。** 停息改由 `endIdo()` 负责 | `test_L9_*` |
| L-10 | 主网开售前就开始计息 | **已修。** 第一次 `openSale` 才开始计息 | `test_L10_*` |
| I-8 | `disburse` 的 bool 参数是死代码 | **已删除** | 接口复读 |
| I-11 | 周末最后一个区块买入可拿整周利息 | 未改，已写入功能报告。见 R5-L4 的说明 | `test_I11_lastBlockPurchaseEarnsTheWholeWeek` |

---

## 4. 发现

### R5-M1 发布私钥泄露时，可以立即领到 25% 帽（中）

**位置：** `NemoRewards.publishRoot`、`NemoRewards.claim`、`script/Deploy.s.sol`

**现象：** root 发布后立即生效，领取时只核对 proof 和 25% 帽。构造函数把 `publisher` 设为 `initialOwner`，`maxRootIncrease` 默认为 0，也就是不限单次增量。部署脚本两项都没有改。

所以拿到 publisher 私钥的人可以这样做：

1. 发布一棵只有一片叶子 `(自己, 额度)` 的树，额度取 `rewardCap − totalDirectAccrued`。
2. 在同一个区块里调用 `claim`，领走全部额度。

复现用的不是「这笔入金按规则该发多少」，而是「合约允许一次领走的上限」。Bob 入金 10,000U、上级是 Alice：直推是 10% × 10,000 = 1,000U，记给 Alice。25% 帽是 2,500U，扣掉这 1,000U 还剩 1,500U。泄露的 publisher 可以发布一棵只有自己一片叶子的树，在同一区块领走这 1,500U（`test_R5_M1_leakedPublisherDrainsToCap`）。按极差规则，这笔入金本身的网体奖是 0：入金者自己的档位不参与，上级在这笔入金之前的资格也是 0。10,000U 只是让 Alice 的伞下业绩达到 1 万，她对**之后**下级的入金才有 7% 资格。设置 `setMaxRootIncrease(100U)` 后，同样的发布会报 `IncreaseTooLarge`（`test_R5_M1_maxRootIncreaseBoundsLeak`）。

**影响：** 损失上限是全站入金的 25% 减去已发的直推和网体奖。这部分钱本来就是给网体奖预留的，所以直推准备金和用户本金不受影响，但会挤掉真实用户的网体奖额度。

发布在本地电脑上执行，泄露面比服务器小，但本地电脑也会中木马或丢失。

**为什么不算「已接受的 Owner 权限」：** 把 publisher 从 Owner 里拆出来，正是为了让它成为权限更低的钥匙。在不设上限时，这把钥匙对网体额度的控制力和 Owner 一样。

**建议（都不用改合约）：**

- 部署后用一个专用地址调用 `setPublisher`，不要继续用 Owner。
- 按预计的每期网体奖设置 `setMaxRootIncrease`，例如上一期增量的 1.5–2 倍，或一个固定值。某一期确实超出时，Owner 可以先临时调高上限。
- Owner 转给多签后，publisher 泄露时由多签调用 `setPublisher` 换钥匙，必要时 `pause`。
- 部署脚本可以从环境变量读取 `PUBLISHER` 和 `MAX_ROOT_INCREASE` 并直接设置，省得漏做。

### R5-M2 链下数据库不区分部署（已修）

**位置：** `scripts/lib/reward-db.mjs`

账户、root、proof 三张表的主键都包含 `ido_address`。索引和发布按金库地址读写。已经存在的旧表会在启动时补上这一列并更换主键。还没有连接真实 Postgres 跑通「建表 → 索引 → 预览 → 发布」。

### R5-L1 NFT 达到 1 万张后，跨档入金整笔失败（低）

**位置：** `NemoIdo._syncNfts`、`NemoIdo.importVolumes`

**现象：** `nftsAllocated + 新增张数 > nftCap` 时整笔回滚，USDT 不收，NEMOKEY 也不铸。导入的历史张数也占用这 1 万张的额度。

复现：导入 9,999 张后，1000U 入金失败；500U 入金成功，总数到 1 万张；此后的入金只要让本人累计金额跨过下一个 500U 整数，就会失败（`test_R5_L1_nftCapRevertsWholeDeposit`）。

**影响：** 1 万张对应约 500 万 U，高于 300 万 U 的目标，正常情况下碰不到。一旦碰到，用户看到的是入金失败，而不是「入金成功，但不再发 NFT」。

**建议：** 前端在剩余额度不足时提示。若希望额度用完后仍然接受入金，可以把 `_syncNfts` 改成超出部分不铸。这是业务选择，当前行为也符合「上限 1 万张」的要求。

### R5-L2 `endIdo` 只停周息，不停入金（低）

**位置：** `NemoIdo.endIdo`

**现象：** `endIdo` 设置 `idoEnded` 和 `idoEndedWeek`，但不修改 `saleOpen`。结束以后，入金照常收 USDT、铸 NEMOKEY 和 NFT、记直推，只是不再计周息（`test_R5_L2_endIdoLeavesSaleOpen`）。

**影响：** 管理员以为「结束 IDO」就停止了入金，实际上还没有停。

**建议：** 操作手册写明先 `closeSale` 再 `endIdo`；或者在 `endIdo` 里顺带执行 `saleOpen = false`，只需一行。

### R5-L3 金库暂停挡不住周息领取（低）

**位置：** `NemoNftInterest.claim`

**现象：** 周息领取不检查金库的 `paused()`。金库暂停时仍然可以领周息（`test_R5_L3_interestClaimIgnoresPause`）。NEMOKEY 合约自己暂停时铸币会失败，所以暂停代币才能挡住周息领取。

**影响：** 应急时如果只暂停金库，周息仍然会继续铸出。

**建议：** 应急手册写明要同时暂停金库和代币；或者在 `claim` 里加一行 `if (vault.paused()) revert`。

### R5-L4 全站上限截掉的利息直接作废，并且先到先得（低）

**位置：** `NemoNftInterest._capExtra`、`_settle`

**现象：** 结算时把本次利息压到剩余全站额度以内，被截掉的部分不留存，`settledThrough` 照样推进。上限用满以后，谁先结算谁拿到额度，后结算的人那几周是 0。之后即使 Owner 调高上限，也补不回已经结算过的周（`test_R5_L4_clippedInterestIsLost`）。

**影响：** 按默认参数，5000 万枚上限对应约 1,667 万 U 的持仓领一周 3%。按 300 万 U 目标、IDO 期间几个月估算，碰到上限的可能性不大。

同一原因下还有一个情况（R3 的 I-11）：周六 23:59 买入的 NFT 当周整周计息。本金不能退，所以这最多只是多拿一周利息。

**建议：** 前端显示剩余全站额度。如果希望公平分摊，需要改成按周快照，合约会复杂很多，不建议本期改。

### R5-L5 索引器没有起始区块、分段检查点和并发锁（已修）

**位置：** `scripts/index-rewards.mjs`

没有检查点时从 `START_BLOCK` 开始（默认 0）。每 `CHUNK_BLOCKS` 个区块（默认 2000）写一次检查点和账户。索引和发布共用 `pg_try_advisory_lock`，另一份进程在跑时本次直接跳过。

### R5-L6 先上链、后写 proof，并且私钥变量名不一致（已修）

**位置：** `scripts/publish-root.mjs`

先把 root 和 proof 写成未生效，再发 `publishRoot`，交易成功后才标成生效。写库失败就不会发交易。脚本只读 `PUBLISHER_PRIVATE_KEY`；如果环境里还有 `PRIVATE_KEY`，直接退出。发交易前核对私钥地址等于链上 `publisher()`。

### R5-I1 修改兑换比例后，周息要等下一版档位才跟着变（提示）

`setTiers` 把当时的 `tokensPerUsdt` 记进版本。之后只调用 `setTokensPerUsdt` 时，周息本金仍按旧比例计算（`test_R5_I1_rateChangeNeedsNewTierVersion`）。这是有意的设计，已写入功能报告；改比例后记得在同一周再调用一次 `setTiers`。

### R5-I2 单户上限按「当前张数 × 最新比例」计算（提示）

单户上限等于 `当前 NFT 张数 × 500U × 最新版本比例 × accountCapBps`，而不是历史每周本金的加总。NFT 不能转出，张数只增不减，所以这个上限只会变大。按默认参数，每周 3% 大约 34 周才会碰到 100%。

### R5-I3 版本数没有硬上限（提示）

每周最多新增一个档位版本，同一周内修改会覆盖。结算时对每个版本循环一次，每次都是读存储。按周计，即使运行几年，版本数也只有几百个，结算成本可以接受。

### R5-I4 导入的业绩不计入 25% 帽的分母（提示）

`importVolumes` 只写本人业绩，不增加 `totalContributed`。因此历史业绩不会扩大 25% 帽的额度，链下计算也不为导入业绩产生网体奖。这个口径和功能报告一致，请业务方确认。

### R5-I5 每笔入金多一次外部调用（提示）

`_contribute` 在铸 NFT 前调用 `NemoNftInterest.settle`，1000U 入金的 gas 从约 27 万增加到约 33 万。按 BSC 的 gas 价格，费用可以接受。

### R5-I6 部署脚本没有设置 publisher 和增量上限（提示）

`Deploy.s.sol` 只在 Owner 就是广播账户时，才自动调用 `setRewards` 和 `setNftInterest`。publisher 和 `maxRootIncrease` 都没有设置，需要人工补。见 R5-M1。

### R5-I7 旧测试名称没有同步更新（提示）

`AuditPoc.t.sol` 里的 `test_H2_rootPublisherIsFullOwner`、`test_M1_pendingRootIsUnfunded`、`test_L8_grantNftIsUnbounded`、`test_L9_firstCloseSaleEndsInterestForever` 仍用 R3 时的名字，测试内容已经改为验证修复后的行为。建议后续改名，以免误读。

---

## 5. 已知并接受（Owner 权限，不作为阻断项）

以下都是 Owner 或利息合约 Owner 的运营权限。项目方已确认保留。建议上线前把各合约的 Owner 转给多签，并在前端或文档里公开这份清单。

| 编号 | 权限 | 最坏情况 | 缓解 |
|------|------|----------|------|
| A-1 | `withdrawTreasury` 提取「余额 − 直推准备金 − 已发布但未领的网体奖」 | 链下已算出、尚未发布的网体奖可能被提前提走，发布后领取失败 | 每期发布前核对金库余额；多签 |
| A-2 | `publishRoot` 申报的累计额合约不核对，Owner 也可以发布 | 少报时，部分用户领不到；多报时，只受 25% 帽约束 | `verify-root.mjs` 公开核对；设置 `maxRootIncrease` |
| A-3 | 延迟到期后仍可更换奖励合约 | 新地址可调用 `disburse`，最多拿走直推准备金以外的余额 | 延迟期内社区可以看到 `RewardsProposed` 事件；多签 |
| A-4 | `setDirectReferralBps` 最高 2500 | 直推用满 25% 时，网体奖没有额度 | 参数公开 |
| A-5 | `setTokensPerUsdt` / `setNemoSchedule` / `setNemoBonus` | 改变之后入金得到的 NEMOKEY 数量 | 事件公开 |
| A-6 | NEMOKEY Owner 可以直接铸币，最多到 CAP | 铸满后入金和领息全部失败（M-5 / L-4） | 只用于早期用户本金；多签 |
| A-7 | `setTiers` 单档每周最高 10%；`setInterestCap`（≤ 5000 万）；`setAccountCapBps`（≤ 100%） | 提高未来的周息，或者下调上限使未结算的利息变少 | 已结束的周不能改；两个上限都不能调高到默认值以上 |
| A-8 | `pause` / `unpause` | 暂停期间无法入金、领直推、领网体奖 | 多签 |
| A-9 | 导入数据（用户、上级、业绩） | 导入错误会影响邀请关系、NFT 额度和补发上限 | 冻结后不能再导入；导入对照表公开 |
| A-10 | `grantNft`（不超过导入张数） | 补发时机影响起算周 | 补发上限是导入张数 |
| A-11 | `endIdo` / `closeSale` / `withdrawUnsoldNemo` | 结束时机影响周息的周数 | 事件公开 |

**「非准备金」的链上算法**（回答此前的问题）：

```
treasuryWithdrawable = 金库 USDT 余额
                     − directReserve         （totalDirectAccrued − totalClaimed）
                     − rewards.outstanding() （committed − totalTeamPaid）
```

---

## 6. 资金不变量（已核对）

1. `disburse` 只锁定直推准备金。只要 `余额 ≥ directReserve + 本次金额`，网体付款就能成功；直推准备金永远不会被网体付款或 Owner 提取占用。
2. `withdrawTreasury` 最多提取 `treasuryWithdrawable`，所以已发布而未领取的网体奖也受保护。
3. `totalDirectAccrued + totalTeamPaid ≤ totalContributed × 25%`：每次 `publishRoot` 和 `claim` 都检查，常量不可改。
4. 每个地址的网体累计领取额只增不减：领取要求 `cumulative ≥ claimed`，同一片叶子第二次领取报 `NothingToClaim`。
5. NFT 总张数 ≤ `nftCap`（1 万），包括导入占用的张数；补发 ≤ 导入张数。
6. 周息总额 ≤ `interestCap`（≤ 5000 万枚）；单户终身周息 ≤ 本人 NFT 本金 × `accountCapBps`。
7. 周息只计 `startWeek`（首次开售的那一周）到 `idoEndedWeek`（`endIdo` 所在周的下一周）之间的周；已经结束的周不会被后来的张数或参数改写。
8. 邀请树不会成环：已经有下级的地址不能再绑定上级。

Forge 的不变量测试 `NemoIdo.invariant.t.sol` 覆盖直推准备金、`余额 = 可提 + 准备金` 和 NEMOKEY 不超过 CAP，但不变量测试里没有挂奖励合约和周息合约。第 3–7 条目前靠单元测试和复现测试覆盖，建议把两者接入不变量测试。

---

## 7. 上线前清单

**必须**

- [ ] 外部审计。
- [ ] 部署后 `setPublisher(专用地址)`，并 `setMaxRootIncrease(合理值)`（R5-M1）。
- [ ] 连真实 Postgres 跑通「建表 → 索引 → 预览 → 发布 → verify-root」。表结构已按金库地址区分（R5-M2）。
- [ ] BSC 测试网完整跑一轮，包括 `proposeRewards` → 等 1 小时 → `acceptRewards`，以及 `endIdo`。
- [ ] 所有合约的 Owner 转给多签，新 Owner 执行 `acceptOwnership`。

**建议**

- [x] 发布脚本先写库后发交易，并统一私钥变量名（R5-L6）。
- [x] 索引器加起始区块、分段检查点和锁（R5-L5）。
- [ ] 在操作手册里写明：先 `closeSale` 再 `endIdo`；应急时同时暂停金库和代币（R5-L2、R5-L3）。
- [ ] 安装并运行 Slither，处理新增告警。
- [ ] 补充 revert 分支测试，当前分支覆盖率 47%。

---

## 8. 雷迪森（约 3000 万 U）RWA 的建议

建议新部署一套金库、NFT 和周息合约，不要沿用本期金库。理由：

- 本期金库的 NFT 上限、25% 帽分母和周息起止周都是按本期设定的，混在一起会让两期的额度互相挤占。
- 分开以后，两期的准备金、root 和数据库互不影响，审计范围也清楚。
- 邀请关系可以在用户第一次操作新金库时，从本期金库公开的 `referrerOf` 继承，不必重新导入。本期没有实现这段继承代码。

前提是先完成 R5-M2：数据库按金库地址区分，否则两期共用一个库会混账。
