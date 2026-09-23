// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "../lib/forge-std/src/Test.sol";
import {NemoIdoBase} from "./helpers/NemoIdoBase.sol";
import {NemoIdo} from "../src/NemoIdo.sol";
import {NemoNetworks} from "../src/network/NemoNetworks.sol";
import {NemoToken} from "../src/NemoToken.sol";
import {MockUSDT} from "../src/MockUSDT.sol";

contract NemoAllocationTest is NemoIdoBase {
    function test_week1_quote_100u_is_10000() public view {
        assertEq(ido.quote(100 * UNIT), 10_000 * UNIT);
    }

    function test_week1_quote_1000u_gets_2pct_bonus() public view {
        assertEq(ido.quote(1000 * UNIT), 102_000 * UNIT);
    }

    function test_quote_999u_no_bonus() public view {
        assertEq(ido.quote(999 * UNIT), 99_900 * UNIT);
    }

    function test_week2_quote_100u_is_9980() public {
        _openSale();
        vm.roll(block.number + 30);
        assertEq(ido.currentWeek(), 1);
        assertEq(ido.tokensPer100(1), 9980 * UNIT);
        assertEq(ido.quote(100 * UNIT), 9980 * UNIT);
    }

    function test_contributeMintsPlaceholderNemo() public {
        _openSale();
        _register(alice, "ALICE001", "");
        _contribute(alice, 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 10_000 * UNIT);
        assertEq(ido.totalNemoAllocated(), 10_000 * UNIT);
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
        volW[0] = alice;
        selves[0] = 1000 * UNIT;
        ido.importVolumes(volW, selves);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();

        assertEq(nemo.balanceOf(alice), 0);
        assertEq(ido.totalNemoAllocated(), 0);
    }

    function test_paramChangeAppliesToQuote() public {
        _openSale();
        vm.prank(owner);
        ido.setNemoSchedule(5000e18, 0, 7 days, 0);
        assertEq(ido.quote(100 * UNIT), 5000 * UNIT);
    }

    function test_emptyVaultStillMintsOnContribute() public {
        _openSale();
        _register(alice, "ALICE001", "");
        assertEq(nemo.balanceOf(address(ido)), 0);
        _contribute(alice, 100 * UNIT);
        assertEq(_self(alice), 100 * UNIT);
        assertEq(nemo.balanceOf(alice), 10_000 * UNIT);
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

    function test_wrongNetworkParamsRevert() public {
        vm.chainId(56);
        vm.expectRevert(NemoIdo.WrongNetwork.selector);
        new NemoIdo(address(usdt), address(nemo), address(nft), owner, NemoNetworks.local());
    }

    function test_week2_ceilMatchesQuote() public {
        _openSale();
        vm.roll(block.number + 30);
        uint256 amount = 1e18 + 1;
        uint256 quoted = ido.quote(amount);
        uint256 per100 = ido.tokensPer100(1);
        uint256 expected = (amount * per100 + 100e18 - 1) / 100e18;
        assertEq(quoted, expected);
    }
}

contract NemoTokenTest is Test {
    NemoToken internal token;
    address internal owner = makeAddr("owner");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal campaign = makeAddr("campaign");

    function setUp() public {
        token = new NemoToken(owner);
        vm.prank(owner);
        token.setMinter(minter);
    }

    function test_startsEmptyCapped() public view {
        assertEq(token.name(), "nemokey");
        assertEq(token.symbol(), "NEMOKEY");
        assertEq(token.totalSupply(), 0);
        assertEq(token.CAP(), 1_000_000_000e18);
        assertEq(token.minter(), minter);
    }

    function test_minterCanMint() public {
        vm.prank(minter);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_ownerCanMintCampaignInventory() public {
        vm.prank(owner);
        token.mint(campaign, 1000e18);
        assertEq(token.balanceOf(campaign), 1000e18);
    }

    function test_strangerMintReverts() public {
        vm.prank(alice);
        vm.expectRevert(NemoToken.NotAuthorized.selector);
        token.mint(alice, 1e18);
    }

    function test_capExceededReverts() public {
        uint256 cap = token.CAP();
        vm.prank(minter);
        token.mint(alice, cap);
        vm.prank(minter);
        vm.expectRevert(NemoToken.CapExceeded.selector);
        token.mint(alice, 1);
    }

    function test_plainTransferReverts() public {
        vm.prank(minter);
        token.mint(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        token.transfer(bob, 1e18);

        vm.prank(alice);
        token.approve(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_allowlistCampaignCanAirdrop() public {
        vm.prank(owner);
        token.mint(campaign, 100e18);
        vm.prank(owner);
        token.setTransferAllowlist(campaign, true);

        vm.prank(campaign);
        token.transfer(alice, 40e18);
        assertEq(token.balanceOf(alice), 40e18);

        vm.prank(alice);
        vm.expectRevert(NemoToken.TransfersLocked.selector);
        token.transfer(bob, 1e18);

        vm.prank(alice);
        token.transfer(campaign, 10e18);
        assertEq(token.balanceOf(campaign), 70e18);
    }

    function test_pauseBlocksMint() public {
        vm.prank(owner);
        token.pause();
        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 1e18);
        vm.prank(owner);
        token.unpause();
        vm.prank(minter);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);
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
