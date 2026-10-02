# nemoido 安全审计报告（第六版，链下修复后全面复审）

日期：2026-09-24  
代码状态：提交 `11e8efd` 加上工作区全部未提交改动（分支 `localdev`）  
取代：[SECURITY-AUDIT-2026-09-24-R5.md](SECURITY-AUDIT-2026-09-24-R5.md)。R5、R4、R3、R2 和第一版保留为历史  
配套功能报告：[FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)  
复现测试：`test/audit/AuditPoc.t.sol`（R3）、`test/audit/AuditPocR5.t.sol`（R5）  
端到端脚本：`scripts/e2e-postgres.sh`（真实 Postgres + Anvil）

---

## 0. 结论

没有高危问题。资金路径上没有发现能让普通用户多领、少付或卡死金库的漏洞。

本轮相对 R5 的变化：

1. **R5 的三项链下问题已修，并在真实 Postgres 上跑通。** 数据库按金库地址区分；索引器支持起始区块、分段检查点和并发锁；发布时先写库再上链。第一次用 Docker 起了真实 Postgres，从部署一路跑到领取和核对，此前这一步一直没有做。
2. **本轮新发现三项，都已修好。**
   - 发布脚本不生成社区核对用的公开明细文件。
   - 重复发布同一个 root 时，数据库里当前生效的那期会被改成未生效。
   - 修改两个周息上限时不发事件。
3. **第一次对当前代码跑了 Slither。** 共 31 条，没有真实的高危或中危，详见第 4 节。
4. **仍需上线前处理的只有一项中危（R6-M1）。** publisher 默认等于 Owner，单次增量上限默认不限，部署脚本两项都没有设置。只需在部署后配置，合约不用改。

| 等级 | 未处理 | 本轮已修 |
|------|--------|----------|
| 高 | 0 | — |
| 中 | 1（R6-M1） | — |
| 低 | 3（R6-L2 至 R6-L4，合约行为，业务可接受） | 4（R6-F1 至 R6-F3，R6-L1） |
| 提示 | 11（R6-I1 至 R6-I11） | — |
| 已知并接受（Owner 权限） | 11（A-1 至 A-11） | — |

主网上线仍需要外部审计。本轮没有广播测试网或主网。

---

## 1. 范围与方法

**合约**（相对 R5，只有 `NemoNftInterest` 增加了两个事件）

| 文件 | 说明 |
|------|------|
| `src/NemoIdo.sol` | 金库：入金、邀请、直推、铸币、导入、补发 NFT、奖励地址延迟切换、结束 IDO |
| `src/NemoRewards.sol` | 网体奖累计 Merkle root，发布即生效 |
| `src/NemoNftInterest.sol` | NFT 周息，按周分版本，全站和单户上限 |
| `src/NemoToken.sol` | NEMOKEY，CAP 10 亿枚，默认不可转 |
| `src/NemoNFT.sol` | 灵魂绑定 NFT，铸币地址只能设一次 |
| `src/network/NemoNetworks.sol` | 三套网络参数 |
| `src/INemoRewards.sol`、`src/INemoNftInterest.sol` | 接口 |
| `script/Deploy.s.sol` | 部署脚本 |

**链下：** `scripts/index-rewards.mjs`、`scripts/publish-root.mjs`、`scripts/verify-root.mjs`、`scripts/lock-interest-boundary.mjs`、`scripts/e2e-postgres.sh`，以及 `scripts/lib/` 下的 `reward-db`、`reward-index`、`team-reward`、`merkle`、`interest-week`。

**方法**

- 逐行复读本轮改动的链下代码，复核全部合约。
- 全量 Forge、覆盖率、JS 单测。
- 真实 Postgres + Anvil 端到端测试。
- Slither 0.11.6（Python 3.12，排除 `lib`、`test`、`script`）。
- 核对 R5 每一项的现状。

**判定原则（项目方已确认）**

- 合约保持简单，工作尽量放到链下，只要不影响用户入金、直推实时提现和网体提现。
- Merkle root 是事后增信：社区用脚本核对，对不上时在链下解决，合约不阻拦。
- Owner 权限保留，列出即可，默认接受。

