// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Vesting
/// @notice Linear vesting with an optional cliff, for any ERC-20. Anyone can fund a
///         schedule for anyone. Nothing is revocable: once funded, only the
///         beneficiary can ever receive the tokens, and only on the schedule.
///         Used by the coin factory for creator allocations (5%, 6 months) and for
///         anything else that must be provably locked. JIG itself has no team
///         allocation (spec 2).
contract Vesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Schedule {
        address token;
        address beneficiary;
        uint128 total;
        uint128 released;
        uint64 start;
        uint64 cliff; // seconds after start before anything unlocks
        uint64 duration; // seconds from start until fully unlocked
    }

    Schedule[] public schedules;
    mapping(address beneficiary => uint256[] ids) private _byBeneficiary;

    event ScheduleCreated(
        uint256 indexed id, address indexed token, address indexed beneficiary, uint256 total, uint64 start, uint64 cliff, uint64 duration
    );
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadSchedule();
    error NothingDue();

    /// @notice Pull `total` of `token` from the caller and lock it for `beneficiary`.
    /// @dev Caller must have approved this contract. Fee-on-transfer tokens are not supported.
    function create(address token, address beneficiary, uint256 total, uint64 start, uint64 cliff, uint64 duration)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (total == 0 || total > type(uint128).max) revert ZeroAmount();
        if (duration == 0 || cliff > duration) revert BadSchedule();
        if (start == 0) start = uint64(block.timestamp);
        if (uint256(start) + duration > type(uint64).max) revert BadSchedule();

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), total);
        if (IERC20(token).balanceOf(address(this)) - before != total) revert BadSchedule();

        id = schedules.length;
        schedules.push(
            Schedule({
                token: token,
                beneficiary: beneficiary,
                total: uint128(total),
                released: 0,
                start: start,
                cliff: cliff,
                duration: duration
            })
        );
        _byBeneficiary[beneficiary].push(id);
        emit ScheduleCreated(id, token, beneficiary, total, start, cliff, duration);
    }

    /// @notice Send everything currently unlocked on schedule `id` to its beneficiary. Anyone may call.
    function release(uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = schedules[id];
        amount = releasable(id);
        if (amount == 0) revert NothingDue();
        s.released += uint128(amount);
        IERC20(s.token).safeTransfer(s.beneficiary, amount);
        emit Released(id, s.beneficiary, amount);
    }

    function vested(uint256 id) public view returns (uint256) {
        Schedule storage s = schedules[id];
        uint256 t = block.timestamp;
        if (t < s.start + s.cliff) return 0;
        if (t >= s.start + s.duration) return s.total;
        return (uint256(s.total) * (t - s.start)) / s.duration;
    }

    function releasable(uint256 id) public view returns (uint256) {
        return vested(id) - schedules[id].released;
    }

    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function count() external view returns (uint256) {
        return schedules.length;
    }
}
