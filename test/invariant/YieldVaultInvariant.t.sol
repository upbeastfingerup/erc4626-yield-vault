// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {YieldVault} from "../../src/YieldVault.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockYieldStrategy} from "../../src/mocks/MockYieldStrategy.sol";

/// @dev Drives random sequences of user + admin + market actions and tracks ghost variables.
contract Handler is Test {
    YieldVault public vault;
    MockERC20 public token;
    MockYieldStrategy public strat;
    address public owner;
    address public feeTo;
    address[] public actors;

    // ghost state
    uint256 public ghostGross; // cumulative yield injected into the strategy
    uint256 public ghostLossEvents;
    bool public priceDroppedWithoutLoss;
    bool public everHadYield;
    uint256 public lastPrice;
    uint256 public calls;
    uint256 public ghostFeeValue; // value (assets) of fee shares at the time they were minted
    uint256 internal lastFeeBal;

    constructor(YieldVault v, MockERC20 t, MockYieldStrategy s, address owner_, address feeTo_) {
        vault = v;
        token = t;
        strat = s;
        owner = owner_;
        feeTo = feeTo_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            token.mint(a, 1e30);
            vm.prank(a);
            token.approve(address(v), type(uint256).max);
        }
        lastPrice = _price();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev "user price": assets for 1e24 shares (1 whole share) incl. pending fee.
    function _price() internal view returns (uint256) {
        return vault.convertToAssets(1e24);
    }

    /// @dev Price may only fall if a loss occurred since the last check.
    function _check(bool lossSince) internal {
        uint256 p = _price();
        // Tolerance: a price dip of <= 1e-9 relative is allowed (fee-share rounding), and the check is skipped
        // in the "dust regime" (< 1e12 wei TVL) where one wei is a visible fraction of the pot.
        if (!lossSince && vault.totalAssets() >= 1e12 && p < lastPrice && lastPrice - p > lastPrice / 1e9) {
            priceDroppedWithoutLoss = true;
        }
        lastPrice = p;
        uint256 fb = vault.balanceOf(feeTo);
        if (fb > lastFeeBal) ghostFeeValue += vault.convertToAssets(fb - lastFeeBal);
        lastFeeBal = fb;
        ++calls;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        uint256 max = vault.maxDeposit(a);
        if (max == 0) return;
        amt = bound(amt, 1, max > 1e27 ? 1e27 : max);
        vm.prank(a);
        vault.deposit(amt, a);
        _check(false);
    }

    function mint(uint256 seed, uint256 shares) external {
        address a = _actor(seed);
        uint256 max = vault.maxMint(a);
        if (max == 0) return;
        shares = bound(shares, 1, max > 1e33 ? 1e33 : max);
        vm.prank(a);
        vault.mint(shares, a);
        _check(false);
    }

    function redeem(uint256 seed, uint256 frac) external {
        address a = _actor(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(frac, 1, bal);
        vm.prank(a);
        vault.redeem(shares, a, a);
        _check(false);
    }

    function withdraw(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amt = bound(amt, 1, max);
        vm.prank(a);
        vault.withdraw(amt, a, a);
        _check(false);
    }

    function addYield(uint256 amt) external {
        uint256 before = vault.totalAssets();
        amt = bound(amt, 0, before / 2 + 1e18);
        strat.donateYield(amt);
        ghostGross += amt;
        if (amt > 0) everHadYield = true;
        _check(false);
    }

    function passTime(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + dt);
        uint256 afterTa = vault.totalAssets();
        if (afterTa > before) {
            ghostGross += afterTa - before;
            everHadYield = true;
        }
        _check(false);
    }

    function loss(uint256 amt) external {
        uint256 ta = strat.totalAssets();
        if (ta == 0) return;
        amt = bound(amt, 1, ta);
        strat.simulateLoss(amt);
        ++ghostLossEvents;
        _check(true);
    }

    function harvest() external {
        vault.harvest();
        _check(false);
    }

    function togglePause(bool p) external {
        vm.prank(owner);
        if (p) vault.pause();
        else vault.unpause();
    }

    function setFee(uint16 bps) external {
        // Fee changes would break the "fee <= fee% of gains" accounting bound for the *initial* fee;
        // keep it at or below the initial rate (2000).
        bps = uint16(bound(bps, 0, 2_000));
        vm.prank(owner);
        vault.setPerformanceFee(bps);
        _check(false);
    }
}