---

## 2. 测试与实测

| 项 | 结果 |
|----|------|
| `forge test` | 120 项通过，1 项跳过（SimMarket 大规模模拟，按设计跳过），0 失败 |
| JS 单测 `npm run test:js` | 21 项通过（新增：先入金 1 万再直推 1000U 得 100U 直推 + 70U 网体、分段扫描区间、表主键含金库地址、锁键稳定） |
| 覆盖率（行 / 分支） | NemoIdo 88.7% / 41.5%；NemoRewards 100% / 53.9%；NemoNftInterest 98.5% / 64.3%；NemoToken 100% / 45.5%；NemoNFT 100% / 42.9%；合计 84.5% / 47.6% |
| 300 账户 Anvil 实跑 | 299 笔入金、58 个账户有网体奖（合计 11,507.5U）；1000U 入金 gas 深链浅链都是 329,747 |
| **真实 Postgres 端到端**（`scripts/e2e-postgres.sh`，本轮新增） | 见下表，全部符合预期 |
| Slither | 31 条：1 高（误报）、8 中（均不构成问题）、18 低、4 提示。见第 4 节 |
| BSC 测试网 / 主网 | 未广播 |

**端到端测试的步骤和结果**

| 步骤 | 结果 |
|------|------|
| 预先建一张 R5 之前的旧表，并写入一行旧数据 | 启动时自动补上 `ido_address` 列，主键改为 `chain_id, ido_address, wallet` |
| 索引（`START_BLOCK=0`，`CHUNK_BLOCKS=100`） | 600 条日志，写到区块 1206；本金库 300 个账户，旧数据那一行被隔离（`ido_address = ''`） |
| 再次索引 | 提示已追上，不重复记账 |
| 环境里同时设置 `PRIVATE_KEY` | 拒绝发布，proof 不写库 |
| 用非 publisher 私钥发布 | 报「不是 publisher」，不发交易 |
| 正常发布 | 58 片叶子；先写未生效 proof 和公开明细文件，交易成功后才标成生效 |
| `verify-root` 核对公开文件 | 通过 |
| 重复发布同一个 root | 仍然只有 1 期生效（修 R6-F2 之前会变成 0 期） |
| 公开文件里改一个金额（+1 wei） | 核对失败，退出码 1 |
| 用数据库里的 6 层 proof 领取（一个没领过的地址） | 领到 6U；链上 `claimed` 和库里的 `claimed_wei` 都是 6U |
| 已领过的地址再领 | 合约报 `NothingToClaim` |
| 另一个连接先持有锁，再启动索引 | 本次跳过 |

---

## 3. R5 问题的现状

| R5 编号 | 问题 | 现状 |
|---------|------|------|
| R5-M1 | 发布私钥泄露时可以立即领到 25% 帽 | **未改**，即本版 R6-M1 |
| R5-M2 | 数据库不区分部署 | **已修，已在真实 Postgres 验证。** 旧表自动迁移 |
| R5-L1 | NFT 满 1 万张后跨档入金整笔失败 | **已改：入金不再回滚。** 达到上限后按剩余额度铸满，超出记为待发，见 R6-L1 |
| R5-L2 | `endIdo` 不停入金 | 未改，即 R6-L2 |
| R5-L3 | 金库暂停挡不住周息领取 | 未改，即 R6-L3 |
| R5-L4 | 全站上限截掉的利息作废 | 未改，即 R6-L4 |
| R5-L5 | 索引器没有起始区块、分段检查点和锁 | **已修，已验证** |
| R5-L6 | 先上链后写 proof；私钥变量名不一致 | **已修，已验证** |
| R5-I1 至 I7 | 提示 | 保留为 R6-I1 至 I7 |

R3 各项的现状见 R5 第 3 节，本轮没有变化。

---

## 4. Slither 结果分析

