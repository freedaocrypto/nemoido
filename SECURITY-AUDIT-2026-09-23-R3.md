# nemoido 安全审计报告（第三版，加入 NFT 周息后）

> **历史版本。** 已被 [SECURITY-AUDIT-2026-09-24-R6.md](SECURITY-AUDIT-2026-09-24-R6.md) 取代，各项现状见 R5 第 3 节。下面的原文未改写。

日期：2026-09-23  
代码状态：提交 `11e8efd` 加上工作区未提交的改动（分支 `localdev`）。改动包括「每日 root、删除垫付、Postgres 实时索引」和「NFT 周息、早期用户补发 NFT、北京时间周界」  
取代：同日第二版 [SECURITY-AUDIT-2026-09-23-R2.md](SECURITY-AUDIT-2026-09-23-R2.md)。第二版和第一版 [SECURITY-AUDIT-2026-09-23.md](SECURITY-AUDIT-2026-09-23.md) 都保留为历史记录，没有改写  
配套功能报告：[FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)  
复现测试：`test/audit/AuditPoc.t.sol`，共 16 项，都按本报告描述的行为通过。修复后，对应的测试会变红

> 这是内部审计，不能替代主网上线前的外部审计。本次没有运行 Slither（本机没有安装），也没有向 BSC 测试网或主网广播。

---

## 1. 结论

| 等级 | 数量 | 编号 |
|------|------|------|
| 高 | 2 | H-1、H-2 |
| 中 | 5 | M-1 至 M-5 |
| 低 | 9 | L-1 至 L-3、L-5 至 L-10（L-4 已并入 M-5） |
| 提示 | 13 | I-1 至 I-13 |

**本版新增的 NFT 周息**

计息的主体逻辑没有发现算错钱的问题。已经测过的行为包括：

- 按周分段结算；
- 改档位不追溯已结束的周；
- 张数变化前先结清旧周；
- 关售后停止计息。

新问题集中在三处。

1. **M-5**：Nemokey 只有一个 10 亿枚上限，入金铸币、周息、管理员手动铸币共用这个额度。周息每周增加，没有预留额度。额度一旦用完，入金和领周息会同时失败。
2. **NFT 供应缺少约束（L-8）**：`grantNft` 没有上限，也不记录补发过多少张。NFT 合约的 Owner 还能换铸币地址，绕过金库直接铸造，之后结算时会把过去几周按新张数补算。NFT 是未来酒店分红的凭证，补发数量应该能在链上核对。
3. **计息开始和结束的时间点**：第一次关售会永久停止计息，重新开售也不恢复（L-9）。主网上，补发给早期用户的 NFT 在开售之前就开始计息（L-10）。在每周最后一个区块买入，也能拿到一整周的利息（I-11）。

**沿用上一版的结论**

用户资金的主要风险仍然在 Owner 权限上：

- **H-1**：Owner 可以随时换掉奖励合约地址，没有延迟；
- **H-2**：每日自动发布 root 需要 Owner 私钥常驻服务器。

每日发布流程和数据库的 M-3、M-4 也还没有修。

直推提现路径（`NemoIdo.claim`）仍然没有发现问题。

**上线建议**

- H-1、H-2、M-3、M-4、M-5 修复前，不要上主网。
- L-8 在补发早期用户 NFT 之前修掉。
- L-9、L-10 在主网部署前，由业务方确认口径，并写进合约或运维手册。

---

## 2. 范围与方法

**合约**

