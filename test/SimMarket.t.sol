// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {NemoIdo} from "../src/NemoIdo.sol";
import {NemoToken} from "../src/NemoToken.sol";
import {MockUSDT} from "../src/MockUSDT.sol";

/// @notice localdev market-promotion sim. Stops at phase 1: several CoBuilders + 3-tier differential.
contract SimMarket is Test {
    uint256 internal constant UNIT = 1e18;
    uint256 internal constant USER_COUNT = 3000;
    uint256 internal constant BANKROLL = 10_000 * UNIT;
    uint256 internal constant KOL_N = 8;
    uint256 internal constant CAP_PER_KOL = 3;
    uint256 internal constant AMB_PER_CAP = 10;
    uint256 internal constant LEAF_PER_AMB = 10;
    uint256 internal constant CAP_N = KOL_N * CAP_PER_KOL; // 24
    uint256 internal constant AMB_N = CAP_N * AMB_PER_CAP; // 240
    uint256 internal constant LEAF_N = AMB_N * LEAF_PER_AMB; // 2400
    uint256 internal constant TREE_N = 1 + KOL_N + CAP_N + AMB_N + LEAF_N; // 2673
    uint256 internal constant BATCH = 100;

    MockUSDT internal usdt;
    NemoToken internal nemo;
    NemoIdo internal ido;

    address[] internal users;

    string internal report;
    uint256 internal snapCount;
    uint256 internal contributeCount;
    uint256 internal firstCobuilderAt;
    bool internal sawThreeTier;
    bool internal recorded50u;

    address internal sample50Payer;
    uint256 internal sample50Amount;
    uint256 internal sample50Direct;
    uint256 internal sample50Team;
    uint256 internal sample50AmbTeamBefore;
    uint256 internal sample50AmbTeamAfter;

    address internal tierPayer;
    uint256 internal tierAmount;
    address internal tierAmb;
    address internal tierCap;
    address internal tierKol;
    uint256 internal tierDirect;
    uint256 internal tierAmbTeam;
    uint256 internal tierCapTeam;
    uint256 internal tierKolTeam;
    uint256 internal tierWeek;
    uint256 internal tierBlock;
    uint256 internal tierAmbBps;
    uint256 internal tierCapBps;
    uint256 internal tierKolBps;

    address internal obsAmb;
    address internal obsCap;
    address internal obsKol;
    uint256 internal obsDirect0;
    uint256 internal obsAmbTeamRew0;
    uint256 internal obsCapTeamRew0;
    uint256 internal obsKolTeamRew0;
    uint256 internal obsAmbVol0;
    uint256 internal obsCobuilders0;

    function setUp() public {
        usdt = new MockUSDT();
        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        nemo = new NemoToken(predicted, address(this));
        ido = new NemoIdo(address(usdt), address(nemo), address(this));
        require(address(ido) == predicted, "ido pred");

        users = new address[](USER_COUNT);
        for (uint256 i = 0; i < USER_COUNT; i++) {
            address who = vm.addr(i + 1);
            users[i] = who;
            usdt.mint(who, BANKROLL);
            vm.prank(who);
            usdt.approve(address(ido), type(uint256).max);
        }

        _importTree();
        ido.freezeImport();
        ido.openSale();
    }

    function test_phase1_cobuilders_and_three_tier_then_pause() public {
        report = unicode"# localdev 市场推广模拟报告（第一阶段）\n\n";
        report = string.concat(
            report,
            unicode"> 本报告由 `forge test --match-contract SimMarket` 根据链上实际记账生成，金额单位为整数 USDT（去掉 1e18）。\n\n",
            unicode"## 分支提醒\n\n",
            unicode"**禁止把 `localdev` 部署到 BSC 主网。** 本分支 `weekDuration = 30` 个区块，",
            unicode"`currentWeek()` 用 `block.number`。主网必须改回 `7 days` + `block.timestamp`。",
            unicode"构造函数已在 `chainid == 56` 拒绝部署。\n\n",
            unicode"## 模拟设定\n\n",
            unicode"- 地址：3000 个，每人预先打入 **10000 USDT**（开售前 mint + approve，不推进「周」）\n",
            unicode"- 邀请树：1 根 + 8 KOL + 24 团长 + 240 大使 + 2400 叶子（共 2673 人注册；其余 327 人只持币未注册）\n",
            unicode"- 入金：KOL/团长 1000U，大使 100U，叶子混杂 50 / 100 / 1000U\n",
            unicode"- 出块：每笔 `contribute` 后 `vm.roll(+1)`，每 30 块 nemokey 少发 20 枚/100U\n",
            unicode"- 停止条件：至少 3 个共建者，且出现一笔 3%/6%/9% 三段极差\n\n"
        );

        _snapshot(unicode"开售（尚无入金）");

        _payIdentity(users[0], 1000 * UNIT);
        for (uint256 i = 0; i < KOL_N; i++) {
            _payIdentity(users[_kolIndex(i)], 1000 * UNIT);
        }
        for (uint256 i = 0; i < CAP_N; i++) {
            _payIdentity(users[_capIndex(i)], 1000 * UNIT);
        }
        for (uint256 i = 0; i < AMB_N; i++) {
            _payIdentity(users[_ambIndex(i)], 100 * UNIT);
        }
        _snapshot(unicode"身份波结束（根/KOL/团长 1000U，大使 100U）");

        bool stopped;
        for (uint256 k = 0; k < KOL_N && !stopped; k++) {
            for (uint256 c = 0; c < CAP_PER_KOL && !stopped; c++) {
                for (uint256 a = 0; a < AMB_PER_CAP && !stopped; a++) {
                    for (uint256 l = 0; l < LEAF_PER_AMB && !stopped; l++) {
                        uint256 idx = _leafIndex(k, c, a, l);
                        uint256 amount = _leafAmount(l, idx);
                        _payAndObserve(users[idx], amount, k, c, a);
                        if (_cobuilderCount() >= 3 && sawThreeTier) {
                            stopped = true;
                        }
                    }
                }
            }
        }

        require(stopped, "phase1 stop condition not met");
        _snapshot(unicode"第一阶段暂停（共建者 >= 3 且已出现三段极差）");
        _appendAnalysis();
        vm.writeFile("docs/localdev-sim-report.md", report);

        console2.log("wrote docs/localdev-sim-report.md");
        console2.log("contributes", contributeCount);
        console2.log("week", ido.currentWeek());
        console2.log("block", block.number);
        console2.log("cobuilders", _cobuilderCount());
        console2.log("treasuryWithdrawable", usdtBal(ido.treasuryWithdrawable()));
        console2.log("contractUsdt", usdtBal(usdt.balanceOf(address(ido))));
    }

    // -------------------------------------------------------------------------
    // Tree indices: [root][8 kol][24 cap][240 amb][2400 leaf]
    // -------------------------------------------------------------------------

    function _kolIndex(
        uint256 k
    ) internal pure returns (uint256) {
        return 1 + k;
    }

    function _capIndex(
        uint256 i
    ) internal pure returns (uint256) {
        return 1 + KOL_N + i;
    }

    function _capIndexKC(
        uint256 k,
        uint256 c
    ) internal pure returns (uint256) {
        return 1 + KOL_N + k * CAP_PER_KOL + c;
    }

    function _ambIndex(
        uint256 i
    ) internal pure returns (uint256) {
        return 1 + KOL_N + CAP_N + i;
    }

    function _ambIndexKCA(
        uint256 k,
        uint256 c,
        uint256 a
    ) internal pure returns (uint256) {
        return 1 + KOL_N + CAP_N + (k * CAP_PER_KOL + c) * AMB_PER_CAP + a;
    }

    function _leafIndex(
        uint256 k,
        uint256 c,
        uint256 a,
        uint256 l
    ) internal pure returns (uint256) {
        uint256 ambSerial = (k * CAP_PER_KOL + c) * AMB_PER_CAP + a;
        return 1 + KOL_N + CAP_N + AMB_N + ambSerial * LEAF_PER_AMB + l;
    }

    function _leafAmount(
        uint256 leafSlot,
        uint256 userIndex
    ) internal pure returns (uint256) {
        // First three leaves under each ambassador put 1000U so teamVolume can cross 3000.
        if (leafSlot < 3) return 1000 * UNIT;
        uint256 r = uint256(keccak256(abi.encode(userIndex))) % 2;
        return r == 0 ? 50 * UNIT : 100 * UNIT;
    }

    function _importTree() internal {
        for (uint256 start = 0; start < TREE_N; start += BATCH) {
            uint256 n = start + BATCH > TREE_N ? TREE_N - start : BATCH;
            address[] memory wallets = new address[](n);
            bytes32[] memory codes = new bytes32[](n);
            for (uint256 j = 0; j < n; j++) {
                uint256 i = start + j;
                wallets[j] = users[i];
                codes[j] = _code8(i);
            }
            ido.importUsers(wallets, codes);
        }

        uint256 refN = TREE_N - 1;
        for (uint256 start = 0; start < refN; start += BATCH) {
            uint256 n = start + BATCH > refN ? refN - start : BATCH;
            address[] memory wallets = new address[](n);
            address[] memory refs = new address[](n);
            for (uint256 j = 0; j < n; j++) {
                uint256 i = start + j + 1;
                wallets[j] = users[i];
                refs[j] = users[_referrerIndex(i)];
            }
            ido.importReferrers(wallets, refs);
        }
    }

    function _referrerIndex(
        uint256 i
    ) internal pure returns (uint256) {
        if (i == 0) revert("root");
        if (i < 1 + KOL_N) return 0;
        if (i < 1 + KOL_N + CAP_N) {
            uint256 capSerial = i - (1 + KOL_N);
            return _kolIndex(capSerial / CAP_PER_KOL);
        }
        if (i < 1 + KOL_N + CAP_N + AMB_N) {
            uint256 ambSerial = i - (1 + KOL_N + CAP_N);
            return _capIndex(ambSerial / AMB_PER_CAP);
        }
        uint256 leafSerial = i - (1 + KOL_N + CAP_N + AMB_N);
        uint256 ambSerial2 = leafSerial / LEAF_PER_AMB;
        return _ambIndex(ambSerial2);
    }

    function _code8(
        uint256 i
    ) internal pure returns (bytes32 out) {
        bytes memory b = new bytes(8);
        b[0] = "U";
        uint256 n = i;
        for (uint256 k = 0; k < 7; k++) {
            b[7 - k] = bytes1(uint8(48 + (n % 10)));
            n /= 10;
        }
        assembly {
            out := mload(add(b, 32))
        }
    }

    // -------------------------------------------------------------------------
    // Contribute + observe
    // -------------------------------------------------------------------------

    function _pay(
        address who,
        uint256 amount
    ) internal {
        vm.prank(who);
        ido.contribute(amount);
        unchecked {
            contributeCount++;
        }
        vm.roll(block.number + 1);
    }

    function _payIdentity(
        address who,
        uint256 amount
    ) internal {
        uint256 before = _cobuilderCount();
        _pay(who, amount);
        if (before == 0 && _cobuilderCount() > 0) {
            _snapshot(unicode"第一个共建者出现");
        }
    }

    function _payAndObserve(
        address who,
        uint256 amount,
        uint256 k,
        uint256 c,
        uint256 a
    ) internal {
        obsAmb = users[_ambIndexKCA(k, c, a)];
        obsCap = users[_capIndexKC(k, c)];
        obsKol = users[_kolIndex(k)];
        obsCobuilders0 = _cobuilderCount();
        obsDirect0 = _directOf(obsAmb);
        obsAmbTeamRew0 = _teamRewOf(obsAmb);
        obsCapTeamRew0 = _teamRewOf(obsCap);
        obsKolTeamRew0 = _teamRewOf(obsKol);
        obsAmbVol0 = _teamVolOf(obsAmb);

        _pay(who, amount);
        _observeAfter(who, amount);
    }

    function _observeAfter(
        address who,
        uint256 amount
    ) internal {
        if (obsCobuilders0 == 0 && _cobuilderCount() > 0 && firstCobuilderAt == 0) {
            firstCobuilderAt = snapCount + 1;
            _snapshot(unicode"第一个共建者出现");
        }

        if (!recorded50u && amount < 100 * UNIT) {
            recorded50u = true;
            sample50Payer = who;
            sample50Amount = amount;
            sample50Team = (_teamRewOf(obsAmb) - obsAmbTeamRew0) + (_teamRewOf(obsCap) - obsCapTeamRew0)
                + (_teamRewOf(obsKol) - obsKolTeamRew0);
            sample50Direct = _directOf(obsAmb) - obsDirect0;
            sample50AmbTeamBefore = obsAmbVol0;
            sample50AmbTeamAfter = _teamVolOf(obsAmb);
        }

        if (sawThreeTier || amount < 100 * UNIT) return;
        if (ido.teamBpsOf(obsAmb) != 300 || ido.teamBpsOf(obsCap) != 600 || ido.teamBpsOf(obsKol) != 900) {
            return;
        }

        uint256 dAmb = _teamRewOf(obsAmb) - obsAmbTeamRew0;
        uint256 dCap = _teamRewOf(obsCap) - obsCapTeamRew0;
        uint256 dKol = _teamRewOf(obsKol) - obsKolTeamRew0;
        if (dAmb == 0 || dCap == 0 || dKol == 0) return;

        sawThreeTier = true;
        tierPayer = who;
        tierAmount = amount;
        tierAmb = obsAmb;
        tierCap = obsCap;
        tierKol = obsKol;
        tierDirect = _directOf(obsAmb) - obsDirect0;
        tierAmbTeam = dAmb;
        tierCapTeam = dCap;
        tierKolTeam = dKol;
        tierWeek = ido.currentWeek();
        tierBlock = block.number;
        tierAmbBps = 300;
        tierCapBps = 600;
        tierKolBps = 900;
        _snapshot(unicode"第一笔三段极差（3% / 6% / 9%）");
    }

    function _cobuilderCount() internal view returns (uint256 n) {
        if (uint256(ido.roleOf(users[0])) == uint256(NemoIdo.Role.CoBuilder)) n++;
        for (uint256 i = 0; i < KOL_N; i++) {
            if (uint256(ido.roleOf(users[_kolIndex(i)])) == uint256(NemoIdo.Role.CoBuilder)) n++;
        }
    }

    function _directOf(
        address who
    ) internal view returns (uint256) {
        (,,,, uint256 directRewards,,,) = ido.accounts(who);
        return directRewards;
    }

    function _teamRewOf(
        address who
    ) internal view returns (uint256) {
        (,,,,, uint256 teamRewards,,) = ido.accounts(who);
        return teamRewards;
    }

    function _selfOf(
        address who
    ) internal view returns (uint256) {
        (,, uint256 selfVolume,,,,,) = ido.accounts(who);
        return selfVolume;
    }

    function _teamVolOf(
        address who
    ) internal view returns (uint256) {
        (,,, uint256 teamVolume,,,,) = ido.accounts(who);
        return teamVolume;
    }

    function usdtBal(
        uint256 amount
    ) internal pure returns (uint256) {
        return amount / UNIT;
    }

    function _roleLabel(
        address who
    ) internal view returns (string memory) {
        uint256 r = uint256(ido.roleOf(who));
        if (r == 4) return "CoBuilder";
        if (r == 3) return "Partner";
        if (r == 2) return "Ambassador";
        if (r == 1) return "Explorer";
        return "None";
    }

    function _snapshot(
        string memory label
    ) internal {
        uint256 bal = usdtBal(usdt.balanceOf(address(ido)));
        uint256 wd = usdtBal(ido.treasuryWithdrawable());
        uint256 reserved = usdtBal(ido.reservedRewards());
        uint256 week = ido.currentWeek();
        uint256 per100 = ido.tokensPer100(week) / UNIT;
        uint256 contributed = usdtBal(ido.totalContributed());
        uint256 cobuilders = _cobuilderCount();

        console2.log("---- snapshot ----");
        console2.log(label);
        console2.log("block", block.number);
        console2.log("week", week);
        console2.log("tokensPer100", per100);
        console2.log("contributedU", contributed);
        console2.log("contractUsdtU", bal);
        console2.log("treasuryWithdrawableU", wd);
        console2.log("reservedRewardsU", reserved);
        console2.log("cobuilders", cobuilders);

        report = string.concat(
            report,
            "### ",
            label,
            "\n\n",
            unicode"| 项 | 值 |\n|---|---:|\n",
            "| block.number | ",
            vm.toString(block.number),
            " |\n",
            "| currentWeek | ",
            vm.toString(week),
            " |\n",
            unicode"| tokensPer100 (枚/100U) | ",
            vm.toString(per100),
            " |\n",
            unicode"| 累计入金 (U) | ",
            vm.toString(contributed),
            " |\n",
            unicode"| 合约 USDT 余额 (U) | ",
            vm.toString(bal),
            " |\n",
            "| treasuryWithdrawable (U) | ",
            vm.toString(wd),
            " |\n",
            "| reservedRewards (U) | ",
            vm.toString(reserved),
            " |\n",
            unicode"| 共建者人数（根+8 KOL） | ",
            vm.toString(cobuilders),
            " |\n",
            unicode"| 已入金笔数 | ",
            vm.toString(contributeCount),
            " |\n\n"
        );
        unchecked {
            snapCount++;
        }
    }

    function _appendAnalysis() internal {
        _appendCobuilders();
        _append50u();
        _appendTier();
        report = string.concat(
            report,
            unicode"## 暂停原因\n\n",
            unicode"已满足第一阶段目标：共建者人数 = ",
            vm.toString(_cobuilderCount()),
            unicode"，且已出现三段极差分配。后续推广波次未再跑。\n"
        );
    }

    function _appendCobuilders() internal {
        report = string.concat(report, unicode"## 共建者名单（根 + 8 个 KOL）\n\n");
        report = string.concat(
            report,
            unicode"| 角色 | 地址 | 本人 (U) | 伞下 (U) | 身份 | 团队档 bps |\n|---|---|---:|---:|---|---:|\n"
        );
        report = string.concat(report, _row("Root", users[0]));
        for (uint256 i = 0; i < KOL_N; i++) {
            report = string.concat(report, _row(string.concat("KOL", vm.toString(i)), users[_kolIndex(i)]));
        }
    }

    function _append50u() internal {
        report = string.concat(report, unicode"\n## 50U 入金（应无推广奖）\n\n");
        if (!recorded50u) {
            report = string.concat(report, unicode"本阶段叶子尚未出现 50U 入金。\n\n");
            return;
        }
        report = string.concat(
            report,
            unicode"付款人 `",
            vm.toString(sample50Payer),
            unicode"` 投入 **",
            vm.toString(usdtBal(sample50Amount)),
            unicode"U**。\n\n"
        );
        report = string.concat(
            report, unicode"- 直推增量：**", vm.toString(usdtBal(sample50Direct)), unicode"U**（应为 0）\n"
        );
        report = string.concat(
            report,
            unicode"- 整条链团队奖增量：**",
            vm.toString(usdtBal(sample50Team)),
            unicode"U**（应为 0）\n"
        );
        report = string.concat(
            report,
            unicode"- 直推人伞下业绩：",
            vm.toString(usdtBal(sample50AmbTeamBefore)),
            unicode"U → ",
            vm.toString(usdtBal(sample50AmbTeamAfter)),
            unicode"U（业绩仍计入）\n\n"
        );
        if (sample50Direct == 0 && sample50Team == 0 && sample50AmbTeamAfter == sample50AmbTeamBefore + sample50Amount)
        {
            report = string.concat(
                report, unicode"结论：与合约一致——`< 100U` 只加业绩、不发直推/团队奖。\n\n"
            );
        } else {
            report = string.concat(report, unicode"结论：**与预期不符，需要复查。**\n\n");
        }
    }

    function _appendTier() internal {
        report = string.concat(report, unicode"## 三段极差对照（抽一笔 ≥100U）\n\n");
        if (!sawThreeTier) {
            report = string.concat(report, unicode"未捕获三段极差。\n\n");
            return;
        }
        report = string.concat(
            report,
            unicode"付款人 `",
            vm.toString(tierPayer),
            unicode"` 投入 **",
            vm.toString(usdtBal(tierAmount)),
            unicode"U**（block ",
            vm.toString(tierBlock),
            unicode"，week ",
            vm.toString(tierWeek),
            unicode"）。\n\n"
        );
        report = string.concat(
            report,
            unicode"链：叶子 → 大使 `",
            vm.toString(tierAmb),
            unicode"`（",
            vm.toString(tierAmbBps),
            unicode" bps）→ 团长 `",
            vm.toString(tierCap),
            unicode"`（",
            vm.toString(tierCapBps),
            unicode" bps）→ KOL `",
            vm.toString(tierKol),
            unicode"`（",
            vm.toString(tierKolBps),
            unicode" bps）。\n\n",
            unicode"| 科目 | 公式 | 期望 (U) | 实际 (U) |\n|---|---|---:|---:|\n"
        );
        _tierRow(unicode"直推（大使）", unicode"amount × 10%", (tierAmount * 1000) / 10_000, tierDirect);
        _tierRow(unicode"大使团队", unicode"amount × 3%", (tierAmount * 300) / 10_000, tierAmbTeam);
        _tierRow(
            unicode"团长级差",
            unicode"amount × (6%-3%)",
            (tierAmount * (tierCapBps - tierAmbBps)) / 10_000,
            tierCapTeam
        );
        _tierRow(
            unicode"KOL 级差",
            unicode"amount × (9%-6%)",
            (tierAmount * (tierKolBps - tierCapBps)) / 10_000,
            tierKolTeam
        );
        uint256 expTeam = (tierAmount * 900) / 10_000;
        uint256 actTeam = tierAmbTeam + tierCapTeam + tierKolTeam;
        _tierRow(unicode"团队合计", unicode"<= 9%", expTeam, actTeam);
        _tierRow(unicode"直推+团队", unicode"<= 19%", (tierAmount * 1900) / 10_000, tierDirect + actTeam);
        report = string.concat(report, "\n");

        bool ok = tierDirect == (tierAmount * 1000) / 10_000 && tierAmbTeam == (tierAmount * 300) / 10_000
            && tierCapTeam == (tierAmount * 300) / 10_000 && tierKolTeam == (tierAmount * 300) / 10_000;
        if (ok && (tierDirect + actTeam) * 10_000 <= tierAmount * 1900) {
            report = string.concat(
                report,
                unicode"结论：实际记账与 `_settleDirect` / `_settleTeam` 公式一致。",
                unicode"直推与团队叠在大使身上（10%+3%），团长和 KOL 只拿级差，整条链不超过 19%。\n\n"
            );
        } else {
            report = string.concat(report, unicode"结论：**与公式不一致，需要复查。**\n\n");
        }
    }

    function _tierRow(
        string memory col1,
        string memory col2,
        uint256 expected,
        uint256 actual
    ) internal {
        report = string.concat(
            report,
            "| ",
            col1,
            " | ",
            col2,
            " | ",
            vm.toString(usdtBal(expected)),
            " | ",
            vm.toString(usdtBal(actual)),
            " |\n"
        );
    }

    function _row(
        string memory label,
        address who
    ) internal view returns (string memory) {
        return string.concat(
            "| ",
            label,
            " | `",
            vm.toString(who),
            "` | ",
            vm.toString(usdtBal(_selfOf(who))),
            " | ",
            vm.toString(usdtBal(_teamVolOf(who))),
            " | ",
            _roleLabel(who),
            " | ",
            vm.toString(ido.teamBpsOf(who)),
            " |\n"
        );
    }
}
