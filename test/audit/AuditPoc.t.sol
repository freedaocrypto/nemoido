// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "../helpers/NemoIdoBase.sol";
import {NemoIdo} from "../../src/NemoIdo.sol";
import {NemoRewards} from "../../src/NemoRewards.sol";
import {NemoNetworks} from "../../src/network/NemoNetworks.sol";

/// @notice Stand-in for a rewards address the owner points the vault at.
contract RogueRewards {
    function outstanding() external pure returns (uint256) {
        return 0;
    }

    function pull(
        NemoIdo vault,
        address to,
        uint256 amount
    ) external {
        vault.disburse(to, amount, true);
    }
}

/// @notice Reproductions for SECURITY-AUDIT-2026-09-23.md. Each test asserts the
///         behaviour the report describes, so a fix will turn the test red.
contract AuditPocTest is NemoIdoBase {
    NemoRewards internal rewards;
    uint256 internal signerPk = 0xA11CE;
    address internal signer;

    function setUp() public override {
        super.setUp();
        signer = vm.addr(signerPk);
        rewards = new NemoRewards(address(ido), owner, signer, NemoNetworks.local());
        vm.prank(owner);
        ido.setRewards(address(rewards));
        _openSale();
    }

    /// H-1: swapping the rewards pointer releases the active root's reserve.
    function test_H1_setRewardsDrainsTeamReserve() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        _activate(_leaf(alice, 500 * UNIT), 500 * UNIT);
        assertEq(rewards.outstanding(), 500 * UNIT);

        RogueRewards rogue = new RogueRewards();
        vm.prank(owner);
        ido.setRewards(address(rogue));

        uint256 free = usdt.balanceOf(address(ido)) - ido.directReserve();
        rogue.pull(ido, owner, free);
        assertEq(usdt.balanceOf(address(ido)), ido.directReserve());

        vm.prank(alice);
        vm.expectRevert(NemoIdo.NotRewards.selector);
        rewards.claim(500 * UNIT, new bytes32[](0));
    }

    /// M-1: the pending root is not reserved, so the treasury can be emptied during the timelock.
    function test_M1_pendingRootIsUnfunded() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);

        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 500 * UNIT), bytes32("h"), 500 * UNIT);
        uint256 withdrawable = ido.treasuryWithdrawable();
        vm.prank(owner);
        ido.withdrawTreasury(owner, withdrawable);

        vm.warp(block.timestamp + 60);
        rewards.activateRoot();
        vm.prank(alice);
        vm.expectRevert(NemoIdo.InsufficientTreasury.selector);
        rewards.claim(500 * UNIT, new bytes32[](0));
    }

    /// M-2: `cumulative` is not tied to the leaves. Under-declaring it shrinks the reserve.
    function test_M2_underDeclaredCumulativeLeavesClaimsUnfunded() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _register(carol, "CAROL001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        _contribute(carol, 10_000 * UNIT);

        bytes32 la = _leaf(alice, 400 * UNIT);
        bytes32 lc = _leaf(carol, 400 * UNIT);
        bytes32 root = _hashPair(la, lc);
        _activate(root, 1 * UNIT);
        assertEq(rewards.outstanding(), 1 * UNIT);

        uint256 withdrawable = ido.treasuryWithdrawable();
        vm.prank(owner);
        ido.withdrawTreasury(owner, withdrawable);

        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = lc;
        vm.prank(alice);
        vm.expectRevert(NemoIdo.InsufficientTreasury.selector);
        rewards.claim(400 * UNIT, proofA);
    }

    /// M-3: a leaked advance signer pays accounts that never deposited, with no root at all.
    function test_M3_advanceSignerPaysWithoutRoot() public {
        _register(alice, "ALICE001", "");
        _contribute(alice, 100_000 * UNIT);
        assertEq(rewards.merkleRoot(), bytes32(0));

        uint256 paid;
        for (uint256 i = 0; i < 20; i++) {
            address sybil = address(uint160(0xBEEF00 + i));
            uint256 deadline = block.timestamp + 1 hours;
            bytes memory sig = _sign(sybil, 1_000 * UNIT, 0, deadline);
            vm.prank(sybil);
            rewards.claimAdvance(1_000 * UNIT, deadline, sig);
            paid += usdt.balanceOf(sybil);
        }
        assertEq(paid, 20_000 * UNIT);
        assertEq(rewards.totalTeamPaid(), 20_000 * UNIT);

        vm.prank(owner);
        vm.expectRevert(NemoRewards.CumulativeTooLow.selector);
        rewards.submitRoot(_leaf(alice, 1 * UNIT), bytes32("h"), 1 * UNIT);
    }

    /// L-1: a prepaid amount stays inside `outstanding` until the user submits a proof.
    function test_L1_prepaidStaysReservedUntilUserClaims() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(alice, 300 * UNIT, 0, deadline);
        vm.prank(alice);
        rewards.claimAdvance(300 * UNIT, deadline, sig);

        _activate(_leaf(alice, 300 * UNIT), 300 * UNIT);
        assertEq(rewards.outstanding(), 300 * UNIT);
        assertEq(ido.reservedRewards(), ido.directReserve() + 300 * UNIT);
    }

    /// L-2: direct referral at the 25% ceiling leaves no room for any team payout.
    function test_L2_directAtCapStarvesTeam() public {
        vm.prank(owner);
        ido.setDirectReferralBps(2500);
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);

        vm.prank(owner);
        vm.expectRevert(NemoRewards.CapExceeded.selector);
        rewards.submitRoot(_leaf(alice, 1 * UNIT), bytes32("h"), 1 * UNIT);
    }

    /// L-3: an attacker can challenge every root; the owner is the only judge.
    function test_L3_ownerDecidesChallenge() public {
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        vm.prank(owner);
        rewards.submitRoot(_leaf(alice, 10 * UNIT), bytes32("h"), 10 * UNIT);

        vm.startPrank(carol);
        usdt.approve(address(rewards), type(uint256).max);
        rewards.challenge();
        vm.stopPrank();

        uint256 before = usdt.balanceOf(owner);
        vm.prank(owner);
        rewards.dismissChallenge();
        assertEq(usdt.balanceOf(owner), before + 1 * UNIT);

        vm.prank(carol);
        rewards.challenge();
        vm.warp(block.timestamp + 60);
        vm.expectRevert(NemoRewards.ChallengedRoot.selector);
        rewards.activateRoot();
    }

    /// L-4: vault pause does not stop team payouts.
    function test_L4_pauseDoesNotStopTeamClaims() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        _activate(_leaf(alice, 100 * UNIT), 100 * UNIT);

        vm.prank(owner);
        ido.pause();
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        rewards.claim(100 * UNIT, new bytes32[](0));
        assertEq(usdt.balanceOf(alice) - before, 100 * UNIT);
    }

    /// L-5: once NEMOKEY hits CAP, every deposit reverts.
    function test_L5_tokenCapBlocksDeposits() public {
        _register(alice, "ALICE001", "");
        vm.startPrank(owner);
        nemo.mint(owner, nemo.CAP());
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        ido.contribute(1 * UNIT);
    }

    function _activate(
        bytes32 root,
        uint256 cumulative
    ) internal {
        vm.prank(owner);
        rewards.submitRoot(root, bytes32("h"), cumulative);
        vm.warp(block.timestamp + 60);
        rewards.activateRoot();
    }

    function _leaf(
        address account,
        uint256 cumulative
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function _hashPair(
        bytes32 a,
        bytes32 b
    ) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
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
