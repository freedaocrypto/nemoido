// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Deploy-time parameters. Pick one profile; the vault reverts if chainid does not match.
library NemoNetworks {
    struct Params {
        uint256 chainId;
        address usdt;
        uint256 rootTimelock;
        uint256 challengeBond;
        uint256 advancePerAccountCap;
        uint256 advanceDailyCap;
        uint256 directReferralBps;
        uint256 minIdo;
        uint256 minReferralAmount;
        uint256 tokensPerUsdt;
        uint256 weekDuration;
        bool weekByBlock;
        uint256 ambassadorMin;
        uint256 partnerMin;
    }

    function local() internal pure returns (Params memory p) {
        p.chainId = 31337;
        p.usdt = address(0);
        p.rootTimelock = 60;
        p.challengeBond = 1e18;
        p.advancePerAccountCap = 1_000e18;
        p.advanceDailyCap = 100_000e18;
        _shared(p);
        p.weekDuration = 30;
        p.weekByBlock = true;
    }

    function bscTestnet() internal pure returns (Params memory p) {
        p.chainId = 97;
        p.usdt = address(0);
        p.rootTimelock = 1 hours;
        p.challengeBond = 10e18;
        p.advancePerAccountCap = 500e18;
        p.advanceDailyCap = 50_000e18;
        _shared(p);
        p.weekDuration = 1 hours;
        p.weekByBlock = false;
    }

    function bscMainnet() internal pure returns (Params memory p) {
        p.chainId = 56;
        p.usdt = 0x55d398326f99059fF775485246999027B3197955;
        p.rootTimelock = 24 hours;
        p.challengeBond = 100e18;
        p.advancePerAccountCap = 1_000e18;
        p.advanceDailyCap = 100_000e18;
        _shared(p);
        p.weekDuration = 7 days;
        p.weekByBlock = false;
    }

    function _shared(
        Params memory p
    ) private pure {
        p.directReferralBps = 1000;
        p.minIdo = 1e18;
        p.minReferralAmount = 100e18;
        p.tokensPerUsdt = 100e18;
        p.ambassadorMin = 100e18;
        p.partnerMin = 1000e18;
    }
}
