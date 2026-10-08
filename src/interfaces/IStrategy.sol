// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Minimal pluggable yield-strategy interface used by {YieldVault}.
/// @dev The strategy holds the vault's underlying asset and is only ever called by the vault.
interface IStrategy {
    /// @notice The ERC-20 asset this strategy accepts.
    function asset() external view returns (address);

    /// @notice Total underlying assets currently managed by the strategy (principal + accrued yield).
    function totalAssets() external view returns (uint256);

    /// @notice Pull `amount` assets from the vault (already approved/transferred) and put them to work.
    /// @dev The vault transfers tokens to the strategy before calling this.
    function deposit(uint256 amount) external;

    /// @notice Withdraw up to `amount` assets and send them to the vault.
    /// @return withdrawn The amount actually sent to the vault.
    function withdraw(uint256 amount) external returns (uint256 withdrawn);
}
