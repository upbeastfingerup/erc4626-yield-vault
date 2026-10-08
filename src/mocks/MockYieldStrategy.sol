// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title MockYieldStrategy
/// @notice Demo strategy whose managed balance grows by a configurable per-second rate. Yield is
///         "realised" by minting the (mock) asset to itself on `accrue()`; `totalAssets()` also reports
///         the not-yet-minted pending yield so the vault sees a continuously rising share price.
/// @dev Test-only. `donateYield` / `simulateLoss` let tests drive gains and losses deterministically.
contract MockYieldStrategy is IStrategy {
    using SafeERC20 for IERC20;

    error OnlyVault();

    address public immutable override asset;
    address public immutable vault;
    /// @notice Yield per second in 1e18 precision (e.g. 1e9 ~ 3.15% APR).
    uint256 public ratePerSecond;
    uint256 public lastAccrual;
    uint256 internal _managed;

    constructor(address asset_, address vault_, uint256 ratePerSecond_) {
        asset = asset_;
        vault = vault_;
        ratePerSecond = ratePerSecond_;
        lastAccrual = block.timestamp;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @inheritdoc IStrategy
    function totalAssets() public view override returns (uint256) {
        return _managed + _pending();
    }

    function _pending() internal view returns (uint256) {
        return (_managed * ratePerSecond * (block.timestamp - lastAccrual)) / 1e18;
    }

    /// @notice Realise time-based yield by minting the asset to this contract.
    function accrue() public {
        uint256 p = _pending();
        lastAccrual = block.timestamp;
        if (p > 0) {
            IMintable(asset).mint(address(this), p);
            _managed += p;
        }
    }

    /// @notice Test helper: add yield immediately.
    function donateYield(uint256 amount) external {
        accrue();
        IMintable(asset).mint(address(this), amount);
        _managed += amount;
    }

    /// @notice Test helper: realise a loss by burning managed assets.
    function simulateLoss(uint256 amount) external {
        accrue();
        if (amount > _managed) amount = _managed;
        _managed -= amount;
        IERC20(asset).safeTransfer(address(0xdead), amount);
    }

    /// @inheritdoc IStrategy
    function deposit(uint256 amount) external override onlyVault {
        accrue();
        _managed += amount;
    }

    /// @inheritdoc IStrategy
    function withdraw(uint256 amount) external override onlyVault returns (uint256 withdrawn) {
        accrue();
        withdrawn = amount > _managed ? _managed : amount;
        _managed -= withdrawn;
        IERC20(asset).safeTransfer(vault, withdrawn);
    }
}
