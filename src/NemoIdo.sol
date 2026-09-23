// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {INemoRewardsView, INemoVaultPay} from "./INemoRewards.sol";
import {NemoNetworks} from "./network/NemoNetworks.sol";
import {NemoToken} from "./NemoToken.sol";
import {NemoNFT} from "./NemoNFT.sol";

/// @title NemoIdo
/// @notice Vault for invite links, USDT deposits, direct referral, nemokey and NFT.
///         Multi-level rewards are not computed here. `NemoRewards` authorizes those payouts.
contract NemoIdo is Ownable2Step, Pausable, ReentrancyGuard, INemoVaultPay {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REWARD_CAP_BPS = 2500;
    uint256 public constant USDT_UNIT_100 = 100e18;
    uint256 public constant NFT_UNIT = 500e18;

    enum Role {
        None,
        Explorer,
        Ambassador,
        Partner
    }

    struct Account {
        address referrer;
        bytes32 inviteCode;
        uint256 selfVolume;
        uint256 directRewards;
        uint256 claimed;
        bool registered;
    }

    IERC20 public immutable usdt;
    IERC20 public immutable nemo;
    NemoNFT public immutable nft;
    bool public immutable weekByBlock;

    bool public importFrozen;
    bool public saleOpen;
    uint256 public saleOpenedAt;
    uint256 public saleOpenedBlock;

    uint256 public baseTokensPer100 = 10_000e18;
    uint256 public weeklyDecayAbs = 20e18;
    uint256 public weekDuration;
    uint256 public minTokensPer100;
    uint256 public nemoBonusThreshold = 1000e18;
    uint256 public nemoBonusBps = 200;
    uint256 public tokensPerUsdt;

    uint256 public minIdo;
    uint256 public minReferralAmount;
    uint256 public ambassadorMin;
    uint256 public partnerMin;
    uint256 public directReferralBps;

    mapping(address => Account) public accounts;
    mapping(bytes32 => address) public codeToAccount;
    mapping(address => bool) public hasChildren;
    mapping(address => uint256) public nftMinted;

    address public rewards;

    uint256 public totalDirectAccrued;
    uint256 public totalClaimed;
    uint256 public totalContributed;
    uint256 public totalNemoAllocated;

    event Registered(address indexed account, bytes32 indexed code, address indexed referrer);
    event ReferrerBound(address indexed account, address indexed referrer);
    event Contributed(address indexed account, uint256 amount, uint256 selfVolume, uint256 nemoAmount);
    event NemoAllocated(address indexed account, uint256 nemoAmount);
    event NftMinted(address indexed account, uint256 count, uint256 totalMinted);
    event DirectRewardAccrued(address indexed referrer, address indexed from, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event ImportFrozen();
    event SaleOpened();
    event SaleClosed();
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event UserImported(address indexed account, bytes32 indexed code);
    event ReferrerImported(address indexed account, address indexed referrer);
    event VolumeImported(address indexed account, uint256 selfVolume);
    event DirectReferralBpsUpdated(uint256 bps);
    event MinReferralAmountUpdated(uint256 amount);
    event MinIdoUpdated(uint256 amount);
    event IdentityThresholdsUpdated(uint256 ambassadorMin, uint256 partnerMin);
    event RewardsUpdated(address indexed rewards);
    event TeamDisbursed(address indexed to, uint256 amount, bool fromOutstanding);
    event NemoScheduleUpdated(
        uint256 baseTokensPer100, uint256 weeklyDecayAbs, uint256 weekDuration, uint256 minTokensPer100
    );
    event NemoBonusUpdated(uint256 threshold, uint256 bps);
    event TokensPerUsdtUpdated(uint256 rate);
    event UnsoldNemoWithdrawn(address indexed to, uint256 amount);

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
    error HasChildren();
    error AmountTooSmall();
    error NothingToClaim();
    error InsufficientTreasury();
    error LengthMismatch();
    error ZeroAddress();
    error InvalidThresholds();
    error RewardBpsTooHigh();
    error InsufficientNemo();
    error InvalidSchedule();
    error WrongNetwork();
    error NotRewards();

    constructor(
        address usdt_,
        address nemo_,
        address nft_,
        address initialOwner,
        NemoNetworks.Params memory params
    ) Ownable(initialOwner) {
        if (block.chainid != params.chainId) revert WrongNetwork();
        if (usdt_ == address(0) || nemo_ == address(0) || nft_ == address(0) || initialOwner == address(0)) {
            revert ZeroAddress();
        }
        if (params.weekDuration == 0 || params.tokensPerUsdt == 0 || params.minIdo == 0) revert InvalidSchedule();
        if (params.directReferralBps > REWARD_CAP_BPS) revert RewardBpsTooHigh();
        usdt = IERC20(usdt_);
        nemo = IERC20(nemo_);
        nft = NemoNFT(nft_);
        weekByBlock = params.weekByBlock;
        weekDuration = params.weekDuration;
        tokensPerUsdt = params.tokensPerUsdt;
        minIdo = params.minIdo;
        minReferralAmount = params.minReferralAmount;
        ambassadorMin = params.ambassadorMin;
        partnerMin = params.partnerMin;
        directReferralBps = params.directReferralBps;
    }

    function getAccount(
        address account
    ) external view returns (Account memory) {
        return accounts[account];
    }

    function pendingOf(
        address account
    ) public view returns (uint256) {
        Account storage a = accounts[account];
        if (a.directRewards <= a.claimed) return 0;
        return a.directRewards - a.claimed;
    }

    function referrerOf(
        address account
    ) public view returns (address) {
        return accounts[account].referrer;
    }

    function directReserve() public view returns (uint256) {
        return totalDirectAccrued - totalClaimed;
    }

    function reservedRewards() public view returns (uint256) {
        return directReserve() + _teamOutstanding();
    }

    function treasuryWithdrawable() public view returns (uint256) {
        uint256 bal = usdt.balanceOf(address(this));
        uint256 reserved = reservedRewards();
        if (bal <= reserved) return 0;
        return bal - reserved;
    }

    function roleOf(
        address account
    ) public view returns (Role) {
        Account storage a = accounts[account];
        if (!a.registered || a.selfVolume == 0) return Role.None;
        if (a.selfVolume >= partnerMin) return Role.Partner;
        if (a.selfVolume >= ambassadorMin) return Role.Ambassador;
        return Role.Explorer;
    }

    function currentWeek() public view returns (uint256) {
        if (weekByBlock) {
            if (saleOpenedBlock == 0 || block.number < saleOpenedBlock) return 0;
            return (block.number - saleOpenedBlock) / weekDuration;
        }
        if (saleOpenedAt == 0 || block.timestamp < saleOpenedAt) return 0;
        return (block.timestamp - saleOpenedAt) / weekDuration;
    }

    function tokensPer100(
        uint256 week
    ) public view returns (uint256) {
        uint256 decay = weeklyDecayAbs * week;
        if (decay >= baseTokensPer100) return minTokensPer100;
        uint256 per100 = baseTokensPer100 - decay;
        if (per100 < minTokensPer100) return minTokensPer100;
        return per100;
    }

    function tokensFor(
        uint256 amount
    ) public view returns (uint256) {
        return (amount * tokensPerUsdt) / 1e18;
    }

    function nftRemainder(
        address account
    ) public view returns (uint256) {
        return accounts[account].selfVolume % NFT_UNIT;
    }

    /// @notice Historical week quote. Deposits mint with `tokensFor`, not this.
    function quote(
        uint256 amount
    ) public view returns (uint256) {
        uint256 per100 = tokensPer100(currentWeek());
        uint256 nemoAmount = (amount * per100 + USDT_UNIT_100 - 1) / USDT_UNIT_100;
        if (amount >= nemoBonusThreshold && nemoBonusBps > 0) {
            nemoAmount = (nemoAmount * (BPS_DENOMINATOR + nemoBonusBps)) / BPS_DENOMINATOR;
        }
        return nemoAmount;
    }

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

    function disburse(
        address to,
        uint256 amount,
        bool fromOutstanding
    ) external nonReentrant {
        if (msg.sender != rewards) revert NotRewards();
        if (to == address(0) || amount == 0) revert ZeroAddress();
        uint256 bal = usdt.balanceOf(address(this));
        uint256 locked = directReserve();
        if (!fromOutstanding) locked += _teamOutstanding();
        if (bal < locked + amount) revert InsufficientTreasury();
        usdt.safeTransfer(to, amount);
        emit TeamDisbursed(to, amount, fromOutstanding);
    }

    function freezeImport() external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        importFrozen = true;
        emit ImportFrozen();
    }

    function openSale() external onlyOwner {
        if (!importFrozen) revert ImportNotFrozenError();
        saleOpen = true;
        if (saleOpenedAt == 0) {
            saleOpenedAt = block.timestamp;
            saleOpenedBlock = block.number;
        }
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

    function withdrawUnsoldNemo(
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > nemo.balanceOf(address(this))) revert InsufficientNemo();
        nemo.safeTransfer(to, amount);
        emit UnsoldNemoWithdrawn(to, amount);
    }

    function setDirectReferralBps(
        uint256 bps
    ) external onlyOwner {
        if (bps > REWARD_CAP_BPS) revert RewardBpsTooHigh();
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
        uint256 partnerMin_
    ) external onlyOwner {
        if (ambassadorMin_ == 0 || ambassadorMin_ > partnerMin_) revert InvalidThresholds();
        ambassadorMin = ambassadorMin_;
        partnerMin = partnerMin_;
        emit IdentityThresholdsUpdated(ambassadorMin_, partnerMin_);
    }

    function setRewards(
        address rewards_
    ) external onlyOwner {
        if (rewards_ == address(0)) revert ZeroAddress();
        rewards = rewards_;
        emit RewardsUpdated(rewards_);
    }

    function setNemoSchedule(
        uint256 baseTokensPer100_,
        uint256 weeklyDecayAbs_,
        uint256 weekDuration_,
        uint256 minTokensPer100_
    ) external onlyOwner {
        if (baseTokensPer100_ == 0 || weekDuration_ == 0) revert InvalidSchedule();
        if (minTokensPer100_ > baseTokensPer100_) revert InvalidSchedule();
        baseTokensPer100 = baseTokensPer100_;
        weeklyDecayAbs = weeklyDecayAbs_;
        weekDuration = weekDuration_;
        minTokensPer100 = minTokensPer100_;
        emit NemoScheduleUpdated(baseTokensPer100_, weeklyDecayAbs_, weekDuration_, minTokensPer100_);
    }

    function setNemoBonus(
        uint256 threshold,
        uint256 bps
    ) external onlyOwner {
        if (threshold == 0 || bps > BPS_DENOMINATOR) revert InvalidSchedule();
        nemoBonusThreshold = threshold;
        nemoBonusBps = bps;
        emit NemoBonusUpdated(threshold, bps);
    }

    function setTokensPerUsdt(
        uint256 rate
    ) external onlyOwner {
        if (rate == 0) revert InvalidSchedule();
        tokensPerUsdt = rate;
        emit TokensPerUsdtUpdated(rate);
    }

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
        uint256[] calldata selfVolumes
    ) external onlyOwner {
        if (importFrozen) revert ImportFrozenError();
        uint256 n = wallets.length;
        if (n != selfVolumes.length) revert LengthMismatch();
        for (uint256 i = 0; i < n; i++) {
            address account = wallets[i];
            if (!accounts[account].registered) revert NotRegistered();
            accounts[account].selfVolume = selfVolumes[i];
            nftMinted[account] = selfVolumes[i] / NFT_UNIT;
            emit VolumeImported(account, selfVolumes[i]);
        }
    }

    function _teamOutstanding() internal view returns (uint256) {
        if (rewards == address(0)) return 0;
        return INemoRewardsView(rewards).outstanding();
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
        if (hasChildren[account]) revert HasChildren();
        accounts[account].referrer = referrer;
        hasChildren[referrer] = true;
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

        if (amount >= minReferralAmount) {
            _settleDirect(account, amount);
        }

        uint256 nemoAmount = tokensFor(amount);
        if (nemoAmount > 0) {
            NemoToken(address(nemo)).mint(account, nemoAmount);
            totalNemoAllocated += nemoAmount;
            emit NemoAllocated(account, nemoAmount);
        }
        _syncNfts(account);
        emit Contributed(account, amount, accounts[account].selfVolume, nemoAmount);
    }

    function _syncNfts(
        address account
    ) internal {
        uint256 owed = accounts[account].selfVolume / NFT_UNIT;
        uint256 minted = nftMinted[account];
        if (owed <= minted) return;
        uint256 count = owed - minted;
        nftMinted[account] = owed;
        nft.mint(account, count);
        emit NftMinted(account, count, owed);
    }

    function _settleDirect(
        address from,
        uint256 amount
    ) internal {
        address referrer = accounts[from].referrer;
        if (referrer == address(0)) return;
        uint256 reward = (amount * directReferralBps) / BPS_DENOMINATOR;
        if (reward == 0) return;
        accounts[referrer].directRewards += reward;
        totalDirectAccrued += reward;
        emit DirectRewardAccrued(referrer, from, reward);
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
