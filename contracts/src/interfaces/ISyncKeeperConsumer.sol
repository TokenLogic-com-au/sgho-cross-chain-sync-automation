// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISyncKeeperConsumer Interface
 * @dev The interface of the {SyncKeeperConsumer} contract, the keeper-style consumer that rebalances
 * the two sided oracle pool of a `CustomSender` through a Chainlink CRE workflow.
 *
 * The oracle pool holds both `GHO` and `SGHO`, and user flow pushes it either way: a deposit takes
 * `SGHO` out and puts `GHO` in, a redeem does the reverse. A sync corrects the imbalance by sending
 * the token that is in surplus to the mainnet vault and receiving the token that is short.
 */
interface ISyncKeeperConsumer {
    /**
     * @dev The encoded fee data is shorter than the three ABI words it must decode to.
     * @param length The length of the provided fee data.
     * @param minLength The minimum length required to decode the fee data.
     */
    error FeeOtoDTooShort(uint256 length, uint256 minLength);

    /**
     * @dev The gas limit encoded in the extra arguments passed to {setExtraArgs} is below
     * {MIN_PROCESS_MESSAGE_GAS}.
     */
    error InvalidGasLimit();

    /**
     * @dev The first 4 bytes of the extra arguments passed to {setExtraArgs} do not match
     * `ExtraArgsCodec.GENERIC_EXTRA_ARGS_V3_TAG`.
     * @param tag The rejected 4-byte tag found at the start of the extra arguments.
     */
    error InvalidExtraArgsTag(bytes4 tag);

    /**
     * @dev The gas limit encoded in the fee data is below {MIN_PROCESS_MESSAGE_GAS}.
     * @param gasLimit The gas limit encoded in the provided fee data.
     * @param minGas The minimum gas limit required to process the message.
     */
    error InsufficientGasLimit(uint32 gasLimit, uint32 minGas);

    /// @dev A required address parameter is the zero address.
    error ZeroAddress();

    /// @dev A required amount parameter is zero.
    error ZeroAmount();

    /**
     * Emitted when the CCIP extra arguments are updated.
     * @param extraArgs The new encoded extra arguments forwarded to the CCIP router.
     */
    event ExtraArgsUpdated(bytes extraArgs);

    /**
     * Emitted when the minimum `GHO` balance is updated.
     * @param previous The previous minimum `GHO` balance.
     * @param current The new minimum `GHO` balance.
     */
    event MinGhoBalanceUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the minimum `SGHO` balance is updated.
     * @param previous The previous minimum `SGHO` balance.
     * @param current The new minimum `SGHO` balance.
     */
    event MinSGhoBalanceUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the sync amount is updated.
     * @param previous The previous sync amount.
     * @param current The new sync amount.
     */
    event SyncAmountUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the minimum sync amount is updated.
     * @param previous The previous minimum sync amount.
     * @param current The new minimum sync amount.
     */
    event MinSyncAmountUpdated(uint256 previous, uint256 current);

    /**
     * Emitted when the settlement window is updated.
     * @param previous The previous settlement window, in seconds.
     * @param current The new settlement window, in seconds.
     */
    event SettlementWindowUpdated(uint256 previous, uint256 current);

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
     * Emitted when the oracle pool is rebalanced.
     * @param tokenSent The address of the token sent to the mainnet vault (the token in surplus).
     * @param amount The amount of `tokenSent` sent.
     * @param minAmountOut The minimum amount of the opposite token expected in return.
     */
    event SyncPerformed(
        address indexed tokenSent,
        uint256 amount,
        uint256 minAmountOut
    );

    /**
     * Emitted when a report is processed while the oracle pool is not set on the `CustomSender`,
     * meaning no sync is performed.
     */
    event SyncSkippedOracleMisconfigured();

    /**
     * Emitted when a report is processed while both sides of the oracle pool are funded above their
     * thresholds, meaning no sync is performed.
     * @param ghoBalance The current `GHO` balance of the oracle pool.
     * @param sGhoBalance The current `SGHO` balance of the oracle pool.
     */
    event SyncSkippedUpkeepNotNeeded(uint256 ghoBalance, uint256 sGhoBalance);

    /**
     * Emitted when a report is processed while a side of the oracle pool is short but no actionable
     * surplus exists to send, meaning no sync is performed. This covers both sides being below their
     * thresholds, and the funded side holding less than {minSyncAmount} above its own threshold.
     * @param ghoBalance The current `GHO` balance of the oracle pool.
     * @param sGhoBalance The current `SGHO` balance of the oracle pool.
     */
    event SyncSkippedNoSurplus(uint256 ghoBalance, uint256 sGhoBalance);

