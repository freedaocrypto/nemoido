// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "../lib/forge-std/src/Script.sol";
import {NemoToken} from "../src/NemoToken.sol";
import {NemoIdo} from "../src/NemoIdo.sol";

/// @notice Mainnet/BSC deploy. Set USDT_ADDRESS and optionally OWNER.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address usdt = vm.envAddress("USDT_ADDRESS");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);

        vm.startBroadcast(pk);
        NemoToken nemo = new NemoToken(deployer, owner);
        NemoIdo ido = new NemoIdo(usdt, address(nemo), owner);
        nemo.transfer(address(ido), nemo.CAP());
        vm.stopBroadcast();

        console2.log("NemoIdo", address(ido));
        console2.log("NEMOKEY", address(nemo));
        console2.log("USDT", usdt);
        console2.log("owner", owner);
    }
}
