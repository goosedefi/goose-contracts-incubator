// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "../libs/IBEP20.sol";

interface IHouseFactory{
    function createNewHouse(
        uint256 layerId,
        IBEP20 _stakeToken,
        IBEP20 _rewardToken,
        uint256 _rewardsPerBlock,
        uint256 _startBlock) external returns (address);
}
