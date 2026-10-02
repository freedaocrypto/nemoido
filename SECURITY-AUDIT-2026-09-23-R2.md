# nemoido 安全审计报告（第二版，简化后）

> **已被 [SECURITY-AUDIT-2026-09-23-R3.md](SECURITY-AUDIT-2026-09-23-R3.md) 取代。** 第三版加入了 NFT 周息的审计，原 L-4 并入 M-5。本文保留为历史，未改写。

日期：2026-09-23  
代码状态：提交 `11e8efd` 加上工作区未提交的「每日 root、删除垫付、Postgres 实时索引」改动（分支 `localdev`）  
取代：同日第一版 [SECURITY-AUDIT-2026-09-23.md](SECURITY-AUDIT-2026-09-23.md)，第一版保留为历史记录，未改写  
配套功能报告：[FUNCTIONAL-REPORT.md](FUNCTIONAL-REPORT.md)  
复现测试：`test/audit/AuditPoc.t.sol`（10 项，均按本报告描述的行为通过；修复后对应测试会变红）

> 这是内部审计，不能替代主网上线前的外部审计。本次没有运行 Slither（本机未安装），没有广播 BSC 测试网或主网。

---

## 1. 结论

| 等级 | 数量 | 编号 |
|------|------|------|
| 高 | 2 | H-1、H-2 |
| 中 | 4 | M-1、M-2、M-3、M-4 |
| 低 | 7 | L-1 至 L-7 |
| 提示 | 10 | I-1 至 I-10 |

用户资金的主要风险仍然集中在 Owner 权限上。简化之后又多了一个问题：`submitRoot` 只允许 Owner 调用，每日自动发布就得把 Owner 私钥放在服务器上（H-2），而这把钥匙同时能抽库、能换奖励合约地址。

新发现的中危有两项。M-3：每天提交新 root 会覆盖待生效的 root，并重新开始 24 小时计时，如果不先激活，网体奖可能永远无法生效。M-4：数据库表不区分合约地址，重新部署后新旧数据会混在一起。这两项都需要在测试网跑每日流程之前修掉。

直推提现路径（`NemoIdo.claim`）没有发现新问题。第一版里和垫付相关的 M-3（签名密钥）、L-1（预付超锁）随代码删除，不再适用。

**上线建议：** H-1、H-2、M-3、M-4 修复前不要上主网。M-1、M-2 至少要有运维上的约束（见各条建议），并在前端公开 root 的明细。

---

## 2. 范围与方法

**合约**

| 文件 | 说明 |
|------|------|
| `src/NemoIdo.sol` | 金库：注册、邀请、入金、直推、铸币、导入、抽库。简化中未改动 |
| `src/NemoRewards.sol` | 网体奖：累计 Merkle root、timelock、挑战、领取。已删除垫付和 EIP-712 |
| `src/INemoRewards.sol` | 金库与奖励合约之间的接口 |
| `src/NemoToken.sol` / `src/NemoNFT.sol` | NEMOKEY（有上限、转账白名单）/ 灵魂绑定 NFT |
| `src/network/NemoNetworks.sol` | 三套网络参数，已删除垫付上限字段 |
| `script/Deploy.s.sol` | 按网络部署，主网需 `ALLOW_MAINNET=true` |

**链下脚本（本版新增的审计范围）**

| 文件 | 说明 |
|------|------|
| `scripts/index-rewards.mjs` | 读链上事件，重放极差，写入 Postgres |
| `scripts/lib/reward-index.mjs` / `reward-db.mjs` | 事件到计算器状态的映射；建表和事务写入 |
| `scripts/lib/team-reward.mjs` | 极差 + 6 万平级抽成计算器 |
| `scripts/publish-root.mjs` | 从库里组树、`submitRoot`、存 proof、`--activate` |
| `scripts/lib/merkle.mjs` | OpenZeppelin 兼容的 Merkle 树 |

**方法：** 逐行人工阅读；对每个可以用测试证明的问题写 Forge 复现；重跑全部测试和覆盖率；重跑 300 人 Anvil 实测（结果见功能报告第 8 节）。

**测试结果：** Forge 93 项通过（不含跳过的 SimMarket），JS 15 项通过。

