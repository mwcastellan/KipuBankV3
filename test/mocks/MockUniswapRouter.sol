// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

contract MockUniswapRouter {
    address public immutable _factory;
    address public immutable _weth;

    uint256 public ethToUsdcRate = 1; // 1 wei ETH => 1 USDC
    uint256 public tokenToUsdcRate = 1; // 1 token => 1 USDC

    constructor(address factory_, address weth_) {
        _factory = factory_;
        _weth = weth_;
    }

    // Required by KipuBankV3
    function factory() external view returns (address) {
        return _factory;
    }

    function WETH() external view returns (address) {
        return _weth;
    }

    // Simulates: ETH -> USDC path [WETH, USDC]
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        require(path.length == 2, "bad path");
        require(path[0] == _weth, "path[0] must be WETH");

        uint256 amountOut = msg.value * ethToUsdcRate;
        require(amountOut >= amountOutMin, "slippage");

        // Mint USDC mock token
        MockERC20(path[1]).mint(to, amountOut);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = amountOut;
    }

    // Simulates: tokenIn -> USDC path [tokenIn, USDC]
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "bad path");

        uint256 amountOut = amountIn * tokenToUsdcRate;
        require(amountOut >= amountOutMin, "slippage");

        // Mint USDC mock token
        MockERC20(path[1]).mint(to, amountOut);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
