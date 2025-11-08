// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MockERC20} from "./MockERC20.sol";

contract MockUniswapV2Router02 {
    address private _factory;
    address private _WETH;
    address public USDC;

    // rates: token => USDC per 1 token (1e18 base), ETH rate separado
    mapping(address => uint256) public tokenToUsdcRate1e18;
    uint256 public ethToUsdcRate1e18; // USDC per 1 ETH (1e18 base)

    constructor(address weth_) {
        _WETH = weth_;
    }

    function setFactory(address f) external {
        _factory = f;
    }
    function setUSDC(address u) external {
        USDC = u;
    }
    function setTokenRate(address token, uint256 rate1e18) external {
        tokenToUsdcRate1e18[token] = rate1e18;
    }
    function setEthRate(uint256 rate1e18) external {
        ethToUsdcRate1e18 = rate1e18;
    }

    // Router02 interface pieces used by KipuBankV3
    function factory() external view returns (address) {
        return _factory;
    }
    function WETH() external view returns (address) {
        return _WETH;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "path");
        require(path[1] == USDC, "dst!=USDC");

        MockERC20 tokenIn = MockERC20(path[0]);
        require(tokenToUsdcRate1e18[address(tokenIn)] > 0, "rate0");
        // pull from caller (KipuBankV3)
        require(
            tokenIn.transferFrom(msg.sender, address(this), amountIn),
            "pull"
        );

        uint256 usdcOut = (amountIn * tokenToUsdcRate1e18[address(tokenIn)]) /
            1e18;
        require(usdcOut >= amountOutMin, "slip");
        MockERC20(USDC).mint(to, usdcOut);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = usdcOut;
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256[] memory amounts) {
        require(path.length == 2, "path");
        require(path[0] == _WETH && path[1] == USDC, "route");
        require(ethToUsdcRate1e18 > 0, "rate0");

        uint256 usdcOut = (msg.value * ethToUsdcRate1e18) / 1e18;
        require(usdcOut >= amountOutMin, "slip");
        MockERC20(USDC).mint(to, usdcOut);

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = usdcOut;
    }
}
