// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KipuBankV3 – DeFi-enabled smart contract bank with Uniswap V2 routing to USDC
/// @notice Accepts native ETH and any ERC20 with a direct USDC pair on Uniswap V2, swaps to USDC, and credits user balances.
/// @dev This version extends KipuBankV2 by integrating Uniswap V2 for token-to-USDC swaps, enforcing a global USDC-denominated cap, and maintaining non-custodial safety.
/// @author Marcelo Walter Castellan
/// @custom:date 2025-11-07

/*
    Summary
	    Users can deposit: ETH, USDC, or any ERC20 with a direct USDC pair
	    Non-USDC deposits are swapped to USDC via Uniswap V2 router
	    Balances are kept internally in USDC units (token amounts, 6 decimals)
	    A global `bankCap` (in USDC) limits the total USDC under custody
	
    Owner retains admin controls and can pause operations
	    Reentrancy protection and SafeERC20 are used for safety
	
    Key Design Choices
	    Users pass minUsdcOut and deadline to protect against MEV/slippage
	    For cap enforcement, we pre-check with minUsdcOut and assert after swap
	    We require a direct USDC pair when swapping tokens (token ↔ USDC)
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IUniswapV2Router02
} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {
    IUniswapV2Factory
} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

/// @dev Main DeFi banking contract allowing deposits in ETH or ERC20 tokens swapped to USDC via Uniswap V2.
contract KipuBankV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the bank cap is updated.
    /// @param oldCap Previous USDC cap.
    /// @param newCap New USDC cap value.
    event BankCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the Uniswap router address is updated.
    /// @param oldRouter Previous router address.
    /// @param newRouter New router address.
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    /// @notice Emitted when the USDC token address is updated.
    /// @param oldUsdc Previous USDC token address.
    /// @param newUsdc New USDC token address.
    event USDCUpdated(address indexed oldUsdc, address indexed newUsdc);

    /// @notice Emitted after a successful direct USDC deposit.
    /// @param user The user making the deposit.
    /// @param usdcAmount The amount of USDC deposited.
    event DepositUsdc(address indexed user, uint256 usdcAmount);

    /// @notice Emitted after a deposit of ETH or ERC20 swapped to USDC.
    /// @param user Depositor address.
    /// @param tokenIn Input token address (zero address for ETH).
    /// @param amountIn Input amount sent by the user.
    /// @param usdcReceived Actual USDC received after swap.
    event DepositSwapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );

    /// @notice Emitted when a user withdraws USDC.
    /// @param user The user initiating the withdrawal.
    /// @param usdcAmount Amount withdrawn in USDC units.
    /// @param to Recipient address.
    event WithdrawUsdc(
        address indexed user,
        uint256 usdcAmount,
        address indexed to
    );

    /*//////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when an address parameter is zero.
    error ZeroAddress();

    /// @dev Thrown when an amount parameter is zero.
    error ZeroAmount();

    /// @dev Thrown when a token does not have a direct USDC pair or is unsupported.
    error UnsupportedToken();

    /// @dev Thrown when deposit exceeds the global bank cap.
    error CapExceeded();

    /// @dev Thrown when user balance is insufficient for withdrawal.
    error InsufficientBalance();

    /// @dev Thrown when ETH is sent directly instead of via depositEth().
    error UsedepositEth();

    /*//////////////////////////////////////////////////////////////
                                Storage
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V2 router instance used for swaps.
    IUniswapV2Router02 public router;

    /// @notice Uniswap V2 factory instance derived from the router.
    IUniswapV2Factory public factory;

    /// @notice Wrapped ETH (WETH) address used by Uniswap.
    address public immutable WETH;

    /// @notice Address of the USDC token used as the unit of account.
    address public usdc;

    /// @notice Mapping of user addresses to their USDC-denominated balances.
    mapping(address => uint256) public balanceOfUsdc;

    /// @notice Total USDC currently held by the contract.
    uint256 public totalUsdc;

    /// @notice Global maximum cap of total USDC allowed under custody.
    uint256 public bankCap;

    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    /// @param _router Address of the Uniswap V2 router.
    /// @param _usdc Address of the USDC token contract.
    /// @param _bankCap Global USDC cap limit for the bank.
    /// @param _owner Owner address for administrative functions.
    constructor(
        address _router,
        address _usdc,
        uint256 _bankCap,
        address _owner
    ) {
        if (
            _router == address(0) || _usdc == address(0) || _owner == address(0)
        ) revert ZeroAddress();
        _transferOwnership(_owner);
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(router.factory());
        WETH = router.WETH();
        usdc = _usdc;
        bankCap = _bankCap;
    }

    /*//////////////////////////////////////////////////////////////
                            View Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks whether a given token has a direct USDC pair on Uniswap V2.
    /// @param token Token address to check.
    /// @return bool True if a direct USDC pair exists.
    function hasDirectUsdcPair(address token) public view returns (bool) {
        return factory.getPair(token, usdc) != address(0);
    }

    /// @notice Returns remaining USDC capacity until reaching the global cap.
    /// @return uint256 Remaining capacity in USDC units.
    function remainingCapacity() external view returns (uint256) {
        if (totalUsdc >= bankCap) return 0;
        return bankCap - totalUsdc;
    }

    /*//////////////////////////////////////////////////////////////
                            Admin Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the Uniswap V2 router address.
    /// @dev Also updates the factory reference to match the new router.
    /// @param _router New router address.
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        address old = address(router);
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(router.factory());
        emit RouterUpdated(old, _router);
    }

    /// @notice Updates the USDC token contract address.
    /// @param _usdc New USDC token address.
    function setUsdc(address _usdc) external onlyOwner {
        if (_usdc == address(0)) revert ZeroAddress();
        address old = usdc;
        usdc = _usdc;
        emit USDCUpdated(old, _usdc);
    }

    /// @notice Updates the global USDC bank cap.
    /// @param _cap New bank cap in USDC units.
    function setBankCap(uint256 _cap) external onlyOwner {
        uint256 old = bankCap;
        bankCap = _cap;
        emit BankCapUpdated(old, _cap);
    }

    /// @notice Pauses all deposits and withdrawals.
    /// @dev Only callable by owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses all deposits and withdrawals.
    /// @dev Only callable by owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allows owner to recover any ERC20 mistakenly sent to the contract.
    /// @dev Does not affect user USDC balances.
    /// @param token Token address to recover.
    /// @param to Recipient address.
    /// @param amount Amount to transfer.
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            Deposit Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits USDC directly into the bank.
    /// @param amountUsdc Amount of USDC to deposit.
    /// @custom:security Non-reentrant, requires approval.
    function depositUsdc(
        uint256 amountUsdc
    ) external whenNotPaused nonReentrant {
        if (amountUsdc == 0) revert ZeroAmount();
        if (totalUsdc + amountUsdc > bankCap) revert CapExceeded();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amountUsdc);
        unchecked {
            balanceOfUsdc[msg.sender] += amountUsdc;
            totalUsdc += amountUsdc;
        }

        emit DepositUsdc(msg.sender, amountUsdc);
    }

    /// @notice Deposits native ETH which is swapped for USDC via Uniswap V2.
    /// @param minUsdcOut Minimum acceptable USDC output (slippage protection).
    /// @param deadline Unix timestamp after which the swap is invalid.
    /// @custom:security Non-reentrant, uses msg.value.
    function depositEth(
        uint256 minUsdcOut,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (totalUsdc + minUsdcOut > bankCap) revert CapExceeded();

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = usdc;

        router.swapExactETHForTokens{value: msg.value}(
            minUsdcOut,
            path,
            address(this),
            deadline
        );

        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        uint256 received = usdcAfter - usdcBefore;
        // Final cap assertion with the actual output
        if (totalUsdc + received > bankCap) revert CapExceeded();
        unchecked {
            balanceOfUsdc[msg.sender] += received;
            totalUsdc += received;
        }

        emit DepositSwapped(msg.sender, address(0), msg.value, received);
    }

    /// @notice Deposits an ERC20 token which is swapped for USDC via Uniswap V2.
    /// @param tokenIn ERC20 token to deposit.
    /// @param amountIn Amount of token to deposit.
    /// @param minUsdcOut Minimum acceptable USDC received.
    /// @param deadline Unix timestamp after which the swap expires.
    /// @custom:security Non-reentrant, requires approval.
    function depositToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdcOut,
        uint256 deadline
    ) external whenNotPaused nonReentrant {
        if (tokenIn == address(0)) revert ZeroAddress();
        if (tokenIn == usdc) revert UnsupportedToken(); // use depositUsdc
        if (amountIn == 0) revert ZeroAmount();
        if (!hasDirectUsdcPair(tokenIn)) revert UnsupportedToken();
        if (totalUsdc + minUsdcOut > bankCap) revert CapExceeded();

        // Pull tokens in first
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // Approve router (reset to 0 first to satisfy some ERC20s)
        IERC20(tokenIn).forceApprove(address(router), 0);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = usdc;

        router.swapExactTokensForTokens(
            amountIn,
            minUsdcOut,
            path,
            address(this),
            deadline
        );

        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        uint256 received = usdcAfter - usdcBefore;
        if (totalUsdc + received > bankCap) revert CapExceeded();
        unchecked {
            balanceOfUsdc[msg.sender] += received;
            totalUsdc += received;
        }

        emit DepositSwapped(msg.sender, tokenIn, amountIn, received);
    }

    /*//////////////////////////////////////////////////////////////
                            Withdraw Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraws USDC to the specified address.
    /// @param amountUsdc Amount of USDC to withdraw.
    /// @param to Recipient address.
    /// @custom:security Non-reentrant.
    function withdrawUsdc(
        uint256 amountUsdc,
        address to
    ) external whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amountUsdc == 0) revert ZeroAmount();
        uint256 bal = balanceOfUsdc[msg.sender];
        if (bal < amountUsdc) revert InsufficientBalance();
        unchecked {
            balanceOfUsdc[msg.sender] = bal - amountUsdc;
            totalUsdc -= amountUsdc;
        }

        IERC20(usdc).safeTransfer(to, amountUsdc);
        emit WithdrawUsdc(msg.sender, amountUsdc, to);
    }

    /*//////////////////////////////////////////////////////////////
                                Receive
    //////////////////////////////////////////////////////////////*/

    /// @notice Rejects plain ETH transfers; users must use depositEth().
    /// @dev Prevents accidental ETH loss due to direct transfer.
    receive() external payable {
        revert UsedepositEth();
    }
}
