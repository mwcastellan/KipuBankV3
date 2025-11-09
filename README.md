# 🏦 KipuBankV3 – DeFi Bank Integrado con Uniswap V2

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.30-363636?style=flat-square&logo=solidity)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.0-4E5EE4?style=flat-square&logo=openzeppelin)](https://openzeppelin.com/)
[![Uniswap V2](https://img.shields.io/badge/Uniswap-V2-ff007a?style=flat-square&logo=uniswap)](https://uniswap.org/)

## Autor: Marcelo Walter Castellan  
**Fecha:** 09/11/2025

---

## 📘 Descripción General

**KipuBankV3** representa la evolución de **KipuBankV2** hacia un protocolo DeFi interoperable y completamente integrado con **Uniswap V2**, que permite depósitos en **cualquier token soportado** y su conversión automática a **USDC**.  
Este nuevo enfoque acerca al contrato a un modelo de *stable-backed bank*, asegurando que los saldos internos estén expresados en una unidad estable y auditada (USDC).

---

## 🚀 Mejoras Implementadas y Motivación

### 1. 🔄 Integración con Uniswap V2

- Permite a los usuarios **depositar cualquier token ERC20 soportado**.
- El contrato **swapea automáticamente los tokens a USDC** usando `IUniswapV2Router02`.
- Simplifica la gestión de balances al mantenerlos **denominados en USDC**, reduciendo exposición a volatilidad.

### 2. 🧱 Arquitectura Modulada y Documentada

- Código completamente documentado con **NatSpec** en inglés técnico.
- Separación clara entre **lógica de depósito**, **swaps** y **restricciones del banco**.
- Eventos detallados (`DepositSwapped`, `WithdrawUsdc`, `ParamsUpdated`) que facilitan auditoría y seguimiento de operaciones.

### 3. ⚙️ Seguridad Mejorada

- Uso de `ReentrancyGuard` para prevenir ataques de reentrada.
- `Ownable` para control administrativo.
- Validaciones en constructor y parámetros críticos (`require` en direcciones no nulas).
- Manejo seguro de tokens mediante `SafeERC20`.

### 4. 💰 Bank Cap y Slippage Control

- Se conserva el **bank cap global**, pero ahora expresado en USDC.
- Implementa verificación de **slippage tolerado**, protegiendo a los usuarios ante variaciones extremas de precios durante el swap.
- Uso de revert personalizados (`SlippageExceeded`, `CapExceeded`) para auditorías y pruebas.

### 5. 🧪 Compatibilidad Total con Foundry

- Despliegue, pruebas unitarias y verificación completamente integrados en **Foundry** (`forge`).
- Scripts automatizados de despliegue y verificación en Sepolia.

---

## ⚙️ Instrucciones de Despliegue e Interacción

### Prerequisitos

- Tener **Foundry** instalado (`foundryup`).
- Contar con una **cuenta MetaMask o clave privada** con fondos de testnet (Sepolia).
- Un **RPC URL válido** (Infura, Alchemy o Ankr).

### 1. Configurar variables

```bash
export SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/TU_INFURA_KEY"
export PRIVATE_KEY="0xTU_CLAVE_PRIVADA"
```

### 2. Compilar el contrato

```bash
forge build
```

### 3. Ejecutar script de despliegue

```bash
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3   --rpc-url $SEPOLIA_RPC_URL   --private-key $PRIVATE_KEY   --broadcast   --verify
```

> 💡 Ejemplo de salida esperada:
> ```
> KipuBankV3 deployed at: 0x26380305DAC69f945B2Ed884de60D558b2361D63
> ```

### 4. Interacción con el contrato

**Depositar ETH**
```bash
cast send <direccion_contrato> "depositEth()" --value 0.1ether --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

**Depositar token ERC20**
```bash
cast send <token> "approve(address,uint256)" <direccion_contrato> 1000000000000000000
cast send <direccion_contrato> "depositToken(address,uint256)" <token> 1000000000000000000
```

**Consultar balance en USDC**
```bash
cast call <direccion_contrato> "getBalance(address)" <tu_wallet>
```

---

## 🧭 Decisiones de Diseño y Trade-offs

| Decisión | Justificación | Trade-off |
|-----------|----------------|-----------|
| Uso de USDC como activo base | Reduce exposición a volatilidad y simplifica contabilidad | Requiere dependencia en liquidez y disponibilidad de pares USDC |
| Enrutamiento Uniswap V2 directo | Permite swaps descentralizados sin custodios | Menor control sobre deslizamientos extremos |
| No validación de oráculos | Uniswap V2 provee precios mediante pools | No existen límites de tiempo/frescura sobre precios on-chain |
| Slippage manual en test | Facilita control durante pruebas en Sepolia | Requiere ajustes de tolerancia por red y liquidez |

---

## 🧩 Cobertura de Pruebas y Métodos

### Herramientas
- **Foundry (`forge test`)**
- **LCOV y cobertura de gas (`forge coverage`)**
- **Análisis: https://kipubankv3lcov.vercel.app/

### Alcance de pruebas
- Depósitos ETH y tokens.
- Conversión automática a USDC.
- Límite de `bankCap`.
- Manejo de errores por *slippage*.
- Validaciones de dirección nula y permisos administrativos.

### Ejemplo de ejecución
```bash
forge test --match-contract KipuBankV3Test
```

### Cobertura
- Cobertura de líneas: ~95%
- Casos revert: `SlippageExceeded`, `CapExceeded`, `ZeroAmount`
- Eventos validados: `DepositSwapped`, `WithdrawUsdc`, `ParamsUpdated`

---

## 🛡️ Informe de Análisis de Amenazas

### Identificación de Debilidades

| Amenaza | Descripción | Mitigación Actual | Recomendación |
|----------|-------------|------------------|----------------|
| **Slippage extrema en swaps** | El swap puede fallar si el pool tiene poca liquidez | Control de slippage configurable | Añadir consulta previa de reservas o oráculo |
| **Liquidez insuficiente en Uniswap** | Fallos de `swapExactTokensForTokens` | Uso de try/catch con revert controlado | Implementar fallback o colateral alternativo |
| **Dependencia de USDC centralizado** | Riesgo de censura o congelamiento | Elección de USDC por estabilidad | Permitir múltiples stables (DAI, USDT) |
| **Ataques de reentrada** | Posible si no se protege la lógica de swap | Uso de `ReentrancyGuard` | Monitoreo de actualizaciones OZ |
| **Exposición del owner** | El owner controla parámetros críticos | Validaciones `onlyOwner` | Sugerir `multi-sig` o `TimelockController` |

### Madurez del Protocolo
> Nivel actual: **Beta funcional en testnet Sepolia.**

Pasos faltantes para producción:
- Implementar auditoría externa.
- Añadir test de fuzzing y estrés.
- Simulaciones de liquidez con mainnet fork.

---

## 📊 Resumen Técnico

| Item | Valor |
|------|-------|
| **Solidity** | ^0.8.30 |
| **Framework** | Foundry |
| **DEX Integrado** | Uniswap V2 |
| **Stablecoin Base** | USDC |
| **Red** | Sepolia (Testnet) |
| **Dirección desplegada** | [0x26380305DAC69f945B2Ed884de60D558b2361D63](https://sepolia.etherscan.io/address/0x26380305DAC69f945B2Ed884de60D558b2361D63) |

---

## 👨‍💻 Desarrollador

**Autor:** Marcelo Walter Castellan  
**GitHub:** [mwcastellan](https://github.com/mwcastellan)  
**Correo:** mcastellan@yahoo.com  
**Fecha de actualización:** 09 de Noviembre de 2025  
