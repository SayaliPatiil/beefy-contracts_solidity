// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;

interface IEps2LP {
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external;
}