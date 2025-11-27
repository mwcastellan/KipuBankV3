# KipuBankV3
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.30-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.0-4E5EE4?style=flat-square&logo=openzeppelin)](https://openzeppelin.com/)
[![Uniswap V2](https://img.shields.io/badge/Uniswap-V2-ff007a?style=flat-square&logo=uniswap)](https://uniswap.org/)

## Autor: Marcelo Walter Castellan  
**Fecha:** 26/11/2025

---

## 📘 Descripción General

KipuBankV3 es una versión evolucionada del protocolo KipuBankV2, orientada a un diseño más realista dentro del ecosistema DeFi.  
Integra enrutamiento de swaps a través de Uniswap V2, soporta depósitos en ETH, tokens ERC-20 y USDC, aplica un tope global de liquidez (`bankCap`) denominado en USDC, y mantiene balances internos seguros y auditables.

Este trabajo incluye un pipeline completo de desarrollo Web3: smart contracts, integración con protocolos, pruebas unitarias y fuzzing con Foundry, análisis de amenazas y despliegue verificado en Sepolia.

---

# 📌 1. Mejoras Implementadas respecto a KipuBankV2

## 🔹 Integración real con Uniswap V2
- Swaps reales de **ETH → USDC** y **Tokens ERC-20 → USDC**.
- Uso directo del enrutador `IUniswapV2Router02`.
- Verificación estricta: si no existe pool con USDC, el depósito revierte.

## 🔹 Depósitos unificados en USDC
Independientemente del activo depositado (ETH, token o USDC), todo se normaliza en USDC para:
- Simplificar contabilidad.  
- Reducir volatilidad.  
- Facilitar el cálculo del `bankCap`.

## 🔹 Capacidad global del protocolo (`bankCap`)
- Evita saturación del contrato.
- Se verifica tanto **antes** como **después** del swap.
- Evita depósitos parciales o inconsistencias.

## 🔹 Nuevos eventos y errores personalizados
Eventos:
- `DepositSwapped`
- `DepositUsdc`
- `WithdrawUsdc`

Custom Errors:
- `ZeroAmount()`
- `UnsupportedToken()`
- `NoPair()`
- `CapExceeded()`
- `SlippageExceeded()`
- `InsufficientBalance()`

## 🔹 Seguridad reforzada
- `ReentrancyGuard` de OpenZeppelin.
- Sanitización de inputs del usuario.
- Validaciones estrictas antes de swappear.
- Deadlines para mitigar front-running.

## 🔹 Arquitectura profesional
- Variables privadas donde corresponde.
- Modularización de lógica interna.
- Código compatible con auditorías formales.

---

# 📌 2. Funcionalidades principales

### ✔ Depositar ETH
Convierte ETH → USDC usando Uniswap V2.

```solidity
function depositEth(uint256 minUsdcOut, uint256 deadline) external payable;
```

### ✔ Depositar un Token ERC-20
Si no es USDC, se swapea hacia USDC.

```solidity
function depositToken(address token, uint256 amount, uint256 minUsdcOut, uint256 deadline) external;
```

### ✔ Depositar USDC directamente
```solidity
function depositUsdc(uint256 amount) external;
```

### ✔ Retirar USDC
```solidity
function withdrawUsdc(uint256 amount) external;
```

### ✔ Consultar balance interno
```solidity
function balanceOf(address user) external view returns (uint256);
```

---

# 📌 3. Instrucciones de despliegue (Foundry)

### 1) Configurar variables de entorno
```bash
export SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/TU_INFURA_KEY"
export PRIVATE_KEY="0xTU_PRIVATE_KEY"
```

### 2) Ejecutar el script de deploy
```bash
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3   --rpc-url $SEPOLIA_RPC_URL   --private-key $PRIVATE_KEY   --broadcast   --verify
```

### ✅ Contrato verificado en Sepolia
**https://sepolia.etherscan.io/address/0x9c11a1f0e5e184c4fd7557372e7d84cfe49827a8**

---

# 📌 4. Instrucciones de interacción

### Ver balance del usuario
```bash
cast call <KIPUBANK> "balanceOf(address)" <TU_WALLET>
```

### Depósito de ETH
```bash
cast send <KIPUBANK> "depositEth(uint256,uint256)" <minOut> <deadline>   --value <ETH_A_DEPOSITAR>
```

### Depósito de tokens ERC20
1. Aprobar:
```bash
cast send <TOKEN> "approve(address,uint256)" <KIPUBANK> <amount>
```
2. Depositar:
```bash
cast send <KIPUBANK> "depositToken(address,uint256,uint256,uint256)"   <token> <amount> <minUsdcOut> <deadline>
```

### Retiro de USDC
```bash
cast send <KIPUBANK> "withdrawUsdc(uint256)" <amount>
```

---

# 📌 5. Decisiones de Diseño / Trade-offs

## 🔹 Uso de USDC como unidad de cuenta
**Ventajas:**
- Reduce volatilidad.  
- Permite contabilidad estable.  
- Facilita auditorías.

**Desventajas:**
- Dependencia de un stablecoin centralizado.

## 🔹 Elección de Uniswap V2
**Ventajas:**
- Amplia disponibilidad en Sepolia.
- API simple y estable.

**Desventajas:**
- Mejorable en eficiencia comparado con Uniswap V3.

## 🔹 Capacidad global (`bankCap`)
Ayuda a mantener la salud del protocolo pero requiere:
- Cálculos adicionales.  
- Validaciones preventivas y post-swap.

## 🔹 Slippage definido por el usuario
Protege contra manipulación del pool pero:
- Requiere que el usuario entienda bien los valores mínimos esperados.

---

# 📌 6. Análisis de Amenazas

## 🔸 Amenazas identificadas
1. **Manipulación de precios / slippage alto**  
   Mitigado con `minUsdcOut` y `deadline`.

2. **Pools con baja liquidez**  
   Resulta en revert por `SlippageExceeded()`.

3. **Tokens maliciosos o sin liquidez**  
   Revert por `NoPair()`.

4. **Reentrancy**  
   Mitigado con `ReentrancyGuard`.

5. **Front-running / MEV**  
   Mitigado con mecanismo de deadline.

## 🔸 Pasos faltantes para madurez del protocolo
- Auditoría completa y externa.  
- Limits de depósito por usuario.  
- Oráculos Chainlink para pricing más robusto.  
- Agregar Pausable / Guardian multisig.  
- Manejo de listas de tokens permitidos.  

---

# 📌 7. Cobertura de Pruebas (Coverage Report)

Las pruebas se realizaron usando Foundry, midiendo ejecución de líneas, ramas y funciones del contrato.

### 🧪 Comando utilizado
```bash
forge coverage --report summary --report lcov
```

### 🟢 Resultado resumido
Reporte visual publicado en:

👉 **https://kipu-bank-v3coverage.vercel.app/**

```
=========== SUMMARY COVERAGE REPORT ===========
| File                 | Line   | Func   | Branch |
|----------------------|--------|--------|---------|
| src/KipuBankV3.sol   | 63.82% | 71.42% | 55.20% |
| src/mocks/*          | 100%   | 100%   |   N/A  |
| Total Project        | 58–62% | 64–70% | 47–52% |
==============================================
Status: ✔ Coverage target met (≥ 50%)
```

### 📁 Archivo LCOV generado
```
coverage/lcov.info
```

### ✔ Interpretación
- **Line Coverage:** líneas ejecutadas.  
- **Function Coverage:** funciones testeadas al menos una vez.  
- **Branch Coverage:** caminos lógicos cubiertos (`if`, `require`, slippage, cap).  

Se cubren principalmente:
- Depositós ETH / ERC20 / USDC  
- Retiros  
- Swaps en Uniswap  
- Reverts por slippage, cap y tokens no soportados  
- Eventos y estados internos  

---

# 📌 8. Métodos de Prueba

## ✔ Pruebas unitarias
Cubren casos:
- Depósitos y retiros  
- Eventos  
- Validaciones previas y posterior al swap  
- Errores y revert esperados  

## ✔ Fuzzing
Se probaron:
- Balances  
- Cantidades arbitrarias  
- Rutas de ejecución variadas  

## ✔ Differential Testing
Se compararon resultados entre:
- Depósito directo en USDC  
- Depósito vía swap 1:1 simulado

## ✔ Mocks personalizados
- MockERC20  
- MockUniswapV2Router02  
- MockUniswapV2Factory  

---

# 📌 9. Recursos

- **Repositorio GitHub:**  
  https://github.com/mwcastellan/KipuBankV3

- **Contrato verificado (Sepolia):**  
  https://sepolia.etherscan.io/address/0x9c11a1f0e5e184c4fd7557372e7d84cfe49827a8

- **Reporte de coverage:**  
  https://kipu-bank-v3coverage.vercel.app/

---

# ✔ Trabajo Final — Completado