| 文件 | 说明 |
|------|------|
| `src/NemoIdo.sol` | 金库：注册、邀请、入金、直推、铸币、导入、提取。本版新增 `setNftInterest`、`grantNft`、`closeSale` 记录停息周、入金前结算周息 |
| `src/NemoNftInterest.sol` | **本版新增**：NFT 周息。档位按版本保存；按周结算；`claim` 时铸 Nemokey；主网按北京时间周日 0 点切周 |
| `src/INemoNftInterest.sol` | **本版新增**：金库调用的利息接口 |
| `src/NemoRewards.sol` | 网体奖：累计 Merkle root、timelock、挑战、领取 |
| `src/INemoRewards.sol` | 金库与奖励合约之间的接口 |
| `src/NemoToken.sol` | NEMOKEY：上限 10 亿枚，转账白名单。本版新增 `interestMinter` |
| `src/NemoNFT.sol` | 灵魂绑定 NFT |
| `src/network/NemoNetworks.sol` | 三套网络参数 |
| `script/Deploy.s.sol` | 按网络部署。本版加入利息合约和它的铸币权 |

**链下脚本**

| 文件 | 说明 |
|------|------|
| `scripts/index-rewards.mjs` | 读链上事件、重放极差、写入 Postgres |
| `scripts/lib/reward-index.mjs`、`reward-db.mjs` | 事件映射、建表、事务写入。本版新增 `nemo_interest_boundary` 表 |
| `scripts/lib/team-reward.mjs` | 极差加 6 万平级抽成的计算器 |
| `scripts/publish-root.mjs` | 组 Merkle 树、`submitRoot`、存 proof、`--activate` |
| `scripts/lock-interest-boundary.mjs`、`scripts/lib/interest-week.mjs` | **本版新增**：按区块时间二分查找北京时间周日 0 点的高度 N |

**方法**

- 逐行人工阅读。
- 能用测试证明的问题，都写了 Forge 复现。
- 重跑全部测试和覆盖率。

**测试结果**

Forge 109 项通过（不含跳过的 SimMarket），JS 16 项通过。

| 合约 | 行 | 语句 | 分支 | 函数 |
|------|----|------|------|------|
| NemoIdo | 89.6% | 79.8% | 45.1% | 90.0% |
| NemoNftInterest | 98.2% | 95.0% | 70.0% | 94.1% |
| NemoRewards | 96.6% | 86.2% | 36.0% | 92.3% |
| NemoToken | 100% | 86.1% | 45.5% | 100% |
| NemoNFT | 100% | 84.0% | 33.3% | 100% |

覆盖率是在加入本版 6 项复现之前统计的。

---

## 3. 高危

### H-1 `setRewards` 没有延迟，Owner 可以换掉奖励合约，提走当期网体准备金

**位置：** `NemoIdo.setRewards`（第 399 行）、`NemoIdo.disburse`（第 295 行）、`_teamOutstanding`（第 513 行）

**问题：** 金库把 `rewards` 地址当作唯一可信的付款方，准备金里的网体部分也直接读 `rewards.outstanding()`。Owner 一笔交易就能把这个地址换成自己的合约。新合约报告 `outstanding() = 0`，准备金就只剩直推部分，再通过 `disburse` 把其余余额全部转走。原奖励合约里已经生效的网体奖，用户去领时会报 `NotRewards`，领不出来。

**复现：** `test_H1_setRewardsDrainsTeamReserve`

**建议：** 二选一。

1. `rewards` 只能设置一次。`nftInterest` 已经是这样做的，可以照搬。
2. 换地址走 timelock，并且要求旧合约 `outstanding() == 0` 才能切换。

### H-2 每日自动发布 root，需要 Owner 私钥常驻服务器

**位置：** `NemoRewards.submitRoot`（第 93 行，`onlyOwner`）；`scripts/publish-root.mjs` 读取 `PRIVATE_KEY`

**问题：** 每 24 小时全自动发布 root，就要把能调用 `submitRoot` 的私钥放在定时任务服务器上。而合约里只有 Owner 能调用它。部署脚本默认用同一个 `OWNER`，这把钥匙同时还能：

- 提取金库余额；
- 更换奖励合约（H-1）；
- 调整周息档位（每档最高每周 10%）；
- 给任意地址补发 NFT（L-8）。

