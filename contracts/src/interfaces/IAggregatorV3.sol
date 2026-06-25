// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Chainlink AggregatorV3 interface used to read the sGHO 4626 vault exchange rate.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
