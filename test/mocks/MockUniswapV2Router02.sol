// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

interface ILikeFactory {
    function setPair(address tokenA, address tokenB, address pair) external;
}

contract MockUniswapV2Router02 {
    address public immutable WETH;
    address public factory;

    // rate[tokenIn] = USDC out per 1 tokenIn (con 1e18 como base independiente de decimals del tokenIn)
    mapping(address => uint256) public tokenToUsdcRate1e18;
    address public USDC;

    constructor(address _weth) {
        WETH = _weth;
    }

    function setFactory(address _factory) external {
        factory = _factory;
    }

    function setUSDC(address _usdc) external {
        USDC = _usdc;
    }

    function setRate(address tokenIn, uint256 usdcPerToken1e18) external {
        tokenToUsdcRate1e18[tokenIn] = usdcPerToken1e18;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; i++) {
            // Simulamos solo hop final a USDC con rate fijo
            if (path[i] == USDC) {
                uint256 rate = tokenToUsdcRate1e18[path[i-1]];
                // asumimos 18 dec en cálculo intermedio; el test ajusta montos acorde
                amounts[i] = (amounts[i-1] * rate) / 1e18;
            } else {
                // Passthrough si no es USDC (no usado en estos tests)
                amounts[i] = amounts[i-1];
            }
        }
    }

    // Simplificación: solo soportamos swapExactTokensForTokens hacia USDC en 2 hops: tokenIn -> USDC
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        require(path.length >= 2, "path");
        require(path[path.length - 1] == USDC, "dst!=USDC");

        // transferFrom tokenIn
        MockERC20 tokenIn = MockERC20(path[0]);
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn), "xferIn");

        // calcular out
        uint256 rate = tokenToUsdcRate1e18[address(tokenIn)];
        uint256 usdcOut = (amountIn * rate) / 1e18;
        require(usdcOut >= amountOutMin, "slip");

        // mintear o transferir USDC
        MockERC20 usdc = MockERC20(USDC);
        usdc.mint(to, usdcOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = usdcOut;
    }
}
