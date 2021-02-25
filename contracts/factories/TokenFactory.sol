// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "../interfaces/ITokenFactory.sol";
import "../GooseToken.sol";

contract TokenFactory is ITokenFactory, Ownable {

    function createNewToken(uint256 layerId, string memory name, string memory symbol) override external onlyOwner returns (address){
        GooseToken token = new GooseToken{salt : bytes32(layerId)}(name, symbol);
        Ownable(token).transferOwnership(msg.sender);
        return address(token);
    }

}