| 合约 | 行 | 语句 | 分支 | 函数 |
|------|----|------|------|------|
| NemoIdo | 89.1% | 80.0% | 45.2% | 89.4% |
| NemoRewards | 96.6% | 86.2% | 36.0% | 92.3% |
| NemoToken | 100% | 86.5% | 50.0% | 100% |
| NemoNFT | 100% | 84.0% | 33.3% | 100% |

---

## 3. 高危

### H-1 `setRewards` 没有延迟，Owner 可以换掉奖励合约，抽走当期网体准备金

**位置：** `NemoIdo.setRewards`（第 384 行）、`NemoIdo.disburse`（第 287 行）、`_teamOutstanding`（第 470 行）

**问题：** 金库把 `rewards` 地址当作唯一可信的付款方，准备金里的网体部分也直接读 `rewards.outstanding()`。Owner 一笔交易就能把地址换成自己的合约：新合约报告 `outstanding() = 0`，准备金只剩直推部分，再通过 `disburse` 把其余余额全部转走。原奖励合约里已经生效、等着用户领取的网体奖变成 `NotRewards`，领不出来。

**影响：** 已激活 root 对应的全部网体奖。Owner 私钥泄露时，损失范围从「非准备金」扩大到「除直推准备金以外的全部余额」。

**复现：** `test_H1_setRewardsDrainsTeamReserve`

**建议：** 二选一。

1. `rewards` 只能设置一次（部署后锁定）。
2. 换地址走和 root 一样的 timelock（例如主网 48 小时），并且要求旧合约 `outstanding() == 0` 才能切换。

### H-2 每日自动发布 root 需要 Owner 私钥常驻服务器

**位置：** `NemoRewards.submitRoot`（第 93 行，`onlyOwner`）；`scripts/publish-root.mjs` 第 110–150 行读取 `PRIVATE_KEY`

**问题：** 按新流程，root 每 24 小时发布一次，并且要能全自动运行。合约里只有 Owner 一个角色可以 `submitRoot`，所以定时任务所在的服务器必须持有 Owner 私钥。这把钥匙同时也是：

- `NemoRewards` 的 Owner：能 `cancelPending`、`dismissChallenge`（押金归 Owner）；
- 通常也是 `NemoIdo` 的 Owner（部署脚本默认同一个 `OWNER`）：能 `withdrawTreasury`、`setRewards`（见 H-1）、`setDirectReferralBps`、`pause`。

服务器、CI 或环境变量一旦泄露，攻击者就拿到金库的全部 Owner 权限。反过来，如果 Owner 放在多签里，自动化就做不到，只能每天人工签名。

**影响：** 自动化服务器被攻破时，可以直接走 H-1 抽走全部非直推资金，也可以随意提交 root（受 25% 帽约束，timelock 期间仍能挑战，但裁决挑战的也是同一把钥匙，见 L-2）。

**复现：** `test_H2_rootPublisherIsFullOwner`（非 Owner 不能提交；能提交 root 的地址也能清空金库可提余额）

**建议：**

1. 在 `NemoRewards` 增加独立的 `publisher` 角色，只能 `submitRoot`，由 Owner 设置和撤换。定时任务只持有 publisher 私钥。
2. `NemoIdo` 和 `NemoRewards` 的 Owner 转给多签（Ownable2Step 需新 Owner `acceptOwnership`）。
3. `cancelPending` 保留给 Owner，这样 publisher 提交了错误 root，多签还能撤回。

---

## 4. 中危

### M-1 待生效 root 不计入准备金，Owner 可以在 timelock 期间先抽库

**位置：** `NemoIdo.treasuryWithdrawable`（第 183 行）只锁 `directReserve + outstanding`；`outstanding` 只算已激活的 root

**问题：** 从 `submitRoot` 到 `activateRoot` 的 24 小时里，新 root 的增量不在准备金中。Owner 可以在这段时间把可提余额全部提走，root 生效后，用户领取时报 `InsufficientTreasury`。链下已经算出、还没提交 root 的网体奖，也同样没有任何链上保障。

**复现：** `test_M1_pendingRootIsUnfunded`

**建议：**

- 合约：`treasuryWithdrawable` 再扣掉 `pendingCumulative − rootPaid`（取正值）。
- 运维：`publish-root.mjs --apply` 在提交前检查 `金库余额 − 直推准备金 ≥ teamSum − totalTeamPaid`，不够就停止并报警。当前脚本只检查 25% 帽，没有检查余额。

