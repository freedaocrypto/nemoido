# 主网部署前检查备忘

上主网前按下面核对。来源是 2026-09-24 在 `test.freedao.life` 用邀请码 `L34U8YSZ` 注册失败。

## 2026-09-24：邀请码无效

现象：注册页提示「邀请码无效，请核对后再试」。对应接口 `POST /api/auth/wallet` 返回 `INVALID_INVITE`。

三处核对结果：

| 位置 | `L34U8YSZ` |
|---|---|
| 网站测试库 `nomad_users`（Neon，`test.freedao.life` 的 `DATABASE_URL`） | 没有。该库当时只有 5 个用户，邀请码是 `ROOTANVL`、`WPNVLBL2`、`83LEB9JS`、`5LRFXWU3`、`CPA9WFTC` |
| 正式库 `nomad_users` | 有。持有人钱包与导入文件一致，且已绑定上级 |
| BSC 测试网金库 `codeToAccount` | 有。该地址已 `registered`，邀请码字节与网站编码一致 |

结论：坏在网站连的那一个数据库，不在合约。当时注册根本不会读链。

2026-09-24 之后，`life_dev` 在 `NEXT_PUBLIC_NEMO_NETWORK=bscTestnet` 时改为以金库 `codeToAccount` 为准。`nemo_invite_cache` 只缓存已经从链上读到的码；缓存没有命中才查链，查到后写入。数据库里多出来、但链上没有的码不会被当成有效邀请码。未配置测试网金库地址时，仍走原来的数据库查询，避免正式站在主网合约接上之前无法注册。

`lib/invite.ts` 的 `resolveReferrerId` 只用 `prisma.nomadUser.findUnique({ where: { inviteCode } })`。找不到就抛 `INVALID`。链上导入脚本只写了金库，没有把这 30 个用户写进测试站的 `nomad_users`。所以正式站上有效的码，在测试站上全部无效。

反过来也成立：测试库里那 5 个码都能过网站注册，但一个都不在测试网 `codeToAccount` 里。用它们注册成功后，第一次入金走 `registerAndContribute` 时，合约会因上级码不存在而 `InvalidReferrer`。

## 上线前必须核对

网站用户表和金库邀请表是两套数据。导入合约不会创建网站账号，网站注册也不会写链。

1. 抽一个真实邀请码，同时查即将上线的那个数据库和即将使用的金库。
   - 数据库：`nomad_users.inviteCode` 能查到，且 `referrerId` 链完整，没有指向另一套库里的用户。
   - 金库：`codeToAccount(bytes32)` 不是零地址，`getAccount` 的 `registered` 为真。
   - 两边指向同一个钱包。
2. 编码必须一致：大写 `A-Z0-9`，ASCII 靠左写入 `bytes32`，右侧补零。合约 `_isValidInviteCode` 只接受这种格式。网站用 `trim().toUpperCase()` 再同样编码。小写、空格、UTF-8 多字节都会在链上变成另一个码或直接 `InvalidCode`。
3. 确认网站环境变量 `DATABASE_URL` 就是上面查过的那一个库。测试站、预览环境、正式站各有各的库，不能用「正式库里有」代替「这个环境的库里有」。
4. 新用户在网站注册时会领到一个只存在于数据库的新邀请码。这个码要等该用户自己入金、合约执行 `registerAndContribute` 之后才出现在 `codeToAccount`。在此之前，别人不能拿这个新码在链上当上级。
5. 历史用户若先导入链上、再让别人用他们的码在网站注册，必须先把这些用户（含上级，否则外键和邀请链对不上）放进网站正在使用的 `nomad_users`。只导入金库不够。
6. 正式站不要设置 `NEXT_PUBLIC_NEMO_NETWORK`。登录切链（`ensureBscChain`）默认是 BSC 主网 `0x38`。测试网入金面板另切到链 `97`。这次注册失败与切链无关，签名在服务端验完才查邀请码。主网部署时确认登录和入金都落在链 56，测试环境才使用 `bscTestnet` 那一组地址。

## 2026-09-24：仪表盘 USDT 显示为 0

现象：测试钱包 `0xc297969e261cd146f555ebc32255eb8371ba7fcc` 在 BSC 测试网 MockUSDT 上有 100000，dashboard 显示 0。快照写入成功，没有报错。

原因：余额查询不读 `NEXT_PUBLIC_BSC_TESTNET_USDT`，也不存在 `NEXT_PUBLIC_PAY_USDT_ADDRESS`。

