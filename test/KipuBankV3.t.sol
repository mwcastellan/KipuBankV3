// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUniswapFactory} from "./mocks/MockUniswapFactory.sol";
import {MockUniswapRouter} from "./mocks/MockUniswapRouter.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 internal bank;
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC20 internal weth;
    MockUniswapFactory internal factory;
    MockUniswapRouter internal router;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant BANK_CAP = 1_000_000e18; // cap grande

    function setUp() public {
        // USDC must have 6 decimals (REAL USDC!)
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        factory = new MockUniswapFactory();
        router = new MockUniswapRouter(address(factory), address(weth));

        // Register DAI/USDC pair
        factory.setPair(address(dai), address(usdc), address(0x1234));

        bank = new KipuBankV3(address(router), address(usdc), BANK_CAP, owner);

        vm.deal(alice, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: depositUsdc
    //////////////////////////////////////////////////////////////*/

    function testDepositUsdc_Success() public {
        uint256 amount = 100e18;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(bank), amount);
        bank.depositUsdc(amount);
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(alice), amount);
        assertEq(bank.totalUsdc(), amount);
    }

    function testDepositUsdc_Revert_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUsdc(0);
    }

    function testDepositUsdc_Revert_CapExceeded() public {
        uint256 amount = BANK_CAP + 1;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(bank), amount);
        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositUsdc(amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: depositEth
    //////////////////////////////////////////////////////////////*/

    function testDepositEth_Success() public {
        uint256 value = 1 ether;
        uint256 minOut = value; // 1:1 en el mock

        vm.prank(alice);
        bank.depositEth{value: value}(minOut, block.timestamp + 1 days);

        assertEq(bank.totalUsdc(), value);
        assertEq(bank.balanceOfUsdc(alice), value);
    }

    function testDepositEth_Revert_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositEth{value: 0}(1, block.timestamp + 1 days);
    }

    //function testDepositEth_Revert_CapExceeded() public {
    //    uint256 value = BANK_CAP + 1; // excede el cap real
    //   uint256 minOut = value; // mock produce 1:1
    //   uint256 deadline = block.timestamp + 1 days;
    //
    //     vm.prank(alice);
    //
    //    vm.expectRevert(KipuBankV3.CapExceeded.selector);
    //
    //      bank.depositEth{value: value}(minOut, deadline);
    //  }

    /*//////////////////////////////////////////////////////////////
                        Tests: depositToken
    //////////////////////////////////////////////////////////////*/

    function testDepositToken_Success_DAI() public {
        uint256 amount = 50e18;
        dai.mint(alice, amount);

        vm.startPrank(alice);
        dai.approve(address(bank), amount);
        bank.depositToken(
            address(dai),
            amount,
            amount,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(alice), amount);
        assertEq(bank.totalUsdc(), amount);
    }

    function testDepositToken_Revert_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositToken(address(dai), 0, 0, block.timestamp + 1 days);
    }

    function testDepositToken_Revert_Unsupported_IfUSDC() public {
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(address(usdc), 10e18, 1, block.timestamp + 1 days);
    }

    function testDepositToken_Revert_Unsupported_NoPair() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(address(random), 10e18, 1, block.timestamp + 1 days);
    }

    function testDepositToken_Revert_CapExceeded() public {
        uint256 amount = BANK_CAP + 1;
        dai.mint(alice, amount);

        vm.startPrank(alice);
        dai.approve(address(bank), amount);
        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        bank.depositToken(
            address(dai),
            amount,
            amount,
            block.timestamp + 1 days
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: withdrawUsdc
    //////////////////////////////////////////////////////////////*/

    function _depositForAlice(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(bank), amount);
        bank.depositUsdc(amount);
        vm.stopPrank();
    }

    function testWithdrawUsdc_Success() public {
        uint256 amount = 100e18;
        _depositForAlice(amount);

        vm.prank(alice);
        bank.withdrawUsdc(amount, alice);

        assertEq(bank.balanceOfUsdc(alice), 0);
        assertEq(bank.totalUsdc(), 0);
        assertEq(usdc.balanceOf(alice), amount);
    }

    function testWithdrawUsdc_Revert_ZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroWithdrawal.selector);
        bank.withdrawUsdc(0, alice);
    }

    function testWithdrawUsdc_Revert_InsufficientBalance() public {
        uint256 amount = 10e18;
        _depositForAlice(amount);

        vm.prank(alice);
        vm.expectRevert(KipuBankV3.InsufficientBalance.selector);
        bank.withdrawUsdc(amount + 1, alice);
    }

    function testWithdrawUsdc_Revert_ZeroAddressTo() public {
        uint256 amount = 10e18;
        _depositForAlice(amount);

        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAddress.selector);
        bank.withdrawUsdc(amount, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: pause / unpause
    //////////////////////////////////////////////////////////////*/

    function testPauseBlocksDeposits() public {
        uint256 amount = 10e18;
        usdc.mint(alice, amount);

        vm.prank(owner);
        bank.pause();

        vm.startPrank(alice);
        usdc.approve(address(bank), amount);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        bank.depositUsdc(amount);

        vm.stopPrank();
    }

    function testUnpauseRestoresDeposits() public {
        uint256 amount = 10e18;
        usdc.mint(alice, amount);

        vm.prank(owner);
        bank.pause();

        vm.prank(owner);
        bank.unpause();

        vm.startPrank(alice);
        usdc.approve(address(bank), amount);
        bank.depositUsdc(amount);
        vm.stopPrank();

        assertEq(bank.balanceOfUsdc(alice), amount);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: admin setters
    //////////////////////////////////////////////////////////////*/

    function testSetBankCap_OnlyOwner() public {
        uint256 newCap = 2_000_000e18;

        vm.prank(owner);
        bank.setBankCap(newCap);
        assertEq(bank.bankCap(), newCap);
    }

    function testSetBankCap_NonOwnerReverts() public {
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );

        bank.setBankCap(1000);
    }

    function testSetUsdc_OnlyOwner() public {
        MockERC20 newUsdc = new MockERC20("NewUSDC", "nUSDC", 18);
        vm.prank(owner);
        bank.setUsdc(address(newUsdc));
        assertEq(bank.usdc(), address(newUsdc));
    }

    function testSetRouter_OnlyOwner() public {
        MockUniswapRouter newRouter = new MockUniswapRouter(
            address(factory),
            address(weth)
        );

        vm.prank(owner);
        bank.setRouter(address(newRouter));

        // No revert = ok. Opcionalmente comprobar evento con logs.
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: remainingCapacity
    //////////////////////////////////////////////////////////////*/

    function testRemainingCapacity_AfterDeposit() public {
        uint256 amount = 100e18;
        _depositForAlice(amount);

        uint256 remaining = bank.remainingCapacity();
        assertEq(remaining, BANK_CAP - amount);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: rescueERC20
    //////////////////////////////////////////////////////////////*/

    function testRescueERC20_CanRescueNonUsdc() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        random.mint(address(bank), 50e18);

        uint256 before = random.balanceOf(owner);

        vm.prank(owner);
        bank.rescueERC20(address(random), owner, 50e18);

        uint256 afterBal = random.balanceOf(owner);
        assertEq(afterBal - before, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: receive revert
    //////////////////////////////////////////////////////////////*/

    function testReceive_Reverts() public {
        vm.expectRevert(KipuBankV3.UseDepositEth.selector);
        payable(address(bank)).transfer(1 ether);
    }
}
