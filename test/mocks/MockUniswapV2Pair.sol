// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockERC20.sol";

contract MockUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function mint(address to, uint amount0, uint amount1) external {
        reserve0 += uint112(amount0);
        reserve1 += uint112(amount1);
        MockERC20(token0).mint(to, amount0);
        MockERC20(token1).mint(to, amount1);
    }

    function swap(uint amount0Out, uint amount1Out, address to) external {
        if (amount0Out > 0) {
            reserve0 -= uint112(amount0Out);
            MockERC20(token0).mint(to, amount0Out);
        }
        if (amount1Out > 0) {
            reserve1 -= uint112(amount1Out);
            MockERC20(token1).mint(to, amount1Out);
        }
    }

    function setReserves(uint112 _r0, uint112 _r1) external {
        reserve0 = _r0;
        reserve1 = _r1;
    }
}
