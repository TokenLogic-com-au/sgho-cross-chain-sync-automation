// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICustomSender} from "./interfaces/ICustomSender.sol";
import {ISyncKeeperConsumer} from "./interfaces/ISyncKeeperConsumer.sol";

/**
 * @title SyncKeeperConsumer Contract
 * @dev The keeper-style consumer that tops up the oracle pool of a `CustomSender` through a
 * Chainlink CRE workflow.
 *
 * The workflow reads {needsUpkeep}, which compares the `GHO` balance of the oracle pool to
 * {minOraclePoolBalance}. When the pool is short, the workflow submits a signed report, and the
 * {ReceiverTemplate} validation path calls {_processReport}, which re-checks the gate, derives
 * `minAmountOut` from the sGHO/GHO exchange rate feed, and calls `CustomSender.sync`. The body of
 * the report is ignored, as every parameter of the sync is held by this contract.
 *
 * This contract must be granted the `SYNC_ROLE` on the `CustomSender`, and must hold enough native
 * token to cover the CCIP fee whenever the fee is not paid in `GHO`.
 *
 * {CUSTOM_SENDER}, {GHO} and {SGHO} are immutable and cached from the `CustomSender` at
 * construction. The sync parameters ({syncAmount}, {feeOtoD}, {extraArgs}) and the feed
 * configuration ({priceFeed}, {maxPriceStaleness}) are owner-updatable.
 */
