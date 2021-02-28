// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libs/BEP20.sol";
import "./interfaces/IMintable.sol";

contract GooseToken is IMintable, BEP20 {

    constructor(string memory name, string memory symbol) public BEP20(name, symbol) {
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) override external onlyOwner {
        _mint(_to, _amount);
    }
}