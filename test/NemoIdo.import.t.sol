// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoIdo} from "../src/NemoIdo.sol";

contract NemoIdoImportTest is NemoIdoBase {
    function test_importDoesNotAccrueRewards() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](2);
        bytes32[] memory codes = new bytes32[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        codes[0] = _code("ALICE001");
        codes[1] = _code("BOB00001");
        ido.importUsers(wallets, codes);

        address[] memory children = new address[](1);
        address[] memory refs = new address[](1);
        children[0] = bob;
        refs[0] = alice;
        ido.importReferrers(children, refs);

        address[] memory volW = new address[](2);
        uint256[] memory selves = new uint256[](2);
        uint256[] memory teams = new uint256[](2);
        volW[0] = alice;
        volW[1] = bob;
        selves[0] = 1000 * UNIT;
        selves[1] = 5000 * UNIT;
        teams[0] = 5000 * UNIT;
        teams[1] = 0;
        ido.importVolumes(volW, selves, teams);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();

        assertEq(ido.pendingOf(alice), 0);
        assertEq(ido.pendingOf(bob), 0);
        assertEq(_self(alice), 1000 * UNIT);
        assertEq(_team(alice), 5000 * UNIT);
        assertEq(ido.reservedRewards(), 0);

        _contribute(bob, 1000 * UNIT);
        assertEq(_direct(alice), 100 * UNIT);
        assertEq(_teamRewards(alice), 30 * UNIT); // team 6000 → 3%
        assertEq(_team(alice), 6000 * UNIT);
    }

    function test_importAfterFreezeReverts() public {
        vm.startPrank(owner);
        ido.freezeImport();
        address[] memory wallets = new address[](1);
        bytes32[] memory codes = new bytes32[](1);
        wallets[0] = alice;
        codes[0] = _code("ALICE001");
        vm.expectRevert(NemoIdo.ImportFrozenError.selector);
        ido.importUsers(wallets, codes);
        vm.stopPrank();
    }

    function test_importLengthMismatch() public {
        address[] memory wallets = new address[](2);
        bytes32[] memory codes = new bytes32[](1);
        wallets[0] = alice;
        wallets[1] = bob;
        codes[0] = _code("ALICE001");
        vm.prank(owner);
        vm.expectRevert(NemoIdo.LengthMismatch.selector);
        ido.importUsers(wallets, codes);
    }

    function test_importDuplicateUserReverts() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](1);
        bytes32[] memory codes = new bytes32[](1);
        wallets[0] = alice;
        codes[0] = _code("ALICE001");
        ido.importUsers(wallets, codes);
        vm.expectRevert(NemoIdo.AlreadyRegistered.selector);
        ido.importUsers(wallets, codes);
        vm.stopPrank();
    }

    function test_importReferrerCycleReverts() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](2);
        bytes32[] memory codes = new bytes32[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        codes[0] = _code("ALICE001");
        codes[1] = _code("BOB00001");
        ido.importUsers(wallets, codes);

        address[] memory children = new address[](2);
        address[] memory refs = new address[](2);
        children[0] = bob;
        children[1] = alice;
        refs[0] = alice;
        refs[1] = bob;
        vm.expectRevert(NemoIdo.Cycle.selector);
        ido.importReferrers(children, refs);
        vm.stopPrank();
    }

    function test_newDepositAfterImportAccrues() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](2);
        bytes32[] memory codes = new bytes32[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        codes[0] = _code("ROOTANVL");
        codes[1] = _code("BOB00001");
        ido.importUsers(wallets, codes);
        address[] memory children = new address[](1);
        address[] memory refs = new address[](1);
        children[0] = bob;
        refs[0] = alice;
        ido.importReferrers(children, refs);
        address[] memory volW = new address[](1);
        uint256[] memory selves = new uint256[](1);
        uint256[] memory teams = new uint256[](1);
        volW[0] = alice;
        selves[0] = 100 * UNIT;
        teams[0] = 0;
        ido.importVolumes(volW, selves, teams);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();

        assertEq(ido.pendingOf(alice), 0);
        _contribute(bob, 200 * UNIT);
        assertEq(_direct(alice), 20 * UNIT);
        vm.prank(alice);
        ido.claim();
        assertEq(ido.pendingOf(alice), 0);
    }
}
