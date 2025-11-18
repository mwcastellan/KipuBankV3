// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockUniswapV2Factory.sol";
import "./MockUniswapV2Pair.sol";
import "./MockERC20.sol";

contract MockUniswapV2Router02 {
    MockUniswapV2Factory public immutable factory;
    address public immutable WETH;

    constructor(address _factory, address _weth) {
        factory = MockUniswapV2Factory(_factory);
        WETH = _weth;
    }

    function getAmountsOut(uint amountIn, address[] calldata path)
        public
        view
        returns (uint[] memory amounts)
    {
        require(path.length >= 2);

        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        for (uint i = 0; i < path.length - 1; i++) {
            address tokenIn = path[i];
            address tokenOut = path[i+1];

            address pair = factory.getPair(tokenIn, tokenOut);
            require(pair != address(0), "PAIR_NOT_FOUND");

            (uint112 r0, uint112 r1,) = MockUniswapV2Pair(pair).getReserves();

            if (tokenIn < tokenOut) {
                amounts[i+1] = (amounts[i] * r1) / r0;
            } else {
                amounts[i+1] = (amounts[i] * r0) / r1;
            }
        }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint minOut,
        address[] calldata path,
        address to,
        uint
    ) external returns (uint[] memory amounts)
    {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[path.length - 1] >= minOut, "INSUFFICIENT_OUTPUT");

        // Mint directly to simulate delivery
        MockERC20(path[path.length - 1]).mint(to, amounts[path.length - 1]);
    }
}
