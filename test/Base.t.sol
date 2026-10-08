// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockYieldStrategy} from "../src/mocks/MockYieldStrategy.sol";

abstract contract Base is Test {
    MockERC20 internal token;
    YieldVault internal vault;
    MockYieldStrategy internal strat;

    address internal owner = makeAddr("owner");
    address internal feeTo = makeAddr("feeTo");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint16 internal constant FEE = 2_000; // 20%
    uint256 internal constant CAP = 1_000_000e18;

    function _deploy(uint16 feeBps, uint256 cap, uint256 rate) internal {
        token = new MockERC20("Mock USD", "mUSD", 18);
        vault = new YieldVault(token, "Yield Vault Share", "yvUSD", owner, feeTo, feeBps, cap);
        strat = new MockYieldStrategy(address(token), address(vault), rate);
        vm.prank(owner);
        vault.setStrategy(IStrategy(address(strat)));
    }

    function _fund(address who, uint256 amt) internal {
        token.mint(who, amt);
        vm.prank(who);
        token.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        _fund(who, amt);
        vm.prank(who);
        return vault.deposit(amt, who);
    }
}
