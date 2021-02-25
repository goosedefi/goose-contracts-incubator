// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import '@openzeppelin/contracts/access/Ownable.sol';
import "../libs/IBEP20.sol";
import "../interfaces/IFeeProcessorFactory.sol";
import "../interfaces/IFeeProcessor.sol";
import "../FeeProcessor.sol";

contract FeeProcessorFactory is IFeeProcessorFactory, Ownable {

    function createNewFeeProcessor(
        uint256 layerId,
        address _schedulerAddr,
        address _gooseToken,
        address _houseChef,
        address _houseToken,
        address _feeHolder,
        uint16 _feeDevShareBP,
        uint16 _houseShareBP
    ) override external onlyOwner returns (IFeeProcessor){
        FeeProcessor processor = new FeeProcessor{salt : bytes32(layerId)}(
            _schedulerAddr,
            _gooseToken,
            _houseChef,
            _houseToken,
            _feeHolder,
            _feeDevShareBP,
            _houseShareBP
        );
        Ownable(processor).transferOwnership(msg.sender);
        return processor;
    }

}
