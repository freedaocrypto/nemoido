// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "../lib/forge-std/src/Test.sol";
import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoIdo} from "../src/NemoIdo.sol";
import {NemoToken} from "../src/NemoToken.sol";
import {MockUSDT} from "../src/MockUSDT.sol";

contract NemoAllocationTest is NemoIdoBase {
    function test_week1_100u_is_10000_nemo() public {
        _openSale();
        _register(alice, "ALICE001", "");
        uint256 quoted = ido.quote(100 * UNIT);
        assertEq(quoted, 10_000 * UNIT);
        _contribute(alice, 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 10_000 * UNIT);
        assertEq(ido.totalNemoAllocated(), 10_000 * UNIT);
    }

    function test_week1_1000u_gets_2pct_bonus() public {
        _openSale();
        _register(alice, "ALICE001", "");
        assertEq(ido.quote(1000 * UNIT), 102_000 * UNIT);
        _contribute(alice, 1000 * UNIT);
        assertEq(nemo.balanceOf(alice), 102_000 * UNIT);
    }

    function test_999u_no_bonus() public {
        _openSale();
        _register(alice, "ALICE001", "");
        assertEq(ido.quote(999 * UNIT), 99_900 * UNIT);
        _contribute(alice, 999 * UNIT);
        assertEq(nemo.balanceOf(alice), 99_900 * UNIT);
    }

    function test_splitDeposits_miss_lump_bonus() public {
        _openSale();
        _register(alice, "ALICE001", "");
        for (uint256 i = 0; i < 10; i++) {
            _contribute(alice, 100 * UNIT);
        }
        assertEq(nemo.balanceOf(alice), 100_000 * UNIT);
        assertLt(nemo.balanceOf(alice), 102_000 * UNIT);
    }

    function test_week2_100u_is_9980() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.roll(block.number + 30);
        assertEq(ido.currentWeek(), 1);
        assertEq(ido.tokensPer100(1), 9980 * UNIT);
        assertEq(ido.quote(100 * UNIT), 9980 * UNIT);
        _contribute(alice, 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 9980 * UNIT);
    }

    function test_quoteMatchesTransfer() public {
        _openSale();
        _register(bob, "BOB00001", "");
        uint256 amount = 150 * UNIT;
        uint256 quoted = ido.quote(amount);
        _contribute(bob, amount);
        assertEq(nemo.balanceOf(bob), quoted);
    }

    function test_importDoesNotPayNemo() public {
        vm.startPrank(owner);
        address[] memory wallets = new address[](1);
        bytes32[] memory codes = new bytes32[](1);
        wallets[0] = alice;
        codes[0] = _code("ALICE001");
        ido.importUsers(wallets, codes);
        address[] memory volW = new address[](1);
        uint256[] memory selves = new uint256[](1);
        uint256[] memory teams = new uint256[](1);
        volW[0] = alice;
        selves[0] = 1000 * UNIT;
        teams[0] = 0;
        ido.importVolumes(volW, selves, teams);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();

        assertEq(nemo.balanceOf(alice), 0);
        assertEq(ido.totalNemoAllocated(), 0);
    }

    function test_paramChangeAppliesNextDeposit() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.prank(owner);
        ido.setNemoSchedule(5000e18, 0, 7 days, 0);
        assertEq(ido.quote(100 * UNIT), 5000 * UNIT);
        _contribute(alice, 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 5000 * UNIT);
    }

    function test_insufficientNemoReverts() public {
        _openSale();
        _register(alice, "ALICE001", "");
        uint256 left = nemo.balanceOf(address(ido));
        vm.prank(owner);
        ido.withdrawUnsoldNemo(owner, left);
        vm.prank(alice);
        vm.expectRevert(NemoIdo.InsufficientNemo.selector);
        ido.contribute(100 * UNIT);
    }

    function test_saleOpenedAtStableOnReopen() public {
        _openSale();
        uint256 opened = ido.saleOpenedAt();
        uint256 openedBlock = ido.saleOpenedBlock();
        vm.prank(owner);
        ido.closeSale();
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 10);
        vm.prank(owner);
        ido.openSale();
        assertEq(ido.saleOpenedAt(), opened);
        assertEq(ido.saleOpenedBlock(), openedBlock);
    }

    function test_localdevRejectsBscMainnet() public {
        vm.chainId(56);
        vm.expectRevert(NemoIdo.LocaldevNotForMainnet.selector);
        new NemoIdo(address(usdt), address(nemo), owner);
    }

    function test_week2_ceilMatchesQuote() public {
        _openSale();
        _register(alice, "ALICE001", "");
        vm.roll(block.number + 30);
        uint256 amount = 1e18 + 1;
        uint256 quoted = ido.quote(amount);
        uint256 per100 = ido.tokensPer100(1);
        uint256 expected = (amount * per100 + 100e18 - 1) / 100e18;
        assertEq(quoted, expected);
        _contribute(alice, amount);
        assertEq(nemo.balanceOf(alice), quoted);
    }
}

contract NemoTokenTest is Test {
    NemoToken internal token;
    address internal owner = makeAddr("owner");
    address internal ido = makeAddr("ido");
    address internal alice = makeAddr("alice");

    function setUp() public {
        token = new NemoToken(ido, owner);
    }

    function test_mintsCapToDistribution() public {
        assertEq(token.name(), "nemokey");
        assertEq(token.symbol(), "NEMOKEY");
        assertEq(token.totalSupply(), token.CAP());
        assertEq(token.balanceOf(ido), 500_000_000e18);
        assertEq(token.balanceOf(owner), 0);
    }

    function test_pauseBlocksTransfer() public {
        vm.prank(ido);
        token.transfer(alice, 1e18);
        vm.prank(owner);
        token.pause();
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(ido, 1e18);
        vm.prank(owner);
        token.unpause();
        vm.prank(alice);
        token.transfer(ido, 1e18);
    }

    function test_cannotRescueSelf() public {
        MockUSDT usdt = new MockUSDT();
        usdt.mint(address(token), 10e18);
        vm.prank(owner);
        token.rescue(usdt, owner, 10e18);
        assertEq(usdt.balanceOf(owner), 10e18);

        vm.prank(owner);
        vm.expectRevert(NemoToken.RescueSelf.selector);
        token.rescue(token, owner, 1);
    }
}
