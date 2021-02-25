// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "../libs/IBEP20.sol";
import "./IFeeProcessor.sol";

interface IFeeProcessorFactory{
    function createNewFeeProcessor(
        uint256 layerId,
        address _schedulerAddr,
        address _gooseToken,
        address _houseChef,
        address _houseToken,
        address _feeHolder,
        uint16 _feeDevShareBP,
        uint16 _houseShareBP
    ) external returns (IFeeProcessor);
}