**复现：** `test_H2_rootPublisherIsFullOwner`

**建议：** 在 `NemoRewards` 增加一个只能调用 `submitRoot` 的 `publisher` 角色。其余 Owner 权限统一交给多签。

---

## 4. 中危

### M-1 待生效的 root 不计入准备金

在 timelock 期间，Owner 可以先把钱提走。root 生效后，用户领取会报 `InsufficientTreasury`。

**复现：** `test_M1_pendingRootIsUnfunded`

**建议：**
- `treasuryWithdrawable` 再扣掉待生效 root 的增量；
- `publish-root.mjs --apply` 在提交前检查金库余额是否足够。

### M-2 root 的 `cumulative` 由 Owner 申报，和叶子合计之间没有链上约束

少报会缩小准备金，Owner 就能提走本该锁定的钱。

**复现：** `test_M2_underDeclaredCumulativeLeavesClaimsUnfunded`

**建议：** 公开每期 root 的叶子明细，让外部可以核对合计金额。挑战期内发现不一致，任何人都可以提出挑战。

### M-3 每天提交新 root 会覆盖待生效的 root，并重新开始计时

主网的 timelock 和发布间隔都是 24 小时。只要某天提交得稍早，或者重复运行一次，这一期就要多等 24 小时；每天都早一点的话，网体奖可能永远无法生效。

**复现：** `test_M3_dailySubmitResetsPendingTimer`

**建议：**
- 脚本先读 `pendingRoot`：已到期就先激活，未到期就停止；
- 或者合约里在已有待生效 root 时拒绝新的提交。

### M-4 Postgres 表不区分合约部署，重新部署后新旧数据会混在一起

账户表、root 表、proof 表的主键都只有 `chain_id`。同一条链上重新部署金库以后，旧数据会叠加进新部署，导致网体奖多发或发错人。修 H-1、H-2 就需要重新部署，所以这个问题一定会遇到。本版新增的 `nemo_interest_boundary` 按 `chain_id + week` 存储，同样不区分部署；不过周界只由时间决定，混用的影响不大。

**建议：** 所有 `nemo_` 表加 `ido_address` 列，并放进主键；检查点记录区块哈希。

### M-5 入金、周息、手动铸币共用 10 亿枚上限，额度用完后入金和领周息都会失败（本版新增，并入原 L-4）

**位置：**
- `NemoToken.mint`（第 67 行）检查 `totalSupply() + amount > CAP`；
- 铸币方有三个：金库 `_contribute`、`NemoNftInterest.claim`（第 125 行）、Owner。

**问题：** Nemokey 的铸币额度只有一个上限，没有给周息预留任何额度。

- **入金：** 每 1U 铸 100 枚，10 亿枚大约对应 1000 万 USDT 入金。
- **周息：** 每周按持有张数对应的本金再铸 1%–3%。IDO 持续 26 周、全部按 3% 计算的话，利息累计相当于本金的 78%。入金只到约 560 万 USDT，额度就会用完。
- **手动铸币：** 管理员给早期用户手动铸的本金，也占这个额度。

额度一旦用完：

- 每笔入金都会失败，因为入金时必须铸币（原 L-4）；
- 已经累计的周息也领不出来，`claim` 报 `CapExceeded`，用户看到的「可领」数量无法兑现。

**复现：** `test_M5_sharedCapBlocksInterestAndDeposits`（60 张 NFT 满一周可领 9 万枚；额度用完后，领周息和入金都失败）

**建议：**
- 按预计入金规模、IDO 周数、最高档利率，算出周息的最大发行量，再调整 `CAP`，或者给周息单独设额度；
- 入金铸币在剩余额度不足时，改为按剩余额度铸造或跳过，不要整笔失败；
- `pending` 或页面上提示剩余额度。

---

## 5. 低危

### L-1 直推比例调到 25% 以后，网体奖完全发不出去

