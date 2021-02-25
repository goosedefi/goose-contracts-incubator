// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import '@openzeppelin/contracts/access/Ownable.sol';
import "../libs/IBEP20.sol";
import "../interfaces/IHouseFactory.sol";
import "../HouseChef.sol";

contract HouseFactory is IHouseFactory, Ownable {

    function createNewHouse(
        uint256 layerId,
        IBEP20 _stakeToken,
        IBEP20 _rewardToken,
        uint256 _rewardsPerBlock,
        uint256 _startBlock
    ) override external onlyOwner returns (address){
        HouseChef chef = new HouseChef{salt : bytes32(layerId)}(_stakeToken, _rewardToken, _rewardsPerBlock, _startBlock);
        Ownable(chef).transferOwnership(msg.sender);
        return address(chef);
    }

}
