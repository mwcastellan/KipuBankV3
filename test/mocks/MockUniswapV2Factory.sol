// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockUniswapV2Factory {
    address public router;
    mapping(address => mapping(address => address)) public getPair;

    constructor(address _router) {
        router = _router;
    }

    function setPair(address tokenA, address tokenB, address pair) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}
