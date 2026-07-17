// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @dev A price feed whose answer, decimals and last update timestamp are settable by tests.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 feedDecimals, int256 answer) {
        _decimals = feedDecimals;
        _answer = answer;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 answer) external {
        _answer = answer;
    }

    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