命令：`uvx --python 3.12 --from slither-analyzer slither . --config-file slither.config.json --json slither-report.json`。仓库里原来的 `slither-report.json` 是 9 月 3 日针对旧代码生成的，不含奖励合约和周息合约，已用本次结果替换。这个文件在 `.gitignore` 里，只保存在本地。

| 检测项 | 数量 | 判断 |
|--------|------|------|
| uninitialized-state（高）：`versionTiers` 从未初始化 | 1 | **误报。** 构造函数和 `setTiers` 都通过 `_writeTiers` 用 `push` 写入。Slither 不识别对映射内数组的 `push`。周息测试覆盖了读取 |
| divide-before-multiply（中）：`quote`、`_preview`、`_capExtra` | 3 | **不损失精度。** 周息本金 = `张数 × 500e18 × 100e18 / 1e18`，比例是 100e18，正好整除。`quote` 的向上取整只用于显示 |
| incorrect-equality（中）：`== 0` 等 | 5 | 都是判断「是否设置过」或「是否为零」，不依赖余额，不能被操纵 |
| events-maths（低）：两个上限修改不发事件 | 2 | **已修（R6-F3）** |
| calls-loop（低）：`_preview` 在循环里读 `vault.NFT_UNIT()` | 3 | 调用的是自己部署的金库常量，不会失败；版本数有限（R6-I3） |
| reentrancy-benign / reentrancy-events（低） | 4 | 外部调用对象都是自己部署的合约（NEMOKEY、周息合约），并且有重入锁。可以接受 |
| timestamp（低） | 11 | 周的划分和延迟本来就按区块时间。BSC 出块者只能微调几秒，影响不到按周或按小时的判断 |
| costly-loop、missing-inheritance（提示） | 4 | `_writeTiers` 清空旧档位最多 16 次；接口没有显式继承，不影响行为 |

---

## 5. 发现

### R6-M1 发布私钥泄露时，可以立即领到 25% 帽（中，即 R5-M1，未改）

**位置：** `NemoRewards.publishRoot` / `claim`、`script/Deploy.s.sol`

root 发布即生效，领取时只核对 proof 和 25% 帽。构造函数把 `publisher` 设为 Owner，`maxRootIncrease` 默认为 0（不限），部署脚本两项都没改。

拿到发布私钥的人可以发布一棵只有自己一片叶子的树，额度取「25% 帽 − 已记直推 − 已付网体奖」，然后在同一个区块里领走。例如 Bob 入金 10,000U，直推 1,000U 记给 Alice，25% 帽是 2,500U，攻击者一次领走剩下的 1,500U（`test_R5_M1_leakedPublisherDrainsToCap`）。

这 1,500U 是合约允许的上限，不是这笔入金应发的网体奖。按极差规则，这笔入金的网体奖是 0：上级当时的资格还是 0。

设置 `setMaxRootIncrease(100U)` 后，同样的发布会失败（`test_R5_M1_maxRootIncreaseBoundsLeak`）。

**影响：** 直推准备金和用户本金不受影响，但真实用户的网体奖额度会被挤掉。发布脚本现在会核对私钥必须等于链上 `publisher()`，这能防止拿错钥匙，防不了钥匙被盗。

**建议（不用改合约）：**

- 部署后用专用地址调用 `setPublisher`。
- 按每期预计网体奖设置 `setMaxRootIncrease`，例如上一期增量的 1.5–2 倍。
- 可以让部署脚本从环境变量读取 `PUBLISHER` 和 `MAX_ROOT_INCREASE` 并直接设置。

### R6-L1 NFT 满 1 万张后，入金不再回滚，超出部分记为待发（低，改自 R5-L1）

**位置：** `NemoIdo._syncNfts`、`nftDeferred`

**原行为：** `nftsAllocated + 新增张数 > nftCap` 时整笔回滚，用户在上限满了以后无法入金。

**现行为：** 达到上限后，`_syncNfts` 先把本期剩余额度铸满，超出的张数不铸，`nftMinted` 只加实际铸出的数量，并发出 `NftDeferred(账户, 张数)`。入金的 USDT 照常入库，NEMOKEY、直推、网体奖都不受影响。待发张数是 `selfVolume / 500 − nftMinted`，用只读函数 `nftDeferred(账户)` 读取，不需要新存储。待发的 NFT 在本期不存在，因此本期不计周息。

