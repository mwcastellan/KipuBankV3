// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    function run() external {
        // --- Configurar los parámetros ---
        address router = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;  // UniswapV2Router02 en Sepolia
        address usdc   = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;  // USDC en Sepolia
        uint256 bankCap = 1_000_000 ether;                            // 1 millón en wei (ajustable)
        address owner  = 0xD38CFbEa8E7A08258734c13c956912857cD6B37b;  // Tu dirección

        vm.startBroadcast();

        KipuBankV3 bank = new KipuBankV3(router, usdc, bankCap, owner);

        vm.stopBroadcast();

        console.log("KipuBankV3 deployed at:", address(bank));
    }
}

	