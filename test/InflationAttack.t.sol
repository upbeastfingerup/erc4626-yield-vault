// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @dev Deliberately vulnerable textbook vault: shares = assets * supply / totalAssets, no virtual offset.
contract NaiveVault is ERC20 {
    IERC20 public immutable asset;

    constructor(IERC20 a) ERC20("naive", "nv") {
        asset = a;
    }

    function deposit(uint256 amt) external returns (uint256 shares) {
        uint256 ts = totalSupply();
        uint256 ta = asset.balanceOf(address(this));
        shares = ts == 0 ? amt : Math.mulDiv(amt, ts, ta);
        asset.transferFrom(msg.sender, address(this), amt);
        _mint(msg.sender, shares);
    }

    function redeem(uint256 shares) external returns (uint256 out) {
        out = Math.mulDiv(shares, asset.balanceOf(address(this)), totalSupply());
        _burn(msg.sender, shares);
        asset.transfer(msg.sender, out);
    }
}

/// @notice Classic first-depositor inflation attack: attacker mints 1 wei of shares, donates a large
///         amount directly to the vault, victim's deposit rounds to 0 shares and the attacker steals it.
contract InflationAttackTest is Base {
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        _deploy(0, type(uint256).max, 0); // fee off to isolate the attack
    }

    /// @notice Control experiment: the attack WORKS against a naive vault (proves the test is meaningful).
    function test_naiveVaultIsExploitable() public {
        NaiveVault nv = new NaiveVault(token);
        token.mint(attacker, 10_001e18);
        token.mint(victim, 10_000e18);

        vm.startPrank(attacker);
        token.approve(address(nv), type(uint256).max);
        nv.deposit(1); // 1 wei -> 1 share
        token.transfer(address(nv), 10_000e18); // donation
        vm.stopPrank();

        vm.startPrank(victim);
        token.approve(address(nv), type(uint256).max);
        uint256 vShares = nv.deposit(10_000e18); // 10_000e18 * 1 / (10_000e18+1) = 0
        vm.stopPrank();
        assertEq(vShares, 0, "victim minted zero shares");

        vm.prank(attacker);
        uint256 out = nv.redeem(1);
        assertEq(out, 20_000e18 + 1, "attacker takes everything (own 10_001 + victim 10_000)");
        assertGt(out, 10_001e18, "attacker profit");
    }

    /// @notice The same attack against YieldVault: victim keeps ~all value, attacker takes a net loss.
    function test_yieldVaultBlocksInflationAttack() public {
        uint256 donation = 10_000e18;
        uint256 victimDeposit = 10_000e18;
        token.mint(attacker, 1 + donation);
        token.mint(victim, victimDeposit);

        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        uint256 aShares = vault.deposit(1, attacker);
        token.transfer(address(vault), donation); // direct donation to inflate price
        vm.stopPrank();

        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        uint256 vShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(vShares, 0, "victim gets shares");

        vm.prank(victim);
        uint256 victimOut = vault.redeem(vShares, victim, victim);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(aShares, attacker, attacker);

        uint256 victimLoss = victimDeposit - victimOut;
        uint256 attackerLoss = 1 + donation - attackerOut;
        // Victim loses only the rounding of ~1 share unit of the 1e6-offset (~2.5e-7 of the deposit)...
        assertLe(victimLoss, victimDeposit / 1e6, "victim loss < 0.0001%");
        // ...while the attacker burns ~50% of the donation and the attack is a net loss.
        assertLt(attackerOut, 1 + donation, "attacker net loss");
        assertGt(attackerLoss, victimLoss * 1000, "attacker loses >1000x what victim loses");
        emit log_named_uint("victim lost (wei)", victimDeposit - victimOut);
        emit log_named_uint("attacker lost (wei)", attackerLoss);
    }

    /// @notice Fuzz: for any donation / victim size the attacker never profits.
    function testFuzz_attackNeverProfitable(uint96 donation, uint96 victimDep) public {
        donation = uint96(bound(donation, 1, type(uint96).max));
        victimDep = uint96(bound(victimDep, 1e6, type(uint96).max));
        token.mint(attacker, uint256(donation) + 1);
        token.mint(victim, victimDep);

        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        uint256 aShares = vault.deposit(1, attacker);
        token.transfer(address(vault), donation);
        vm.stopPrank();

        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(victimDep, victim);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(aShares, attacker, attacker);
        assertLe(attackerOut, uint256(donation) + 1, "attack never profits");
    }

    /// @notice Fuzz: whenever the victim deposits at least the donation, they lose < 0.001% (rounding only).
    function testFuzz_victimLossBounded(uint96 donation, uint96 victimDep) public {
        donation = uint96(bound(donation, 1, type(uint96).max));
        victimDep = uint96(bound(victimDep, uint256(donation) > 1e6 ? donation : 1e6, type(uint96).max));
        token.mint(attacker, uint256(donation) + 1);
        token.mint(victim, victimDep);

        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        token.transfer(address(vault), donation);
        vm.stopPrank();

        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        uint256 vShares = vault.deposit(victimDep, victim);
        assertGt(vShares, 0, "victim never rounded to zero shares");
        uint256 out = vault.redeem(vShares, victim, victim);
        vm.stopPrank();
        assertGe(out + victimDep / 1e5, victimDep, "victim loss < 0.001%");
    }
}
