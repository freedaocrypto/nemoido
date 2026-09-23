# nemoido 技术架构

日期：2026-09-23  
范围：链下网体结算。Foundry / Solidity 0.8.28。  
源码：`src/NemoIdo.sol`、`src/NemoRewards.sol`、`src/NemoToken.sol`、`src/NemoNFT.sol`、`src/network/NemoNetworks.sol`

主网脚本已按 chainid `56` 配好，但没有 `ALLOW_MAINNET=true` 不会广播。主网仍需要外部审计。[SECURITY-AUDIT.md](SECURITY-AUDIT.md) 写的是上一版链上遍历模块，不覆盖本结构。

---

## 1. 拆分

```mermaid
flowchart TB
  User[用户] -->|approve + contribute| Vault[NemoIdo]
  User -->|register / bindReferrer| Vault
  User -->|claim 直推| Vault
  Vault -->|mint tokensPerUsdt| Token[NemoToken]
  Vault -->|每 500U 一枚| NFT[NemoNFT]
  Calc[scripts/lib/team-reward.mjs] -->|submitRoot| Rewards[NemoRewards]
  Calc -->|EIP-712 claimAdvance| Rewards
  User -->|claim cumulative + proof| Rewards
  Rewards -->|disburse| Vault
  Vault -->|USDT| User
```

| 合约 | 职责 |
|------|------|
| **NemoIdo** | USDT 金库：邀请、入金、直推、导入、铸 NEMOKEY / NFT。`contribute` 不再沿邀请链循环 |
| **NemoRewards** | 累计 Merkle 是发奖依据。签名只能垫付根之上的增量，并受单账户帽和每日帽限制 |
| **NemoToken** | `nemokey / NEMOKEY`。按需 mint，默认禁转 |
| **NemoNFT** | 灵魂绑定。本人业绩每 500 USDT 一枚 |

链下计算器在 `scripts/lib/team-reward.mjs`，数字锁在 `scripts/fixtures/team-golden.json`。邀请关系留在链上，任何人都能复算。

zkVM 不在本期。挑战不接 UMA：押金 + 时间窗 + Owner 撤销或没收。

---

## 2. 生命周期

```
部署（NETWORK=local|bscTestnet|bscMainnet）
  → importUsers / importReferrers / importVolumes（只写本人业绩，不发奖）
  → freezeImport → openSale
  → register / contribute
  → 直推：用户 claim()
  → 网体：submitRoot → 挑战窗 → activateRoot → claim(proof)
  → 可选：claimAdvance（垫付未进 root 的增量）
```

`openSale` 必须已经 `freezeImport`。`closeSale` 后不能入金，直推 `claim` 仍可用，除非 `pause`。

---

## 3. 网络参数

`NemoNetworks.Params` 在部署时传入。`block.chainid` 不匹配则 `WrongNetwork`。

- **local 31337**：MockUSDT；timelock 60 秒；垫付额度放宽；周为 30 个区块。
- **bscTestnet 97**：MockUSDT；timelock 1 小时；周为 1 小时时间戳。
- **bscMainnet 56**：USDT `0x55d398326f99059fF775485246999027B3197955`；timelock 24 小时；周为 7 天。

周参数只从这份配置读。`quote()` 用它计算历史序号，入金铸币不读 `quote()`。

---

## 4. NemoIdo

### 4.1 账户

```solidity
struct Account {
    address referrer;
    bytes32 inviteCode;
    uint256 selfVolume;
    uint256 directRewards;
    uint256 claimed;
    bool registered;
}
```

直推待领：`pendingOf = directRewards - claimed`。  
直推准备金：`directReserve = totalDirectAccrued - totalClaimed`。  
总准备金：`reservedRewards = directReserve + rewards.outstanding()`。  
`withdrawTreasury` 不能抽走准备金。`disburse` 只允许奖励合约调用，且垫付不能动直推准备金，也不能动当前 root 尚未归因的 outstanding。

### 4.2 邀请

邀请码 1–32 位大写字母或数字，ASCII 左对齐。防环是 O(1)：已有下级就不能再绑上级。没有深度上限，因为入金不再遍历。

### 4.3 入金

