// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockUniswapV2Router02 {
    uint256 public rate; // rate = cuántos USDC devuelve 1 unidad del token

    constructor(uint256 _rate) {
        rate = _rate;
    }

    // Simula getAmountsOut
    function getAmountsOut(
        uint amountIn,
        address[] memory path
    ) external view returns (uint[] memory amounts) {
        require(path.length >= 2, "invalid-path");

        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        uint256 out = amountIn * rate;
        amounts[path.length - 1] = out;
    }

    // Simula swapExactTokensForTokens
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path       
    ) external view returns (uint[] memory amounts) {
        require(path.length >= 2, "invalid-path");

        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        uint out = amountIn * rate;

        require(out >= amountOutMin, "slippage");

        amounts[path.length - 1] = out;
    }
}
