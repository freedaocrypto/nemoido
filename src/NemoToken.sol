// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NemoToken
/// @notice Pre-issue IDO voucher (name/symbol: nemokey / NEMOKEY).
///         Fixed 500m supply minted once to the IDO vault.
///         Official listing will map by holder proportion; this contract does not swap.
contract NemoToken is ERC20, ERC20Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant CAP = 500_000_000e18;

    error ZeroAddress();
    error RescueSelf();

    constructor(
        address distribution,
        address initialOwner
    ) ERC20("nemokey", "NEMOKEY") Ownable(initialOwner) {
        if (distribution == address(0) || initialOwner == address(0)) revert ZeroAddress();
        _mint(distribution, CAP);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover tokens sent here by mistake. Cannot pull this token from holders.
    function rescue(
        IERC20 token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (address(token) == address(this)) revert RescueSelf();
        token.safeTransfer(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
