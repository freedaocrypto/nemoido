// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "../helpers/NemoIdoBase.sol";
import {NemoIdo} from "../../src/NemoIdo.sol";
import {NemoNftInterest} from "../../src/NemoNftInterest.sol";
import {NemoRewards} from "../../src/NemoRewards.sol";
import {NemoNetworks} from "../../src/network/NemoNetworks.sol";

/// @notice Reproductions for SECURITY-AUDIT-2026-09-24-R5.md. Each test asserts the
///         behaviour the report describes, so a fix will turn the test red.
contract AuditPocR5Test is NemoIdoBase {
    NemoRewards internal rewards;
    NemoNftInterest internal interest;
    address internal bot = makeAddr("publisher");

    function setUp() public override {
        super.setUp();
        rewards = new NemoRewards(address(ido), owner, NemoNetworks.local());
        interest = new NemoNftInterest(address(ido), owner);
        vm.startPrank(owner);
        ido.setRewards(address(rewards));
        nemo.setInterestMinter(address(interest));
        ido.setNftInterest(address(interest));
        rewards.setPublisher(bot);
        vm.stopPrank();
    }

    /// R5-M1: with maxRootIncrease = 0, a leaked publisher key publishes a root that pays
    ///        itself up to the 25% cap and claims it in the same block.
    function test_R5_M1_leakedPublisherDrainsToCap() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        uint256 room = rewards.rewardCap() - ido.totalDirectAccrued();
        assertEq(room, 2_500 * UNIT);

        vm.prank(bot);
        rewards.publishRoot(_leaf(bot, room), bytes32("x"), room, "");
        vm.prank(bot);
        rewards.claim(room, new bytes32[](0));
        assertEq(usdt.balanceOf(bot), room);
    }

    /// R5-M1 mitigation: a per-publish ceiling bounds the same attack.
    function test_R5_M1_maxRootIncreaseBoundsLeak() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        vm.prank(owner);
        rewards.setMaxRootIncrease(100 * UNIT);

        vm.prank(bot);
        vm.expectRevert(NemoRewards.IncreaseTooLarge.selector);
        rewards.publishRoot(_leaf(bot, 1_500 * UNIT), bytes32("x"), 1_500 * UNIT, "");
    }

    /// R5-L1 fixed: at the NFT cap the deposit still goes through. The vault mints what is
    ///       left of the cap and records the rest as deferred for the next phase.
    function test_R5_L1_nftCapDefersInsteadOfReverting() public {
        vm.startPrank(owner);
        ido.importUsers(_one(carol), _oneCode("CAROL001"));
        ido.importVolumes(_one(carol), _oneAmount(9_999 * 500 * UNIT));
        vm.stopPrank();
        _openSale();
        _register(bob, "BOB00001", "");
        _register(alice, "ALICE001", "BOB00001");
        _contribute(bob, 100 * UNIT);

        vm.expectEmit(address(ido));
        emit NemoIdo.NftDeferred(alice, 1);
        _contribute(alice, 1_000 * UNIT);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(ido.nftDeferred(alice), 1);
        assertEq(ido.nftsAllocated(), 10_000);
        assertEq(_direct(bob), 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 100_000 * UNIT);

        _contribute(alice, 1_000 * UNIT);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(ido.nftDeferred(alice), 3);
        assertEq(ido.nftsAllocated(), 10_000);
        assertEq(usdt.balanceOf(address(ido)), 2_100 * UNIT);
    }

    /// Deferred NFTs do not exist in this phase, so they earn no interest here.
    function test_R5_L1_deferredNftsEarnNoInterest() public {
        vm.startPrank(owner);
        ido.importUsers(_one(carol), _oneCode("CAROL001"));
        ido.importVolumes(_one(carol), _oneAmount(10_000 * 500 * UNIT));
        vm.stopPrank();
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 30_000 * UNIT);
        assertEq(nft.balanceOf(alice), 0);
        assertEq(ido.nftDeferred(alice), 60);
        vm.roll(block.number + 30 * 2);
        assertEq(interest.pending(alice), 0);
    }

    /// R5-L2: endIdo stops interest but not the sale. Deposits still mint NEMOKEY and NFTs.
    function test_R5_L2_endIdoLeavesSaleOpen() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.prank(owner);
        ido.endIdo();
        assertTrue(ido.saleOpen());

        _contribute(alice, 1_000 * UNIT);
        assertEq(nft.balanceOf(alice), 2);
        vm.roll(block.number + 30 * 3);
        assertEq(interest.pending(alice), 0);
    }

    /// R5-L3: NFT interest claims ignore the vault pause.
    function test_R5_L3_interestClaimIgnoresPause() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 1_000 * UNIT);
        vm.roll(block.number + 30);
        vm.prank(owner);
        ido.pause();

        uint256 before = nemo.balanceOf(alice);
        vm.prank(alice);
        interest.claim();
        assertEq(nemo.balanceOf(alice) - before, 1_000 * UNIT);
    }

    /// R5-L4: interest clipped by the global cap is dropped, not deferred. Raising the cap
    ///        later does not restore the weeks already settled.
    function test_R5_L4_clippedInterestIsLost() public {
        vm.prank(owner);
        interest.setInterestCap(1_000 * UNIT);
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "");
        _contribute(alice, 1_000 * UNIT);
        _contribute(bob, 1_000 * UNIT);
        vm.roll(block.number + 30);

        _contribute(alice, 100 * UNIT);
        _contribute(bob, 100 * UNIT);
        assertEq(interest.accrued(alice), 1_000 * UNIT);
        assertEq(interest.accrued(bob), 0);

        vm.prank(owner);
        interest.setInterestCap(50_000_000 * UNIT);
        assertEq(interest.pending(bob), 0);
    }

    /// R5-I1: interest principal uses the rate snapshotted by the tier version, so a later
    ///        setTokensPerUsdt does not change interest until setTiers is called again.
    function test_R5_I1_rateChangeNeedsNewTierVersion() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 1_000 * UNIT);
        vm.prank(owner);
        ido.setTokensPerUsdt(200e18);
        vm.roll(block.number + 30);
        assertEq(interest.pending(alice), 1_000 * UNIT);
    }

    function _leaf(
        address account,
        uint256 cumulative
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
    }

    function _one(
        address account
    ) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _oneCode(
        string memory code
    ) internal pure returns (bytes32[] memory codes) {
        codes = new bytes32[](1);
        codes[0] = _code(code);
    }

    function _oneAmount(
        uint256 amount
    ) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
