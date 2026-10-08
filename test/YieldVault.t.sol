// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockYieldStrategy} from "../src/mocks/MockYieldStrategy.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract YieldVaultTest is Base {
    function setUp() public {
        _deploy(FEE, CAP, 0);
    }

    // ---------------------------------------------------------------- basics

    function test_metadata() public view {
        assertEq(vault.asset(), address(token));
        assertEq(vault.decimals(), 18 + 6);
        assertEq(vault.sharePrice(), vault.PRICE_UNIT());
        assertEq(vault.highWaterMark(), vault.PRICE_UNIT());
    }

    function test_depositRoutesToStrategy() public {
        _deposit(alice, 100e18);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(strat.totalAssets(), 100e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_redeemRoundTrip() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(out, 100e18, 1);
        assertEq(token.balanceOf(alice), out);
        assertLe(out, 100e18);
    }

    function test_mintAndWithdraw() public {
        _fund(alice, 1_000e18);
        vm.startPrank(alice);
        uint256 cost = vault.mint(500e24, alice);
        assertEq(vault.balanceOf(alice), 500e24);
        assertApproxEqAbs(cost, 500e18, 1);
        vault.withdraw(100e18, alice, alice);
        vm.stopPrank();
        // started with 1000, paid ~500 for the mint, withdrew 100
        assertApproxEqAbs(token.balanceOf(alice), 1_000e18 - cost + 100e18, 0);
    }

    function test_previewMatchesExecution_withPendingFee() public {
        _deposit(alice, 100e18);
        strat.donateYield(50e18);
        uint256 pDep = vault.previewDeposit(10e18);
        uint256 pRed = vault.previewRedeem(1e24);
        _fund(bob, 10e18);
        vm.prank(bob);
        assertEq(vault.deposit(10e18, bob), pDep);
        vm.prank(alice);
        assertEq(vault.redeem(1e24, alice, alice), pRed);
    }

    // ------------------------------------------------------------------- fees

    function test_noFeeWithoutGain() public {
        _deposit(alice, 100e18);
        _deposit(bob, 50e18);
        vault.harvest();
        assertEq(vault.balanceOf(feeTo), 0);
    }

    function test_feeOnGain() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        vault.harvest();
        // 20% of 10 = 2 assets of fee
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(feeTo)), 2e18, 1e3);
        // alice keeps ~8 of the 10
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 108e18, 1e3);
    }

    function test_highWaterMark_noFeeOnRecovery() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        vault.harvest();
        uint256 feeSharesAfterGain = vault.balanceOf(feeTo);
        uint256 hwm = vault.highWaterMark();

        strat.simulateLoss(20e18);
        vault.harvest();
        assertEq(vault.highWaterMark(), hwm, "hwm must not fall");
        assertEq(vault.balanceOf(feeTo), feeSharesAfterGain);

        // Recover the same 20 -> back to (roughly) old price -> no new fee
        strat.donateYield(20e18);
        vault.harvest();
        assertApproxEqAbs(vault.balanceOf(feeTo), feeSharesAfterGain, feeSharesAfterGain / 1e9 + 1e3);

        // Gain beyond the old mark IS charged
        strat.donateYield(10e18);
        vault.harvest();
        assertGt(vault.balanceOf(feeTo), feeSharesAfterGain);
    }

    function test_feeSettledOnDepositAndWithdraw() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        assertEq(vault.balanceOf(feeTo), 0);
        _deposit(bob, 10e18);
        assertGt(vault.balanceOf(feeTo), 0, "deposit settles fee");
    }

    function test_lateDepositorNotChargedForEarlierGain() public {
        _deposit(alice, 100e18);
        strat.donateYield(100e18);
        uint256 bobShares = _deposit(bob, 100e18);
        uint256 feeBefore = vault.balanceOf(feeTo);
        vault.harvest();
        assertEq(vault.balanceOf(feeTo), feeBefore, "no extra fee after bob joins");
        // bob can redeem ~ what he put in
        vm.prank(bob);
        uint256 out = vault.redeem(bobShares, bob, bob);
        assertApproxEqAbs(out, 100e18, 1e3);
    }

    function test_timeBasedYield() public {
        _deploy(FEE, CAP, 1e10); // ~31% APR for visibility
        _deposit(alice, 1_000e18);
        skip(365 days);
        uint256 ta = vault.totalAssets();
        assertGt(ta, 1_000e18);
        vault.harvest();
        assertGt(vault.balanceOf(feeTo), 0);
        assertGt(vault.convertToAssets(vault.balanceOf(alice)), 1_000e18);
    }

    function test_setFee_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldVault.FeeTooHigh.selector, uint16(3001), uint16(3000)));
        vault.setPerformanceFee(3001);
    }

    function test_setFee_settlesAtOldRate() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        vm.prank(owner);
        vault.setPerformanceFee(0);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(feeTo)), 2e18, 1e3);
        strat.donateYield(10e18);
        uint256 b = vault.balanceOf(feeTo);
        vault.harvest();
        assertEq(vault.balanceOf(feeTo), b, "zero fee after change");
    }

    function test_feeRecipientChange() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        vm.prank(owner);
        vault.setFeeRecipient(bob);
        assertGt(vault.balanceOf(feeTo), 0);
        strat.donateYield(10e18);
        vault.harvest();
        assertGt(vault.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------- cap

    function test_depositCap() public {
        vm.prank(owner);
        vault.setDepositCap(100e18);
        assertEq(vault.maxDeposit(alice), 100e18);
        _deposit(alice, 60e18);
        assertEq(vault.maxDeposit(alice), 40e18);
        _fund(bob, 50e18);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 50e18, 40e18)
        );
        vault.deposit(50e18, bob);
        vm.prank(bob);
        vault.deposit(40e18, bob);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
    }

    function test_mintRespectsCap() public {
        vm.prank(owner);
        vault.setDepositCap(100e18);
        _fund(alice, 1_000e18);
        uint256 over = vault.previewDeposit(200e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(over, alice);
    }

    function test_yieldMayExceedCapButDepositsStayBlocked() public {
        vm.prank(owner);
        vault.setDepositCap(100e18);
        _deposit(alice, 100e18);
        strat.donateYield(5e18);
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_unlimitedCap() public {
        vm.prank(owner);
        vault.setDepositCap(type(uint256).max);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    // ---------------------------------------------------------- pause/emergency

    function test_pauseBlocksDepositsNotWithdrawals() public {
        uint256 shares = _deposit(alice, 100e18);
        vm.prank(owner);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        _fund(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(10e18, bob);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(out, 100e18, 1);
    }

    function test_emergencyExitPullsFundsAndStaysWithdrawable() public {
        uint256 sa = _deposit(alice, 100e18);
        uint256 sb = _deposit(bob, 50e18);
        strat.donateYield(15e18);
        vm.prank(owner);
        vault.emergencyExit();
        assertTrue(vault.paused());
        assertTrue(vault.emergency());
        assertEq(strat.totalAssets(), 0);
        assertEq(token.balanceOf(address(vault)), 165e18);
        assertEq(vault.totalAssets(), 165e18);

        vm.prank(alice);
        uint256 a = vault.redeem(sa, alice, alice);
        vm.prank(bob);
        uint256 b = vault.redeem(sb, bob, bob);
        assertGt(a, 100e18);
        assertGt(b, 50e18);
    }

    function test_unpauseResumesInvesting() public {
        _deposit(alice, 100e18);
        vm.startPrank(owner);
        vault.emergencyExit();
        vault.unpause();
        vm.stopPrank();
        _deposit(bob, 10e18);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(strat.totalAssets(), 110e18);
    }

    function test_onlyOwnerAdmin() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        vault.pause();
        vm.expectRevert(err);
        vault.unpause();
        vm.expectRevert(err);
        vault.emergencyExit();
        vm.expectRevert(err);
        vault.setDepositCap(1);
        vm.expectRevert(err);
        vault.setPerformanceFee(1);
        vm.expectRevert(err);
        vault.setFeeRecipient(alice);
        vm.expectRevert(err);
        vault.setStrategy(IStrategy(address(0)));
        vm.stopPrank();
    }

    function test_strategyOnlyCallableByVault() public {
        vm.expectRevert(MockYieldStrategy.OnlyVault.selector);
        strat.deposit(1);
        vm.expectRevert(MockYieldStrategy.OnlyVault.selector);
        strat.withdraw(1);
    }

    // ------------------------------------------------------------- strategy

    function test_migrateStrategy() public {
        _deposit(alice, 100e18);
        strat.donateYield(10e18);
        MockYieldStrategy s2 = new MockYieldStrategy(address(token), address(vault), 0);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(s2)));
        assertEq(strat.totalAssets(), 0);
        assertEq(s2.totalAssets(), 110e18);
        assertEq(vault.totalAssets(), 110e18);
    }

    function test_setStrategyZero_leavesIdle() public {
        _deposit(alice, 100e18);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(0)));
        assertEq(token.balanceOf(address(vault)), 100e18);
        _deposit(bob, 10e18);
        assertEq(token.balanceOf(address(vault)), 110e18);
    }

    function test_strategyAssetMismatchReverts() public {
        MockYieldStrategy bad = new MockYieldStrategy(address(0xBEEF), address(vault), 0);
        vm.prank(owner);
        vm.expectRevert(YieldVault.StrategyAssetMismatch.selector);
        vault.setStrategy(IStrategy(address(bad)));
    }

    function test_withdrawAfterLoss_sharesBearLoss() public {
        uint256 sa = _deposit(alice, 100e18);
        strat.simulateLoss(40e18);
        vm.prank(alice);
        uint256 out = vault.redeem(sa, alice, alice);
        assertApproxEqAbs(out, 60e18, 1e3);
    }

    function test_constructorValidation() public {
        vm.expectRevert(YieldVault.ZeroAddress.selector);
        new YieldVault(token, "x", "x", owner, address(0), 0, 1);
        vm.expectRevert(abi.encodeWithSelector(YieldVault.FeeTooHigh.selector, uint16(5000), uint16(3000)));
        new YieldVault(token, "x", "x", owner, feeTo, 5000, 1);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Any deposit/redeem round trip never returns more than was put in.
    function testFuzz_roundTripNeverProfits(uint96 amt) public {
        amt = uint96(bound(amt, 1, CAP));
        uint256 shares = _deposit(alice, amt);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertLe(out, amt);
    }

    /// @dev Round trip loses at most a dust amount thanks to the 1e6 virtual offset.
    function testFuzz_roundTripDustOnly(uint96 amt) public {
        amt = uint96(bound(amt, 1e6, CAP));
        uint256 shares = _deposit(alice, amt);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(out, amt, 2);
    }

    /// @dev Previews are exact for deposit even with yield and pending fee.
    function testFuzz_previewDepositExact(uint96 first, uint96 yield_, uint96 second) public {
        first = uint96(bound(first, 1e6, CAP / 4));
        yield_ = uint96(bound(yield_, 0, CAP / 4));
        second = uint96(bound(second, 1, CAP / 4));
        _deposit(alice, first);
        strat.donateYield(yield_);
        uint256 expected = vault.previewDeposit(second);
        assertEq(_deposit(bob, second), expected);
    }

    function testFuzz_previewRedeemExact(uint96 first, uint96 yield_) public {
        first = uint96(bound(first, 1e6, CAP / 2));
        yield_ = uint96(bound(yield_, 0, CAP / 2));
        uint256 sh = _deposit(alice, first);
        strat.donateYield(yield_);
        uint256 expected = vault.previewRedeem(sh);
        vm.prank(alice);
        assertEq(vault.redeem(sh, alice, alice), expected);
    }

    /// @dev Fee never exceeds feeBps of the realised gain.
    function testFuzz_feeBoundedByGain(uint96 amt, uint96 gain) public {
        amt = uint96(bound(amt, 1e18, CAP / 2));
        gain = uint96(bound(gain, 0, CAP / 2));
        _deposit(alice, amt);
        strat.donateYield(gain);
        vault.harvest();
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(feeTo));
        assertLe(feeValue, (uint256(gain) * FEE) / 10_000 + 1e3);
    }

    /// @dev Depositors are never charged for gains made before they joined, any ordering.
    function testFuzz_noFeeWithoutYield(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, CAP / 2));
        b = uint96(bound(b, 1, CAP / 2));
        _deposit(alice, a);
        _deposit(bob, b);
        vault.harvest();
        assertEq(vault.balanceOf(feeTo), 0);
    }

    function testFuzz_capNeverExceededByDeposits(uint96 cap, uint96 amt) public {
        cap = uint96(bound(cap, 1, type(uint96).max));
        vm.prank(owner);
        vault.setDepositCap(cap);
        uint256 max = vault.maxDeposit(alice);
        amt = uint96(bound(amt, 1, type(uint96).max));
        _fund(alice, amt);
        vm.prank(alice);
        if (amt > max) {
            vm.expectRevert();
            vault.deposit(amt, alice);
        } else {
            vault.deposit(amt, alice);
            assertLe(vault.totalAssets(), cap);
        }
    }
}
