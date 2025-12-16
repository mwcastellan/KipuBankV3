// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockUniswapFactory {
    mapping(bytes32 => address) private _pairs;

    function setPair(address tokenA, address tokenB, address pair) external {
        bytes32 key1 = keccak256(abi.encode(tokenA, tokenB));
        bytes32 key2 = keccak256(abi.encode(tokenB, tokenA));
        _pairs[key1] = pair;
        _pairs[key2] = pair;
    }

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return _pairs[keccak256(abi.encode(tokenA, tokenB))];
    }
}