复现：导入 9,999 张占满额度后，Alice 入金 1,000U，铸出 1 张、记 1 张待发，1,000U 入库，上级照常拿到 100U 直推，Alice 拿到 10 万枚 NEMOKEY（`test_R5_L1_nftCapDefersInsteadOfReverting`）；导入满 1 万张后再入金，全部记为待发且不计息（`test_R5_L1_deferredNftsEarnNoInterest`）。在本地 Anvil 上也实测通过，`export-deferred-nfts.mjs` 正确导出了这份名单。

**过渡到下一期的流程：**

1. 接近上限时前端提示，同时部署并测试下一期合约。
2. 达到上限后入金照常，超出的 NFT 自动记为待发。
3. 下一期就绪后，前端把入金入口切到新金库，本期 `closeSale` 再 `endIdo`。
4. 在 `closeSale` 的区块跑 `npm run export:deferred`（`export-deferred-nfts.mjs`）导出待发名单，公开这份文件；在下一期冻结导入之前导入地址、邀请码、上级，再用 `grantNft` 补发这些 NFT。

**说明：** 过渡期入金的 USDT 留在本期金库，直推和网体奖也按本期规则结算。下一期只继承 NFT 权益和邀请关系，不重复发奖（现有导入逻辑本来就只写业绩、不发奖）。若要把这部分资金用于下一期，由 Owner 通过 `withdrawTreasury` 提取非准备金，属于已接受的权限，建议在迁移名单里一并公示。

### R6-L2 `endIdo` 只停周息，不停入金（低，即 R5-L2）

结束以后仍然可以入金，照常铸 NEMOKEY、NFT 和直推，只是不再计息（`test_R5_L2_endIdoLeavesSaleOpen`）。建议操作手册写明先 `closeSale` 再 `endIdo`，或者在 `endIdo` 里加一行 `saleOpen = false`。

### R6-L3 金库暂停挡不住周息领取（低，即 R5-L3）

周息 `claim` 不检查金库的暂停状态（`test_R5_L3_interestClaimIgnoresPause`）。暂停 NEMOKEY 才能挡住。建议应急时两者一起暂停，或者在 `claim` 里加一行检查。

### R6-L4 全站上限截掉的利息作废，先到先得（低，即 R5-L4）

利息超出剩余全站额度的部分不留存，之后调高上限也补不回来（`test_R5_L4_clippedInterestIsLost`）。按 300 万 U 目标估算，碰到 5000 万枚上限的可能性不大。

### R6-F1 发布脚本不生成公开明细（本轮发现，已修）

**位置：** `scripts/publish-root.mjs`

**问题：** `verify-root.mjs` 需要一份 `{root, contentHash, entries}` 的 JSON，但发布脚本不输出这个文件。社区核对这一步实际上没有输入。

**修复：** 发布时，在发交易之前把明细写到 `roots/<链>-<金库>-<root>.json`，目录可用 `PUBLIC_DIR` 修改。`roots/` 已加入 `.gitignore`。端到端测试确认这份文件能通过 `verify-root`，改动 1 wei 就会失败。

### R6-F2 重复发布同一个 root 时，生效标记被清掉（本轮发现，已修）

**位置：** `scripts/lib/reward-db.mjs` 的 `saveRoot`

**问题：** 为修 R5-L6，发布前先按「未生效」写一次 root。如果新 root 和当前生效的 root 相同（例如只是补发、或者这一周没有新网体奖），这次写入会把当前那期也改成未生效。交易确认之前，前端查不到任何生效的 proof；如果交易失败，这个状态会一直保留。

**修复：** 更新时用 `active = 新值 OR 原值`，只有新的一期生效时，才把其他期改成未生效。端到端测试确认重复发布后仍然只有 1 期生效。

### R6-F3 修改周息上限不发事件（本轮发现，已修）

**位置：** `NemoNftInterest.setInterestCap`、`setAccountCapBps`（Slither events-maths）