| 变量 | 实际用途 |
|---|---|
| `NEXT_PUBLIC_USDT_CONTRACT` | 仪表盘余额的代币合约。未设置时用 BSC 主网官方 USDT `0x55d398326f99059fF775485246999027B3197955` |
| `NEXT_PUBLIC_PAY_USDT_BSC` | 二维码收款地址，不参与余额 |
| `NEXT_PUBLIC_BSC_TESTNET_USDT` | 测试网 MockUSDT。`NEXT_PUBLIC_NEMO_NETWORK=bscTestnet` 时，仪表盘和 `/ido` 都读它，RPC 为链 97 |

主网查询打到链 56。这个钱包在主网官方 USDT 上就是 0，所以页面显示 0。快照最多缓存 24 小时；改完查询后要点 dashboard 上的同步，否则仍显示旧的 0。

IDO 页面上的「尚未开售 / pendingOf 返回 0x」是同一类问题：登录把钱包切到主网后，若用钱包自己的 RPC 去读测试网合约地址，主网上该地址没有代码，调用返回空数据。读取必须走链 97 的 HTTP RPC。写交易仍由钱包签名，并先切到 `0x61`。

主网核对：

7. 正式站 `NEXT_PUBLIC_NEMO_NETWORK` 必须为空，余额才会走链 56 和 `NEXT_PUBLIC_USDT_CONTRACT`（或默认官方 USDT）。测试站才设 `bscTestnet`，并让 `NEXT_PUBLIC_BSC_TESTNET_USDT` 等于当时部署的 MockUSDT。
8. 抽一个已知余额的钱包，对一下页面数字和对应链上 `balanceOf`。链、合约地址、小数位（18）三者要一致。收款地址 `NEXT_PUBLIC_PAY_USDT_BSC` 是主网收款钱包，不能当成代币合约。

## 网络对照（2026-09-24 整理）

全站只有一个开关：`NEXT_PUBLIC_CHAIN_NETWORK`，取值 `mainnet`、`testnet` 或 `local`。登录切链、IDO 读写、仪表盘余额、网体证明都按这个标签读取对应的那一组地址，不会混用另一组。抽奖开奖区块不走这个开关，固定链 56。`NEXT_PUBLIC_NEMO_NETWORK=bscTestnet` 只在新标签为空时当作 `testnet`，正式环境不要再依赖它。`NEXT_PUBLIC_LOCAL_CHAIN_ID` 单独设置不会把网站切到本地链。

| 路径 | 测试站 `bscTestnet` | 正式站（开关为空） |
|---|---|---|
| 登录 `ensureBscChain` | 链 97 `0x61`，没有这条链时由钱包添加 | 链 56 `0x38` |
| IDO 读取 | 链 97 的 HTTP RPC，不用钱包当前网络 | 不显示测试网面板，走二维码付款 |
| IDO 写交易 | 先切到 `0x61` 再签名 | 不显示测试网面板 |
| 仪表盘 USDT / BNB | MockUSDT `NEXT_PUBLIC_BSC_TESTNET_USDT`，链 97 | `NEXT_PUBLIC_USDT_CONTRACT` 或官方 USDT `0x55d398326f99059fF775485246999027B3197955`，链 56 |
| 节点申请、大使申请 | 不渲染 `PaymentPanel`，禁止 `sendUsdtBsc` | 主网官方 USDT 转到 `NEXT_PUBLIC_PAY_USDT_BSC` |
| 网体证明 `chain_id` | 97 | 56（未接主网金库时接口因没有金库地址而返回空证明） |
| 抽奖区块、`lib/activity/bsc.ts` | 仍是链 56 | 链 56 |

没有名为 `NEXT_PUBLIC_PAY_USDT_ADDRESS` 的变量。

上线核对：

9. 测试构建和正式构建各用各的环境变量。测试构建必须带 `NEXT_PUBLIC_NEMO_NETWORK=bscTestnet` 以及 `NEXT_PUBLIC_BSC_TESTNET_USDT`、`_IDO`、`_REWARDS`、`_INTEREST`。正式构建不要设置 `NEXT_PUBLIC_NEMO_NETWORK`。`NEXT_PUBLIC_*` 在构建时写进前端，改完变量要重新部署。
10. 登录后钱包所在的链，必须和 IDO 读请求、写交易、仪表盘余额是同一条。读请求走该链的 HTTP RPC。
11. 在测试站打开节点申请和大使申请，确认页面没有主网付款按钮。`sendUsdtBsc` 在测试模式下直接拒绝。
12. 抽奖用的区块高度保持链 56。不要为了测试站把 `lib/activity/bsc.ts` 改到测试网。
13. 上主网前用一个已知钱包核对三件事：页面 USDT 等于该链 `balanceOf`；邀请码在该链 `codeToAccount` 能查到；收款地址不是代币合约。
14. 关掉测试开关只会回到二维码付款和主网官方 USDT，不会自动接上主网金库。主网金库地址要单独接入，不能把测试网的四个合约地址填进正式环境。

