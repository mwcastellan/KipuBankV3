// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV2Router02} from "./mocks/MockUniswapV2Router02.sol";
import {MockUniswapV2Factory} from "./mocks/MockUniswapV2Factory.sol";

contract KipuBankV3Test is Test {
    // Eventos (mismo signature que en el contrato para expectEmit)
    event BankCapUpdated(uint256 oldCap, uint256 newCap);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event USDCUpdated(address indexed oldUsdc, address indexed newUsdc);
    event DepositUsdc(address indexed user, uint256 usdcAmount);
    event DepositSwapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );
    event WithdrawUsdc(
        address indexed user,
        uint256 usdcAmount,
        address indexed to
    );

    // SUT
    KipuBankV3 public bank;

    // Mocks
    MockUniswapV2Router02 public router;
    MockUniswapV2Factory public factory;
    MockERC20 public USDC;
    MockERC20 public WETH;
    MockERC20 public DAI;
    MockERC20 public WBTC;

    address public owner = address(0xD38CFbEa8E7A08258734c13c956912857cD6B37b);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 public constant CAP = 1_000_000e6;

    function setUp() public {
        // Tokens
        USDC = new MockERC20("USD Coin", "USDC", 6);
        WETH = new MockERC20("Wrapped Ether", "WETH", 18);
        DAI = new MockERC20("Dai", "DAI", 18);
        WBTC = new MockERC20("Wrapped BTC", "WBTC", 8);

        // Router + Factory
        router = new MockUniswapV2Router02(address(WETH));
        factory = new MockUniswapV2Factory();
        router.setFactory(address(factory));
        router.setUSDC(address(USDC));

        // Rates
        router.setTokenRate(address(DAI), 1e18); // 1 DAI -> 1 USDC
        router.setTokenRate(address(WBTC), 70_000e18); // 1 WBTC -> 70k USDC
        router.setEthRate(3_000e18); // 1 ETH  -> 3000 USDC

        // Pairs directos a USDC
        factory.setPair(address(DAI), address(USDC), address(0x111));
        factory.setPair(address(WBTC), address(USDC), address(0x222));
        // WETH-USDC par para depositEth (no lo usa hasDirectUsdcPair, pero es realista)
        factory.setPair(address(WETH), address(USDC), address(0x333));

        // Deploy SUT
        vm.prank(owner);
        bank = new KipuBankV3(address(router), address(USDC), CAP, owner);

        // Fondos
        USDC.mint(alice, CAP); //  USDC.mint(alice, 10_000e6);
        DAI.mint(alice, 10_000e18);
        WBTC.mint(alice, 2e8);

        USDC.mint(bob, 5_000e6);

        // Approvals
        vm.prank(alice);
        USDC.approve(address(bank), type(uint256).max);
        vm.prank(alice);
        DAI.approve(address(bank), type(uint256).max);
        vm.prank(alice);
        WBTC.approve(address(bank), type(uint256).max);

        vm.deal(alice, 100 ether);
    }

    // -------- Constructor / estado inicial --------
    function testInitialState() public {
        assertEq(address(bank.router()), address(router));
        assertEq(address(bank.usdc()), address(USDC));
        assertEq(bank.bankCap(), CAP);
        assertTrue(bank.WETH() == address(WETH));
    }

    // -------- hasDirectUsdcPair / helpers --------
    function testHasDirectUsdcPair() public {
        assertTrue(bank.hasDirectUsdcPair(address(DAI)));
        assertTrue(bank.hasDirectUsdcPair(address(WBTC)));
        assertFalse(bank.hasDirectUsdcPair(address(0xDEAD))); // sin par
    }

    function testRemainingCapacity() public {
        assertEq(bank.remainingCapacity(), CAP);
        vm.prank(alice);
        bank.depositUsdc(1_000e6);
        assertEq(bank.remainingCapacity(), CAP - 1_000e6);
    }

    // -------- Depósito USDC --------
    function testDepositUsdc_Success_Emits() public {
        uint256 amt = 1_234e6;
        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit DepositUsdc(alice, amt);
        bank.depositUsdc(amt);

        assertEq(bank.balanceOfUsdc(alice), amt);
        assertEq(bank.totalUsdc(), amt);
        assertEq(USDC.balanceOf(address(bank)), amt);
    }

    function testDepositUsdc_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUsdc(0);
    }

    function testDepositUsdc_Revert_CapExceeded() public {
        vm.prank(alice);
        bank.depositUsdc(CAP - 100e6);
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositUsdc(200e6);
    }

    // -------- Depósito ETH --------
    function testDepositEth_Success_Emits() public {
        uint256 ethIn = 2 ether; // 2 ETH * 3000 = 6000 USDC
        uint256 minOut = 5_500e6;

        uint256 usdcBefore = USDC.balanceOf(address(bank));
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        // user, tokenIn(0), amountIn, usdcReceived (match on topics/data)
        emit DepositSwapped(alice, address(0), ethIn, 0);
        bank.depositEth{value: ethIn}(minOut, block.timestamp + 1 hours);

        uint256 received = USDC.balanceOf(address(bank)) - usdcBefore;
        assertEq(received, 6_000e6);
        assertEq(bank.balanceOfUsdc(alice), received);
        assertEq(bank.totalUsdc(), received);
    }

    function testDepositEth_Revert_Slippage() public {
        uint256 ethIn = 1 ether; // 3000 USDC
        uint256 minOut = 3_500e6; // mayor a lo que da el rate
        vm.prank(alice);
        vm.expectRevert(bytes("slip"));
        bank.depositEth{value: ethIn}(minOut, block.timestamp + 1 hours);
    }

    function testDepositEth_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositEth(1, block.timestamp + 1 hours);
    }

    function testDepositEth_Revert_CapExceeded_ByPrecheckOrFinal() public {
        // Llenamos casi todo el cap
        vm.prank(alice);
        bank.depositUsdc(CAP - 1000);
        // minOut ya superaría el cap
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositEth{value: 1 ether}(2000, block.timestamp + 1 hours);
    }

    // -------- Depósito Token --------
    function testDepositToken_Success_DAI_1to1() public {
        uint256 daiIn = 2_000e18;
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit DepositSwapped(alice, address(DAI), daiIn, 0);
        bank.depositToken(
            address(DAI),
            daiIn,
            1_900e6,
            block.timestamp + 1 hours
        );

        assertEq(bank.balanceOfUsdc(alice), 2_000e6);
        assertEq(bank.totalUsdc(), 2_000e6);
        assertEq(USDC.balanceOf(address(bank)), 2_000e6);
    }

    function testDepositToken_Success_WBTC_HighValue() public {
        uint256 wbtcIn = 1e8; // 1 WBTC
        vm.prank(alice);
        bank.depositToken(
            address(WBTC),
            wbtcIn,
            60_000e6,
            block.timestamp + 1 hours
        );

        assertEq(bank.balanceOfUsdc(alice), 70_000e6);
        assertEq(bank.totalUsdc(), 70_000e6);
    }

    function testDepositToken_Revert_Unsupported_NoPair() public {
        address XYZ = address(0xBEEF);
        // no pair configurado
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(XYZ, 100, 1, block.timestamp + 1 hours);
    }

    function testDepositToken_Revert_Unsupported_IfUSDC() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(
            address(USDC),
            100e6,
            100e6,
            block.timestamp + 1 hours
        );
    }

    function testDepositToken_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositToken(address(DAI), 0, 0, block.timestamp + 1 hours);
    }

    function testDepositToken_Revert_Slippage() public {
        vm.prank(alice);
        vm.expectRevert(bytes("slip"));
        bank.depositToken(
            address(DAI),
            100e18,
            200e6,
            block.timestamp + 1 hours
        );
    }

    function testDepositToken_Revert_CapExceeded_Precheck() public {
        vm.prank(alice);
        bank.depositUsdc(CAP - 1_000e6);
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositToken(
            address(DAI),
            1_000e18,
            1_000e6,
            block.timestamp + 1 hours
        );
    }

    // -------- Withdraw --------
    function testWithdrawUsdc_Success_Emits() public {
        vm.prank(alice);
        bank.depositUsdc(2_000e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit WithdrawUsdc(alice, 500e6, bob);
        bank.withdrawUsdc(500e6, bob);

        assertEq(bank.balanceOfUsdc(alice), 1_500e6);
        assertEq(bank.totalUsdc(), 1_500e6);
        assertEq(USDC.balanceOf(bob), 500e6);
    }

    function testWithdrawUsdc_Revert_ZeroAddress() public {
        vm.prank(alice);
        bank.depositUsdc(1_000e6);
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAddress.selector);
        bank.withdrawUsdc(100e6, address(0));
    }

    function testWithdrawUsdc_Revert_ZeroAmount() public {
        vm.prank(alice);
        bank.depositUsdc(1);
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.withdrawUsdc(0, alice);
    }

    function testWithdrawUsdc_Revert_InsufficientBalance() public {
        vm.prank(alice);
        bank.depositUsdc(100e6);
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.InsufficientBalance.selector);
        bank.withdrawUsdc(200e6, alice);
    }

    // -------- Pausable / Ownable / Admin --------
    function testPause_Unpause_OnlyOwner() public {
        vm.prank(owner);
        bank.pause();

        vm.prank(alice);
        vm.expectRevert(); // not owner => Pausable no expone revert específico aquí, pero no importa
        bank.unpause();

        vm.prank(owner);
        bank.unpause();

        // deposit durante pausa => revert
        vm.prank(owner);
        bank.pause();
        vm.prank(alice);
        vm.expectRevert();
        bank.depositUsdc(1e6);
        vm.prank(owner);
        bank.unpause();
    }

    function testSetters_OnlyOwner_AndEvents() public {
        // setUsdc
        MockERC20 NEWUSDC = new MockERC20("nUSDC", "nUSDC", 6);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit USDCUpdated(address(USDC), address(NEWUSDC));
        bank.setUsdc(address(NEWUSDC));
        assertEq(address(bank.usdc()), address(NEWUSDC));

        // setRouter (cambia factory/WETH indirectamente en prod; aquí solo evento)
        MockUniswapV2Router02 newRouter = new MockUniswapV2Router02(
            address(WETH)
        );
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit RouterUpdated(address(router), address(newRouter));
        bank.setRouter(address(newRouter));
        assertEq(address(bank.router()), address(newRouter));

        // setBankCap
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit BankCapUpdated(CAP, CAP + 1);
        bank.setBankCap(CAP + 1);
        assertEq(bank.bankCap(), CAP + 1);
    }

    // -------- rescueERC20 --------
    function testRescueERC20_OnlyOwner() public {
        // Enviamos tokens extra al contrato
        USDC.mint(address(bank), 123e6);

        // No afecta balances internos; owner puede rescatar
        vm.prank(owner);
        bank.rescueERC20(address(USDC), owner, 23e6);
        assertEq(USDC.balanceOf(owner), 23e6);
    }

    function testRescueERC20_Revert_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(KipuBankV3.ZeroAddress.selector);
        bank.rescueERC20(address(0), owner, 1);
        vm.prank(owner);
        vm.expectRevert(KipuBankV3.ZeroAddress.selector);
        bank.rescueERC20(address(USDC), address(0), 1);
    }

    // -------- Receive() bloqueo --------
    function testReceive_Revert_UseDepositEth() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok, ) = address(bank).call{value: 1 ether}("");
        assertFalse(ok, "should revert");
    }
}
