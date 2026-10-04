// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoNFT} from "../src/NemoNFT.sol";
import {NemoToken} from "../src/NemoToken.sol";

/// @notice Owner switches for NEMOKEY and the RWA pass. Both start locked.
contract TransfersEnabledTest is NemoIdoBase {
    function setUp() public override {
        super.setUp();
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "");
        _register(carol, "CAROL001", "");
        _contribute(alice, 100 * UNIT);
        _contribute(bob, 1000 * UNIT);
    }

    function test_nftStartsLockedAndOwnerCanToggle() public {
        assertFalse(nft.transfersEnabled());
        uint256 id = 1;
        assertEq(nft.ownerOf(id), bob);

        vm.prank(bob);
        vm.expectRevert(NemoNFT.TransfersLocked.selector);
        nft.transferFrom(bob, alice, id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setTransfersEnabled(true);

        vm.prank(owner);
        nft.setTransfersEnabled(true);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.ownerOf(id), alice);

        vm.prank(owner);
        nft.setTransfersEnabled(false);
        vm.prank(alice);
        vm.expectRevert(NemoNFT.TransfersLocked.selector);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), alice);
    }

    function test_nemokeyAllowlistRemainsWhenSwitchIsOff() public {
        assertFalse(nemo.transfersEnabled());
        vm.prank(alice);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        nemo.transfer(bob, 1 * UNIT);

        vm.prank(owner);
        nemo.setTransferAllowlist(alice, true);
        uint256 bobBefore = nemo.balanceOf(bob);
        vm.prank(alice);
        nemo.transfer(bob, 1 * UNIT);
        assertEq(nemo.balanceOf(bob), bobBefore + 1 * UNIT);

        uint256 bobBal = nemo.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        nemo.transfer(carol, 1 * UNIT);
        assertEq(nemo.balanceOf(bob), bobBal);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nemo.setTransfersEnabled(true);

        vm.prank(owner);
        nemo.setTransfersEnabled(true);
        vm.prank(bob);
        nemo.transfer(carol, 1 * UNIT);
        assertEq(nemo.balanceOf(carol), 1 * UNIT);

        vm.prank(owner);
        nemo.setTransfersEnabled(false);
        vm.prank(carol);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        nemo.transfer(bob, 1 * UNIT);

        vm.prank(alice);
        nemo.transfer(carol, 1 * UNIT);
        assertEq(nemo.balanceOf(carol), 2 * UNIT);
    }
}