**复现：** `test_L1_directAtCapStarvesTeam`
**建议：** 把直推上限调低，或者给网体单独设帽。

### L-2 挑战只由 Owner 一人裁决

**复现：** `test_L2_ownerDecidesChallenge`
**建议：** 裁决权交给独立多签；驳回挑战时收下的押金不要归 Owner。

### L-3 金库暂停后，网体领取仍然可以进行

周息领取也不受金库暂停影响，只能暂停 NEMOKEY 代币本身来挡住。

**复现：** `test_L3_pauseDoesNotStopTeamClaims`
**建议：**
- `disburse` 加上 `whenNotPaused`；
- 利息合约也单独加暂停开关。

### L-4 已并入 M-5

原来的「代币上限挡住入金」，现在是 M-5 的一部分。复现测试 `test_L4_tokenCapBlocksDeposits` 仍然保留。

### L-5 NFT 逐枚循环铸造，大额入金 gas 很高

`grantNft` 同样是逐枚铸造，一次补发几百张可能超出区块 gas 上限，需要分几笔发。

**建议：** 限制单笔入金或单次补发的张数，或者改为批量铸造。

### L-6 首次索引从创世块开始，中途不保存进度，也没有并发锁

**建议：**
- 增加 `START_BLOCK`；
- 分段提交检查点；
- 用 `pg_advisory_lock` 保证同一时间只有一个进程在写。

### L-7 root 提交之后才保存 proof，root 明细也没有公开

**建议：**
- 先把 proof 写入数据库，再发交易；
- 每期的叶子 JSON 公开发布。

### L-8 NFT 发行缺少约束：补发没有上限、不留记录，NFT 合约 Owner 还能绕过金库直接铸造（本版新增）

**位置：** `NemoIdo.grantNft`（第 423 行）、`NemoNFT.setMinter`（第 28 行）

**问题：**

1. **补发没有上限。** `grantNft` 只检查地址已注册、数量大于 0，不和导入的 `nftMinted` 比较，也不记录已经补发了多少张。同一个地址可以被补发两次；没有任何入金的地址，也可以直接补发 60 张，从下一周起按 3% 计息。
2. **可以绕过金库铸造。** NFT 合约的 Owner 可以把铸币地址从金库换成自己，直接调用 `NemoNFT.mint`。这样铸造不会先结算周息。之后用户领取或入金时，过去几周会按新张数全部补算：4 周前持有 2 张，现在直接铸到 60 张，一次就能领到 4 周 × 9 万枚。

NFT 代表未来酒店分红的权益。多出来的 NFT 除了带来周息增发，还会稀释所有持有人的分红份额。

**复现：**
- `test_L8_grantNftIsUnbounded`：重复补发；无入金地址被补发 60 张；
- `test_L8_directNftMintIsPaidRetroactively`：绕过金库铸造后，过去 4 周被补算。

**建议：**
- 增加 `granted[account]`，要求 `granted + 本次数量 ≤ 导入的入金 / 500`；
- 补发只允许在开售前进行，或者在 `freezeImport` 之前进行；
- 部署后把 NFT 的铸币地址锁死，只能设置一次；
- 每次补发都发出事件，并在前端公开，方便核对。

### L-9 第一次关售会永久停止计息，重新开售也不恢复（本版新增）

**位置：** `NemoIdo.closeSale`（第 326 行）

**问题：** 以前 `closeSale` 只是一个开关，可以关了再开。现在第一次调用就会写入 `idoEnded = true`，之后再 `openSale` 也不会恢复周息。下面几种情况都会让全部用户永久失去之后的周息：

- 临时关售做维护；
- 手滑误点；
- 开售之前就调用了 `closeSale`。

**复现：** `test_L9_firstCloseSaleEndsInterestForever`

**建议：** 把「结束 IDO」拆成一个单独的函数，例如 `endIdo()`，调用前要求二次确认或有 timelock。`closeSale` 恢复成只控制入金开关。

