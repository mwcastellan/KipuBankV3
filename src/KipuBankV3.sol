// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KipuBankV3 – DeFi-enabled smart contract bank with Uniswap V2 routing to USDC
/// @notice Accepts native ETH and any ERC20 with a direct USDC pair on Uniswap V2, swaps to USDC, and credits user balances.
/// @dev This version extends KipuBankV2 by integrating Uniswap V2 for token-to-USDC swaps, enforcing a global USDC-denominated cap, and maintaining non-custodial safety.
/// @author Marcelo Walter Castellan
/// @custom:date 2025-11-25
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
    error UseDepositEth();

    /*//////////////////////////////////////////////////////////////
                            Storage
    //////////////////////////////////////////////////////////////*/

    // SLOT 0 (20 + 20 bytes → 2 addresses en 1 slot)
    // NOTE: I_WETH is immutable and not stored in a regular storage slot.
    /// @notice Wrapped ETH (WETH) address used by Uniswap.
    address private immutable I_WETH;
    /// @notice Address of the USDC token used as the unit of account.
    address private sUsdc;

    // SLOT 1 (20 + 20 bytes → 2 addresses en 1 slot)
    /// @notice Uniswap V2 router instance used for swaps.
    IUniswapV2Router02 internal sRouter;
    /// @notice Uniswap V2 factory instance derived from the router.
    IUniswapV2Factory internal sFactory;

    // SLOT 2 (128 bits + 128 bits)
    /// @notice Total USDC currently held by the contract.
    uint128 private sTotalUsdc;
    /// @notice maximum cap of total USDC allowed under custody.
    uint128 private sBankCap;

    /// @notice Mapping of user addresses to their USDC-denominated balances.
    mapping(address => uint256) private sBalanceOfUsdc;

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
        sBankCap = uint128(_bankCap);
    }
    /*//////////////////////////////////////////////////////////////
                            Views
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks whether a given token has a direct USDC pair on Uniswap V2.
    /// @param _token Token address to check.
    ///@return isDirectPair True if a direct USDC pair exists.
    function hasDirectUsdcPair(
        address _token
    ) public view returns (bool isDirectPair) {
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

    /// @notice Returns the WETH address used by the bank for ETH → WETH conversions.
    /// @dev This value is immutable and set during contract deployment.
    /// @return weth The address of the WETH token.
    function WETH() external view returns (address weth) {
        return I_WETH;
    }

    /// @notice Returns the USDC token address used as the internal accounting unit.
    /// @dev All balances and the global cap are denominated in this token (6 decimals).
    /// @return usdcToken The address of the USDC contract.
    function usdc() external view returns (address usdcToken) {
        return sUsdc;
    }

    /// @notice Returns the total amount of USDC currently held in custody by the contract.
    /// @dev This value increases with deposits and decreases with withdrawals.
    /// @return total The total USDC balance tracked internally.
    function totalUsdc() external view returns (uint256 total) {
        return sTotalUsdc;
    }

    /// @notice Returns the global USDC-denominated limit for the bank.
    /// @dev Deposits revert once total USDC would exceed this cap.
    /// @return cap The maximum amount of USDC the bank is allowed to hold.
    function bankCap() external view returns (uint256 cap) {
        return sBankCap;
    }

    /// @notice Returns the USDC balance of a specific user.
    /// @param user The address whose internal USDC balance is being queried.
    /// @return balance The amount of USDC credited to the user.
    function balanceOfUsdc(
        address user
    ) external view returns (uint256 balance) {
        return sBalanceOfUsdc[user];
    }

    /// @notice Updates the Uniswap V2 router address.
    /// @dev Also updates the factory reference to match the new router.
    /// @param _router New router address.
    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        address _old = address(sRouter);

        IUniswapV2Router02 _newR = IUniswapV2Router02(_router);
        sRouter = _newR;
        sFactory = IUniswapV2Factory(_newR.factory());

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
        sBankCap = uint128(_cap);
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

        uint256 _newTotal = uint256(sTotalUsdc) + _amountUsdc;
        if (_newTotal > sBankCap) revert CapExceeded();

        IERC20(sUsdc).safeTransferFrom(msg.sender, address(this), _amountUsdc);
        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] + _amountUsdc;

        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = uint128(_newTotal);
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
        uint128 _sTotalUsdc = sTotalUsdc;
        uint128 _sBankCap = sBankCap;
        if (uint256(_sTotalUsdc) + _minUsdcOut > _sBankCap)
            revert CapExceeded();

        address _sUsdc = sUsdc;
        IERC20 _usdc = IERC20(_sUsdc);
        uint256 _beforeBal = _usdc.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = I_WETH;
        path[1] = _sUsdc;

        IUniswapV2Router02 _sRouter = sRouter;
        _sRouter.swapExactETHForTokens{value: msg.value}(
            _minUsdcOut,
            path,
            address(this),
            _deadline
        );

        uint256 _received = _usdc.balanceOf(address(this)) - _beforeBal;
        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] + _received;
        uint256 _newTotal = uint256(_sTotalUsdc) + _received;
        if (_newTotal > _sBankCap) revert CapExceeded();

        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = uint128(_newTotal);
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
        address _sUsdc = sUsdc;
        if (_tokenIn == _sUsdc) revert UnsupportedToken();
        if (_amountIn == 0) revert ZeroAmount();
        if (!hasDirectUsdcPair(_tokenIn)) revert UnsupportedToken();
        uint128 _sTotalUsdc = sTotalUsdc;
        uint256 _sBankCap = sBankCap;
        if (uint256(_sTotalUsdc) + _minUsdcOut > _sBankCap)
            revert CapExceeded();

        IERC20 _tmptokenIn = IERC20(_tokenIn);
        IERC20 _usdc = IERC20(_sUsdc);

        _tmptokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        IUniswapV2Router02 _sRouter = sRouter;
        _tmptokenIn.forceApprove(address(_sRouter), 0);
        _tmptokenIn.forceApprove(address(_sRouter), _amountIn);

        uint256 _beforeBal = _usdc.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _sUsdc;

        _sRouter.swapExactTokensForTokens(
            _amountIn,
            _minUsdcOut,
            path,
            address(this),
            _deadline
        );

        uint256 _received = _usdc.balanceOf(address(this)) - _beforeBal;
        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] + _received;
        /// uint256 _newTotal = uint256(_sTotalUsdc) + _received;

        if (_sTotalUsdc + _received > _sBankCap) revert CapExceeded();

        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = uint128(_sTotalUsdc + _received);
        }

        emit DepositSwapped(msg.sender, _tokenIn, _amountIn, _received);
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
        uint256 _newBalanceOfUsdc = sBalanceOfUsdc[msg.sender] - _amountUsdc;
        uint128 _newsTotalUsdc = sTotalUsdc - uint128(_amountUsdc);

        unchecked {
            sBalanceOfUsdc[msg.sender] = _newBalanceOfUsdc;
            sTotalUsdc = _newsTotalUsdc;
        }

        IERC20(sUsdc).safeTransfer(_to, _amountUsdc);

        emit WithdrawUsdc(msg.sender, _amountUsdc, _to);
    }

    /*//////////////////////////////////////////////////////////////
                                Receive
    //////////////////////////////////////////////////////////////*/

    /// @notice Rejects plain ETH transfers; users must use depositEth().
    /// @dev Prevents accidental ETH loss due to direct transfer.
    receive() external payable {
        revert UseDepositEth();
    }
}
