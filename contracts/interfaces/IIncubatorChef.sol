// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "../libs/IBEP20.sol";

interface IIncubatorChef{
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) external;
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, uint256 _maxDepositAmount, bool _withUpdate) external;
    function massUpdatePools() external;
    function setFeeAddress(address _feeAddress) external;
}