### L-10 主网上，补发的 NFT 在开售前就开始计息（本版新增）

**位置：** `NemoNftInterest._week`（第 178 行）

**问题：** 主网按北京时间自然周计算，起点是利息合约部署的那一周，和金库是否开售无关。只要早期用户在导入阶段被补发了 NFT，从下一周起就开始计息，哪怕 IDO 还没开售。本地和测试网用的是金库的 `currentWeek()`，开售前一直是 0，所以不会出现这个问题。结果是两边行为不一致，测试网上发现不了。

**复现：** `test_L10_mainnetInterestAccruesBeforeSaleOpens`（主网时钟：不开售，补发 2 张，两周后可领 2000 枚）

**建议：** 由业务方确认「IDO 期间」从哪一刻开始算。如果从开售算起，就把 `startWeek` 改成开售时所在的周，并在 `openSale` 时写入。

---

## 6. 提示

| 编号 | 内容 | 建议 |
|------|------|------|
| I-1 | Owner 权力集中：导入、参数、提取、奖励地址、root、挑战裁决、周息档位（最高每周 10%）、NFT 补发，全在同一个 Owner 手里 | 上线前把 Owner 转给多签 |
| I-2 | 邀请码先到先得，可能被抢注 | 前端提示，或者在导入阶段预留 |
| I-3 | `registerAndContribute` 对已注册用户会忽略传入的邀请码 | 前端隐藏这个输入框 |
| I-4 | 合约假设 USDT 是 18 位小数，周息本金也按 `500e18` 计算 | 部署时断言 `decimals() == 18` |
| I-5 | `quote()` 用的是旧公式，和实际铸造数量不一致 | 前端只用 `tokensFor` |
| I-6 | `MockUSDT` 任何人都能铸造 | 只在本地和测试网使用 |
| I-7 | `OWNER` 不是广播账户时，部署脚本不会调用 `setRewards` 和 `setNftInterest`；NEMOKEY 和 NFT 的新 Owner 需要 `acceptOwnership` | 写进部署清单。注意：`setNftInterest` 没调用之前的入金不会结算周息 |
| I-8 | 删除垫付后留下的死代码：`disburse` 的 `fromOutstanding=false` 分支、`_attribute` 里的空事件分支 | 删掉 |
| I-9 | 数据库里的直推金额按固定 10% 计算，Owner 改参数后会和链上不一致 | 改为索引 `DirectRewardAccrued` 事件 |
| I-10 | 导入的业绩只算本人业绩，不计入上级的伞下；网体奖从产生到能提现，最长约 48 小时 | 由业务方确认口径 |
| I-11 | 周中买入的 NFT，当周按买入后的张数算整周。在每周最后一个区块买入，也能拿到一整周的利息，相当于「掐点」多拿一周 1%–3%。关售那一周同样如此（复现：`test_I11_lastBlockPurchaseEarnsTheWholeWeek`） | 这是计划里确认过的口径。如果要改，可以让当周新增的张数从下一周才开始计息 |
| I-12 | 本地和测试网上，`interestWeek(timestamp)` 忽略传入的时间，直接返回当前周。先关售、后 `setNftInterest` 时，停息周会被算成调用 `setNftInterest` 时的那一周。主网按时间戳计算，没有这个问题。`calendarWeeks` 直接写死为 `chainid == 56` | 部署时先 `setNftInterest` 再开售（部署脚本已经这样做）；需要时把周制度改成构造参数传入 |
| I-13 | 利息合约只能设置一次，并且记着不可变的金库地址。利息合约出了 bug，只能连金库一起重新部署。另外，事件索引器还没有接入周息事件，页面只能用 `pending()` 实时读取 | 主网前做外部审计；需要对账时再把 `InterestSettled`、`InterestClaimed` 加进索引器 |

---

## 7. 本版复核过、没有问题的点