### M-2 root 的 `cumulative` 由 Owner 申报，和叶子合计没有链上约束

**位置：** `NemoRewards.submitRoot`（第 93 行）、`activateRoot`（第 134 行）

**问题：** 合约无法从 Merkle root 推出叶子合计，只能相信 Owner 传入的 `cumulative`。少报时，`outstanding` 变小，准备金也跟着变小，Owner 能提走本该锁定的钱，之后用户领取失败。多报时，准备金被虚高锁住。

**复现：** `test_M2_underDeclaredCumulativeLeavesClaimsUnfunded`（两片叶子各 400，申报 1，抽库后 Alice 领不到）

**建议：**

- 公开每期 root 的完整叶子列表（见 L-7），前端和第三方可以核对「叶子合计 = `cumulative`」和 `contentHash`。
- 挑战期内发现不符就 `challenge()`。
- 长期方案：链上只记录累计额上限，或者改用 zk / 乐观证明，本期不做。

### M-3 每天提交新 root 会覆盖待生效 root 并重新计时，可能永远无法生效

**位置：** `NemoRewards.submitRoot`（第 101–106 行）直接覆盖 `pendingRoot` 和 `pendingEta`；`scripts/publish-root.mjs --apply` 不检查是否已有待生效 root

**问题：** 主网 `rootTimelock = 24 小时`，发布节奏也是 24 小时。设想这样一个时间线：

1. 第 1 天 0:00，提交 root A，eta 为第 2 天 0:00。
2. 第 1 天 23:59，定时任务稍有提前（或者手动补跑、重试），提交 root B。A 被覆盖，eta 改成第 2 天 23:59。
3. 以后每天都比 eta 早一点提交，就永远没有 root 能激活。

`activateRoot` 本身不限调用人，但定时任务把 `--apply` 和 `--activate` 拆成两次运行，也没有先后约束。任何一次重复运行都会让用户多等 24 小时。另外，`submitRoot` 会退还当前挑战者的押金，Owner 可以借此绕开一次挑战。

**影响：** 用户的网体奖提现被无限期推迟。资金没有丢失，但对「每 24 小时发放一次」的承诺来说，这是活性故障。

**复现：** `test_M3_dailySubmitResetsPendingTimer`

**建议：**

- 脚本：`--apply` 开头先读 `pendingRoot`。如果已到期，先 `activateRoot` 再提交；如果未到期，停止，不覆盖。把「激活 → 提交」合成一个定时任务。
- 合约（可选）：`submitRoot` 在已有待生效 root 时 revert，想替换必须先 `cancelPending`，把覆盖变成显式操作。
- 运营上把 timelock 设得比发布间隔短（例如 12 小时），或者把发布间隔设为「上一期激活之后 24 小时」。

### M-4 Postgres 表不区分合约部署，重新部署后新旧数据混账

**位置：** `scripts/lib/reward-db.mjs` 第 14–43 行。`nemo_team_account`、`nemo_team_root`、`nemo_team_proof` 的主键都只有 `chain_id`；`index-rewards.mjs` 第 80 行和 `publish-root.mjs` 第 80 行都按 `chain_id` 读取全部账户

**问题：** 检查点表按 `(chain_id, ido_address)` 区分，账户表却不区分。在同一条链上换一个新的金库地址（修 H-1/H-2 需要重新部署；测试网也会反复部署）时：

1. 新金库的检查点从 0 开始，但 `loadAccounts` 读出了旧金库的全部账户，包括业绩和累计网体奖。
2. 新事件在旧数据上叠加，伞下业绩和网体奖都会重复计算。
3. `publish-root.mjs` 组树时把旧金库的奖励也算进新 root。只要没有超过 25% 帽，就会被提交上链，付给不该拿的人，或者让 `cumulative` 虚高。

本地 Anvil 重启时还有反向问题：新链的区块号比旧检查点小，索引器一直显示「已追上」，不会写入新数据。

**影响：** 重新部署后，网体奖可能多发或错发；本地和测试网的数据不可信。

**建议：**

- 所有 `nemo_` 表加 `ido_address`（或 `deployment_id`）列并加进主键，读取时按 `(chain_id, ido_address)` 过滤。
- `publish-root.mjs` 读取 `vault.rewards()`，确认等于 `REWARDS_ADDRESS`（当前 ABI 里有这个函数但没有调用）。
- 检查点记录区块哈希；启动时发现链上同高度哈希不同，就拒绝运行并提示重建。

