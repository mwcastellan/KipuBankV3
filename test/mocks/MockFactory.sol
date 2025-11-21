// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockFactory {
    address tokenA;
    address tokenB;

    constructor(address a, address b) {
        tokenA = a;
        tokenB = b;
    }

    function getPair(address _a, address _b) external view returns (address) {
        if (
            (_a == tokenA && _b == tokenB) ||
            (_a == tokenB && _b == tokenA)
        ) {
            return address(0xABCD); // dummy pair
        }
        return address(0);
    }
}
