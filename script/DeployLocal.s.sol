// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDT} from "../src/MockUSDT.sol";
import {NemoIdo} from "../src/NemoIdo.sol";

/// @notice Local Anvil deploy: MockUSDT + NemoIdo, mint 1M USDT to #0–#3.
contract DeployLocal is Script {
    function run() external {
        uint256 pk =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        MockUSDT usdt = new MockUSDT();
        address[4] memory users = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906
        ];
        for (uint256 i = 0; i < users.length; i++) {
            usdt.mint(users[i], 1_000_000e18);
        }
        NemoIdo ido = new NemoIdo(address(usdt), deployer);
        vm.stopBroadcast();

        console2.log("USDT", address(usdt));
        console2.log("NemoIdo", address(ido));
        console2.log("owner", deployer);
    }
}
