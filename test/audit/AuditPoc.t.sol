// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {NemoIdoBase} from "../helpers/NemoIdoBase.sol";
import {NemoIdo} from "../../src/NemoIdo.sol";
import {NemoNFT} from "../../src/NemoNFT.sol";
import {NemoNftInterest} from "../../src/NemoNftInterest.sol";
import {NemoRewards} from "../../src/NemoRewards.sol";
import {NemoToken} from "../../src/NemoToken.sol";
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
        vault.disburse(to, amount);
    }
}

/// @notice Reproductions for SECURITY-AUDIT-2026-09-23-R3.md. Each test asserts the
///         behaviour the report describes, so a fix will turn the test red.
contract AuditPocTest is NemoIdoBase {
    NemoRewards internal rewards;

    function setUp() public override {
        super.setUp();
        rewards = new NemoRewards(address(ido), owner, NemoNetworks.local());
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
        ido.proposeRewards(address(rogue));
        vm.warp(block.timestamp + 60);
        vm.prank(owner);
        ido.acceptRewards();

        uint256 free = usdt.balanceOf(address(ido)) - ido.directReserve();
        rogue.pull(ido, owner, free);
        assertEq(usdt.balanceOf(address(ido)), ido.directReserve());

        vm.prank(alice);
        vm.expectRevert(NemoIdo.NotRewards.selector);
        rewards.claim(500 * UNIT, new bytes32[](0));
    }

    /// H-2: the key that submits the daily root is the same key that can empty the treasury.
    function test_H2_rootPublisherIsFullOwner() public {
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);

        address bot = makeAddr("bot");
        vm.prank(bot);
        vm.expectRevert(NemoRewards.NotPublisher.selector);
        rewards.publishRoot(_leaf(alice, 1 * UNIT), bytes32("h"), 1 * UNIT, "");

        vm.startPrank(owner);
        rewards.publishRoot(_leaf(alice, 1 * UNIT), bytes32("h"), 1 * UNIT, "");
        uint256 all = ido.treasuryWithdrawable();
        ido.withdrawTreasury(owner, all);
        vm.stopPrank();
        assertEq(ido.treasuryWithdrawable(), 0);
    }

    /// M-1: the pending root is not reserved, so the treasury can be emptied during the timelock.
    function test_M1_pendingRootIsUnfunded() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);

        vm.prank(owner);
        rewards.publishRoot(_leaf(alice, 500 * UNIT), bytes32("h"), 500 * UNIT, "");
        // Accepted: the owner can still withdraw the unclaimed team reserve only up to
        // treasuryWithdrawable, which now locks `outstanding` the moment the root is live.
        assertEq(ido.treasuryWithdrawable() + rewards.outstanding() + ido.directReserve(), usdt.balanceOf(address(ido)));
        uint256 withdrawable = ido.treasuryWithdrawable();
        vm.prank(owner);
        ido.withdrawTreasury(owner, withdrawable);

        vm.prank(alice);
        rewards.claim(500 * UNIT, new bytes32[](0));
        assertEq(rewards.totalTeamPaid(), 500 * UNIT);
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
        _activate(_hashPair(la, lc), 1 * UNIT);
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

    /// M-3 fixed: a new root replaces the previous one immediately and stays claimable.
    function test_M3_republishStaysClaimable() public {
        _register(alice, "ALICE001", "");
        _contribute(alice, 10_000 * UNIT);
        vm.prank(owner);
        rewards.publishRoot(_leaf(alice, 10 * UNIT), bytes32("d1"), 10 * UNIT, "");
        vm.prank(owner);
        rewards.publishRoot(_leaf(alice, 20 * UNIT), bytes32("d2"), 20 * UNIT, "");
        assertEq(rewards.merkleRoot(), _leaf(alice, 20 * UNIT));
        vm.prank(alice);
        rewards.claim(20 * UNIT, new bytes32[](0));
        assertEq(rewards.totalTeamPaid(), 20 * UNIT);
    }

    /// L-1: a qualified referrer at 25% direct uses up the cap created by that deposit.
    function test_L1_directAtCapStarvesTeam() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(alice, 100 * UNIT);
        vm.prank(owner);
        ido.setDirectReferralBps(2500);
        _contribute(bob, 10_000 * UNIT);
        assertEq(_direct(alice), 2_500 * UNIT);

        vm.prank(owner);
        vm.expectRevert(NemoRewards.CapExceeded.selector);
        rewards.publishRoot(_leaf(alice, 26 * UNIT), bytes32("h"), 26 * UNIT, "");
    }

    /// L-2 fixed: there is no on-chain challenge entry. A stranger cannot publish.
    function test_L2_noOnChainChallenge() public {
        (bool ok,) = address(rewards).call(abi.encodeWithSignature("challenge()"));
        assertFalse(ok);
    }

    /// L-3 fixed: vault pause stops team payouts.
    function test_L3_pauseStopsTeamClaims() public {
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "ALICE001");
        _contribute(bob, 10_000 * UNIT);
        _activate(_leaf(alice, 100 * UNIT), 100 * UNIT);

        vm.prank(owner);
        ido.pause();
        vm.prank(alice);
        vm.expectRevert();
        rewards.claim(100 * UNIT, new bytes32[](0));
    }

    /// L-4: once NEMOKEY hits CAP, every deposit reverts.
    function test_L4_tokenCapBlocksDeposits() public {
        _register(alice, "ALICE001", "");
        vm.startPrank(owner);
        nemo.mint(owner, nemo.CAP());
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        ido.contribute(1 * UNIT);
    }

    /// Removed feature: the advance entry point no longer exists.
    function test_advanceEntryRemoved() public {
        (bool ok,) = address(rewards).call(
            abi.encodeWithSignature("claimAdvance(uint256,uint256,bytes)", 1 ether, block.timestamp + 1 hours, bytes(""))
        );
        assertFalse(ok);
        assertEq(rewards.totalTeamPaid(), 0);
    }

    function _activate(
        bytes32 root,
        uint256 cumulative
    ) internal {
        vm.prank(owner);
        rewards.publishRoot(root, bytes32("h"), cumulative, "");
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
}

