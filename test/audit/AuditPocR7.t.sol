// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {NemoIdoBase} from "../helpers/NemoIdoBase.sol";
import {NemoIdo} from "../../src/NemoIdo.sol";
import {NemoNftInterest} from "../../src/NemoNftInterest.sol";

/// @notice Attacker-view reproductions. Each test asserts current behaviour, so a fix turns it red.
contract AuditPocR7Test is NemoIdoBase {
    NemoNftInterest internal interest;

    function setUp() public override {
        super.setUp();
        interest = new NemoNftInterest(address(ido), owner);
        vm.startPrank(owner);
        nemo.setInterestMinter(address(interest));
        ido.setNftInterest(address(interest));
        vm.stopPrank();
    }

    /// The site hands out the invite code before it is on chain. Whoever registers it first owns it:
    /// the real owner's first deposit reverts, and people using the real owner's link bind to the attacker.
    function test_R7_squattedInviteCodeHijacksDownline() public {
        _openSale();
        _register(eve, "VICTIM88", "");
        _contribute(eve, 100 * UNIT);

        vm.prank(alice);
        vm.expectRevert(NemoIdo.CodeTaken.selector);
        ido.registerAndContribute(_code("VICTIM88"), bytes32(0), 1_000 * UNIT);

        vm.prank(bob);
        ido.registerAndContribute(_code("BOB00001"), _code("VICTIM88"), 10_000 * UNIT);
        assertEq(ido.referrerOf(bob), eve);
        assertEq(_direct(eve), 1_000 * UNIT);
    }

    /// A second wallet as one's own referrer returns 10% of every deposit as USDT, claimable at once.
    function test_R7_sybilSelfReferralRebate() public {
        _openSale();
        _register(eve, "EVEMAIN1", "");
        _contribute(eve, 100 * UNIT);
        _register(dave, "EVEALT01", "EVEMAIN1");
        _contribute(dave, 10_000 * UNIT);

        uint256 before = usdt.balanceOf(eve);
        vm.prank(eve);
        ido.claim();
        assertEq(usdt.balanceOf(eve) - before, 1_000 * UNIT);
    }

    /// Interest is not time-weighted: an NFT minted in the last block of a week earns the same
    /// full week as one minted in the first block.
    function test_R7_lastBlockDepositEarnsFullWeek() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _register(bob, "BOB00001", "");
        uint256 start = ido.saleOpenedBlock();
        uint256 week = ido.weekDuration();

        vm.roll(start + week);
        _contribute(alice, 1_000 * UNIT);
        vm.roll(start + 2 * week - 1);
        _contribute(bob, 1_000 * UNIT);
        vm.roll(start + 2 * week);

        assertGt(interest.pending(alice), 0);
        assertEq(interest.pending(alice), interest.pending(bob));
    }
}
