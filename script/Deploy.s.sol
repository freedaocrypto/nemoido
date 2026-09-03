// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NemoIdo} from "../src/NemoIdo.sol";

/// @notice Mainnet/BSC deploy. Set USDT_ADDRESS and optionally OWNER.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address owner = vm.envOr("OWNER", vm.addr(pk));

        vm.startBroadcast(pk);
        NemoIdo ido = new NemoIdo(usdt, owner);
        vm.stopBroadcast();

        console2.log("NemoIdo", address(ido));
        console2.log("USDT", usdt);
        console2.log("owner", owner);
    }
}
