// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {

    function run() external {
        // ============================
        // 1. Leer variables de entorno
        // ============================
        address router = vm.envAddress("ROUTER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 bankCap = vm.envUint("BANK_CAP");
        address owner = vm.envAddress("OWNER_ADDRESS");

        // ============================
        // 2. Iniciar broadcast real
        // ============================
        vm.startBroadcast();

        // ============================
        // 3. Deploy del contrato
        // ============================
        KipuBankV3 kipu = new KipuBankV3(
            router,
            usdc,
            bankCap,
            owner
        ); 

        vm.stopBroadcast();

        // ============================
        // 4. Logs
        // ============================
        console2.log(">KipuBankV3 deployed at:", address(kipu));
        console2.log(">Router:", router);
        console2.log(">USDC:", usdc);
        console2.log(">Bank Cap:", bankCap);
        console2.log(">Owner:", owner);
    }
}
