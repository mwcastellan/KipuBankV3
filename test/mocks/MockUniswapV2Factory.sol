// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockUniswapV2Pair.sol";

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockUniswapV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        allPairs.push(pair);
    }
}
