// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function setPair(address a, address b, address pair) external {
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}