**问题：** Owner 下调两个上限会直接减少用户未结算的利息，但链上没有事件，社区很难发现。

**修复：** 增加 `InterestCapUpdated`、`AccountCapBpsUpdated` 两个事件，测试用 `expectEmit` 验证。

### 提示

| 编号 | 内容 |
|------|------|
| R6-I1 | 修改 `tokensPerUsdt` 后，周息要等下一版档位才跟着变。改比例后在同一周调用一次 `setTiers`（`test_R5_I1_*`） |
| R6-I2 | 单户上限按「当前张数 × 最新比例」计算。NFT 只增不减，上限只会变大；默认每周 3% 约 34 周碰到 100% |
| R6-I3 | 档位版本数没有硬上限，但每周最多新增一个，几年也只有几百个 |
| R6-I4 | 导入的业绩不计入 25% 帽的分母，也不为导入业绩产生网体奖，请业务方确认 |
| R6-I5 | 每笔入金多调用一次周息 `settle`，1000U 入金 gas 约 33 万 |
| R6-I6 | 部署脚本不设置 publisher 和增量上限，见 R6-M1 |
| R6-I7 | `AuditPoc.t.sol` 里部分测试仍用 R3 时的名字，内容已改为验证修复后的行为 |
| R6-I8 | **旧表迁移后留下孤儿数据。** 迁移前的行，`ido_address` 被填成空字符串，不会被任何金库读到，也不会进 root。端到端测试里的那一行就是这样。建议上线前用新库，或者手动删掉 `ido_address = ''` 的行 |
| R6-I9 | **发布脚本拒绝 `PRIVATE_KEY`。** 部署时的终端通常设置了 `PRIVATE_KEY`，发布要换一个干净的终端，只设置 `PUBLISHER_PRIVATE_KEY` |
| R6-I10 | **索引器不处理区块重组。** 依靠确认数（主网默认 15 个区块，约 45 秒）。BSC 很少出现这么深的重组。如果出现，删掉最近的检查点重新索引即可 |
| R6-I11 | **每段都写全部账户。** 索引每写一次检查点，都会 upsert 全部账户。首次同步时，账户数 × 段数可能很大，例如 1 万账户 × 100 段 = 100 万次写入。可以调大 `CHUNK_BLOCKS`，或以后改成只写变动过的账户 |

---

## 6. 已知并接受（Owner 权限，不作为阻断项）

项目方已确认保留。建议上线前把各合约的 Owner 转给多签，并公开这份清单。

| 编号 | 权限 | 最坏情况 | 缓解 |
|------|------|----------|------|
| A-1 | `withdrawTreasury` 提取「余额 − 直推准备金 − 已发布未领的网体奖」 | 链下已算出、尚未发布的网体奖可能被提前提走 | 每期发布前核对金库余额；多签 |
| A-2 | `publishRoot` 申报的累计额合约不核对，Owner 也能发布 | 少报时，部分用户领不到；多报时，只受 25% 帽约束 | 公开明细 + `verify-root`；设置 `maxRootIncrease` |
| A-3 | 延迟到期后仍可更换奖励合约 | 新地址可以动用直推准备金以外的余额 | 延迟期内能看到 `RewardsProposed`；多签 |
| A-4 | `setDirectReferralBps` 最高 2500 | 直推用满 25% 时，网体奖没有额度 | 参数公开 |
| A-5 | `setTokensPerUsdt` / `setNemoSchedule` / `setNemoBonus` | 改变之后入金得到的 NEMOKEY 数量 | 事件公开 |
| A-6 | NEMOKEY Owner 可以直接铸币，最多到 CAP | 铸满后入金和领息都会失败 | 只用于早期用户本金；多签 |
| A-7 | `setTiers`（单档每周 ≤ 10%）、`setInterestCap`（≤ 5000 万）、`setAccountCapBps`（≤ 100%） | 提高未来周息，或者下调上限使未结算利息变少 | 已结束的周不能改；现在有事件 |
| A-8 | `pause` / `unpause` | 暂停期间无法入金和领奖 | 多签 |
| A-9 | 导入数据 | 导入错误会影响邀请关系和 NFT 额度 | 冻结后不能再导入；对照表公开 |
| A-10 | `grantNft`（不超过导入张数） | 补发时机影响起算周 | 上限是导入张数 |
| A-11 | `endIdo` / `closeSale` / `withdrawUnsoldNemo` | 结束时机影响周息周数 | 事件公开 |

