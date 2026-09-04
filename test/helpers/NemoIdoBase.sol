// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {NemoIdo} from "../../src/NemoIdo.sol";
import {NemoToken} from "../../src/NemoToken.sol";
import {MockUSDT} from "../../src/MockUSDT.sol";

contract NemoIdoBase is Test {
    uint256 internal constant UNIT = 1e18;

    MockUSDT internal usdt;
    NemoToken internal nemo;
    NemoIdo internal ido;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve");

    function setUp() public virtual {
        usdt = new MockUSDT();
        (ido, nemo) = _deployPair(address(usdt));
        _mintApprove(alice, 1_000_000 * UNIT);
        _mintApprove(bob, 1_000_000 * UNIT);
        _mintApprove(carol, 1_000_000 * UNIT);
        _mintApprove(dave, 1_000_000 * UNIT);
        _mintApprove(eve, 1_000_000 * UNIT);
    }

    function _deployPair(
        address usdtToken
    ) internal returns (NemoIdo vault, NemoToken token) {
        uint64 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        token = new NemoToken(predicted, owner);
        vault = new NemoIdo(usdtToken, address(token), owner);
        require(address(vault) == predicted, "ido pred");
    }

    function _mintApprove(
        address who,
        uint256 amount
    ) internal {
        usdt.mint(who, amount);
        vm.prank(who);
        usdt.approve(address(ido), type(uint256).max);
    }

    function _code(
        string memory s
    ) internal pure returns (bytes32 out) {
        bytes memory b = bytes(s);
        require(b.length > 0 && b.length <= 32, "code");
        assembly {
            out := mload(add(b, 32))
        }
    }

    function _openSale() internal {
        vm.startPrank(owner);
        ido.freezeImport();
        ido.openSale();
        vm.stopPrank();
    }

    function _register(
        address who,
        string memory code,
        string memory referrerCode
    ) internal {
        vm.prank(who);
        ido.register(_code(code), bytes(referrerCode).length == 0 ? bytes32(0) : _code(referrerCode));
    }

    function _contribute(
        address who,
        uint256 amount
    ) internal {
        vm.prank(who);
        ido.contribute(amount);
    }

    function _self(
        address who
    ) internal view returns (uint256) {
        (,, uint256 selfVolume,,,,,) = ido.accounts(who);
        return selfVolume;
    }

    function _team(
        address who
    ) internal view returns (uint256) {
        (,,, uint256 teamVolume,,,,) = ido.accounts(who);
        return teamVolume;
    }

    function _direct(
        address who
    ) internal view returns (uint256) {
        (,,,, uint256 directRewards,,,) = ido.accounts(who);
        return directRewards;
    }

    function _teamRewards(
        address who
    ) internal view returns (uint256) {
        (,,,,, uint256 teamRewards,,) = ido.accounts(who);
        return teamRewards;
    }
}
