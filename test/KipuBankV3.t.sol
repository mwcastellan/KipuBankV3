// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockRouter.sol";
import "./mocks/MockFactory.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 bank;
    MockERC20 usdc;
    MockERC20 dai;
    MockRouter router;
    MockFactory factory;

    address owner = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xCAFE);

    uint128 constant BANK_CAP = 1_000_000e6; // 1M USDC

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);

        router = new MockRouter(address(usdc));
        factory = new MockFactory(address(dai), address(usdc));

        // conectamos router con factory
        router.setFactory(address(factory));

        bank = new KipuBankV3(address(router), address(usdc), BANK_CAP, owner);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC STATE
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public {
        assertEq(bank.sUsdc(), address(usdc));
        assertEq(bank.sTotalUsdc(), 0);
        assertEq(bank.sBankCap(), BANK_CAP);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT USDC
    //////////////////////////////////////////////////////////////*/

    function testDepositUsdc_Success() public {
        vm.prank(alice);
        usdc.mint(alice, 500e6);
        vm.prank(alice);
        usdc.approve(address(bank), 500e6);

        vm.prank(alice);
        bank.depositUsdc(500e6);

        assertEq(bank.sBalanceOfUsdc(alice), 500e6);
        assertEq(bank.sTotalUsdc(), 500e6);
    }

    function testDepositUsdc_RevertZero() public {
        vm.prank(alice);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUsdc(0);
    }

    function testDepositUsdc_RevertCapExceeded() public {
        vm.prank(owner);
        bank.setBankCap(100e6); // cap chico para testar

        vm.prank(alice);
        usdc.mint(alice, 200e6);
        vm.prank(alice);
        usdc.approve(address(bank), 200e6);

        vm.expectRevert(KipuBankV3.CapExceeded.selector);
        vm.prank(alice);
        bank.depositUsdc(200e6);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW USDC
    //////////////////////////////////////////////////////////////*/

    function testWithdrawUsdc_Success() public {
        vm.startPrank(alice);
        usdc.mint(alice, 100e6);
        usdc.approve(address(bank), 100e6);
        bank.depositUsdc(100e6);

        bank.withdrawUsdc(100e6, alice);

        assertEq(bank.sBalanceOfUsdc(alice), 0);
        assertEq(bank.sTotalUsdc(), 0);
        assertEq(usdc.balanceOf(alice), 100e6);
    }

    function testWithdrawUsdc_RevertZero() public {
        vm.expectRevert(KipuBankV3.ZeroWithdrawal.selector);
        vm.prank(alice);
        bank.withdrawUsdc(0, alice);
    }

    function testWithdrawUsdc_RevertInsufficient() public {
        vm.expectRevert(KipuBankV3.InsufficientBalance.selector);
        vm.prank(alice);
        bank.withdrawUsdc(10e6, alice);
    }

    function testWithdrawUsdc_RevertZeroAddress() public {
        vm.startPrank(alice);
        usdc.mint(alice, 50e6);
        usdc.approve(address(bank), 50e6);
        bank.depositUsdc(50e6);

        vm.expectRevert(KipuBankV3.ZeroAddress.selector);
        bank.withdrawUsdc(50e6, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    function testPauseDeposits() public {
        vm.prank(owner);
        bank.pause();

        vm.expectRevert("Pausable: paused");
        vm.prank(alice);
        bank.depositUsdc(10);
    }

    function testUnpause() public {
        vm.prank(owner);
        bank.pause();

        vm.prank(owner);
        bank.unpause();

        vm.prank(alice);
        usdc.mint(alice, 10e6);
        usdc.approve(address(bank), 10e6);
        bank.depositUsdc(10e6);

        assertEq(bank.sBalanceOfUsdc(alice), 10e6);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function testSetRouter() public {
        vm.prank(owner);
        bank.setRouter(address(0x123));

        assertEq(address(bank.sRouter()), address(0x123));
    }

    function testSetUsdc() public {
        address usdc2 = address(new MockERC20("NEWUSDC", "NUSDC", 6));

        vm.prank(owner);
        bank.setUsdc(usdc2);

        assertEq(bank.sUsdc(), usdc2);
    }

    function testSetBankCap() public {
        vm.prank(owner);
        bank.setBankCap(500e6);

        assertEq(bank.sBankCap(), 500e6);
    }

    function testRescueERC20() public {
        MockERC20 tokenX = new MockERC20("X", "X", 18);
        tokenX.mint(address(bank), 1000);

        vm.prank(owner);
        bank.rescueERC20(address(tokenX), owner, 1000);

        assertEq(tokenX.balanceOf(owner), 1000);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE → REVERT DIRECT ETH
    //////////////////////////////////////////////////////////////*/

    function testReceive_Revert() public {
        vm.expectRevert(KipuBankV3.UsedepositEth.selector);
        (bool ok, ) = address(bank).call{value: 1 ether}("");
        ok;
    }
}
