// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CollateralizedLending} from "../src/CollateralizedLending.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

interface Vm {
    function warp(uint256 newTimestamp) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}

contract CollateralizedLendingTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant ALICE = address(0xA11CE);
    address internal constant LIQUIDATOR = address(0xB0B);

    MockOracle internal oracle;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    CollateralizedLending internal market;

    uint256 internal constant WETH_PRICE = 2_000e18;
    uint256 internal constant USDC_PRICE = 1e18;

    function setUp() public {
        vm.warp(10 days);

        oracle = new MockOracle();
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        market = new CollateralizedLending(address(oracle));

        market.configureAsset(address(weth), true, false, 7_500, 8_000, 500, 0, 1 days);
        market.configureAsset(address(usdc), false, true, 0, 0, 0, 1_000, 1 days);

        oracle.setPrice(address(weth), WETH_PRICE);
        oracle.setPrice(address(usdc), USDC_PRICE);

        weth.mint(ALICE, 10 ether);
        usdc.mint(address(market), 1_000_000e6);
        usdc.mint(LIQUIDATOR, 100_000e6);

        vm.startPrank(ALICE);
        weth.approve(address(market), type(uint256).max);
        usdc.approve(address(market), type(uint256).max);
        vm.stopPrank();

        vm.prank(LIQUIDATOR);
        usdc.approve(address(market), type(uint256).max);
    }

    function testHealthyBorrowing() public {
        _depositAndBorrow(1_000e6);

        (uint256 principal, uint256 interest, uint256 total) = market.debtOf(ALICE, address(usdc));
        assertEq(principal, 1_000e6, "principal");
        assertEq(interest, 0, "interest");
        assertEq(total, 1_000e6, "total debt");
        assertEq(market.borrowLimitUsd(ALICE), 1_500e18, "borrow limit");
        assertEq(market.healthFactor(ALICE), 1_600_000_000_000_000_000, "health factor");
        assertEq(usdc.balanceOf(ALICE), 1_000e6, "borrow transfer");
    }

    function testInterestAccruesWithVmWarp() public {
        _depositAndBorrow(1_000e6);
        vm.warp(block.timestamp + 365 days);

        (uint256 principal, uint256 interest, uint256 total) = market.debtOf(ALICE, address(usdc));
        assertEq(principal, 1_000e6, "principal unchanged");
        assertEq(interest, 100e6, "10% annual interest");
        assertEq(total, 1_100e6, "debt after one year");
    }

    function testOverBorrowIsRejected() public {
        vm.prank(ALICE);
        market.depositCollateral(address(weth), 1 ether);

        vm.expectRevert(CollateralizedLending.BorrowLimitExceeded.selector);
        vm.prank(ALICE);
        market.borrow(address(usdc), 1_501e6);
    }

    function testPriceDropMakesPositionUnhealthy() public {
        _depositAndBorrow(1_400e6);
        oracle.setPrice(address(weth), 1_500e18);

        uint256 health = market.healthFactor(ALICE);
        assertLt(health, 1e18, "price drop should make account liquidatable");
    }

    function testPartialThenFullRepayment() public {
        _depositAndBorrow(1_000e6);
        vm.warp(block.timestamp + 365 days / 2);

        vm.prank(ALICE);
        uint256 firstRepay = market.repay(address(usdc), 400e6);
        assertEq(firstRepay, 400e6, "partial repay amount");

        (uint256 principal, uint256 interest, uint256 total) = market.debtOf(ALICE, address(usdc));
        assertEq(principal, 650e6, "interest paid first, then principal");
        assertEq(interest, 0, "accrued interest repaid");
        assertEq(total, 650e6, "remaining debt");

        usdc.mint(ALICE, 100e6);
        vm.prank(ALICE);
        uint256 finalRepay = market.repay(address(usdc), type(uint256).max);
        assertEq(finalRepay, 650e6, "full repay amount");

        (principal, interest, total) = market.debtOf(ALICE, address(usdc));
        assertEq(principal, 0, "principal cleared");
        assertEq(interest, 0, "interest cleared");
        assertEq(total, 0, "debt cleared");
    }

    function testCollateralWithdrawalOnlyWhileHealthy() public {
        _depositAndBorrow(1_000e6);

        vm.expectRevert(CollateralizedLending.UnhealthyAccount.selector);
        vm.prank(ALICE);
        market.withdrawCollateral(address(weth), 0.5 ether);

        vm.prank(ALICE);
        market.withdrawCollateral(address(weth), 0.25 ether);
        assertEq(market.collateralBalance(ALICE, address(weth)), 0.75 ether, "healthy withdrawal");
    }

    function testLiquidationPaysConfiguredBonus() public {
        _depositAndBorrow(1_400e6);
        oracle.setPrice(address(weth), 1_500e18);

        uint256 liquidatorWethBefore = weth.balanceOf(LIQUIDATOR);

        vm.prank(LIQUIDATOR);
        (uint256 repaid, uint256 seized) = market.liquidate(ALICE, address(usdc), address(weth), 500e6);

        assertEq(repaid, 500e6, "repaid debt");
        assertEq(seized, 0.35 ether, "500 USD plus 5% bonus at 1500 USD/ETH");
        assertEq(weth.balanceOf(LIQUIDATOR) - liquidatorWethBefore, 0.35 ether, "liquidator reward");
        assertEq(market.collateralBalance(ALICE, address(weth)), 0.65 ether, "remaining collateral");

        (, , uint256 remainingDebt) = market.debtOf(ALICE, address(usdc));
        assertEq(remainingDebt, 900e6, "remaining debt");
    }

    function testLiquidationIsBoundedByCloseFactor() public {
        _depositAndBorrow(1_400e6);
        oracle.setPrice(address(weth), 1_500e18);

        vm.prank(LIQUIDATOR);
        (uint256 repaid, uint256 seized) = market.liquidate(ALICE, address(usdc), address(weth), type(uint256).max);

        assertEq(repaid, 700e6, "50% close factor");
        assertEq(seized, 0.49 ether, "close-factor liquidation plus bonus");
    }

    function testHealthyAccountCannotBeLiquidated() public {
        _depositAndBorrow(1_000e6);

        vm.expectRevert(CollateralizedLending.HealthyAccount.selector);
        vm.prank(LIQUIDATOR);
        market.liquidate(ALICE, address(usdc), address(weth), 100e6);
    }

    function testStaleOraclePriceIsRejected() public {
        vm.prank(ALICE);
        market.depositCollateral(address(weth), 1 ether);

        vm.warp(block.timestamp + 2 days);
        oracle.setPriceWithTimestamp(address(weth), WETH_PRICE, block.timestamp - 2 days);

        vm.expectRevert(CollateralizedLending.StalePrice.selector);
        vm.prank(ALICE);
        market.borrow(address(usdc), 1_000e6);
    }

    function testMissingOraclePriceIsRejected() public {
        vm.prank(ALICE);
        market.depositCollateral(address(weth), 1 ether);
        oracle.clearPrice(address(usdc));

        vm.expectRevert(CollateralizedLending.MissingPrice.selector);
        vm.prank(ALICE);
        market.borrow(address(usdc), 1_000e6);
    }

    function testUnsupportedAssetIsRejected() public {
        MockERC20 unsupported = new MockERC20("Unsupported", "NOPE", 18);
        unsupported.mint(ALICE, 1 ether);

        vm.startPrank(ALICE);
        unsupported.approve(address(market), type(uint256).max);
        vm.expectRevert(CollateralizedLending.UnsupportedAsset.selector);
        market.depositCollateral(address(unsupported), 1 ether);
        vm.stopPrank();
    }

    function testSeverePriceCrashCreatesBadDebtAfterCollateralExhaustion() public {
        _depositAndBorrow(1_400e6);
        oracle.setPrice(address(weth), 400e18);

        vm.prank(LIQUIDATOR);
        (uint256 repaid, uint256 seized) = market.liquidate(ALICE, address(usdc), address(weth), type(uint256).max);

        assertEq(seized, 1 ether, "all collateral exhausted");
        assertLt(repaid, 700e6, "collateral bound tighter than close factor");
        assertEq(market.collateralBalance(ALICE, address(weth)), 0, "no collateral remains");
        assertTrue(market.hasBadDebt(ALICE), "remaining debt is bad debt");

        (, , uint256 remainingDebt) = market.debtOf(ALICE, address(usdc));
        assertGt(remainingDebt, 0, "debt remains after collateral exhaustion");
    }

    function _depositAndBorrow(uint256 borrowAmount) internal {
        vm.startPrank(ALICE);
        market.depositCollateral(address(weth), 1 ether);
        market.borrow(address(usdc), borrowAmount);
        vm.stopPrank();
    }

    function assertEq(uint256 actual, uint256 expected, string memory message) internal pure {
        require(actual == expected, message);
    }

    function assertTrue(bool value, string memory message) internal pure {
        require(value, message);
    }

    function assertLt(uint256 a, uint256 b, string memory message) internal pure {
        require(a < b, message);
    }

    function assertGt(uint256 a, uint256 b, string memory message) internal pure {
        require(a > b, message);
    }
}
