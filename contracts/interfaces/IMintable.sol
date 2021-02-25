// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libs/IBEP20.sol";

interface IMintable is IBEP20 {
    function mint(address _to, uint256 _amount) external;
}
