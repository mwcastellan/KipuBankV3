// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {KipuBankV3} from "src/KipuBankV3.sol"; // ⬅️ AJUSTAR si tu ruta no es src/
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapV2Router02} from "./mocks/MockUniswapV2Router02.sol";
import {MockUniswapV2Factory} from "./mocks/MockUniswapV2Factory.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockUniswapV2Router02 public router;
    MockUniswapV2Factory public factory;
    MockERC20 public USDC;
    MockERC20 public WETH9; // solo placeholder de dirección WETH
    MockERC20 public DAI;
    MockERC20 public WBTC;

    address public owner = address(0xA11CE);
    address public alice = address(0xB0B);
    address public bob   = address(0xC0C);

    uint256 public constant BANK_CAP = 1_000_000e6; // 1M USDC (6 dec)
    uint256 public constant ONE = 1e18;

    function setUp() public {
        vm.startPrank(owner);

        // Tokens
        USDC  = new MockERC20("USD Coin", "USDC", 6);
        WETH9 = new MockERC20("Wrapped Ether", "WETH", 18);
        DAI   = new MockERC20("Dai Stablecoin", "DAI", 18);
        WBTC  = new MockERC20("Wrapped BTC", "WBTC", 8);

        // Router + Factory (mocks)
        router = new MockUniswapV2Router02(address(WETH9));
        factory = new MockUniswapV2Factory(address(router));
        router.setFactory(address(factory));
        router.setUSDC(address(USDC));

        // Configurar rates de swap hacia USDC:
        // 1 DAI => 1.00 USDC
        router.setRate(address(DAI), 1e18);
        // 1 WBTC => 70_000 USDC (simulado)
        router.setRate(address(WBTC), 70_000e18);

        // Deploy del banco
        // constructor(address _router, address _factory, address _usdc, uint256 _bankCap)
        bank = new KipuBankV3(address(router), address(factory), address(USDC), BANK_CAP); // ⬅️ AJUSTAR si difiere en tu contrato

        // Fondos iniciales
        USDC.mint(alice, 10_000e6);
        DAI.mint(alice, 10_000e18);
        WBTC.mint(alice, 2e8); // 2 WBTC con 8 dec

        USDC.mint(bob, 5_000e6);

        vm.stopPrank();
    }

    // ========= Helpers =========
    function _approveAll(address user) internal {
        vm.startPrank(user);
        USDC.approve(address(bank), type(uint256).max);
        DAI.approve(address(bank), type(uint256).max);
        WBTC.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    // ========= Tests de Estado Inicial =========
    function test_InitialState() public {
        assertEq(address(bank.USDC()), address(USDC), "USDC addr"); // ⬅️ AJUSTAR getter si difiere
        assertEq(address(bank.router()), address(router), "router"); // ⬅️ AJUSTAR getter si difiere
        assertEq(address(bank.factory()), address(factory), "factory"); // ⬅️ AJUSTAR getter si difiere
        assertEq(bank.bankCap(), BANK_CAP, "cap"); // ⬅️ AJUSTAR getter si difiere
    }

    // ========= Depósitos directos en USDC =========
    function test_DepositUSDC_IncreasesUserAndTotalBalances_AndEmits() public {
        _approveAll(alice);
        uint256 amount = 1_234e6;

        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true);
        // event DepositUSDC(address indexed user, uint256 usdcAmount);
        emit DepositUSDC(alice, amount); // ⬅️ Si tu evento tiene otro nombre/case, ajusta el emit/expectEmit
        bank.depositUsdc(amount); // ⬅️ AJUSTAR si tu firma difiere
        vm.stopPrank();

        assertEq(bank.userUsdcBalance(alice), amount, "user bal"); // ⬅️ AJUSTAR getter si difiere
        assertEq(bank.totalUsdc(), amount, "total"); // ⬅️ AJUSTAR getter si difiere
        assertEq(USDC.balanceOf(address(bank)), amount, "bank hold");
        assertEq(USDC.balanceOf(alice), 10_000e6 - amount, "alice USDC");
    }

    function test_DepositUSDC_RevertsIfCapExceeded() public {
        _approveAll(alice);
        vm.startPrank(alice);
        bank.depositUsdc(BANK_CAP - 100e6);
        vm.expectRevert(); // ⬅️ Si usas error específico: vm.expectRevert(KipuBankV3.BankCapExceeded.selector);
        bank.depositUsdc(200e6);
        vm.stopPrank();
    }

    function test_DepositUSDC_RevertsWhenPaused() public {
        vm.prank(owner);
        bank.pause(); // ⬅️ AJUSTAR nombre si difiere
        _approveAll(alice);
        vm.prank(alice);
        vm.expectRevert(); // ⬅️ Si usas error Paused, coloca el selector
        bank.depositUsdc(1e6);
    }

    // ========= Depósitos con swap (ERC20 -> USDC) =========
    function test_DepositToken_SwapsToUSDC_1to1_DAI() public {
        _approveAll(alice);
        uint256 daiIn = 2_000e18; // 2000 DAI
        uint256 minUsdcOut = 1_900e6;

        vm.prank(alice);
        bank.depositToken(address(DAI), daiIn, minUsdcOut); // ⬅️ AJUSTAR firma si difiere

        // 1 DAI = 1 USDC según mock
        assertEq(bank.userUsdcBalance(alice), 2_000e6, "user bal");
        assertEq(bank.totalUsdc(), 2_000e6, "total");
        assertEq(USDC.balanceOf(address(bank)), 2_000e6, "bank USDC");
        assertEq(DAI.balanceOf(alice), 8_000e18, "alice DAI spent");
    }

    function test_DepositToken_SwapsToUSDC_WBTC_HighValue() public {
        _approveAll(alice);
        uint256 wbtcIn = 1e8; // 1 WBTC (8 dec)
        // 1 WBTC = 70_000 USDC
        uint256 minUsdcOut = 60_000e6;

        vm.prank(alice);
        bank.depositToken(address(WBTC), wbtcIn, minUsdcOut); // ⬅️ AJUSTAR firma si difiere

        assertEq(bank.userUsdcBalance(alice), 70_000e6, "user bal");
        assertEq(bank.totalUsdc(), 70_000e6, "total");
        assertEq(USDC.balanceOf(address(bank)), 70_000e6, "bank USDC");
        assertEq(WBTC.balanceOf(alice), 1e8, "alice WBTC unchanged?"); // en el mock, el router toma del usuario, el banco no; depende de tu implementación real.
    }

    function test_DepositToken_RevertsOnSlippage() public {
        _approveAll(alice);
        uint256 daiIn = 100e18;
        uint256 minUsdcOut = 200e6; // pedimos más de lo que el rate entrega

        vm.prank(alice);
        vm.expectRevert(); // ⬅️ ajusta a tu error (ej. SlippageTooHigh)
        bank.depositToken(address(DAI), daiIn, minUsdcOut);
    }

    // ========= Retiros =========
    function test_WithdrawUSDC_TransfersOut_AndEmits() public {
        _approveAll(alice);
        vm.prank(alice);
        bank.depositUsdc(5_000e6);

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        // event WithdrawUSDC(address indexed user, uint256 usdcAmount);
        emit WithdrawUSDC(alice, 1_500e6); // ⬅️ AJUSTAR nombre si difiere
        bank.withdrawUsdc(1_500e6); // ⬅️ AJUSTAR firma si difiere

        assertEq(bank.userUsdcBalance(alice), 3_500e6, "user bal");
        assertEq(bank.totalUsdc(), 3_500e6, "total");
        assertEq(USDC.balanceOf(alice), 10_000e6 - 5_000e6 + 1_500e6, "alice USDC");
    }

    function test_WithdrawUSDC_RevertsIfInsufficientBalance() public {
        _approveAll(alice);
        vm.prank(alice);
        bank.depositUsdc(500e6);

        vm.prank(alice);
        vm.expectRevert(); // ⬅️ error tipo InsufficientBalance
        bank.withdrawUsdc(800e6);
    }

    function test_WithdrawUSDC_RevertsWhenPaused() public {
        _approveAll(alice);
        vm.prank(alice);
        bank.depositUsdc(100e6);

        vm.prank(owner);
        bank.pause();

        vm.prank(alice);
        vm.expectRevert();
        bank.withdrawUsdc(50e6);
    }

    // ========= Ownable / Admin =========
    function test_OnlyOwnerCanPause_Unpause_AndUpdateParams() public {
        vm.prank(owner);
        bank.pause();

        vm.expectRevert("Ownable: caller is not the owner"); // ⬅️ si usas OZ Ownable
        vm.prank(alice);
        bank.unpause();

        vm.prank(owner);
        bank.unpause();

        // Si tienes setters como setBankCap / setRouter / setFactory, pruébalos:
        vm.prank(owner);
        bank.setBankCap(2_000_000e6); // ⬅️ AJUSTAR si existe
        assertEq(bank.bankCap(), 2_000_000e6);

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        bank.setBankCap(1);
    }

    // ========= Reentrancy (negativo) =========
    // Si tus funciones tienen nonReentrant, este test solo verifica que no reentramos;
    // para demo simple, intentamos una llamada recursiva ficticia usando un helper malicioso
    function test_NoReentrancy_OnDepositAndWithdraw() public {
        // Este es un placeholder: si más adelante agregas un atacante, úsalo aquí.
        _approveAll(alice);
        vm.prank(alice);
        bank.depositUsdc(100e6);

        // No hay reentrancia en mocks; verificamos que al menos el saldo final sea consistente
        uint256 before = bank.totalUsdc();
        vm.prank(alice);
        bank.withdrawUsdc(50e6);
        uint256 afterT = bank.totalUsdc();
        assertEq(before - afterT, 50e6);
    }

    // ========= Invariantes simples =========
    function test_Invariant_TotalEqualsSumBalances_AfterSeveralOps() public {
        _approveAll(alice);
        _approveAll(bob);

        vm.startPrank(alice);
        bank.depositUsdc(1_000e6);
        bank.depositToken(address(DAI), 2_000e18, 1_900e6);
        vm.stopPrank();

        vm.startPrank(bob);
        bank.depositUsdc(500e6);
        vm.stopPrank();

        vm.prank(alice);
        bank.withdrawUsdc(300e6);

        uint256 total = bank.totalUsdc();
        uint256 sumUsers = bank.userUsdcBalance(alice) + bank.userUsdcBalance(bob);
        assertEq(total, sumUsers, "total != sum(users)");
        assertEq(USDC.balanceOf(address(bank)), total, "bank hold != total");
    }

    // ========= Eventos con nombre en conflicto (heads-up) =========
    // Si en tu .sol hay un conflicto con `event depositUsdc` y `function depositUsdc`,
    // renombra el EVENTO a `DepositUSDC` (CamelCase) para evitar el error de “Identifier already declared”.
    // Este test (arriba) asume eventos CamelCase.
    event DepositUSDC(address indexed user, uint256 usdcAmount);
    event WithdrawUSDC(address indexed user, uint256 usdcAmount);
}