---

## 5. 低危

### L-1 直推比例调到 25% 后，网体奖完全无法发放

`setDirectReferralBps` 上限是 `REWARD_CAP_BPS = 2500`，而 25% 帽是直推和网体共用的。直推调到 25% 以后，任何 `submitRoot` 都会 `CapExceeded`。已经激活的 root，用户领取也会失败。

**复现：** `test_L1_directAtCapStarvesTeam`  
**建议：** 直推上限改成例如 1500，给网体留出空间，或者单独设网体帽。

### L-2 挑战由 Owner 一人裁决

`dismissChallenge` 由 Owner 调用，押金归 Owner。被驳回后，挑战者可以在 eta 前再次挑战。Owner 也可以用新的 `submitRoot` 把挑战者押金退掉，重新计时（见 M-3）。挑战机制对 Owner 本身没有约束力，只能起到公开记录的作用。

**复现：** `test_L2_ownerDecidesChallenge`  
**建议：** 裁决权交给独立多签或时间锁；驳回的押金不要归 Owner，改为销毁或进入公共池。

### L-3 金库暂停不影响网体领取

`NemoIdo.pause()` 挡住注册、入金和直推 `claim`，但 `disburse` 没有 `whenNotPaused`，`NemoRewards` 也没有暂停开关。发现 root 有问题时，没有办法立即停止网体付款。

**复现：** `test_L3_pauseDoesNotStopTeamClaims`  
**建议：** `disburse` 加 `whenNotPaused`，或者给 `NemoRewards.claim` 单独加暂停。

### L-4 NEMOKEY 达到上限后，所有入金都会失败

`_contribute` 每笔都 `mint`。`NemoToken.CAP` 用完以后（包括 Owner 直接 mint），入金全部 revert。

**复现：** `test_L4_tokenCapBlocksDeposits`  
**建议：** 铸币前检查剩余额度，不足时按剩余额度铸造或跳过；或者限制 Owner 直接 mint 的额度。

### L-5 NFT 按枚循环铸造，大额入金 gas 高

每 500U 一枚，`NemoNFT.mint` 逐枚循环。6 万 U 单笔约 120 枚，历史实测约 341 万 gas。金额再大可能超过区块 gas 上限，这类入金只能拆开做。

**建议：** 单笔入金设上限，或者改成 ERC-1155 / 批量铸造。

### L-6 首次索引从创世块开始，单次写库，没有中间检查点

`index-rewards.mjs` 第 74 行：没有检查点时从区块 0 开始，每 2000 块、每种事件各发一次 `getLogs`。BSC 主网有几千万个区块，首次同步要发出几十万次请求，全部在内存里累积，最后一次性写库。中途失败就要从头再来。多个索引器同时运行时也没有锁（两个进程会各自读库、各自覆盖）。

**建议：** 增加 `START_BLOCK`（部署区块）；每处理一段就提交一次检查点；用 `pg_advisory_lock` 保证同一时间只有一个索引器和一个发布器在运行。

### L-7 提交 root 之后才保存 proof，root 明细也没有公开

`publish-root.mjs` 第 145–161 行先发交易，交易确认后才把 proof 写进库。如果写库失败或进程中断，链上已经有待生效 root，库里却没有 proof。而重跑时，索引器可能已经写入了新数据，组出来的是另一棵树，用户就无法用这期 root 领取。

另外，`contentHash` 是叶子 JSON 的哈希，但 JSON 本身只存在私有数据库里。外部人员无法重算，挑战机制（M-2、L-2）也就失去了依据。

**建议：** 先把树和 proof 写库（状态「待提交」），再发交易，确认后改成「已提交」。每期叶子 JSON 公开发布（静态文件或 IPFS），和 `contentHash` 对应。

---

## 6. 提示