## 2026-09-24：入金成功但仪表盘不刷新、已确认投入为 0

现象：链上入金 2000 U 成功，仪表盘余额没变，「已确认投入（USDT）」仍是 0。

两处原因：

- 「已确认投入」原本只累加 `nomad_contribution_orders` 里 `status='confirmed'` 的订单。金库入金走链上 `contribute`，不写这张订单表，所以合计是 0。现改为在使用金库时读链上 `getAccount().selfVolume`，与订单确认额取较大值（`app/api/dashboard/route.ts` 调用 `vaultSelfUsdt`）。
- 余额面板 `ChainSnapshotPanel` 只在没有任何快照时才自动同步。已有一份旧快照（入金前的余额）时不会刷新。入金成功后跳转带上 `?refresh=chain`，面板据此强制同步一次。快照仍缓存最多 24 小时，普通访问不会每次打 RPC。

主网核对：

15. 金库模式下，「已确认投入」以链上 `selfVolume` 为准，不要只信订单表。订单表用于主网二维码付款流程。两条流程不要在同一环境同时开。
16. 任何会改变链上余额的写操作（入金、领取），成功后要触发一次余额强制刷新，否则页面显示的是旧快照。快照默认缓存 24 小时。

## 2026-09-27：确认入金后没有交易上链

现象：授权成功、点了「第二步：确认入金」、页面看似完成，但链上 `registered=false`、`selfVolume=0`、没有 Contributed 事件。用普通 RPC `simulateContract` 模拟 `registerAndContribute` 返回成功，说明合约参数没问题，是前端根本没广播那笔交易。

原因：入金和领取原来用 viem `walletClient.writeContract`。它在发送前会用钱包的注入 provider 预估 gas，币安钱包在这一步常常静默失败，于是交易没有发出，也没有抛出可见错误。站内已验证可用的付款（`sendUsdtBsc`）走的是注入钱包的 `eth_sendTransaction` + 自己编码 calldata，不依赖 viem 的预估。

改法：`NemoChainPanel` 全部写操作改为 `encodeFunctionData` + `provider.request('eth_sendTransaction')`，回执用 HTTP RPC 轮询（`components/site/NemoChainPanel.tsx` 的 `sendTx`）。读取仍走 HTTP RPC。

主网核对：

17. 前端发合约写交易统一走注入钱包的 `eth_sendTransaction` + 手动 calldata，不要用 viem `writeContract` 依赖注入钱包预估 gas。上主网前用币安钱包实测一次入金，确认交易真的进入区块（有 tx hash 且 `selfVolume` 增加）。
18. 授权与入金分两步时，第二步成功的判据是链上出现 Contributed 事件或 `selfVolume` 增加，不能只看前端跳转。

## 2026-09-27（二）：确认入金交易 out-of-gas 回滚

现象：币安钱包里出现一条失败交易（`0x05aa73b1…`，status 0x0）。前端没有报错。

链上核对：`gasUsed=714662`，而 gas limit 只有 `720000`——几乎烧光全部 gas，是 out-of-gas，不是 require 回滚（require 会退还剩余 gas）。用 `eth_estimateGas` 实测 `registerAndContribute` 真实需要约 `921451` gas。币安钱包自估的 gas 严重偏低（很可能是授权还没确认时 estimateGas 失败、回退到默认 720000），首次注册+入金+铸 NEMO 这类重调用就 OOG 了。

改法（`components/site/NemoChainPanel.tsx` 的 `sendTx`）：
- 发交易前用 HTTP RPC `estimateGas` 自己估算，乘 1.5 作为 gas limit 显式带入 `eth_sendTransaction`，不依赖钱包自估。
- `estimateGas` 若失败（说明必然回滚）直接抛出原因、不把注定失败的交易发给钱包。
- 回执 `status === 'reverted'` 时抛出带交易哈希的错误，前端 catch 后在 UI 显示。

主网核对：

19. 所有链上写交易发送前必须显式设置 gas limit（自估 × 1.5 或更高），不能依赖注入钱包自估，`registerAndContribute` 首次调用真实用量约 90 万 gas。
20. 前端发交易后必须校验回执 `status`，回滚要向用户显示明确错误（含交易哈希），不能静默跳转。
