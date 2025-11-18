// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public pairs;

    // Configurar manualmente un par
    function setPair(address tokenA, address tokenB, address pair) external {
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
    }

    // Retorna address(1) si no hay par configurado manualmente
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        address p = pairs[tokenA][tokenB];
        if (p != address(0)) return p;
        return address(1); // simulamos "pair existente"
    }
}