contract SyncKeeperConsumer is ReceiverTemplate, ISyncKeeperConsumer {
    /// @inheritdoc ISyncKeeperConsumer
    uint32 public constant override MIN_PROCESS_MESSAGE_GAS = 400_000;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable override CUSTOM_SENDER;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable override GHO;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable override SGHO;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public override minOraclePoolBalance;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public override syncAmount;

    /// @inheritdoc ISyncKeeperConsumer
    address public override priceFeed;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public override maxPriceStaleness;

    /// @dev The encoded CCIP fee data forwarded to `CustomSender.sync`.
    bytes private _feeOtoD;

    /// @dev The encoded extra arguments forwarded to the CCIP router.
    bytes private _extraArgs;

    /**
     * @dev Sets the immutable values cached from the `CustomSender`, and the initial sync and feed
     * configuration.
     *
     * Requirements:
     *
     * - `customSender_` and `priceFeed_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `customSender_` must not be the zero address.
     * - `syncAmount_` must be greater than 0.
     * - `feeOtoD_` must be at least 96 bytes long and encode a gas limit of at least
     *   {MIN_PROCESS_MESSAGE_GAS}.
     *
     * @param forwarder The address of the Chainlink Forwarder contract.
     * @param customSender_ The address of the `CustomSender` contract to sync.
     * @param priceFeed_ The address of the sGHO/GHO exchange rate feed.
     * @param maxPriceStaleness_ The maximum age tolerated for the price feed answer, in seconds.
     * @param minOraclePoolBalance_ The oracle pool balance below which a sync is performed.
     * @param syncAmount_ The amount of `GHO` sent to the oracle pool on each sync.
     * @param feeOtoD_ The encoded CCIP fee data.
     * @param extraArgs_ The encoded extra arguments forwarded to the CCIP router.
     */
    constructor(
        address forwarder,
        address customSender_,
        address priceFeed_,
        uint256 maxPriceStaleness_,
        uint256 minOraclePoolBalance_,
        uint256 syncAmount_,
        bytes memory feeOtoD_,
        bytes memory extraArgs_
    ) ReceiverTemplate(forwarder) {
        require(
            customSender_ != address(0) && priceFeed_ != address(0),
            ZeroAddress()
        );

        address pool = ICustomSender(customSender_).getOraclePool();
        address gho = ICustomSender(customSender_).GHO();
        address sgho = ICustomSender(customSender_).SGHO();

        require(
            pool != address(0) && gho != address(0) && sgho != address(0),
            ZeroAddress()
        );

        require(syncAmount_ > 0, ZeroAmount());

        _decodeAndValidateFeeOtoD(feeOtoD_);

        CUSTOM_SENDER = customSender_;
        GHO = gho;
        SGHO = sgho;
        priceFeed = priceFeed_;
        maxPriceStaleness = maxPriceStaleness_;
        minOraclePoolBalance = minOraclePoolBalance_;
        syncAmount = syncAmount_;
        _feeOtoD = feeOtoD_;
        _extraArgs = extraArgs_;
    }

    /**
     * @dev Receives the native token used to pay the CCIP fee when it is not paid in `GHO`.
     */
    receive() external payable {}

    /// @inheritdoc ISyncKeeperConsumer
    function setMinOraclePoolBalance(
        uint256 minBal
    ) external override onlyOwner {
        require(minBal > 0, ZeroAmount());
        minOraclePoolBalance = minBal;

        emit MinOraclePoolBalanceUpdated(minOraclePoolBalance, minBal);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSyncAmount(uint256 newAmount) external override onlyOwner {
        require(newAmount > 0, ZeroAmount());
        syncAmount = newAmount;

        emit SyncAmountUpdated(syncAmount, newAmount);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setFeeOtoD(bytes calldata newFee) external override onlyOwner {
        bytes memory feeMem = newFee;
        (
            uint128 maxFeeOtoD,
            bool payInGhoOtoD,
            uint32 gasLimitOtoD
        ) = _decodeAndValidateFeeOtoD(feeMem);

        _feeOtoD = newFee;

        emit FeeOtoDUpdated(maxFeeOtoD, payInGhoOtoD, gasLimitOtoD);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setExtraArgs(
        bytes calldata newExtraArgs
    ) external override onlyOwner {
        _extraArgs = newExtraArgs;

        emit ExtraArgsUpdated(newExtraArgs);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setPriceFeed(address newFeed) external override onlyOwner {
        if (newFeed == address(0)) revert ZeroAddress();
        priceFeed = newFeed;

        emit PriceFeedUpdated(priceFeed, newFeed);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMaxPriceStaleness(
        uint256 newStaleness
    ) external override onlyOwner {
        maxPriceStaleness = newStaleness;

        emit MaxPriceStalenessUpdated(maxPriceStaleness, newStaleness);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function feeOtoD() external view override returns (bytes memory) {
        return _feeOtoD;
    }

    /// @inheritdoc ISyncKeeperConsumer
    function extraArgs() external view override returns (bytes memory) {
        return _extraArgs;
    }

    /// @inheritdoc ISyncKeeperConsumer
    function needsUpkeep() external view override returns (bool upkeepNeeded) {
        if (!_validateOracle()) return false;
        upkeepNeeded = _needsUpkeep();
    }

    /**
     * @dev Processes a validated report by syncing the oracle pool.
     * The gate is re-checked here rather than trusted from the report, as the state may have moved
     * between the workflow read and the execution of the report. When the gate no longer holds, the
     * call is a no-op that emits the reason instead of reverting, so that the report is not retried.
     * The body of the report is ignored.
     *
     * Emits a {SyncSkippedOracleMisconfigured} or {SyncSkippedUpkeepNotNeeded} event if no sync is
     * performed.
     */
    function _processReport(bytes calldata /* report */) internal override {
        if (!_validateOracle()) {
            emit SyncSkippedOracleMisconfigured();
            return;
        }

        if (!_needsUpkeep()) {
            emit SyncSkippedUpkeepNotNeeded(
                _oraclePoolTokenBalance(),
                minOraclePoolBalance
            );
            return;
        }

        bytes memory feeMem = _feeOtoD;
        (uint128 maxFeeOtoD, bool payInGhoOtoD, ) = _decodeAndValidateFeeOtoD(
            feeMem
        );

        uint256 nativeAmount = payInGhoOtoD ? 0 : uint256(maxFeeOtoD);
        uint256 amount = syncAmount;
        uint256 minAmountOut = _computeMinAmountOut(amount);

        ICustomSender(CUSTOM_SENDER).sync{value: nativeAmount}(
            GHO,
            amount,
            minAmountOut,
            feeMem,
            _extraArgs
        );
    }

    /**
     * @dev Returns whether the oracle pool is set on the `CustomSender`.
     * The oracle pool can be unset by the `CustomSender` admin at any time, so it is checked before
     * every read of the pool balance.
     *
     * @return True if the oracle pool is set.
     */
    function _validateOracle() internal view returns (bool) {
        return ICustomSender(CUSTOM_SENDER).getOraclePool() != address(0);
    }

    /**
     * @dev Returns whether the oracle pool is funded below {minOraclePoolBalance}.
     *
     * Requirements:
     *
     * - The oracle pool must be set, as checked by {_validateOracle}.
     *
     * @return True if the `GHO` balance of the oracle pool is strictly below
     * {minOraclePoolBalance}.
     */
    function _needsUpkeep() internal view returns (bool) {
        return _oraclePoolTokenBalance() < minOraclePoolBalance;
    }

    /**
     * @dev Decodes and validates the encoded CCIP fee data.
     *
     * Requirements:
     *
     * - `fee` must be at least 96 bytes long, the length of the three ABI words it decodes to.
     * - The gas limit encoded in `fee` must be at least {MIN_PROCESS_MESSAGE_GAS}.
     *
     * @param fee The encoded CCIP fee data.
     * @return maxFeeOtoD The maximum CCIP fee allowed for the origin to destination message.
     * @return payInGhoOtoD Whether the fee is paid in `GHO` (`true`) or in native token (`false`).
     * @return gasLimitOtoD The gas limit for executing the message on the destination chain.
     */
    function _decodeAndValidateFeeOtoD(
        bytes memory fee
    )
        private
        pure
        returns (uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD)
    {
        if (fee.length < 96) revert FeeOtoDTooShort(fee.length, 96);
        (maxFeeOtoD, payInGhoOtoD, gasLimitOtoD) = abi.decode(
            fee,
            (uint128, bool, uint32)
        );

        if (gasLimitOtoD < MIN_PROCESS_MESSAGE_GAS) {
            revert InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS);
        }
    }

    /**
     * @dev Returns the current `GHO` balance of the oracle pool of the `CustomSender`.
     * @return The `GHO` balance of the oracle pool.
     */
    function _oraclePoolTokenBalance() private view returns (uint256) {
        address pool = ICustomSender(CUSTOM_SENDER).getOraclePool();
        return IERC20(GHO).balanceOf(pool);
    }

    /**
     * @dev Converts `ghoAmount` to its sGHO equivalent using the sGHO/GHO exchange rate feed.
     * The feed answer is treated as the amount of `GHO` assets per 1 sGHO share, scaled by
     * `10 ** feed.decimals()`, so the result is `ghoAmount * 10 ** feedDecimals / answer`.
     *
     * Requirements:
     *
     * - The feed answer must be greater than 0.
     * - The feed must have been updated at most {maxPriceStaleness} seconds ago.
     *
     * @param ghoAmount The amount of `GHO` to convert.
     * @return The equivalent amount of sGHO.
     */
    function _computeMinAmountOut(
        uint256 ghoAmount
    ) private view returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(priceFeed);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();

        require(answer > 0, InvalidPrice(answer));
        require(
            block.timestamp - updatedAt <= maxPriceStaleness,
            StalePriceFeed(updatedAt, maxPriceStaleness)
        );

        return (ghoAmount * (10 ** feed.decimals())) / uint256(answer);
    }
}
