// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KipuBankV3 – DeFi-enabled smart contract bank with Uniswap V2 routing to USDC
/// @notice Accepts native ETH and any ERC20 with a direct USDC pair on Uniswap V2, swaps to USDC, and credits user balances.
/// @dev This version extends KipuBankV2 by integrating Uniswap V2 for token-to-USDC swaps, enforcing a global USDC-denominated cap, and maintaining non-custodial safety.
/// @author Marcelo Walter Castellan
/// @custom:date 2025-11-18

/*
    Summary
	    Users can deposit: ETH, USDC, or any ERC20 with a direct USDC pair
	    Non-USDC deposits are swapped to USDC via Uniswap V2 router
	    Balances are kept internally in USDC units (token amounts, 6 decimals)
	    A global `sBankCap` (in USDC) limits the total USDC under custody
	
    Owner retains admin controls and can pause operations
	    Reentrancy protection and SafeERC20 are used for safety
	
    Key Design Choices
	    Users pass minUsdcOut and deadline to protect against MEV/slippage
	    For cap enforcement, we pre-check with minUsdcOut and assert after swap
	    We require a direct USDC pair when swapping tokens (token ↔ USDC)
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

    /// @dev Thrown when a withdrawal amount is zero.
    error ZeroWithdrawal();

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
    IUniswapV2Router02 public sRouter;

    /// @notice Uniswap V2 factory instance derived from the router.
    IUniswapV2Factory public sFactory;

    /// @notice Wrapped ETH (WETH) address used by Uniswap.
    address public immutable I_WETH;

    /// @notice Address of the USDC token used as the unit of account.
    address public sUsdc;

    /// @notice Mapping of user addresses to their USDC-denominated balances.
    mapping(address => uint256) public sBalanceOfUsdc;

    /// @notice Total USDC currently held by the contract.
    uint256 public sTotalUsdc;

    /// @notice maximum cap of total USDC allowed under custody.
    uint256 public sBankCap;

    /*//////////////////////////////////////////////////////////////
                                Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Ensures withdrawal amount is non-zero.
    modifier nonZeroWithdrawal(uint256 amount) {
        if (amount == 0) revert ZeroWithdrawal();
        _;
    }

    /// @dev Ensures the user has sufficient USDC balance for a withdrawal.
    modifier onlySufficientBalance(address user, uint256 amount) {
        if (sBalanceOfUsdc[user] < amount) revert InsufficientBalance();
        _;
    }

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
    ) Ownable(_owner) {
        if (
            _router == address(0) || _usdc == address(0) || _owner == address(0)
        ) revert ZeroAddress();
        IUniswapV2Router02 _routerInstance = IUniswapV2Router02(_router);
        sRouter = _routerInstance;
        sFactory = IUniswapV2Factory(_routerInstance.factory());
        I_WETH = _routerInstance.WETH();
        sUsdc = _usdc;
        sBankCap = _bankCap;
    }

    /*//////////////////////////////////////////////////////////////
                            View Helpers
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks whether a given token has a direct USDC pair on Uniswap V2.
    /// @param _token Token address to check.
    /// @return bool True if a direct USDC pair exists.
    function hasDirectUsdcPair(address _token) public view returns (bool) {
        return sFactory.getPair(_token, sUsdc) != address(0);
    }

    /// @notice Returns remaining USDC capacity until reaching the global cap.
    /// @return uint256 Remaining capacity in USDC units.
    function remainingCapacity() external view returns (uint256) {
        uint256 _totalUsdc = sTotalUsdc;
        uint256 _bankCap = sBankCap;
        if (_totalUsdc >= _bankCap) return 0;
        return _bankCap - _totalUsdc;
    }

    /*//////////////////////////////////////////////////////////////
                            Admin Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates the Uniswap V2 router address.
    /// @dev Also updates the factory reference to match the new router.
    /// @param _router New router address.
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        address _old = address(sRouter);
        IUniswapV2Router02 _newRouter = IUniswapV2Router02(_router);
        sRouter = _newRouter;
        sFactory = IUniswapV2Factory(_newRouter.factory());
        emit RouterUpdated(_old, _router);
    }

    /// @notice Updates the USDC token contract address.
    /// @param _usdc New USDC token address.
    function setUsdc(address _usdc) external onlyOwner {
        if (_usdc == address(0)) revert ZeroAddress();
        address _old = sUsdc;
        sUsdc = _usdc;
        emit USDCUpdated(_old, _usdc);
    }

    /// @notice Updates the global USDC bank cap.
    /// @param _cap New bank cap in USDC units.
    function setBankCap(uint256 _cap) external onlyOwner {
        uint256 _old = sBankCap;
        sBankCap = _cap;
        emit BankCapUpdated(_old, _cap);
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
    /// @param _token Token address to recover.
    /// @param _to Recipient address.
    /// @param _amount Amount to transfer.
    function rescueERC20(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        if (_token == address(0) || _to == address(0)) revert ZeroAddress();
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            Deposit Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits USDC directly into the bank.
    /// @param _amountUsdc Amount of USDC to deposit.
    /// @custom:security Non-reentrant, requires approval.
    function depositUsdc(
        uint256 _amountUsdc
    ) external whenNotPaused nonReentrant {
        if (_amountUsdc == 0) revert ZeroAmount();

        uint256 _totalUsdc = sTotalUsdc;
        uint256 _bankCap = sBankCap;
        uint256 _newTotal = _totalUsdc + _amountUsdc;
        if (_newTotal > _bankCap) revert CapExceeded();

        address _usdc = sUsdc;
        IERC20(_usdc).safeTransferFrom(msg.sender, address(this), _amountUsdc);

        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] + _amountUsdc;
        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = _newTotal;
        }

        emit DepositUsdc(msg.sender, _amountUsdc);
    }

    /// @notice Deposits native ETH which is swapped for USDC via Uniswap V2.
    /// @param _minUsdcOut Minimum acceptable USDC output (slippage protection).
    /// @param _deadline Unix timestamp after which the swap is invalid.
    /// @custom:security Non-reentrant, uses msg.value.
    function depositEth(
        uint256 _minUsdcOut,
        uint256 _deadline
    ) external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        uint256 _totalUsdc = sTotalUsdc;
        uint256 _bankCap = sBankCap;
        if (_totalUsdc + _minUsdcOut > _bankCap) revert CapExceeded();

        address _usdc = sUsdc;
        address _weth = I_WETH;

        uint256 _usdcBefore = IERC20(_usdc).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = _weth;
        path[1] = _usdc;

        IUniswapV2Router02 _router = sRouter;
        _router.swapExactETHForTokens{value: msg.value}(
            _minUsdcOut,
            path,
            address(this),
            _deadline
        );

        uint256 _usdcAfter = IERC20(_usdc).balanceOf(address(this));
        uint256 _received = _usdcAfter - _usdcBefore;

        uint256 _newTotal = _totalUsdc + _received;
        // Final cap assertion with the actual output
        if (_newTotal > _bankCap) revert CapExceeded();

        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] + _received;
        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = _newTotal;
        }

        emit DepositSwapped(msg.sender, address(0), msg.value, _received);
    }

    /// @notice Deposits an ERC20 token which is swapped for USDC via Uniswap V2.
    /// @param _tokenIn ERC20 token to deposit.
    /// @param _amountIn Amount of token to deposit.
    /// @param _minUsdcOut Minimum acceptable USDC received.
    /// @param _deadline Unix timestamp after which the swap expires.
    /// @custom:security Non-reentrant, requires approval.
    function depositToken(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _minUsdcOut,
        uint256 _deadline
    ) external whenNotPaused nonReentrant {
        if (_tokenIn == address(0)) revert ZeroAddress();
        address _usdc = sUsdc;
        if (_tokenIn == _usdc) revert UnsupportedToken(); // use depositUsdc
        if (_amountIn == 0) revert ZeroAmount();
        if (!hasDirectUsdcPair(_tokenIn)) revert UnsupportedToken();
        uint256 _totalUsdc = sTotalUsdc;
        uint256 _bankCap = sBankCap;
        uint256 _newTotalm = _totalUsdc + _minUsdcOut;
        if (_newTotalm > _bankCap) revert CapExceeded();

        // Pull tokens in first
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        // Approve router (reset to 0 first to satisfy some ERC20s)
        IUniswapV2Router02 _router = sRouter;
        IERC20(_tokenIn).forceApprove(address(_router), 0);
        IERC20(_tokenIn).forceApprove(address(_router), _amountIn);

        uint256 _usdcBefore = IERC20(_usdc).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _usdc;

        _router.swapExactTokensForTokens(
            _amountIn,
            _minUsdcOut,
            path,
            address(this),
            _deadline
        );

        uint256 _usdcAfter = IERC20(_usdc).balanceOf(address(this));
        uint256 _balanceOfUsdc = sBalanceOfUsdc[msg.sender] +
            _usdcAfter -
            _usdcBefore;

        uint256 _newTotal = _totalUsdc + _usdcAfter - _usdcBefore;
        if (_newTotal > _bankCap) revert CapExceeded();
        unchecked {
            sBalanceOfUsdc[msg.sender] = _balanceOfUsdc;
            sTotalUsdc = _newTotal;
        }

        // emit DepositSwapped(msg.sender, tokenIn, amountIn, received);
        emit DepositSwapped(msg.sender, _tokenIn, _amountIn, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            Withdraw Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraws USDC to the specified address.
    /// @param _amountUsdc Amount of USDC to withdraw.
    /// @param _to Recipient address.
    /// @custom:security Non-reentrant.
    function withdrawUsdc(
        uint256 _amountUsdc,
        address _to
    )
        external
        whenNotPaused
        nonReentrant
        nonZeroWithdrawal(_amountUsdc)
        onlySufficientBalance(msg.sender, _amountUsdc)
    {
        if (_to == address(0)) revert ZeroAddress();

        uint256 _totalUsdc = sTotalUsdc;
        uint256 _newTotal = _totalUsdc - _amountUsdc;

        uint256 _bal = sBalanceOfUsdc[msg.sender];
        unchecked {
            sBalanceOfUsdc[msg.sender] = _bal - _amountUsdc;
            sTotalUsdc = _newTotal;
        }

        address _usdc = sUsdc;
        IERC20(_usdc).safeTransfer(_to, _amountUsdc);

        emit WithdrawUsdc(msg.sender, _amountUsdc, _to);
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
