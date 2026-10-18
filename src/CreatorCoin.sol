// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFactoryPlatform {
    function platform() external view returns (address);
}

/// @title CreatorCoin
/// @notice A creator coin attached to one NFT collection. Fixed supply minted once to the factory, which distributes
///         it. No mint, no tax, no owner. Burnable so the buyback-and-burn flywheel can destroy it.
///
///         Holder rewards, entirely on chain (Jj, 17 Oct: no key decides who is paid). JIG handed in by the coin's
///         flywheel module (the one notifier, set once by the factory at launch) is streamed to holders over
///         DURATION, pro rata to balance and time held, the StakingRewards pattern with every transfer as the
///         stake/unstake: buying just before a reward lands earns only the seconds held. Holders claim at any time.
///         Protocol addresses (the factory, the pool manager, the fee hook, the airdrop claim, the coin itself and
///         the dead address) are excluded: they hold no share and their balances are not in the eligible supply.
///         Reward streamed while nobody is eligible, and rounding dust, is kept and added to the next stream.
///         Emergency brake (Jj, 17 Oct): the platform (the factory's platform, the Safe) can pause adding and claiming
///         rewards if something goes badly wrong, for at most MAX_PAUSE (14 days) per decision. It cannot move any JIG or coin, and transfers and the reward
///         accounting carry on while paused, so nothing is lost; unpausing resumes exactly where it was.
contract CreatorCoin is ERC20, ERC20Permit, ERC20Burnable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev 1 day (Jj, 18 Oct: "just give out what comes in"): the forwarder pulls at most once a day, so each day's
    ///      intake has paid out in full by the next pull and is never re-spread or stretched (GPT review #10). Was 7 days.
    uint256 public constant DURATION = 1 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant PRECISION = 1e30; // headroom: 1e27 supply x 1e30 stays far below 2^256, small rates do not round away

    address public immutable collection;
    address public immutable factory;
    IERC20 public immutable rewardToken; // JIG

    address public notifier; // the flywheel module allowed to add rewards; set once by the factory
    uint64 public constant MAX_PAUSE = 14 days; // a pause lapses by itself unless the platform renews it (review, 17 Oct)
    uint64 public pausedUntil; // the platform's emergency brake on notifyReward and claim, until this time
    mapping(address => bool) public excluded;
    uint256 public excludedSupply; // sum of excluded balances

    uint256 public rewardRate; // reward per second
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored;
    uint256 public carry; // streamed while nobody was eligible, plus division dust: added to the next stream
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event NotifierSet(address notifier);
    event RewardAdded(uint256 amount, uint256 rate, uint256 periodFinish);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsPaused(bool paused);

    error NotFactory();
    error NotNotifier();
    error NotifierSet_();
    error NotPlatform();
    error Paused();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        address collection_,
        address to,
        address rewardToken_,
        address[] memory excluded_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        collection = collection_;
        factory = msg.sender;
        rewardToken = IERC20(rewardToken_);
        excluded[to] = true;
        excluded[DEAD] = true;
        excluded[address(this)] = true;
        for (uint256 i; i < excluded_.length; i++) excluded[excluded_[i]] = true;
        _mint(to, supply);
    }

    /// @notice The factory names the flywheel module that may add rewards. Once only; address(0) = no rewards.
    function setNotifier(address notifier_) external {
        if (msg.sender != factory) revert NotFactory();
        if (notifier != address(0)) revert NotifierSet_();
        notifier = notifier_;
        emit NotifierSet(notifier_);
    }

    /// @notice The platform pauses (for MAX_PAUSE from now; call again to renew) or resumes adding and claiming
    ///         rewards. Nothing else: no pause can last longer than MAX_PAUSE without a fresh decision.
    function setRewardsPaused(bool paused_) external {
        if (msg.sender != IFactoryPlatform(factory).platform()) revert NotPlatform();
        pausedUntil = paused_ ? uint64(block.timestamp) + MAX_PAUSE : 0;
        emit RewardsPaused(paused_);
    }

    function rewardsPaused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    /// @notice Supply that earns rewards: everything not held by an excluded address.
    function eligibleSupply() public view returns (uint256) {
        return totalSupply() - excludedSupply;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 e = eligibleSupply();
        if (e == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdate) * rewardRate * PRECISION) / e;
    }

    /// @notice JIG `account` can claim now.
    function earned(address account) public view returns (uint256) {
        if (excluded[account]) return 0;
        return (balanceOf(account) * (rewardPerToken() - rewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    /// @notice The flywheel module adds `amount` JIG; it streams over DURATION together with whatever is left.
    function notifyReward(uint256 amount) external nonReentrant {
        if (msg.sender != notifier) revert NotNotifier();
        if (rewardsPaused()) revert Paused();
        _updateGlobal();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 total = amount + carry;
        if (block.timestamp < periodFinish) total += (periodFinish - block.timestamp) * rewardRate;
        rewardRate = total / DURATION;
        carry = total - rewardRate * DURATION; // dust, streamed with the next reward
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        emit RewardAdded(amount, rewardRate, periodFinish);
    }

    /// @notice Pay the caller everything they have earned.
    function claim() external nonReentrant returns (uint256 amount) {
        if (rewardsPaused()) revert Paused();
        _updateGlobal();
        _updateAccount(msg.sender);
        amount = rewards[msg.sender];
        if (amount > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, amount);
            emit RewardPaid(msg.sender, amount);
        }
    }

    function _updateGlobal() internal {
        uint256 t = lastTimeRewardApplicable();
        if (t > lastUpdate) {
            uint256 e = eligibleSupply();
            if (e == 0) carry += (t - lastUpdate) * rewardRate; // nobody to stream to: keep it for the next stream
            else rewardPerTokenStored += ((t - lastUpdate) * rewardRate * PRECISION) / e;
        }
        lastUpdate = t;
    }

    function _updateAccount(address account) internal {
        if (account == address(0) || excluded[account]) return;
        rewards[account] = (balanceOf(account) * (rewardPerTokenStored - rewardPerTokenPaid[account])) / PRECISION + rewards[account];
        rewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    /// @dev Every balance change settles both sides at the current rate first, then moves excluded supply.
    function _update(address from, address to, uint256 value) internal override {
        _updateGlobal();
        _updateAccount(from);
        _updateAccount(to);
        super._update(from, to, value);
        if (from != address(0) && excluded[from]) excludedSupply -= value;
        if (to != address(0) && excluded[to]) excludedSupply += value;
    }
}