/// @notice NFT interest reproductions for SECURITY-AUDIT-2026-09-23-R3.md.
contract InterestAuditPocTest is NemoIdoBase {
    NemoNftInterest internal interest;

    function setUp() public override {
        super.setUp();
        interest = new NemoNftInterest(address(ido), owner);
        vm.startPrank(owner);
        nemo.setInterestMinter(address(interest));
        ido.setNftInterest(address(interest));
        vm.stopPrank();
    }

    /// M-5: deposits, interest and manual grants share one CAP. At CAP, interest and deposits both stop.
    function test_M5_sharedCapBlocksInterestAndDeposits() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 30_000 * UNIT);
        vm.roll(block.number + 30);
        assertEq(interest.pending(alice), 90_000 * UNIT);

        uint256 room = nemo.CAP() - nemo.totalSupply();
        vm.prank(owner);
        nemo.mint(owner, room);

        vm.prank(alice);
        vm.expectRevert(NemoToken.CapExceeded.selector);
        interest.claim();

        vm.prank(alice);
        vm.expectRevert(NemoToken.CapExceeded.selector);
        ido.contribute(100 * UNIT);
    }

    /// L-8: grantNft has no ceiling and no record. The same account can be granted twice,
    ///      or granted without any imported volume, and every grant earns interest.
    function test_L8_grantNftIsUnbounded() public {
        vm.startPrank(owner);
        ido.importUsers(_one(alice), _oneCode("ALICE001"));
        ido.importVolumes(_one(alice), _oneAmount(1_000 * UNIT));
        vm.stopPrank();
        _openSale();
        _register(bob, "BOB00001", "");

        vm.prank(owner);
        ido.grantNft(alice, 2);
        assertEq(nft.balanceOf(alice), 2);
        vm.prank(owner);
        vm.expectRevert(NemoIdo.GrantExceedsImport.selector);
        ido.grantNft(alice, 1);
        vm.prank(owner);
        vm.expectRevert(NemoIdo.GrantExceedsImport.selector);
        ido.grantNft(bob, 60);
    }

    /// L-8: the NFT owner can repoint the minter and mint around the vault. The next
    ///      settle then pays past weeks at the new balance.
    function test_L8_directNftMintIsPaidRetroactively() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 1_000 * UNIT);
        vm.roll(block.number + 30 * 4);

        vm.prank(owner);
        vm.expectRevert(NemoNFT.MinterAlreadySet.selector);
        nft.setMinter(owner);
        assertEq(nft.balanceOf(alice), 2);
    }

    /// L-9: the first closeSale ends interest for good, even if the sale is reopened.
    function test_L9_firstCloseSaleEndsInterestForever() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 1_000 * UNIT);
        vm.startPrank(owner);
        ido.closeSale();
        ido.openSale();
        vm.stopPrank();
        assertFalse(ido.idoEnded());
        vm.prank(owner);
        ido.endIdo();
        assertTrue(ido.idoEnded());

        vm.roll(block.number + 30 * 5);
        assertEq(interest.pending(alice), 1_000 * UNIT);
    }

    /// I-11: buying in the last block of a week earns that whole week.
    function test_I11_lastBlockPurchaseEarnsTheWholeWeek() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.roll(block.number + 29);
        _contribute(alice, 1_000 * UNIT);
        vm.roll(block.number + 1);
        assertEq(interest.pending(alice), 1_000 * UNIT);
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

/// @notice Mainnet calendar clock reproductions.
contract InterestMainnetAuditPocTest is Test {
    /// L-10: on mainnet, granted NFTs earn before the sale ever opens.
    function test_L10_mainnetInterestAccruesBeforeSaleOpens() public {
        vm.chainId(56);
        vm.warp(1_790_000_000);
        NemoToken token = new NemoToken(address(this));
        NemoNFT pass = new NemoNFT(address(this), "NemoNFT", "NEMONFT");
        NemoNetworks.Params memory params = NemoNetworks.bscMainnet();
        NemoIdo ido = new NemoIdo(params.usdt, address(token), address(pass), address(this), params);
        NemoNftInterest interest = new NemoNftInterest(address(ido), address(this));
        token.setMinter(address(ido));
        token.setInterestMinter(address(interest));
        pass.setMinter(address(ido));
        ido.setNftInterest(address(interest));

        address early = makeAddr("early");
        address[] memory wallets = new address[](1);
        wallets[0] = early;
        bytes32[] memory codes = new bytes32[](1);
        codes[0] = bytes32("EARLY001");
        ido.importUsers(wallets, codes);
        uint256[] memory volumes = new uint256[](1);
        volumes[0] = 1_000e18;
        ido.importVolumes(wallets, volumes);
        ido.grantNft(early, 2);

        vm.warp(block.timestamp + 14 days);
        assertFalse(ido.saleOpen());
        assertEq(interest.pending(early), 0);
    }
}