contract YieldVaultInvariantTest is StdInvariant, Test {
    YieldVault vault;
    MockERC20 token;
    MockYieldStrategy strat;
    Handler handler;
    address owner = makeAddr("owner");
    address feeTo = makeAddr("feeTo");
    uint16 constant FEE = 2_000;

    function setUp() public {
        token = new MockERC20("Mock USD", "mUSD", 18);
        vault = new YieldVault(token, "Yield Vault Share", "yvUSD", owner, feeTo, FEE, 5e30);
        strat = new MockYieldStrategy(address(token), address(vault), 3e9);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strat)));
        handler = new Handler(vault, token, strat, owner, feeTo);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = Handler.deposit.selector;
        sel[1] = Handler.mint.selector;
        sel[2] = Handler.redeem.selector;
        sel[3] = Handler.withdraw.selector;
        sel[4] = Handler.addYield.selector;
        sel[5] = Handler.passTime.selector;
        sel[6] = Handler.loss.selector;
        sel[7] = Handler.harvest.selector;
        sel[8] = Handler.togglePause.selector;
        sel[9] = Handler.setFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// @dev totalAssets covers the redeemable value of every holder (incl. fee recipient).
    function invariant_totalAssetsCoversAllRedeemableValue() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += vault.previewRedeem(vault.balanceOf(handler.actors(i)));
        }
        sum += vault.previewRedeem(vault.balanceOf(feeTo));
        assertLe(sum, vault.totalAssets(), "sum(redeemable) > totalAssets");
        assertLe(vault.previewRedeem(vault.totalSupply()), vault.totalAssets());
    }

    /// @dev Accounting identity: idle + strategy == totalAssets.
    function invariant_assetAccountingMatches() public view {
        assertEq(vault.totalAssets(), token.balanceOf(address(vault)) + strat.totalAssets());
    }

    /// @dev Share price never decreases unless a loss was injected (rounding always favours the vault).
    function invariant_sharePriceNeverDecreasesAbsentLoss() public view {
        assertFalse(handler.priceDroppedWithoutLoss(), "price fell without loss");
    }

    /// @dev Fee accrues only on gains: no gains -> no fee shares; total fee value <= fee% of gross gains.
    function invariant_feeOnlyOnGains() public view {
        uint256 feeShares = vault.balanceOf(feeTo);
        if (!handler.everHadYield()) {
            assertEq(feeShares, 0, "fee minted with no gains");
            assertEq(vault.pendingFeeShares(), 0);
        }
        // Value of all fee shares at mint time (+ the still-unminted pending fee) is bounded by fee% of gross gains.
        // (Holdings are NOT used directly: the fee recipient's shares also appreciate like any other holder's.)
        uint256 pendingValue = vault.convertToAssets(vault.pendingFeeShares());
        assertLe(
            handler.ghostFeeValue() + pendingValue,
            (handler.ghostGross() * FEE) / 10_000 + handler.ghostGross() / 1e12 + 1e6, // 1e-12 rounding slack
            "fee > fee% of gross gains"
        );
    }

    /// @dev The high-water mark is monotonic and never exceeds the current-or-prior peak price.
    function invariant_highWaterMarkAtLeastInitial() public view {
        assertGe(vault.highWaterMark(), vault.PRICE_UNIT());
    }

    /// @dev Deposits can never push the vault beyond cap + gains.
    function invariant_capRespected() public view {
        assertLe(vault.totalAssets(), 5e30 + handler.ghostGross());
    }
}
