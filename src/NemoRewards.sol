// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {EIP712} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {INemoVaultPay} from "./INemoRewards.sol";
import {NemoNetworks} from "./network/NemoNetworks.sol";

/// @title NemoRewards
/// @notice Cumulative Merkle root is the authority. An EIP-712 signature may advance
///         only the unpaid delta, and only up to the per-account and daily caps.
///         USDT stays in the vault; this contract calls `disburse`.
contract NemoRewards is Ownable2Step, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REWARD_CAP_BPS = 2500;
    bytes32 public constant ADVANCE_TYPEHASH =
        keccak256("Advance(address account,uint256 cumulative,uint256 nonce,uint256 deadline)");

    INemoVaultPay public immutable vault;
    IERC20 public immutable usdt;

    uint256 public immutable rootTimelock;
    uint256 public immutable challengeBond;
    uint256 public immutable advancePerAccountCap;
    uint256 public immutable advanceDailyCap;

    address public advanceSigner;

    bytes32 public merkleRoot;
    bytes32 public contentHash;
    /// @notice Sum of leaf cumulatives committed by the active root.
    uint256 public committed;
    /// @notice Portion of `committed` already attributed to proven leaves (paid or prepaid).
    uint256 public rootPaid;

    bytes32 public pendingRoot;
    bytes32 public pendingContentHash;
    uint256 public pendingCumulative;
    uint256 public pendingEta;
    address public challenger;

    /// @notice Cumulative USDT already sent to the account (merkle + advance).
    mapping(address => uint256) public claimed;
    /// @notice Highest proven leaf cumulative attributed to the account.
    mapping(address => uint256) public rootAttributed;
    mapping(address => uint256) public nonces;

    uint256 public totalTeamPaid;
    uint256 public advanceDay;
    uint256 public advanceDayUsed;
    mapping(address => uint256) public advanceAccountDay;
    mapping(address => uint256) public advanceAccountUsed;

    event AdvanceSignerUpdated(address indexed signer);
    event RootSubmitted(bytes32 indexed root, bytes32 contentHash, uint256 cumulative, uint256 eta);
    event RootActivated(bytes32 indexed root, uint256 cumulative);
    event RootCancelled(bytes32 indexed root);
    event Challenged(address indexed challenger, bytes32 indexed root);
    event ChallengeDismissed(address indexed challenger);
    event TeamClaimed(address indexed account, uint256 cumulative, uint256 paid);
    event AdvanceClaimed(address indexed account, uint256 cumulative, uint256 paid);

    error ZeroAddress();
    error WrongNetwork();
    error TimelockNotElapsed();
    error ChallengedRoot();
    error NoPending();
    error CumulativeTooLow();
    error NothingToClaim();
    error InvalidProof();
    error CapExceeded();
    error AdvanceExceeded();
    error BadSignature();
    error Expired();
    error BondNotMet();

    constructor(
        address vault_,
        address initialOwner,
        address signer_,
        NemoNetworks.Params memory params
    ) Ownable(initialOwner) EIP712("NemoRewards", "1") {
        if (block.chainid != params.chainId) revert WrongNetwork();
        if (vault_ == address(0) || initialOwner == address(0) || signer_ == address(0)) revert ZeroAddress();
        if (params.rootTimelock == 0 || params.challengeBond == 0) revert BondNotMet();
        vault = INemoVaultPay(vault_);
        usdt = vault.usdt();
        advanceSigner = signer_;
        rootTimelock = params.rootTimelock;
        challengeBond = params.challengeBond;
        advancePerAccountCap = params.advancePerAccountCap;
        advanceDailyCap = params.advanceDailyCap;
    }

    /// @dev Liability of the active root that has not yet been attributed to proven leaves.
    function outstanding() public view returns (uint256) {
        if (committed <= rootPaid) return 0;
        return committed - rootPaid;
    }

    function rewardCap() public view returns (uint256) {
        return (vault.totalContributed() * REWARD_CAP_BPS) / BPS_DENOMINATOR;
    }

    function setAdvanceSigner(
        address signer_
    ) external onlyOwner {
        if (signer_ == address(0)) revert ZeroAddress();
        advanceSigner = signer_;
        emit AdvanceSignerUpdated(signer_);
    }

    function submitRoot(
        bytes32 root,
        bytes32 contentHash_,
        uint256 cumulative
    ) external onlyOwner {
        if (root == bytes32(0)) revert InvalidProof();
        if (cumulative < totalTeamPaid) revert CumulativeTooLow();
        if (vault.totalDirectAccrued() + cumulative > rewardCap()) revert CapExceeded();
        if (challenger != address(0)) _refundChallenger();
        pendingRoot = root;
        pendingContentHash = contentHash_;
        pendingCumulative = cumulative;
        pendingEta = block.timestamp + rootTimelock;
        emit RootSubmitted(root, contentHash_, cumulative, pendingEta);
    }

    function challenge() external {
        if (pendingRoot == bytes32(0) || block.timestamp >= pendingEta) revert NoPending();
        if (challenger != address(0)) revert ChallengedRoot();
        challenger = msg.sender;
        usdt.safeTransferFrom(msg.sender, address(this), challengeBond);
        emit Challenged(msg.sender, pendingRoot);
    }

    function cancelPending() external onlyOwner {
        if (pendingRoot == bytes32(0)) revert NoPending();
        bytes32 root = pendingRoot;
        _clearPending();
        _refundChallenger();
        emit RootCancelled(root);
    }

    /// @notice Multisig override. Slashes the challenger bond to the owner.
    function dismissChallenge() external onlyOwner {
        if (challenger == address(0)) revert NoPending();
        address who = challenger;
        challenger = address(0);
        usdt.safeTransfer(owner(), challengeBond);
        emit ChallengeDismissed(who);
    }

    function activateRoot() external {
        if (pendingRoot == bytes32(0)) revert NoPending();
        if (block.timestamp < pendingEta) revert TimelockNotElapsed();
        if (challenger != address(0)) revert ChallengedRoot();
        if (pendingCumulative < totalTeamPaid) revert CumulativeTooLow();
        if (vault.totalDirectAccrued() + pendingCumulative > rewardCap()) revert CapExceeded();
        merkleRoot = pendingRoot;
        contentHash = pendingContentHash;
        committed = pendingCumulative;
        emit RootActivated(merkleRoot, committed);
        _clearPending();
    }

    function claim(
        uint256 cumulative,
        bytes32[] calldata proof
    ) external nonReentrant {
        _verify(msg.sender, cumulative, proof);
        _attribute(msg.sender, cumulative, false);
    }

    function claimAdvance(
        uint256 cumulative,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        uint256 nonce = nonces[msg.sender];
        bytes32 digest = advanceDigest(msg.sender, cumulative, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNow(advanceSigner, digest, signature)) revert BadSignature();
        nonces[msg.sender] = nonce + 1;

        uint256 already = claimed[msg.sender];
        if (cumulative <= already) revert NothingToClaim();
        uint256 delta = cumulative - already;
        _rollAdvanceDay();
        if (advanceAccountUsed[msg.sender] + delta > advancePerAccountCap) revert AdvanceExceeded();
        if (advanceDayUsed + delta > advanceDailyCap) revert AdvanceExceeded();
        advanceAccountUsed[msg.sender] += delta;
        advanceDayUsed += delta;
        _attribute(msg.sender, cumulative, true);
    }

    function advanceDigest(
        address account,
        uint256 cumulative,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ADVANCE_TYPEHASH, account, cumulative, nonce, deadline)));
    }

    function _verify(
        address account,
        uint256 cumulative,
        bytes32[] calldata proof
    ) internal view {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();
    }

    /// @dev Attributes a proven cumulative to the root. Pays only the unpaid delta.
    ///      Amounts already sent via advance count toward `rootPaid` without a second transfer.
    function _attribute(
        address account,
        uint256 cumulative,
        bool advance
    ) internal {
        uint256 already = claimed[account];
        if (!advance && cumulative < rootAttributed[account]) revert CumulativeTooLow();
        uint256 pay = cumulative > already ? cumulative - already : 0;
        if (pay == 0 && advance) revert NothingToClaim();

        if (pay > 0) {
            if (vault.totalDirectAccrued() + totalTeamPaid + pay > rewardCap()) revert CapExceeded();
            claimed[account] = cumulative > already ? cumulative : already;
            totalTeamPaid += pay;
        }

        if (!advance) {
            uint256 prior = rootAttributed[account];
            if (cumulative > prior) {
                uint256 span = cumulative - prior;
                uint256 credit = span > pay ? span - pay : 0;
                rootAttributed[account] = cumulative;
                rootPaid += credit + pay;
            } else if (pay > 0) {
                rootPaid += pay;
            }
            if (pay == 0 && cumulative <= prior) revert NothingToClaim();
        }

        if (pay > 0) {
            vault.disburse(account, pay, !advance);
            if (advance) emit AdvanceClaimed(account, cumulative, pay);
            else emit TeamClaimed(account, cumulative, pay);
        } else if (!advance) {
            emit TeamClaimed(account, cumulative, 0);
        }
    }

    function _rollAdvanceDay() internal {
        uint256 day = block.timestamp / 1 days;
        if (day != advanceDay) {
            advanceDay = day;
            advanceDayUsed = 0;
        }
        if (advanceAccountDay[msg.sender] != day) {
            advanceAccountDay[msg.sender] = day;
            advanceAccountUsed[msg.sender] = 0;
        }
    }

    function _clearPending() internal {
        pendingRoot = bytes32(0);
        pendingContentHash = bytes32(0);
        pendingCumulative = 0;
        pendingEta = 0;
    }

    function _refundChallenger() internal {
        if (challenger == address(0)) return;
        address who = challenger;
        challenger = address(0);
        usdt.safeTransfer(who, challengeBond);
    }
}
