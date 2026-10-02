// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INemoNftInterest {
    function settle(address account) external;
    function interestWeek(uint256 timestamp) external view returns (uint256);
    function noteSaleOpened() external;
}
