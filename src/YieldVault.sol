// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @title YieldVault
/// @notice ERC-4626 vault that routes deposits into a pluggable {IStrategy}, charges a performance fee
///         protected by a high-water mark, enforces a deposit cap and supports a withdraw-only
///         emergency mode.
/// @dev Personal demo project. UNAUDITED. Do not deploy with real funds.
///
///  Inflation / donation attack defence: `_decimalsOffset()` adds {OFFSET_DECIMALS} virtual decimals to
///  shares (OpenZeppelin virtual shares/assets). Together with the +1 virtual asset, an attacker who
///  donates to the vault must give up ~10^OFFSET_DECIMALS wei per wei of victim loss.
///
///  Fee model: the share price is tracked as `_sharePrice()` ({PRICE_UNIT} = initial price). When the
///  price exceeds `highWaterMark`, a fee of `performanceFeeBps` of the excess value is minted as shares
///  to `feeRecipient`, and the mark is raised. Pending fee shares are included in all conversions, so
///  previews are exact and fees accrue lazily before every state change.
contract YieldVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Extra decimals of precision of shares over the asset (virtual-share offset).
    uint8 public constant OFFSET_DECIMALS = 6;
    /// @notice Maximum performance fee: 30%.
    uint16 public constant MAX_FEE_BPS = 3_000;
    uint256 private constant BPS = 10_000;
    /// @notice Fixed-point scale of {sharePrice} / {highWaterMark} (1e27: price quantisation is far below 1 wei even at 1e9-token TVL).
    uint256 public constant PRICE_UNIT = 1e27;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Active strategy (zero address = funds stay idle in the vault).
    IStrategy public strategy;
    /// @notice Max total assets accepted via deposits/mints. `type(uint256).max` = unlimited.
    uint256 public depositCap;
    /// @notice Performance fee in basis points, charged on gains above the high-water mark.
    uint16 public performanceFeeBps;
    /// @notice Receives fee shares.
    address public feeRecipient;
    /// @notice Highest share price (see `sharePrice()`) on which fees have already been settled.
    uint256 public highWaterMark = PRICE_UNIT;
    /// @notice When true deposits/mints are disabled; withdrawals/redemptions always work.
    bool public paused;
    /// @notice When true idle funds are NOT forwarded to the strategy (set by `emergencyExit`).
    bool public emergency;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event StrategyChanged(address indexed oldStrategy, address indexed newStrategy, uint256 assetsMoved);
    event DepositCapUpdated(uint256 newCap);
    event PerformanceFeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event FeesCharged(uint256 feeAssets, uint256 feeShares, uint256 newHighWaterMark);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyExit(uint256 assetsRecovered);

    error ZeroAddress();
    error FeeTooHigh(uint16 feeBps, uint16 maxBps);
    error DepositsPaused();
    error StrategyAssetMismatch();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error StrategyNotEmpty();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param asset_ Underlying ERC-20.
    /// @param name_ Share token name.
    /// @param symbol_ Share token symbol.
    /// @param owner_ Admin (two-step ownership).
    /// @param feeRecipient_ Receiver of performance-fee shares.
    /// @param feeBps_ Initial performance fee in bps (<= {MAX_FEE_BPS}).
    /// @param cap_ Initial deposit cap in asset units.
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address feeRecipient_,
        uint16 feeBps_,
        uint256 cap_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
        feeRecipient = feeRecipient_;
        performanceFeeBps = feeBps_;
        depositCap = cap_;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-4626 ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    /// @dev Idle balance (incl. any direct donations) plus strategy-managed assets.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        IStrategy s = strategy;
        return s == IStrategy(address(0)) ? idle : idle + s.totalAssets();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return OFFSET_DECIMALS;
    }

    /// @notice Current share price with virtual shares/assets, scaled to {PRICE_UNIT} (starts at exactly {PRICE_UNIT}).
    function sharePrice() public view returns (uint256) {
        return _price(totalAssets(), totalSupply());
    }

    function _price(uint256 assets, uint256 supply) internal pure returns (uint256) {
        uint256 unit = 10 ** OFFSET_DECIMALS;
        return (assets + 1).mulDiv(PRICE_UNIT * unit, supply + unit);
    }

    /// @notice Fee shares that would be minted if fees were settled now.
    function pendingFeeShares() public view returns (uint256 shares) {
        (, shares) = _pendingFee(totalAssets(), totalSupply());
    }

    function _pendingFee(uint256 assets, uint256 supply) internal view returns (uint256 feeAssets, uint256 feeShares) {
        uint256 fee = performanceFeeBps;
        uint256 p = _price(assets, supply);
        uint256 hwm = highWaterMark;
        if (fee == 0 || p <= hwm || supply == 0) return (0, 0);
        // Value (in assets) of the price excess over the high-water mark.
        uint256 excess = assets.mulDiv(p - hwm, p);
        feeAssets = excess.mulDiv(fee, BPS);
        if (feeAssets == 0 || feeAssets >= assets) return (0, 0);
        // Shares worth `feeAssets` *after* they are minted (dilution-correct), rounded down.
        feeShares = feeAssets.mulDiv(supply + 10 ** OFFSET_DECIMALS, assets - feeAssets + 1);
    }

    /// @dev Conversions include pending (unminted) fee shares so previews match execution exactly.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 ta = totalAssets();
        uint256 ts = totalSupply();
        (, uint256 fs) = _pendingFee(ta, ts);
        return assets.mulDiv(ts + fs + 10 ** _decimalsOffset(), ta + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 ta = totalAssets();
        uint256 ts = totalSupply();
        (, uint256 fs) = _pendingFee(ta, ts);
        return shares.mulDiv(ta + 1, ts + fs + 10 ** _decimalsOffset(), rounding);
    }

    /// @notice Settle the performance fee now (permissionless).
    function harvest() external nonReentrant {
        _chargeFees();
    }

    function _chargeFees() internal {
        uint256 ta = totalAssets();
        uint256 ts = totalSupply();
        (uint256 feeAssets, uint256 feeShares) = _pendingFee(ta, ts);
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        uint256 p = _price(ta, ts + feeShares);
        // Mark moves to the post-dilution price only when a fee was actually taken, or price made a new high.
        uint256 hwm = highWaterMark;
        uint256 pre = _price(ta, ts);
        if (pre > hwm) {
            highWaterMark = p;
            emit FeesCharged(feeAssets, feeShares, p);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         LIMITS (CAP / PAUSE)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        if (paused) return 0;
        uint256 cap = depositCap;
        if (cap == type(uint256).max) return type(uint256).max;
        uint256 ta = totalAssets();
        return cap > ta ? cap - ta : 0;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (maxAssets == type(uint256).max) return type(uint256).max;
        return _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT / WITHDRAW HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reentrancy-guarded; settles fees first, pulls assets, then forwards all idle to the strategy.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (paused) revert DepositsPaused();
        _chargeFees();
        super._deposit(caller, receiver, assets, shares);
        _invest();
    }

    /// @dev Works while paused (withdraw-only mode). Pulls from strategy if idle balance is short.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        _chargeFees();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            IStrategy s = strategy;
            if (s != IStrategy(address(0))) s.withdraw(assets - idle);
            idle = IERC20(asset()).balanceOf(address(this));
            if (idle < assets) revert InsufficientLiquidity(assets, idle);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    function _invest() internal {
        IStrategy s = strategy;
        if (emergency || s == IStrategy(address(0))) return;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;
        IERC20(asset()).safeTransfer(address(s), idle);
        s.deposit(idle);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Disable deposits/mints. Withdrawals stay open.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Re-enable deposits and strategy investing.
    function unpause() external onlyOwner {
        paused = false;
        emergency = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Pause deposits and pull every asset out of the strategy into the vault (withdraw-only mode).
    function emergencyExit() external onlyOwner nonReentrant {
        paused = true;
        emergency = true;
        IStrategy s = strategy;
        uint256 recovered;
        if (s != IStrategy(address(0))) {
            uint256 ta = s.totalAssets();
            if (ta > 0) recovered = s.withdraw(ta);
        }
        emit Paused(msg.sender);
        emit EmergencyExit(recovered);
    }

    /// @notice Set a new deposit cap (asset units).
    function setDepositCap(uint256 newCap) external onlyOwner {
        depositCap = newCap;
        emit DepositCapUpdated(newCap);
    }

    /// @notice Update the performance fee. Settles fees at the old rate first.
    function setPerformanceFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        _chargeFees();
        performanceFeeBps = newFeeBps;
        emit PerformanceFeeUpdated(newFeeBps);
    }

    /// @notice Update the fee recipient. Settles pending fees to the old recipient first.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        _chargeFees();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice Migrate to a new strategy: drains the old one, then deploys all idle funds into the new one.
    /// @param newStrategy New strategy (or zero to leave funds idle). Must use the same asset.
    function setStrategy(IStrategy newStrategy) external onlyOwner nonReentrant {
        if (address(newStrategy) != address(0) && newStrategy.asset() != asset()) revert StrategyAssetMismatch();
        _chargeFees();
        IStrategy old = strategy;
        uint256 moved;
        if (old != IStrategy(address(0))) {
            uint256 ta = old.totalAssets();
            if (ta > 0) moved = old.withdraw(ta);
            if (old.totalAssets() > 1) revert StrategyNotEmpty();
        }
        strategy = newStrategy;
        emit StrategyChanged(address(old), address(newStrategy), moved);
        _invest();
    }
}