非准备金的算法：`treasuryWithdrawable = USDT 余额 − (totalDirectAccrued − totalClaimed) − (committed − totalTeamPaid)`。

---

## 7. 资金不变量（已核对）

1. `disburse` 只锁定直推准备金；直推准备金永远不会被网体付款或 Owner 提取占用。
2. `withdrawTreasury` 不超过 `treasuryWithdrawable`，已发布未领的网体奖受保护。
3. `totalDirectAccrued + totalTeamPaid ≤ totalContributed × 25%`：每次 `publishRoot` 和 `claim` 都检查，常量。
4. 每个地址的网体累计领取额只增不减；同一片叶子第二次领取报 `NothingToClaim`（端到端测试已验证）。
5. NFT 铸出总张数 ≤ 1 万（含导入占用）；超出上限的部分记为待发（`nftDeferred`），不铸造、本期不计息；补发 ≤ 导入张数。
6. 周息总额 ≤ `interestCap`；单户终身周息 ≤ NFT 本金 × `accountCapBps`。
7. 周息只计首次开售那一周到 `endIdo` 那一周；已结束的周不会被改写。
8. 邀请树不会成环。
9. **链下：** 同一条链上的不同金库在数据库里互不影响；同一金库同一时间只有一个索引或发布进程；链上生效的 root，数据库里一定已有对应的 proof。

`NemoIdo.invariant.t.sol` 覆盖第 1、2 条和 NEMOKEY 不超过 CAP。第 3–7 条靠单元测试和复现测试覆盖，第 9 条靠端到端测试覆盖。

**关于除不尽的问题：** 网体奖和直推都用整数 wei 计算，`奖励 = 入金wei × 档位差 / 10000`，截断取整。整 U 入金时，3% / 5% / 7% / 9% / 10% 都能整除。发布、领取和 `verify-root` 用的都是同一个 wei 整数，不会因为小数导致核对失败。

---

## 8. 上线前清单

**必须**

- [ ] 外部审计。
- [ ] 部署后 `setPublisher(专用地址)`，并 `setMaxRootIncrease(合理值)`（R6-M1）。
- [ ] BSC 测试网完整跑一轮：部署、导入、开售、入金、发布、领取、`proposeRewards` → 等 1 小时 → `acceptRewards`、`closeSale` → `endIdo`。
- [ ] 所有合约的 Owner 转给多签，新 Owner 执行 `acceptOwnership`。
- [ ] 主网使用新的数据库，并设置 `START_BLOCK` 为金库部署区块（R6-I8）。

**建议**

- [x] 真实 Postgres 跑通「建表 → 索引 → 预览 → 发布 → verify-root → 领取」（本轮完成）。
- [x] 运行 Slither 并逐条处理（本轮完成）。
- [ ] 操作手册写明：先 `closeSale` 再 `endIdo`；应急时同时暂停金库和 NEMOKEY（R6-L2、R6-L3）。
- [ ] 把奖励合约和周息合约接入不变量测试；补 revert 分支测试（当前分支覆盖率 47%）。

---

## 9. 雷迪森（约 3000 万 U）RWA 的建议

建议新部署一套金库、NFT 和周息合约，不要沿用本期金库。本期的 NFT 上限、25% 帽分母和周息起止周都是按本期设定的，分开以后两期的准备金、root 和审计范围互不影响。

邀请关系和 NFT 权益可以在用户第一次操作新金库时继承，或者用 `npm run export:deferred` 导出的待发名单导入。本期达到 1 万张后超出的 NFT 就是通过这份名单在下一期补发的（R6-L1）。

数据库已经按金库地址区分，两期可以共用一个库。