| 编号 | 内容 | 建议 |
|------|------|------|
| I-1 | Owner 集中度高：导入、参数、抽库、奖励地址、root、挑战裁决都在 Owner 手里 | 上线前 Owner 转多签，并公开参数变更流程 |
| I-2 | 邀请码先到先得，可以被抢注 | 前端提示；热门码可以在导入阶段预留 |
| I-3 | `registerAndContribute` 对已注册用户会忽略传入的邀请码，不报错 | 前端在用户已注册时隐藏邀请码输入 |
| I-4 | 合约假设 USDT 是 18 位（BSC 上的 USDT 是 18 位）。换成 6 位代币时，门槛和 NFT 单位都会错 | 部署时断言 `decimals() == 18` |
| I-5 | `quote()` 还是旧的周递减公式，入金实际按 `tokensFor` 铸造，两者不一致 | 前端只用 `tokensFor`，或删除 `quote` |
| I-6 | `MockUSDT` 任何人都能铸造 | 只用于本地和测试网，部署脚本已按网络区分 |
| I-7 | `OWNER` 不是广播账户时，部署脚本不会调用 `setRewards`，NEMOKEY 和 NFT 需要新 Owner `acceptOwnership` | 部署清单里写明这两步 |
| I-8 | 删除垫付后留下两段死代码：`disburse` 的 `fromOutstanding=false` 分支，以及 `_attribute` 里 `pay == 0` 时发空事件的分支（没有垫付以后 `claimed` 总是等于 `rootAttributed`，这个分支执行不到） | 删掉，接口里的 `bool` 参数一并去掉，减少审计面 |
| I-9 | 库里的直推金额按固定 10% 和 100U 门槛计算。Owner 链上改参数后，库里显示的直推会和链上不一致（只影响显示，直推以链上为准） | 索引 `DirectRewardAccrued` 事件，直接用链上金额 |
| I-10 | 导入的历史业绩只算本人业绩（`seedSelf`），不计入上级的伞下业绩。上级的档位资格可能低于业务方预期，网体奖随之偏少。另外，链下 root 里某人的叶子额如果小于他已领金额，他会一直 `CumulativeTooLow`，直到后面的 root 追上。网体奖从产生到能提现最多要等约 48 小时（发布间隔加 timelock） | 业务方确认导入口径；前端显示「预计可领时间」 |

---

## 7. 和第一版相比的变化

| 第一版编号 | 本版 | 状态 |
|------------|------|------|
| H-1 setRewards 抽库 | H-1 | 仍存在 |
| M-1 待生效 root 不锁 | M-1 | 仍存在 |
| M-2 申报累计额 | M-2 | 仍存在 |
| M-3 垫付签名密钥 | — | 垫付代码已删除，不再适用（`test_advanceEntryRemoved`） |
| L-1 预付超锁 | — | 同上，不再适用 |
| L-2 直推占满帽 | L-1 | 仍存在 |
| L-3 Owner 裁决挑战 | L-2 | 仍存在 |
| L-4 暂停不挡网体 | L-3 | 仍存在 |
| L-5 代币上限挡入金 | L-4 | 仍存在 |
| L-6 NFT 循环 gas | L-5 | 仍存在 |
| — | H-2 Owner 私钥上服务器 | 新增 |
| — | M-3 每日提交重置计时 | 新增 |
| — | M-4 数据库不区分部署 | 新增 |
| — | L-6 首次索引 / 并发 | 新增 |
| — | L-7 proof 保存顺序 / 明细不公开 | 新增 |

---

## 8. 应补的测试

- 所有 `revert` 分支：零地址、长度不匹配、参数越界、`NoPending`、`BondNotMet`、`WrongNetwork`。当前分支覆盖率只有 33%–50%，主要缺的就是这些。
- 不变量测试（Foundry invariant）：`USDT 余额 ≥ reservedRewards`；`totalDirectAccrued + totalTeamPaid ≤ 25% × totalContributed`；每个账户 `claimed == rootAttributed`。
- 链下：索引器「从头全量重放」和「分段增量」得到同样的数据库结果；同一条链上两个金库地址互不干扰（M-4 修复后）；`publish-root` 在已有待生效 root 时拒绝提交（M-3 修复后）。
- 主网上线前：外部审计，Slither / Aderyn 静态扫描，BSC 测试网完整跑 7 天每日流程。

---

## 9. 附：信任假设

1. Owner 诚实，私钥安全（H-1、H-2、M-1、M-2、L-2 都依赖这一点）。
2. 链下计算器和数据库没有被篡改；每期 root 的明细可以被公开核对（当前还做不到，见 L-7）。
3. BSC USDT 为 18 位、无转账手续费、不会被冻结金库地址。
4. RPC 返回的事件是正确的，`CONFIRMATIONS`（默认 15）足以覆盖重组。
