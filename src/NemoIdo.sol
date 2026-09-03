// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NemoIdo
/// @notice BSC USDT IDO vault: records contribution / identity, accrues direct + team
///         differential rewards in USDT. Does not mint NEMO.
contract NemoIdo is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant TIER_COUNT = 3;

    enum Role {
        None,
        Explorer,
        Ambassador,
        Partner,
        CoBuilder
    }

    struct Account {
        address referrer;
        bytes32 inviteCode;
        uint256 selfVolume;
        uint256 teamVolume;
        uint256 directRewards;
        uint256 teamRewards;
        uint256 claimed;
        bool registered;
    }

    IERC20 public immutable usdt;

    bool public importFrozen;
    bool public saleOpen;

    uint256 public minIdo = 1e18;
    uint256 public minReferralAmount = 100e18;
    uint256 public ambassadorMin = 100e18;
    uint256 public partnerMin = 1000e18;
    uint256 public coBuilderTeamMin = 30_000e18;
    uint256 public directReferralBps = 1000;
    uint256 public maxReferralDepth = 64;

    uint256[3] public teamTierVolume;
    uint256[3] public teamTierBps;

    mapping(address => Account) public accounts;
    mapping(bytes32 => address) public codeToAccount;

    uint256 public totalAccrued;
    uint256 public totalClaimed;
    uint256 public totalContributed;

    event Registered(address indexed account, bytes32 indexed code, address indexed referrer);
    event ReferrerBound(address indexed account, address indexed referrer);
    event Contributed(address indexed account, uint256 amount, uint256 selfVolume, uint256 teamVolume);
    event DirectRewardAccrued(address indexed referrer, address indexed from, uint256 amount);
    event TeamRewardAccrued(address indexed beneficiary, address indexed from, uint256 amount, uint256 bps);
    event Claimed(address indexed account, uint256 amount);
    event ImportFrozen();
    event SaleOpened();
    event SaleClosed();
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event UserImported(address indexed account, bytes32 indexed code);
    event ReferrerImported(address indexed account, address indexed referrer);
    event VolumeImported(address indexed account, uint256 selfVolume, uint256 teamVolume);
    event DirectReferralBpsUpdated(uint256 bps);
    event MinReferralAmountUpdated(uint256 amount);
    event MinIdoUpdated(uint256 amount);
    event IdentityThresholdsUpdated(uint256 ambassadorMin, uint256 partnerMin, uint256 coBuilderTeamMin);
    event TeamTiersUpdated(uint256[3] volumes, uint256[3] bps);
    event MaxReferralDepthUpdated(uint256 depth);

    error NotRegistered();
    error AlreadyRegistered();
    error CodeTaken();
    error InvalidCode();
    error SaleClosedError();
    error ImportFrozenError();
    error ImportNotFrozenError();
    error AlreadyBound();
    error InvalidReferrer();
    error SelfReferral();
    error Cycle();
    error DepthExceeded();
    error AmountTooSmall();
    error NothingToClaim();
    error InsufficientTreasury();
    error LengthMismatch();
    error ZeroAddress();
    error InvalidTiers();
    error InvalidThresholds();
    error RewardBpsTooHigh();
    error ZeroDepth();

    constructor(
        address usdt_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (usdt_ == address(0) || initialOwner == address(0)) revert ZeroAddress();
        usdt = IERC20(usdt_);
        teamTierVolume = [uint256(3000e18), 10_000e18, 30_000e18];
        teamTierBps = [uint256(300), 600, 900];
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getAccount(
        address account
    ) external view returns (Account memory) {
        return accounts[account];
    }

    function pendingOf(
        address account
    ) public view returns (uint256) {
        Account storage a = accounts[account];
        uint256 accrued = a.directRewards + a.teamRewards;
        if (accrued <= a.claimed) return 0;
        return accrued - a.claimed;
    }

    function reservedRewards() public view returns (uint256) {
        return totalAccrued - totalClaimed;
    }

    function treasuryWithdrawable() public view returns (uint256) {
        uint256 bal = usdt.balanceOf(address(this));
        uint256 reserved = reservedRewards();
        if (bal <= reserved) return 0;
        return bal - reserved;
    }

    function teamBpsForVolume(
        uint256 teamVolume_
    ) public view returns (uint256) {
        if (teamVolume_ >= teamTierVolume[2]) return teamTierBps[2];
        if (teamVolume_ >= teamTierVolume[1]) return teamTierBps[1];
        if (teamVolume_ >= teamTierVolume[0]) return teamTierBps[0];
        return 0;
    }

    function teamBpsOf(
        address account
    ) public view returns (uint256) {
        Account storage a = accounts[account];
        if (!a.registered || a.selfVolume < ambassadorMin) return 0;
        return teamBpsForVolume(a.teamVolume);
    }

    function roleOf(
        address account
    ) public view returns (Role) {
        Account storage a = accounts[account];
        if (!a.registered || a.selfVolume == 0) return Role.None;
        if (a.selfVolume >= partnerMin && a.teamVolume >= coBuilderTeamMin) return Role.CoBuilder;
        if (a.selfVolume >= partnerMin) return Role.Partner;
        if (a.selfVolume >= ambassadorMin) return Role.Ambassador;
        return Role.Explorer;
    }

    function getTeamTiers() external view returns (uint256[3] memory volumes, uint256[3] memory bps) {
        return (teamTierVolume, teamTierBps);
    }

    // -------------------------------------------------------------------------
    // User actions
    // -------------------------------------------------------------------------

    function register(
        bytes32 code,
        bytes32 referrerCode
    ) external whenNotPaused {
        _register(msg.sender, code, referrerCode);
    }

    function bindReferrer(
        bytes32 referrerCode
    ) external whenNotPaused {
        Account storage a = accounts[msg.sender];
        if (!a.registered) revert NotRegistered();
        if (a.referrer != address(0)) revert AlreadyBound();
        address referrer = _referrerFromCode(referrerCode, msg.sender);
        _bindReferrer(msg.sender, referrer);
        emit ReferrerBound(msg.sender, referrer);
    }

    function contribute(
        uint256 amount
    ) external whenNotPaused nonReentrant {
        _contribute(msg.sender, amount);
    }

    function registerAndContribute(
        bytes32 code,
        bytes32 referrerCode,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        if (!accounts[msg.sender].registered) {
            _register(msg.sender, code, referrerCode);
        }
        _contribute(msg.sender, amount);
    }

    function claim() external whenNotPaused nonReentrant {
        uint256 amount = pendingOf(msg.sender);
        if (amount == 0) revert NothingToClaim();
        accounts[msg.sender].claimed += amount;
        totalClaimed += amount;
        usdt.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Admin: sale / import lifecycle
    // -------------------------------------------------------------------------

    function freezeImport() external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        importFrozen = true;
        emit ImportFrozen();
    }

    function openSale() external onlyOwner {
        if (!importFrozen) revert ImportNotFrozenError();
        saleOpen = true;
        emit SaleOpened();
    }

    function closeSale() external onlyOwner {
        saleOpen = false;
        emit SaleClosed();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawTreasury(
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > treasuryWithdrawable()) revert InsufficientTreasury();
        usdt.safeTransfer(to, amount);
        emit TreasuryWithdrawn(to, amount);
    }

    // -------------------------------------------------------------------------
    // Admin: params
    // -------------------------------------------------------------------------

    function setDirectReferralBps(
        uint256 bps
    ) external onlyOwner {
        _assertRewardCap(bps, teamTierBps[2]);
        directReferralBps = bps;
        emit DirectReferralBpsUpdated(bps);
    }

    function setMinReferralAmount(
        uint256 amount
    ) external onlyOwner {
        minReferralAmount = amount;
        emit MinReferralAmountUpdated(amount);
    }

    function setMinIdo(
        uint256 amount
    ) external onlyOwner {
        if (amount == 0) revert AmountTooSmall();
        minIdo = amount;
        emit MinIdoUpdated(amount);
    }

    function setIdentityThresholds(
        uint256 ambassadorMin_,
        uint256 partnerMin_,
        uint256 coBuilderTeamMin_
    ) external onlyOwner {
        if (ambassadorMin_ == 0 || ambassadorMin_ > partnerMin_ || coBuilderTeamMin_ == 0) {
            revert InvalidThresholds();
        }
        ambassadorMin = ambassadorMin_;
        partnerMin = partnerMin_;
        coBuilderTeamMin = coBuilderTeamMin_;
        emit IdentityThresholdsUpdated(ambassadorMin_, partnerMin_, coBuilderTeamMin_);
    }

    function setTeamTiers(
        uint256[3] calldata volumes,
        uint256[3] calldata bps
    ) external onlyOwner {
        if (volumes[0] == 0 || volumes[0] >= volumes[1] || volumes[1] >= volumes[2]) revert InvalidTiers();
        if (bps[0] == 0 || bps[0] >= bps[1] || bps[1] >= bps[2]) revert InvalidTiers();
        _assertRewardCap(directReferralBps, bps[2]);
        teamTierVolume = volumes;
        teamTierBps = bps;
        emit TeamTiersUpdated(volumes, bps);
    }

    function setMaxReferralDepth(
        uint256 depth
    ) external onlyOwner {
        if (depth == 0) revert ZeroDepth();
        if (depth > 128) revert DepthExceeded();
        maxReferralDepth = depth;
        emit MaxReferralDepthUpdated(depth);
    }

    // -------------------------------------------------------------------------
    // Admin: historical import (no rewards)
    // -------------------------------------------------------------------------

    function importUsers(
        address[] calldata wallets,
        bytes32[] calldata codes
    ) external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        uint256 n = wallets.length;
        if (n != codes.length) revert LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            _importUser(wallets[i], codes[i]);
        }
    }

    function importReferrers(
        address[] calldata wallets,
        address[] calldata referrers
    ) external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        uint256 n = wallets.length;
        if (n != referrers.length) revert LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            address account = wallets[i];
            address referrer = referrers[i];
            if (!accounts[account].registered) revert NotRegistered();
            if (accounts[account].referrer != address(0)) revert AlreadyBound();
            _bindReferrer(account, referrer);
            emit ReferrerImported(account, referrer);
        }
    }

    function importVolumes(
        address[] calldata wallets,
        uint256[] calldata selfVolumes,
        uint256[] calldata teamVolumes
    ) external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        uint256 n = wallets.length;
        if (n != selfVolumes.length || n != teamVolumes.length) revert LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            address account = wallets[i];
            if (!accounts[account].registered) revert NotRegistered();
            accounts[account].selfVolume = selfVolumes[i];
            accounts[account].teamVolume = teamVolumes[i];
            emit VolumeImported(account, selfVolumes[i], teamVolumes[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _assertRewardCap(
        uint256 directBps,
        uint256 maxTeamBps
    ) internal pure {
        if (directBps + maxTeamBps > BPS_DENOMINATOR) revert RewardBpsTooHigh();
    }

    function _register(
        address account,
        bytes32 code,
        bytes32 referrerCode
    ) internal {
        if (accounts[account].registered) revert AlreadyRegistered();
        _setCode(account, code);
        accounts[account].registered = true;
        address referrer = address(0);
        if (referrerCode != bytes32(0)) {
            referrer = _referrerFromCode(referrerCode, account);
            _bindReferrer(account, referrer);
        }
        emit Registered(account, code, referrer);
    }

    function _setCode(
        address account,
        bytes32 code
    ) internal {
        if (!_isValidInviteCode(code)) revert InvalidCode();
        if (codeToAccount[code] != address(0)) revert CodeTaken();
        if (account == address(0)) revert ZeroAddress();
        codeToAccount[code] = account;
        accounts[account].inviteCode = code;
    }

    function _importUser(
        address account,
        bytes32 code
    ) internal {
        if (account == address(0)) revert ZeroAddress();
        if (accounts[account].registered) revert AlreadyRegistered();
        _setCode(account, code);
        accounts[account].registered = true;
        emit UserImported(account, code);
    }

    function _referrerFromCode(
        bytes32 referrerCode,
        address account
    ) internal view returns (address referrer) {
        if (referrerCode == bytes32(0)) revert InvalidReferrer();
        referrer = codeToAccount[referrerCode];
        if (referrer == address(0) || !accounts[referrer].registered) revert InvalidReferrer();
        if (referrer == account) revert SelfReferral();
    }

    function _bindReferrer(
        address account,
        address referrer
    ) internal {
        if (referrer == address(0) || !accounts[referrer].registered) revert InvalidReferrer();
        if (referrer == account) revert SelfReferral();
        _assertNoCycle(account, referrer);
        accounts[account].referrer = referrer;
    }

    function _assertNoCycle(
        address account,
        address referrer
    ) internal view {
        address cursor = referrer;
        uint256 depth = 1;
        while (cursor != address(0)) {
            if (cursor == account) revert Cycle();
            if (depth > maxReferralDepth) revert DepthExceeded();
            cursor = accounts[cursor].referrer;
            unchecked {
                depth++;
            }
        }
    }

    function _contribute(
        address account,
        uint256 amount
    ) internal {
        if (!saleOpen) revert SaleClosedError();
        if (!accounts[account].registered) revert NotRegistered();
        if (amount < minIdo) revert AmountTooSmall();

        usdt.safeTransferFrom(account, address(this), amount);

        accounts[account].selfVolume += amount;
        totalContributed += amount;
        _bumpAncestorTeam(account, amount);

        if (amount >= minReferralAmount) {
            _settleDirect(account, amount);
            _settleTeam(account, amount);
        }

        emit Contributed(account, amount, accounts[account].selfVolume, accounts[account].teamVolume);
    }

    function _bumpAncestorTeam(
        address account,
        uint256 amount
    ) internal {
        address cursor = accounts[account].referrer;
        uint256 depth = 0;
        while (cursor != address(0)) {
            if (depth >= maxReferralDepth) revert DepthExceeded();
            accounts[cursor].teamVolume += amount;
            cursor = accounts[cursor].referrer;
            unchecked {
                depth++;
            }
        }
    }

    function _settleDirect(
        address from,
        uint256 amount
    ) internal {
        address referrer = accounts[from].referrer;
        if (referrer == address(0)) return;
        if (accounts[referrer].selfVolume < ambassadorMin) return;
        uint256 reward = (amount * directReferralBps) / BPS_DENOMINATOR;
        if (reward == 0) return;
        accounts[referrer].directRewards += reward;
        totalAccrued += reward;
        emit DirectRewardAccrued(referrer, from, reward);
    }

    function _settleTeam(
        address from,
        uint256 amount
    ) internal {
        uint256 prevBps = 0;
        address cursor = accounts[from].referrer;
        uint256 depth = 0;
        while (cursor != address(0)) {
            if (depth >= maxReferralDepth) revert DepthExceeded();
            uint256 rate = teamBpsOf(cursor);
            if (rate > prevBps) {
                uint256 diff = rate - prevBps;
                uint256 reward = (amount * diff) / BPS_DENOMINATOR;
                if (reward > 0) {
                    accounts[cursor].teamRewards += reward;
                    totalAccrued += reward;
                    emit TeamRewardAccrued(cursor, from, reward, diff);
                }
                prevBps = rate;
            }
            cursor = accounts[cursor].referrer;
            unchecked {
                depth++;
            }
        }
    }

    function _isValidInviteCode(
        bytes32 code
    ) internal pure returns (bool) {
        if (code == bytes32(0)) return false;
        bool ended = false;
        bool hasChar = false;
        for (uint256 i = 0; i < 32; i++) {
            uint8 c = uint8(code[i]);
            if (c == 0) {
                ended = true;
                continue;
            }
            if (ended) return false;
            bool ok = (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39);
            if (!ok) return false;
            hasChar = true;
        }
        return hasChar;
    }
}
