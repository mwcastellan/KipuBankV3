// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./MockERC20.sol";

contract MockRouter {
    address public factory;
    address public usdc;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function setFactory(address f) external {
        factory = f;
    }

    function WETH() external pure returns (address) {
        return address(0xC0FFEE); // dummy WETH
    }

    function factory() external view returns (address) {
        return factory;
    }

    function swapExactETHForTokens(
        uint,
        address[] calldata,
        address to,
        uint
    ) external payable {
        MockERC20(usdc).mint(to, msg.value * 1000); // 1 ETH → 1000 USDC
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint,
        address[] calldata,
        address to,
        uint
    ) external {
        MockERC20(usdc).mint(to, amountIn * 2); // 1 DAI → 2 USDC
    }
}
