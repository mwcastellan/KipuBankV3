// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Factory.sol";
import "./mocks/MockUniswapV2Router02.sol";
import "./mocks/MockUniswapV2Pair.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;

    MockERC20 public USDC;
    MockERC20 public DAI;
    MockERC20 public WETH;

    MockUniswapV2Factory public factory;
    MockUniswapV2Router02 public router;
    MockUniswapV2Pair public daiUsdcPair;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 public constant BANK_CAP = 1_000_000e6; // 1M USDC (6 decimales)
    uint256 public constant ONE_USDC = 1e6;
    uint256 public constant ONE_DAI = 1e18;

    function setUp() public {
        // === 1) Deploy tokens ===
        USDC = new MockERC20("USD Coin", "USDC", 6);
        DAI = new MockERC20("Dai Stablecoin", "DAI", 18);
        WETH = new MockERC20("Wrapped Ether", "WETH", 18);

        // === 2) Deploy factory & router mocks ===
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router02(address(factory), address(WETH));

        // === 3) Crear par DAI/USDC y setear reservas 1:1 ===
        address pairAddr = factory.createPair(address(DAI), address(USDC));
        daiUsdcPair = MockUniswapV2Pair(pairAddr);

        // Reservas: 1,000,000 DAI y 1,000,000 USDC => precio 1:1
        daiUsdcPair.setReserves(
            uint112(1_000_000 * ONE_DAI),
            uint112(1_000_000 * ONE_USDC)
        );

        // === 4) Deploy del KipuBankV3 ===
        // ⚠️ Ajustar el constructor si difiere de tu contrato
        bank = new KipuBankV3(address(router), address(USDC), BANK_CAP, owner);

        // Fondos iniciales para usuarios
        DAI.mint(alice, 100_000 * ONE_DAI);
        USDC.mint(alice, 50_000 * ONE_USDC);
        WETH.mint(alice, 1_000 ether);
    }

    // ================================================================
    //                       TESTS DE ESTADO INICIAL
    // ================================================================

    function testInitialState() public {
        assertEq(bank.sBankCap(), BANK_CAP, "bank cap incorrecto");
        assertEq(bank.sTotalUsdc(), 0, "totalDeposits debe iniciar en 0");
        // Si tenés un getter de USDC, descomentá:
        // assertEq(address(bank.usdc()), address(USDC), "USDC incorrecto");
    }

    // ================================================================
    //                      DEPOSITOS DE USDC DIRECTO
    // ================================================================

    function testDepositUsdc_Success() public {
        vm.startPrank(alice);
        uint256 amount = 1_000 * ONE_USDC;

        USDC.approve(address(bank), amount);
        bank.depositUsdc(amount);

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(bal, amount, "balance interno no actualizado");

        assertEq(bank.sTotalUsdc(), amount, "totalDeposits incorrecto");
        vm.stopPrank();
    }

    function testDepositUsdc_Revert_ZeroAmount() public {
        vm.startPrank(alice);

        USDC.approve(address(bank), 0);
        vm.expectRevert(); // opcional: especificar selector si tenés custom error
        bank.depositUsdc(0);

        vm.stopPrank();
    }

    function testDepositUsdc_Revert_CapExceeded() public {
        vm.startPrank(alice);

        uint256 amount = BANK_CAP + 1;
        USDC.mint(alice, amount);
        USDC.approve(address(bank), amount);

        vm.expectRevert(); // ej: vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositUsdc(amount);

        vm.stopPrank();
    }

    // ================================================================
    //                  DEPOSITOS DE TOKEN → USDC (DAI)
    // ================================================================

    function _buildPath(
        address t0,
        address t1
    ) internal pure returns (address[] memory path) {
        address[] memory path = new address[](2);
        path[0] = t0;
        path[1] = t1;
    }

    function testDepositToken_Success_DAItoUSDC_1to1() public {
        vm.startPrank(alice);

        uint256 daiAmountIn = 1_000 * ONE_DAI;
        // Con reservas 1:1, esperamos 1_000 USDC
        address[] memory path = _buildPath(address(DAI), address(USDC));
        uint[] memory amountsOut = router.getAmountsOut(daiAmountIn, path);

        uint256 expectedUsdc = amountsOut[1];
        uint256 minUsdcOut = (expectedUsdc * 99) / 100; // allow 1% slippage

        DAI.approve(address(bank), daiAmountIn);
        bank.depositToken(
            address(DAI),
            daiAmountIn,
            minUsdcOut,
            block.timestamp + 1 days
        );

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(bal, expectedUsdc, "balance USDC no coincide con swap");

        assertEq(bank.sTotalUsdc(), expectedUsdc, "totalDeposits incorrecto");
        vm.stopPrank();
    }

    function testDepositToken_Revert_ZeroAmount() public {
        vm.startPrank(alice);

        DAI.approve(address(bank), 0);
        vm.expectRevert();
        bank.depositToken(address(DAI), 0, 0, block.timestamp + 1 days);

        vm.stopPrank();
    }

    function testDepositToken_Revert_Unsupported_NoPair() public {
        // Token random sin par
        MockERC20 RND = new MockERC20("Random", "RND", 18);
        RND.mint(alice, 1_000 * 1e18);

        vm.startPrank(alice);
        RND.approve(address(bank), 1_000 * 1e18);

        vm.expectRevert(); // ej: UnsupportedToken
        bank.depositToken(
            address(RND),
            1_000 * 1e18,
            0,
            block.timestamp + 1 days
        );

        vm.stopPrank();
    }

    function testDepositToken_Revert_CapExceeded_Precheck() public {
        vm.startPrank(alice);

        // Hacemos un depósito grande que cruza el cap
        uint256 daiAmountIn = 2_000_000 * ONE_DAI;
        DAI.mint(alice, daiAmountIn);
        DAI.approve(address(bank), daiAmountIn);

        address[] memory path = _buildPath(address(DAI), address(USDC));
        uint[] memory amountsOut = router.getAmountsOut(daiAmountIn, path);
        uint256 expectedUsdc = amountsOut[1];

        // expectedUsdc > BANK_CAP => debe revertir por cap
        uint256 minUsdcOut = (expectedUsdc * 99) / 100;

        vm.expectRevert(); // CapExceeded
        bank.depositToken(
            address(DAI),
            daiAmountIn,
            minUsdcOut,
            block.timestamp + 1 days
        );

        vm.stopPrank();
    }

    function testDepositToken_Revert_Slippage() public {
        vm.startPrank(alice);

        uint256 daiAmountIn = 1_000 * ONE_DAI;
        DAI.approve(address(bank), daiAmountIn);

        // Calculamos output esperado 1:1
        address[] memory path = _buildPath(address(DAI), address(USDC));
        uint[] memory amountsOut = router.getAmountsOut(daiAmountIn, path);
        uint256 expectedUsdc = amountsOut[1];

        // Forzamos minOut mayor al posible => debe revertir por slippage
        uint256 minUsdcOut = expectedUsdc + 1_000_000;

        vm.expectRevert(); // SlippageExceeded o revert string
        bank.depositToken(
            address(DAI),
            daiAmountIn,
            minUsdcOut,
            block.timestamp + 1 days
        );

        vm.stopPrank();
    }

    // ================================================================
    //                         DEPOSITO DE ETH
    // ================================================================
    // ⚠️ Para estos tests, tu KipuBankV3 debe usar WETH internamente
    // y la ruta WETH → USDC, con par creado en la factory.

    function _setupWethUsdcPair() internal {
        address pairAddr = factory.getPair(address(WETH), address(USDC));
        if (pairAddr == address(0)) {
            pairAddr = factory.createPair(address(WETH), address(USDC));
        }
        MockUniswapV2Pair wethUsdcPair = MockUniswapV2Pair(pairAddr);

        // Por simplicidad: 1 ETH = 2000 USDC
        wethUsdcPair.setReserves(
            uint112(1_000 * 1e18), // 1,000 WETH
            uint112(2_000_000 * ONE_USDC) // 2,000,000 USDC
        );
    }

    function testDepositEth_Success() public {
        _setupWethUsdcPair();

        vm.deal(alice, 10 ether);

        vm.startPrank(alice);

        uint256 ethAmount = 1 ether;

        // Ruta WETH → USDC para simular getAmountsOut
        address[] memory path = _buildPath(address(WETH), address(USDC));
        uint[] memory amountsOut = router.getAmountsOut(ethAmount, path);
        uint256 expectedUsdc = amountsOut[1];

        uint256 minUsdcOut = (expectedUsdc * 99) / 100;

        bank.depositEth{value: ethAmount}(minUsdcOut, block.timestamp + 1 days);

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(bal, expectedUsdc, "USDC recibido no coincide con swap");

        vm.stopPrank();
    }

    function testDepositEth_Revert_ZeroAmount() public {
        vm.deal(alice, 0);
        vm.startPrank(alice);

        vm.expectRevert();
        bank.depositEth{value: 0}(0, block.timestamp + 1 days);

        vm.stopPrank();
    }

    function testDepositEth_Revert_CapExceeded() public {
        _setupWethUsdcPair();

        vm.deal(alice, 1_000 ether);
        vm.startPrank(alice);

        uint256 ethAmount = 1_000 ether; // Suficiente para superar BANK_CAP
        address[] memory path = _buildPath(address(WETH), address(USDC));
        uint[] memory amountsOut = router.getAmountsOut(ethAmount, path);
        uint256 expectedUsdc = amountsOut[1];
        uint256 minUsdcOut = (expectedUsdc * 99) / 100;

        vm.expectRevert();
        bank.depositEth{value: ethAmount}(minUsdcOut, block.timestamp + 1 days);

        vm.stopPrank();
    }

    // ================================================================
    //                         WITHDRAW USDC
    // ================================================================

    function testWithdrawUsdc_Success() public {
        vm.startPrank(alice);

        // Primero depositamos USDC
        uint256 amount = 1_000 * ONE_USDC;
        USDC.approve(address(bank), amount);
        bank.depositUsdc(amount);

        // Ahora retiramos la mitad
        uint256 withdrawAmount = 500 * ONE_USDC;
        bank.withdrawUsdc(withdrawAmount, alice);

        uint256 bal = bank.sBalanceOfUsdc(alice);
        assertEq(
            bal,
            amount - withdrawAmount,
            "balance interno no se actualizo"
        );

        // El usuario recibe USDC
        assertEq(
            USDC.balanceOf(alice),
            withdrawAmount,
            "alice no recibio USDC"
        );

        vm.stopPrank();
    }

    function testWithdrawUsdc_Revert_InsufficientBalance() public {
        vm.startPrank(alice);

        uint256 withdrawAmount = 1_000 * ONE_USDC;

        vm.expectRevert();
        bank.withdrawUsdc(withdrawAmount, alice);

        vm.stopPrank();
    }
}
