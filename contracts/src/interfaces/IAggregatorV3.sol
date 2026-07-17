// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAggregatorV3 Interface
 * @dev The minimal Chainlink `AggregatorV3` interface used to read the sGHO ERC-4626 vault
 * exchange rate.
 */
interface IAggregatorV3 {
    /**
     * @notice Returns the number of decimals used to scale the feed answer.
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns the data of the latest round recorded by the feed.
     * @return roundId The identifier of the latest round.
     * @return answer The answer reported for the round, scaled by `10 ** decimals()`.
     * @return startedAt The timestamp at which the round started.
     * @return updatedAt The timestamp at which the answer was last updated.
     * @return answeredInRound The identifier of the round in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
