// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoIdo} from "../src/NemoIdo.sol";

contract NemoIdoTest is NemoIdoBase {
    function test_registerAndContribute_below100_noRewards() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 1000 * UNIT);
        _contribute(bob, 50 * UNIT);

        assertEq(_self(bob), 50 * UNIT);
        assertEq(_team(alice), 50 * UNIT);
        assertEq(_direct(alice), 0);
        assertEq(_teamRewards(alice), 0);
        assertEq(uint256(ido.roleOf(bob)), uint256(NemoIdo.Role.Explorer));
        assertEq(uint256(ido.roleOf(alice)), uint256(NemoIdo.Role.Partner));
    }

    function test_direct10Percent_whenReferrerAmbassador() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 100 * UNIT);
        _contribute(bob, 1000 * UNIT);

        assertEq(_direct(alice), 100 * UNIT);
        assertEq(ido.pendingOf(alice), 100 * UNIT);
        assertEq(uint256(ido.roleOf(alice)), uint256(NemoIdo.Role.Ambassador));
        assertEq(uint256(ido.roleOf(bob)), uint256(NemoIdo.Role.Partner));
    }

    function test_noDirectIfReferrerNotAmbassador() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 50 * UNIT);
        _contribute(bob, 1000 * UNIT);
        assertEq(_direct(alice), 0);
        assertEq(_team(alice), 1000 * UNIT);
    }

    function test_identityPartnerAndCoBuilder() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 1000 * UNIT);
        _contribute(bob, 30_000 * UNIT);
        assertEq(uint256(ido.roleOf(alice)), uint256(NemoIdo.Role.CoBuilder));
        assertEq(uint256(ido.roleOf(bob)), uint256(NemoIdo.Role.Partner));
    }

    function test_teamDifferential_parent9_child6() public {
        _seedTieredTree();
        _contribute(carol, 1000 * UNIT);

        // Carol's 1000: Bob is direct (10%) + team 6%; Alice team differential 3%.
        assertEq(_direct(bob), 100 * UNIT);
        assertEq(_teamRewards(bob), 60 * UNIT);
        assertEq(_direct(alice), 0);
        assertEq(_teamRewards(alice), 30 * UNIT);
        assertEq(ido.pendingOf(bob), 160 * UNIT);
        assertEq(ido.pendingOf(alice), 30 * UNIT);
    }

    function test_teamTiers_3_6_9() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 1000 * UNIT);

        _contribute(bob, 3000 * UNIT);
        assertEq(ido.teamBpsOf(alice), 300);
        assertEq(_teamRewards(alice), (3000 * UNIT * 300) / 10_000);

        _contribute(bob, 7000 * UNIT);
        assertEq(ido.teamBpsOf(alice), 600);

        _contribute(bob, 20_000 * UNIT);
        assertEq(ido.teamBpsOf(alice), 900);
        assertEq(uint256(ido.roleOf(alice)), uint256(NemoIdo.Role.CoBuilder));
    }

    function test_nonAmbassadorDoesNotOccupyTier() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](3);
        bytes32[] memory codes = new bytes32[](3);
        wallets[0] = alice;
        wallets[1] = bob;
        wallets[2] = carol;
        codes[0] = _code("ALICE001");
        codes[1] = _code("BOB00001");
        codes[2] = _code("CAROL001");
        ido.importUsers(wallets, codes);

        address[] memory children = new address[](2);
        address[] memory refs = new address[](2);
        children[0] = bob;
        children[1] = carol;
        refs[0] = alice;
        refs[1] = bob;
        ido.importReferrers(children, refs);

        address[] memory volW = new address[](2);
        uint256[] memory selves = new uint256[](2);
        uint256[] memory teams = new uint256[](2);
        volW[0] = alice;
        volW[1] = bob;
        selves[0] = 1000 * UNIT;
        selves[1] = 50 * UNIT; // not ambassador
        teams[0] = 30_000 * UNIT;
        teams[1] = 10_000 * UNIT;
        ido.importVolumes(volW, selves, teams);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();

        _contribute(carol, 1000 * UNIT);
        assertEq(_direct(bob), 0);
        assertEq(_teamRewards(bob), 0);
        assertEq(_teamRewards(alice), 90 * UNIT); // full 9%
    }

    function test_claimAndTreasuryReserve() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 100 * UNIT);
        _contribute(bob, 1000 * UNIT);

        uint256 pending = ido.pendingOf(alice);
        assertEq(pending, 100 * UNIT);
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        ido.claim();
        assertEq(usdt.balanceOf(alice), aliceBefore + pending);
        assertEq(ido.pendingOf(alice), 0);

        uint256 reserved = ido.reservedRewards();
        assertEq(reserved, 0);
        uint256 withdrawable = ido.treasuryWithdrawable();
        assertEq(withdrawable, usdt.balanceOf(address(ido)));
        vm.prank(owner);
        ido.withdrawTreasury(owner, withdrawable);
        assertEq(usdt.balanceOf(address(ido)), 0);
    }

    function test_cannotDrainReservedRewards() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 100 * UNIT);
        _contribute(bob, 1000 * UNIT);

        uint256 reserved = ido.reservedRewards();
        uint256 withdrawable = ido.treasuryWithdrawable();
        assertEq(reserved, 100 * UNIT);
        assertEq(withdrawable, 1100 * UNIT - 100 * UNIT);
        vm.prank(owner);
        vm.expectRevert(NemoIdo.InsufficientTreasury.selector);
        ido.withdrawTreasury(owner, withdrawable + 1);
    }

    function test_registerAndContribute_oneCall() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.prank(bob);
        ido.registerAndContribute(_code("BOB00001"), _code("ALICE001"), 50 * UNIT);
        assertTrue(ido.getAccount(bob).registered);
        assertEq(_self(bob), 50 * UNIT);
        assertEq(_team(alice), 50 * UNIT);
    }

    function test_bindReferrerOnce() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "");
        vm.prank(bob);
        ido.bindReferrer(_code("ALICE001"));
        vm.prank(bob);
        vm.expectRevert(NemoIdo.AlreadyBound.selector);
        ido.bindReferrer(_code("ALICE001"));
    }

    function test_selfReferralReverts() public {
        _openSale();
        vm.prank(alice);
        vm.expectRevert(NemoIdo.SelfReferral.selector);
        ido.register(_code("ALICE001"), _code("ALICE001"));
    }

    function test_cycleReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _register(carol, "CAROL001", "");
        vm.prank(alice);
        vm.expectRevert(NemoIdo.Cycle.selector);
        ido.bindReferrer(_code("BOB00001"));
    }

    function test_invalidCodeReverts() public {
        _openSale();
        vm.prank(alice);
        vm.expectRevert(NemoIdo.InvalidCode.selector);
        ido.register(bytes32(uint256(1)), bytes32(0));
    }

    function test_duplicateCodeReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.prank(bob);
        vm.expectRevert(NemoIdo.CodeTaken.selector);
        ido.register(_code("ALICE001"), bytes32(0));
    }

    function test_contributeRequiresSaleOpen() public {
        vm.prank(owner);
        ido.freezeImport();
        _register(alice, "ALICE001", "");
        vm.prank(alice);
        vm.expectRevert(NemoIdo.SaleClosedError.selector);
        ido.contribute(100 * UNIT);
    }

    function test_openSaleRequiresFrozenImport() public {
        vm.prank(owner);
        vm.expectRevert(NemoIdo.ImportNotFrozenError.selector);
        ido.openSale();
    }

    function test_minIdoEnforced() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.prank(alice);
        vm.expectRevert(NemoIdo.AmountTooSmall.selector);
        ido.contribute(1);
    }

    function test_adminParamChangeAppliesToNextDeposit() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 100 * UNIT);
        vm.prank(owner);
        ido.setDirectReferralBps(500);
        _contribute(bob, 1000 * UNIT);
        assertEq(_direct(alice), 50 * UNIT);
    }

    function test_setTeamTiers() public {
        vm.prank(owner);
        uint256[3] memory volumes = [uint256(1000 * UNIT), 2000 * UNIT, 3000 * UNIT];
        uint256[3] memory bps = [uint256(100), 200, 300];
        ido.setTeamTiers(volumes, bps);
        assertEq(ido.teamBpsForVolume(1000 * UNIT), 100);
        assertEq(ido.teamBpsForVolume(2000 * UNIT), 200);
        assertEq(ido.teamBpsForVolume(3000 * UNIT), 300);
    }

    function test_rewardCapOnParams() public {
        vm.prank(owner);
        vm.expectRevert(NemoIdo.RewardBpsTooHigh.selector);
        ido.setDirectReferralBps(9200); // 9200 + 900 > 10000
    }

    function testFuzz_teamPlusDirectCap(
        uint256 amount
    ) public {
        amount = bound(amount, 100 * UNIT, 8000 * UNIT);
        _seedTieredTree();
        uint256 aliceTeamBefore = _teamRewards(alice);
        uint256 bobTeamBefore = _teamRewards(bob);
        uint256 bobDirectBefore = _direct(bob);
        _contribute(carol, amount);

        uint256 teamPaid = (_teamRewards(alice) - aliceTeamBefore) + (_teamRewards(bob) - bobTeamBefore);
        uint256 directPaid = _direct(bob) - bobDirectBefore;
        assertLe(teamPaid, (amount * 900) / 10_000);
        assertLe(directPaid, (amount * 1000) / 10_000);
        assertLe(teamPaid + directPaid, (amount * 1900) / 10_000);
    }

    function test_rootanvlCodeAllowed() public {
        _openSale();
        _register(alice, "ROOTANVL", "");
        assertEq(ido.codeToAccount(_code("ROOTANVL")), alice);
    }

    function _seedTieredTree() internal {
        vm.startPrank(owner);
        address[] memory wallets = new address[](3);
        bytes32[] memory codes = new bytes32[](3);
        wallets[0] = alice;
        wallets[1] = bob;
        wallets[2] = carol;
        codes[0] = _code("ALICE001");
        codes[1] = _code("BOB00001");
        codes[2] = _code("CAROL001");
        ido.importUsers(wallets, codes);

        address[] memory children = new address[](2);
        address[] memory refs = new address[](2);
        children[0] = bob;
        children[1] = carol;
        refs[0] = alice;
        refs[1] = bob;
        ido.importReferrers(children, refs);

        address[] memory volW = new address[](2);
        uint256[] memory selves = new uint256[](2);
        uint256[] memory teams = new uint256[](2);
        volW[0] = alice;
        volW[1] = bob;
        selves[0] = 1000 * UNIT;
        selves[1] = 1000 * UNIT;
        teams[0] = 30_000 * UNIT;
        teams[1] = 10_000 * UNIT;
        ido.importVolumes(volW, selves, teams);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();
    }
}