- **不会重复计息。** `settledThrough` 只增不减；`_preview` 从 `max(settledThrough, startWeek)` 结到 `end`，用户重复调用 `claim` 不会重复结算同一周。
- **张数变化前先结算。** NFT 张数只会因为金库的 `contribute` 和 `grantNft` 增加，两处都会先 `settle`。NFT 没有公开的销毁函数，也不能转让，张数不会减少。唯一的例外是 L-8 所说的绕过金库直接铸造。
- **改档位不追溯。** 档位的每个版本都记录了起始周和当时的铸币比例。同一周内再次修改，会覆盖这个版本，不会新开一个。已结束的周始终按旧版本计算（`test_tierChangeAppliesFromTheCurrentWeek`、`test_sameWeekTierEditOverwrites`）。
- **关售之后不再计息。** 结算的截止周固定为 `idoEndedWeek`。重新开售后的新入金，不会给已结束的周追加利息。
- **主网周界。** `230400` 是 1970-01-04 00:00:00 北京时间，那天是周日。周界前 30 秒和周界这一刻，分别属于前后两周（`test_beijingSundayStepsAtMidnight`）。链下脚本二分查找「时间小于周界的最后一个区块」，找到的就是高度 N，并且会校验 N 和 N+1 确实跨过了周界。
- **重入。** `claim` 加了 `nonReentrant`，并且先把 `accrued` 清零再铸币。铸币对象是受信任的 NEMOKEY 合约。
- **权限。** 只有金库能调用 `settle`；代币的利息铸币地址只有代币 Owner 能设置；档位上限是每周 10%，最多 16 档，门槛张数必须严格递增。
- **gas。** 结算循环的次数取决于档位的版本数，和经过了多少周无关。长期不领也不会因为周数太多而领不出来。

---

## 8. 和第二版相比的变化

| 第二版 | 本版 | 状态 |
|--------|------|------|
| H-1、H-2 | H-1、H-2 | 仍然存在。H-2 的影响更大：同一把钥匙现在还能改周息档位、补发 NFT |
| M-1 至 M-4 | M-1 至 M-4 | 仍然存在 |
| L-4 代币上限挡住入金 | 并入 M-5 | 周息共用同一个上限，升级为中危 |
| L-1 至 L-3、L-5 至 L-7 | 同编号 | 仍然存在。L-3、L-5 补充了周息和补发的情况 |
| — | M-5、L-8、L-9、L-10、I-11、I-12、I-13 | 本版新增 |

---

## 9. 应补的测试

- 所有 revert 分支。NemoRewards 和 NemoNFT 的分支覆盖率只有 33%–36%。
- 不变量测试：
  - `USDT 余额 ≥ reservedRewards`；
  - `直推 + 网体 ≤ 25% × 总入金`；
  - `NEMOKEY totalSupply ≤ CAP`；
  - 同一地址的 `settledThrough` 单调递增；
  - 周息累计值等于「逐周按当周张数计算」的参考结果。
- 周息模糊测试：随机穿插入金、补发、改档位、关售，和一个逐周计算的朴素参考实现对比结果。
- 主网时钟：跨年和闰年附近的周日边界；关售落在周六 23:59 和周日 00:00 两种情况。
- 主网上线前：外部审计、静态扫描；在 BSC 测试网上按北京时间自然周完整跑 4 周的周息流程。可以临时改 `calendarWeeks` 来做这项测试。

---

## 10. 信任假设

1. Owner 诚实，私钥安全。H-1、H-2、M-1、M-2、L-2、L-8 都依赖这一点。
2. 链下计算器和数据库没有被篡改。
3. BSC USDT 是 18 位小数、没有转账手续费。
4. BSC 的区块时间戳单调递增，验证者最多能把时间调整几秒。周界附近可能有一两个区块被划到另一周，但仍然只有一个 N。
5. NEMOKEY 的 `CAP` 足够覆盖入金加周息的总量（见 M-5）。
