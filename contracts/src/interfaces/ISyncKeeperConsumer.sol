// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISyncKeeperConsumer Interface
 * @dev The interface of the {SyncKeeperConsumer} contract, the keeper-style consumer that tops up
 * the oracle pool of a `CustomSender` through a Chainlink CRE workflow.
 */
interface ISyncKeeperConsumer {
    /**
     * @dev The encoded fee data is shorter than the three ABI words it must decode to.
     * @param length The length of the provided fee data.
     * @param minLength The minimum length required to decode the fee data.
     */
    error FeeOtoDTooShort(uint256 length, uint256 minLength);

    /**
     * @dev The gas limit encoded in the fee data is below {MIN_PROCESS_MESSAGE_GAS}.
     * @param gasLimit The gas limit encoded in the provided fee data.
     * @param minGas The minimum gas limit required to process the message.
     */
    error InsufficientGasLimit(uint32 gasLimit, uint32 minGas);

    /**
     * @dev The price feed reported a non-positive answer.
     * @param answer The answer reported by the price feed.
     */
    error InvalidPrice(int256 answer);

    /**
     * @dev The price feed was last updated longer than {maxPriceStaleness} ago.
     * @param updatedAt The timestamp at which the price feed was last updated.
     * @param maxStaleness The maximum age tolerated for the price feed answer.
     */
    error StalePriceFeed(uint256 updatedAt, uint256 maxStaleness);

    /// @dev A required address parameter is the zero address.
    error ZeroAddress();

    /// @dev A required amount parameter is zero.
    error ZeroAmount();

    /**
     * Emitted when the minimum oracle pool balance is updated.
     * @param previous The previous minimum oracle pool balance.
     * @param current The new minimum oracle pool balance.
     */
    event MinOraclePoolBalanceUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the sync amount is updated.
     * @param previous The previous sync amount.
     * @param current The new sync amount.
     */
    event SyncAmountUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the CCIP fee data is updated.
     * @param maxFeeOtoD The maximum CCIP fee allowed for the origin to destination message.
     * @param payInGhoOtoD Whether the fee is paid in `GHO` (`true`) or in native token (`false`).
     * @param gasLimitOtoD The gas limit for executing the message on the destination chain.
     */
    event FeeOtoDUpdated(
        uint128 indexed maxFeeOtoD,
        bool indexed payInGhoOtoD,
        uint32 indexed gasLimitOtoD
    );

    /**
     * Emitted when the CCIP extra arguments are updated.
     * @param extraArgs The new encoded extra arguments forwarded to the CCIP router.
     */
    event ExtraArgsUpdated(bytes extraArgs);

    /**
     * Emitted when the price feed is updated.
     * @param previous The address of the previous price feed.
     * @param current The address of the new price feed.
     */
    event PriceFeedUpdated(address indexed previous, address indexed current);

    /**
     * Emitted when the maximum price staleness is updated.
     * @param previous The previous maximum price staleness.
     * @param current The new maximum price staleness.
     */
    event MaxPriceStalenessUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when a report is processed while the oracle pool is not set on the `CustomSender`,
     * meaning no sync is performed.
     */
    event SyncSkippedOracleMisconfigured();

    /**
     * Emitted when a report is processed while the oracle pool is funded above the threshold,
     * meaning no sync is performed.
     * @param poolBalance The current `GHO` balance of the oracle pool.
     * @param minOraclePoolBalance The balance below which a sync is performed.
     */
    event SyncSkippedUpkeepNotNeeded(
        uint256 poolBalance,
        uint256 minOraclePoolBalance
    );

    /**
     * @dev Sets the oracle pool balance below which a sync is performed.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `minBal` must be greater than 0.
     *
     * Emits a {MinOraclePoolBalanceUpdated} event.
     *
     * @param minBal The new minimum oracle pool balance.
     */
    function setMinOraclePoolBalance(uint256 minBal) external;

    /**
     * @dev Sets the amount of `GHO` sent to the oracle pool on each sync.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `newAmount` must be greater than 0.
     *
     * Emits a {SyncAmountUpdated} event.
     *
     * @param newAmount The new sync amount.
     */
    function setSyncAmount(uint256 newAmount) external;

    /**
     * @dev Sets the CCIP fee data forwarded to `CustomSender.sync`.
     * The fee data is the encoding of `(uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD)`.
     * When the fee is paid in native token, this contract must hold enough native token to cover
     * `maxFeeOtoD` on each sync.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `newFee` must be at least 96 bytes long.
     * - The gas limit encoded in `newFee` must be at least {MIN_PROCESS_MESSAGE_GAS}.
     *
     * Emits a {FeeOtoDUpdated} event.
     *
     * @param newFee The new encoded CCIP fee data.
     */
    function setFeeOtoD(bytes calldata newFee) external;

    /**
     * @dev Sets the extra arguments forwarded to the CCIP router on each sync.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits an {ExtraArgsUpdated} event.
     *
     * @param newExtraArgs The new encoded extra arguments, or empty bytes to use the CCIP defaults.
     */
    function setExtraArgs(bytes calldata newExtraArgs) external;

    /**
     * @dev Sets the price feed used to convert the sync amount to its sGHO equivalent.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `newFeed` must not be the zero address.
     *
     * Emits a {PriceFeedUpdated} event.
     *
     * @param newFeed The address of the new sGHO/GHO exchange rate feed.
     */
    function setPriceFeed(address newFeed) external;

    /**
     * @dev Sets the maximum age tolerated for the price feed answer.
     * Setting `newStaleness` to a large value effectively disables the staleness check.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits a {MaxPriceStalenessUpdated} event.
     *
     * @param newStaleness The new maximum price staleness, in seconds.
     */
    function setMaxPriceStaleness(uint256 newStaleness) external;

    /**
     * @notice Returns the minimum gas required to process the CCIP message on the destination chain.
     */
    function MIN_PROCESS_MESSAGE_GAS() external view returns (uint32);

    /**
     * @notice Returns the address of the `CustomSender` contract synced by this contract.
     */
    function CUSTOM_SENDER() external view returns (address);

    /**
     * @notice Returns the address of the `GHO` token, as cached from the `CustomSender`.
     */
    function GHO() external view returns (address);

    /**
     * @notice Returns the address of the `SGHO` token, as cached from the `CustomSender`.
     */
    function SGHO() external view returns (address);

    /**
     * @notice Returns the oracle pool balance below which a sync is performed.
     */
    function minOraclePoolBalance() external view returns (uint256);

    /**
     * @notice Returns the amount of `GHO` sent to the oracle pool on each sync.
     */
    function syncAmount() external view returns (uint256);

    /**
     * @notice Returns the address of the sGHO/GHO exchange rate feed.
     */
    function priceFeed() external view returns (address);

    /**
     * @notice Returns the maximum age tolerated for the price feed answer, in seconds.
     */
    function maxPriceStaleness() external view returns (uint256);

    /**
     * @notice Returns the encoded CCIP fee data forwarded to `CustomSender.sync`.
     */
    function feeOtoD() external view returns (bytes memory);

    /**
     * @notice Returns the encoded extra arguments forwarded to the CCIP router.
     */
    function extraArgs() external view returns (bytes memory);

    /**
     * @dev Returns whether the oracle pool needs to be topped up.
     * This is the gate read by the CRE workflow to decide whether to submit a report, and is
     * re-checked when the resulting report is processed.
     *
     * @return upkeepNeeded True if the oracle pool is set on the `CustomSender` and its `GHO`
     * balance is strictly below {minOraclePoolBalance}.
     */
    function needsUpkeep() external view returns (bool upkeepNeeded);
}
