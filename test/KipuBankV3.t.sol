// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Router02.sol";
import "./mocks/MockUniswapV2Factory.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 bank;
    MockERC20 usdc;
    MockERC20 dai;
    MockUniswapV2Router02 router;
    MockUniswapV2Factory factory;

    address owner = address(0xABCD);
    address alice = address(0x1111);

    uint256 constant BANK_CAP = 1_000_000e6;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockERC20("USDC", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);

        router = new MockUniswapV2Router02(1); // 1:1 swap
        factory = new MockUniswapV2Factory();

        bank = new KipuBankV3(address(router), address(usdc), BANK_CAP, owner);

        vm.stopPrank();
    }

    /*───────────────────────────────────────────────
                        DEPÓSITO ETH
    ───────────────────────────────────────────────*/

    function testDepositETH() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        bank.depositEth{value: 1 ether}(1e6, block.timestamp + 1 hours);

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(bal, 1e6);
    }

    function testDepositETH_RevertZero() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositEth{value: 0 ether}(1e6, block.timestamp + 1 hours);
    }

    /*───────────────────────────────────────────────
                        DEPÓSITO TOKEN
    ───────────────────────────────────────────────*/

    function testDepositToken() public {
        dai.mint(alice, 1e18);
        vm.prank(alice);
        dai.approve(address(bank), 1e18);

        vm.prank(alice);
        bank.depositToken(address(dai), 1e18, 1e6, block.timestamp + 1 hours);

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(bal, 1e6);
    }

    function testDepositToken_RevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositToken(address(dai), 0, 1e6, block.timestamp + 1 hours);
    }

    function testDepositToken_Unsupported_NoPair() public {
        MockERC20 bad = new MockERC20("BAD", "BAD", 18);
        bad.mint(alice, 1e18);

        vm.prank(alice);
        bad.approve(address(bank), 1e18);

        vm.prank(alice);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(address(bad), 1e18, 1, block.timestamp + 1 hours);
    }

    /*───────────────────────────────────────────────
                        DEPÓSITO USDC
    ───────────────────────────────────────────────*/

    function testDepositUSDC() public {
        usdc.mint(alice, 1e6);

        vm.prank(alice);
        usdc.approve(address(bank), 1e6);

        vm.prank(alice);
        bank.depositUsdc(1e6);

        assertEq(bank.sBalanceOfUsdc(alice), 1e6);
    }

    function testDepositUSDC_RevertZero() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUsdc(0);
    }

    /*───────────────────────────────────────────────
                        CONTROL OWNER
    ───────────────────────────────────────────────*/

    function testPause() public {
        // NON-owner → must revert
        vm.prank(alice);
        vm.expectRevert();
        bank.pause();

        // OWNER → OK
        vm.prank(owner);
        bank.pause();
        assertTrue(bank.paused());
    }

    function testSetRouter() public {
        MockUniswapV2Router02 newRouter = new MockUniswapV2Router02(1);

        vm.prank(alice);
        vm.expectRevert(); // alice cannot call
        bank.setRouter(address(newRouter));

        vm.prank(owner);
        bank.setRouter(address(newRouter));

        assertEq(address(bank.sRouter()), address(newRouter));
    }

    function testSetBankCap() public {
        vm.prank(owner);
        bank.setBankCap(10_000e6);
        assertEq(bank.sBankCap(), 10_000e6);
    }

    /*───────────────────────────────────────────────
                        WITHDRAW
    ───────────────────────────────────────────────*/

    function testWithdrawUSDC() public {
        usdc.mint(alice, 1e6);
        vm.prank(alice);
        usdc.approve(address(bank), 1e6);

        vm.prank(alice);
        bank.depositUsdc(1e6);

        vm.prank(owner);
        bank.unpause();

        vm.prank(alice);
        bank.withdrawUsdc(1e6, alice);

        assertEq(usdc.balanceOf(alice), 1e6);
        assertEq(bank.sBalanceOfUsdc(alice), 0);
    }

    function testWithdrawUSDC_RevertInsufficient() public {
        vm.prank(owner);
        bank.unpause();

        vm.prank(alice);
        vm.expectRevert(KipuBankV3.InsufficientBalance.selector);
        bank.withdrawUsdc(1e6, alice);
    }
}
