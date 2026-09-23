// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoRewards} from "../src/NemoRewards.sol";
import {NemoNetworks} from "../src/network/NemoNetworks.sol";

contract NemoRewardsTest is NemoIdoBase {
    NemoRewards internal rewards;
    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    function setUp() public override {
        super.setUp();
        signer = vm.addr(signerPk);
        rewards = new NemoRewards(address(ido), owner, signer, NemoNetworks.local());
        vm.prank(owner);
        ido.setRewards(address(rewards));
    }

    function test_merklePaysTeamOnce() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 500 * UNIT);
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 1000 * UNIT);
        assertEq(_direct(alice), 100 * UNIT);

        bytes32 leaf = _leaf(alice, 30 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(leaf, keccak256("case1"), 30 * UNIT);
        vm.warp(block.timestamp + 60);
        rewards.activateRoot();

        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        rewards.claim(30 * UNIT, new bytes32[](0));
        assertEq(usdt.balanceOf(alice) - before, 30 * UNIT);
        assertEq(rewards.outstanding(), 0);

        vm.prank(alice);
        vm.expectRevert(NemoRewards.NothingToClaim.selector);
        rewards.claim(30 * UNIT, new bytes32[](0));
    }

    function test_activateBeforeTimelockReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 1 * UNIT), bytes32("h"), 1 * UNIT);
        vm.expectRevert(NemoRewards.TimelockNotElapsed.selector);
        rewards.activateRoot();
    }

    function test_badProofReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        bytes32 leaf = _leaf(alice, 10 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(leaf, bytes32("h"), 10 * UNIT);
        vm.warp(block.timestamp + 60);
        rewards.activateRoot();
        vm.prank(alice);
        vm.expectRevert(NemoRewards.InvalidProof.selector);
        rewards.claim(11 * UNIT, new bytes32[](0));
    }

    function test_challengeBlocksThenCancelRefunds() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 10 * UNIT), bytes32("h"), 10 * UNIT);

        vm.startPrank(carol);
        usdt.approve(address(rewards), type(uint256).max);
        rewards.challenge();
        vm.stopPrank();
        assertEq(usdt.balanceOf(address(rewards)), 1 * UNIT);

        vm.warp(block.timestamp + 60);
        vm.expectRevert(NemoRewards.ChallengedRoot.selector);
        rewards.activateRoot();

        uint256 before = usdt.balanceOf(carol);
        vm.prank(owner);
        rewards.cancelPending();
        assertEq(usdt.balanceOf(carol), before + 1 * UNIT);
    }

    function test_dismissChallengeThenActivate() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 10 * UNIT), bytes32("h"), 10 * UNIT);
        vm.startPrank(carol);
        usdt.approve(address(rewards), type(uint256).max);
        rewards.challenge();
        vm.stopPrank();

        uint256 ownerBefore = usdt.balanceOf(owner);
        vm.prank(owner);
        rewards.dismissChallenge();
        assertEq(usdt.balanceOf(owner), ownerBefore + 1 * UNIT);

        vm.warp(block.timestamp + 60);
        rewards.activateRoot();
        assertEq(rewards.merkleRoot(), _leaf(alice, 10 * UNIT));
    }

    function test_advanceThenMerkleDoesNotDoublePay() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 500 * UNIT);
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 1000 * UNIT);

        bytes memory sig = _sign(alice, 30 * UNIT, 0, block.timestamp + 1 hours);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        rewards.claimAdvance(30 * UNIT, block.timestamp + 1 hours, sig);
        assertEq(usdt.balanceOf(alice) - before, 30 * UNIT);

        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 30 * UNIT), bytes32("h"), 30 * UNIT);
        vm.warp(block.timestamp + 60);
        rewards.activateRoot();

        uint256 mid = usdt.balanceOf(alice);
        vm.prank(alice);
        rewards.claim(30 * UNIT, new bytes32[](0));
        assertEq(usdt.balanceOf(alice), mid);
        assertEq(rewards.outstanding(), 0);
        assertEq(rewards.claimed(alice), 30 * UNIT);
    }

    function test_advanceAboveCapReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 100_000 * UNIT);
        bytes memory sig = _sign(alice, 1001 * UNIT, 0, block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(NemoRewards.AdvanceExceeded.selector);
        rewards.claimAdvance(1001 * UNIT, block.timestamp + 1 hours, sig);
    }

    function test_rootAboveGlobalCapReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 1000 * UNIT);
        vm.prank(owner);
        vm.expectRevert(NemoRewards.CapExceeded.selector);
        rewards.submitRoot(_leaf(alice, 200 * UNIT), bytes32("h"), 200 * UNIT);
    }

    function test_mainnetParamsRejectLocalChain() public {
        vm.expectRevert(NemoRewards.WrongNetwork.selector);
        new NemoRewards(address(ido), owner, signer, NemoNetworks.bscMainnet());
    }

    function _leaf(
        address account,
        uint256 cumulative
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function _sign(
        address account,
        uint256 cumulative,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = rewards.advanceDigest(account, cumulative, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
