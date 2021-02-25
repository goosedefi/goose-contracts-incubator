// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

interface ITokenFactory{
    function createNewToken(uint256 layerId, string memory name, string memory symbol) external returns (address);
}
