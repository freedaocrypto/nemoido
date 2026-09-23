// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC721} from "../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

/// @title NemoNFT
/// @notice Soulbound pass: one token per 500 USDT of self volume, minted by the vault.
///         Transfers are permanently disabled. No yield in this phase.
contract NemoNFT is ERC721, Ownable2Step {
    address public minter;
    uint256 public nextId;

    event MinterUpdated(address indexed minter);

    error ZeroAddress();
    error NotAuthorized();
    error TransfersLocked();
    error ZeroCount();

    constructor(
        address initialOwner
    ) ERC721("NemoNFT", "NEMONFT") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setMinter(
        address minter_
    ) external onlyOwner {
        if (minter_ == address(0)) revert ZeroAddress();
        minter = minter_;
        emit MinterUpdated(minter_);
    }

    function mint(
        address to,
        uint256 count
    ) external {
        if (msg.sender != minter) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();
        if (count == 0) revert ZeroCount();
        for (uint256 i = 0; i < count;) {
            unchecked {
                ++nextId;
                ++i;
            }
            _mint(to, nextId);
        }
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert TransfersLocked();
        return super._update(to, tokenId, auth);
    }
}