    /**
     * Emitted when a report is processed within the {settlementWindow} of the previous sync, whose
     * counter-token is still settling over CCIP, so no sync is performed. The report is not retried;
     * the next report proceeds once the window elapses.
     * @param lastSyncAt The timestamp of the previous sync.
     * @param settlementWindow The cooldown in force, in seconds.
     */
    event SyncSkippedCooldown(uint256 lastSyncAt, uint256 settlementWindow);

    /**
     * Emitted when a report is processed while the price feed is non-positive, stale, or timestamped
     * in the future, so a fair `minAmountOut` cannot be derived and no sync is performed. The report
     * is not retried; the next report proceeds once the feed recovers.
     */
    event SyncSkippedStalePrice();

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
     * @dev Sets the `GHO` balance below which the oracle pool is considered short of `GHO`.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `minBal` must be greater than 0.
     *
     * Emits a {MinGhoBalanceUpdated} event.
     *
     * @param minBal The new minimum `GHO` balance.
     */
    function setMinGhoBalance(uint256 minBal) external;

    /**
     * @dev Sets the `SGHO` balance below which the oracle pool is considered short of `SGHO`.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `minBal` must be greater than 0.
     *
     * Emits a {MinSGhoBalanceUpdated} event.
     *
     * @param minBal The new minimum `SGHO` balance.
     */
    function setMinSGhoBalance(uint256 minBal) external;

    /**
     * @dev Sets the amount of the surplus token sent on each sync.
     * The amount is capped at the balance the oracle pool holds of that token above the token's own
     * threshold, so it is an upper bound rather than an exact size.
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
     * @dev Sets the minimum surplus above threshold required to perform a sync. A surplus smaller
     * than this does not justify a fixed CCIP fee and is treated as no surplus. Should be no greater
     * than {syncAmount} for sensible sizing, though this is not enforced.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     * - `newAmount` must be greater than 0.
     *
     * Emits a {MinSyncAmountUpdated} event.
     *
     * @param newAmount The new minimum sync amount.
     */
    function setMinSyncAmount(uint256 newAmount) external;

    /**
     * @dev Sets the minimum delay between syncs, in seconds. After a sync, reports within this
     * window are skipped so that the in-flight counter-token can settle before another correction is
     * made. Setting it to 0 disables the cooldown and allows back-to-back syncs.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits a {SettlementWindowUpdated} event.
     *
     * @param newWindow The new settlement window, in seconds.
     */
    function setSettlementWindow(uint256 newWindow) external;

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
     * @dev Sets the price feed used to convert the synced amount to the opposite token.
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
     * @notice Returns the `GHO` balance below which the oracle pool is considered short of `GHO`.
     */
    function minGhoBalance() external view returns (uint256);

    /**
     * @notice Returns the `SGHO` balance below which the oracle pool is considered short of `SGHO`.
     */
    function minSGhoBalance() external view returns (uint256);

    /**
     * @notice Returns the maximum amount of the surplus token sent on each sync.
     */
    function syncAmount() external view returns (uint256);

    /**
     * @notice Returns the minimum surplus above threshold required to perform a sync.
     */
    function minSyncAmount() external view returns (uint256);

    /**
     * @notice Returns the address of the sGHO/GHO exchange rate feed.
     */
    function priceFeed() external view returns (address);

    /**
     * @notice Returns the maximum age tolerated for the price feed answer, in seconds.
     */
    function maxPriceStaleness() external view returns (uint256);

    /**
     * @notice Returns the minimum delay between syncs, in seconds (0 if the cooldown is disabled).
     */
    function settlementWindow() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the most recent sync, or 0 if none has occurred.
     */
    function lastSyncAt() external view returns (uint256);

    /**
     * @notice Returns the encoded CCIP fee data forwarded to `CustomSender.sync`.
     */
    function feeOtoD() external view returns (bytes memory);

    /**
     * @notice Returns the encoded extra arguments forwarded to the CCIP router.
     */
    function extraArgs() external view returns (bytes memory);

    /**
     * @dev Returns whether the oracle pool can be rebalanced right now.
     * This is the gate read by the CRE workflow to decide whether to submit a report, and is
     * re-evaluated when the resulting report is processed.
     *
     * It is true only when exactly one side of the pool is below its threshold, the other holds at
     * least {minSyncAmount} above its own threshold to send, no {settlementWindow} cooldown from a
     * prior sync is in force, and the price feed is usable (positive and within {maxPriceStaleness}).
     * The gate applies the identical checks the executor applies, so it never signals a sync that
     * {onReport} would then skip.
     *
     * @return upkeepNeeded True if a sync would be performed.
     */
    function needsUpkeep() external view returns (bool upkeepNeeded);
}