1. `saleOpen`、已注册、`amount >= minIdo`（默认 1 USDT）
2. USDT 转入金库，`selfVolume += amount`
3. `amount >= 100 USDT` 时，直接推荐人记 10% 直推
4. `tokensFor(amount)` mint NEMOKEY
5. 按 `selfVolume / 500e18` 补铸 NFT

深链和浅链的 `contribute` gas 在同一量级。NFT 仍按枚 mint，单笔 6 万 U 大约 120 次，这是另一笔 gas。

### 4.4 导入

`importVolumes(wallets, selfVolumes)` 只写本人业绩，并把 `nftMinted` 设成 `self / 500`，避免补铸历史 NFT。不写伞下业绩，不发直推，不发网体奖。

---

## 5. 链下极差

与已删除的 `NemoTeamReward` 同一套口径：

- 资格含本人。费率看本笔 bump 之前的资格。
- `prevBps` 从 0 起，入金者自己的档位不压缩上级。
- 先记极差，再把本笔业绩加进上级伞下，跨档从下一笔生效。
- 档位：500/3%、2k/5%、1 万/7%、3 万/9%、6 万/10%。
- 走完后，D 是最近的、本笔拿到团队奖且 bump 前已是 10% 的祖先；A 是 D 之上最近的另一个 10%。若 `dTeam > 0`，A 再拿 `dTeam` 的 10%。只抽一份。

验收数字在 `scripts/fixtures/team-golden.json`（含 ABCD 与两层 10% 抽成）。`node --test scripts/lib/*.test.mjs` 锁住这些数。

---

## 6. NemoRewards

叶子是 `(account, cumulative)`。OpenZeppelin 叶子：

`keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))`

配对哈希按 bytes32 数值排序。奇数节点直接上提，不复制。

- `claimed`：已经转出的 USDT（Merkle 和垫付加在一起）。
- `rootAttributed`：已经用证明记入 root 的最高累计额。
- `outstanding = committed - rootPaid`。垫付不减少 outstanding。
- 领取只付 `cumulative - claimed`。已垫付过的部分在后续 `claim` 里只入账、不再转账。
- `submitRoot` / `activateRoot` 要求累计合计 ≥ 已经支付的网体奖，并且直推 + 该合计 ≤ 25% 帽。
- 垫付类型：`Advance(address account,uint256 cumulative,uint256 nonce,uint256 deadline)`。域名为 `NemoRewards`，版本 `1`。
- 挑战押金放在奖励合约里。`cancelPending` 退回，`dismissChallenge` 转给 Owner。

---

## 7. NemoToken 与 NemoNFT

- NEMOKEY：CAP `1e9 * 1e18`，无预铸。默认禁转；`transferAllowlist` 放行。Owner 也可以 `mint`。
- NFT：仅金库 `mint(to, count)`，`_update` 禁止非零地址之间的转移。

---

## 8. 部署、导入、数百人

| 入口 | 作用 |
|------|------|
| `script/Deploy.s.sol` | `NETWORK=local\|bscTestnet\|bscMainnet`。主网需 `ALLOW_MAINNET=true` |
| `script/DeployLocal.s.sol` | 固定 local，给 `scripts/local-up.sh` 用 |
| `script/SeedLocal.s.sol` | 冻导入、开售、注册 `ROOTANVL` |
| `scripts/export-freedao.mjs` | `--network`。local / bscTestnet 写模拟地址和对照表 |
| `scripts/import-onchain.mjs` | 导入用户、邀请、本人业绩 |
| `scripts/scale-anvil.mjs` | 约 300 个地址的真实交易、gas 对比、root 和领取 |
| `scripts/scale-network.sh` | local 会部署并跑；测试网缺密钥时只打印说明，不假装已经上链 |

`test/NemoScale.t.sol` 覆盖无上级、只直推、跨档、小于 100U、深浅 gas。`test/NemoRewards.t.sol` 覆盖错误 proof、timelock、挑战撤销、垫付超帽、垫付后再领不双付。`test/SimMarket.t.sol` 仍跳过，它描述的是旧三档，不作为本结构的验收。

---

## 9. 刻意未做

- zkVM 证明
- 接入 UMA
- 把 NFT 改成一次铸造多枚的省 gas 写法
- 董事 1%、33 席、脱离制、`bracketReward`
- 正式币兑换
- 本期广播 BSC 主网
