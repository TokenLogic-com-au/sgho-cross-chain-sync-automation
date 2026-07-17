// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICustomSender} from "./interfaces/ICustomSender.sol";
import {ISyncKeeperConsumer} from "./interfaces/ISyncKeeperConsumer.sol";

/**
 * @title SyncKeeperConsumer Contract
 * @dev The keeper-style consumer that rebalances the two sided oracle pool of a `CustomSender`
 * through a Chainlink CRE workflow.
 *
 * The oracle pool holds both `GHO` and `SGHO`, and user flow pushes it either way: a deposit puts
 * `GHO` in and takes `SGHO` out, a redeem does the reverse. Either side can therefore run short.
 * A sync corrects the imbalance by sending the token that is in surplus to the mainnet vault and
 * receiving the token that is short:
 *
 * - `GHO` below {minGhoBalance} and `SGHO` funded, send `SGHO` and receive `GHO`.
 * - `SGHO` below {minSGhoBalance} and `GHO` funded, send `GHO` and receive `SGHO`.
 * - both sides short, no token is in surplus, so no sync is possible and the pool needs funding.
 * - both sides funded, nothing to do.
 *
 * The workflow reads {needsUpkeep} and, when it holds, submits a signed report. The
 * {ReceiverTemplate} validation path then calls {_processReport}, which re-reads both balances,
 * re-derives which token is in surplus, and calls `CustomSender.sync`. The body of the report is
 * ignored, as every parameter of the sync is derived on chain.
 *
 * This contract must be granted the `SYNC_ROLE` on the `CustomSender`, and must hold enough native
 * token to cover the CCIP fee whenever the fee is not paid in `GHO`.
 *
 * {CUSTOM_SENDER}, {GHO} and {SGHO} are immutable and cached from the `CustomSender` at
 * construction. The thresholds ({minGhoBalance}, {minSGhoBalance}), the sync parameters
 * ({syncAmount}, {feeOtoD}, {extraArgs}) and the feed configuration ({priceFeed},
 * {maxPriceStaleness}) are owner-updatable.
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
    uint256 public override minGhoBalance;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public override minSGhoBalance;

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
     * @dev Sets the immutable values cached from the `CustomSender`, and the initial thresholds,
     * sync parameters and feed configuration.
     *
     * Requirements:
     *
     * - `customSender_` and `priceFeed_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `customSender_` must not be the zero address.
     * - `minGhoBalance_`, `minSGhoBalance_` and `syncAmount_` must be greater than 0.
     * - `feeOtoD_` must be at least 96 bytes long and encode a gas limit of at least
     *   {MIN_PROCESS_MESSAGE_GAS}.
     *
     * @param forwarder The address of the Chainlink Forwarder contract.
     * @param customSender_ The address of the `CustomSender` contract to sync.
     * @param priceFeed_ The address of the sGHO/GHO exchange rate feed.
     * @param maxPriceStaleness_ The maximum age tolerated for the price feed answer, in seconds.
     * @param minGhoBalance_ The `GHO` balance below which the pool is considered short of `GHO`.
     * @param minSGhoBalance_ The `SGHO` balance below which the pool is considered short of `SGHO`.
     * @param syncAmount_ The maximum amount of the surplus token sent on each sync.
     * @param feeOtoD_ The encoded CCIP fee data.
     * @param extraArgs_ The encoded extra arguments forwarded to the CCIP router.
     */
    constructor(
        address forwarder,
        address customSender_,
        address priceFeed_,
        uint256 maxPriceStaleness_,
        uint256 minGhoBalance_,
        uint256 minSGhoBalance_,
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
        address sGho = ICustomSender(customSender_).SGHO();

        require(
            pool != address(0) && gho != address(0) && sGho != address(0),
            ZeroAddress()
        );

        // A zero threshold would mean that side is never considered short, silently disabling half
        // of the rebalance.
        require(
            minGhoBalance_ > 0 && minSGhoBalance_ > 0 && syncAmount_ > 0,
            ZeroAmount()
        );

        _decodeAndValidateFeeOtoD(feeOtoD_);

        CUSTOM_SENDER = customSender_;
        GHO = gho;
        SGHO = sGho;
        priceFeed = priceFeed_;
        maxPriceStaleness = maxPriceStaleness_;
        minGhoBalance = minGhoBalance_;
        minSGhoBalance = minSGhoBalance_;
        syncAmount = syncAmount_;
        _feeOtoD = feeOtoD_;
        _extraArgs = extraArgs_;
    }

    /**
     * @dev Receives the native token used to pay the CCIP fee when it is not paid in `GHO`, and the
     * excess refunded by the `CustomSender` after each sync.
     */
    receive() external payable {}

    /// @inheritdoc ISyncKeeperConsumer
    function setMinGhoBalance(uint256 minBal) external override onlyOwner {
        require(minBal > 0, ZeroAmount());

        uint256 previousMinBal = minGhoBalance;
        minGhoBalance = minBal;

        emit MinGhoBalanceUpdated(previousMinBal, minBal);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMinSGhoBalance(uint256 minBal) external override onlyOwner {
        require(minBal > 0, ZeroAmount());

        uint256 previousMinBal = minSGhoBalance;
        minSGhoBalance = minBal;

        emit MinSGhoBalanceUpdated(previousMinBal, minBal);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSyncAmount(uint256 newAmount) external override onlyOwner {
        require(newAmount > 0, ZeroAmount());

        uint256 previousAmount = syncAmount;
        syncAmount = newAmount;

        emit SyncAmountUpdated(previousAmount, newAmount);
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

        address previousFeed = priceFeed;
        priceFeed = newFeed;

        emit PriceFeedUpdated(previousFeed, newFeed);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMaxPriceStaleness(
        uint256 newStaleness
    ) external override onlyOwner {
        uint256 previousStaleness = maxPriceStaleness;
        maxPriceStaleness = newStaleness;

        emit MaxPriceStalenessUpdated(previousStaleness, newStaleness);
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
    function needsUpkeep() external view override returns (bool) {
        if (!_validateOracle()) return false;

        (uint256 ghoBalance, uint256 sGhoBalance) = _poolBalances();
        (address surplusToken, ) = _evaluatePool(ghoBalance, sGhoBalance);

        return surplusToken != address(0);
    }

    /**
     * @dev Processes a validated report by rebalancing the oracle pool.
     * Both balances are re-read and the surplus token re-derived here rather than trusted from the
     * report, as the pool may have moved between the workflow read and the execution of the report.
     * When no sync is possible the call is a no-op that emits the reason instead of reverting, so
     * that the report is not retried. The body of the report is ignored.
     *
     * The amount sent is {syncAmount} capped at what the surplus side holds above its own
     * threshold, so that `OraclePool.pull` can never revert for insufficient balance and a sync can
     * never flip the shortage over to the side it drew from.
     *
     * Emits a {SyncPerformed} event, or a {SyncSkippedOracleMisconfigured},
     * {SyncSkippedUpkeepNotNeeded} or {SyncSkippedNoSurplus} event if no sync is performed.
     */
    function _processReport(bytes calldata /* report */) internal override {
        if (!_validateOracle()) {
            emit SyncSkippedOracleMisconfigured();
            return;
        }

        (uint256 ghoBalance, uint256 sGhoBalance) = _poolBalances();
        (address surplusToken, uint256 sendable) = _evaluatePool(
            ghoBalance,
            sGhoBalance
        );

        if (surplusToken == address(0)) {
            if (ghoBalance < minGhoBalance || sGhoBalance < minSGhoBalance) {
                emit SyncSkippedNoSurplus(ghoBalance, sGhoBalance);
            } else {
                emit SyncSkippedUpkeepNotNeeded(ghoBalance, sGhoBalance);
            }
            return;
        }

        uint256 amount = syncAmount;
        if (amount > sendable) amount = sendable;

        uint256 minAmountOut = _computeMinAmountOut(surplusToken, amount);

        bytes memory feeMem = _feeOtoD;
        (uint128 maxFeeOtoD, bool payInGhoOtoD, ) = _decodeAndValidateFeeOtoD(
            feeMem
        );
        uint256 nativeAmount = payInGhoOtoD ? 0 : uint256(maxFeeOtoD);

        ICustomSender(CUSTOM_SENDER).sync{value: nativeAmount}(
            surplusToken,
            amount,
            minAmountOut,
            feeMem,
            _extraArgs
        );

        emit SyncPerformed(surplusToken, amount, minAmountOut);
    }

    /**
     * @dev Returns whether the oracle pool is set on the `CustomSender`.
     * The oracle pool can be unset by the `CustomSender` admin at any time, so it is checked before
     * every read of the pool balances.
     *
     * @return True if the oracle pool is set.
     */
    function _validateOracle() internal view returns (bool) {
        return ICustomSender(CUSTOM_SENDER).getOraclePool() != address(0);
    }

    /**
     * @dev Returns the token to send to rebalance the pool and how much of it may be sent.
     *
     * A sync is only possible when exactly one side is below its threshold. When both sides are
     * short there is nothing in surplus to send, and sending either one would deepen the other's
     * deficit. When neither is short there is nothing to correct.
     *
     * Only the balance the surplus side holds *above its own threshold* may be sent, so a sync can
     * never draw that side through its floor and flip the shortage over to it. A side sitting
     * exactly on its threshold therefore has nothing to send, and no sync is possible.
     *
     * @param ghoBalance The current `GHO` balance of the oracle pool.
     * @param sGhoBalance The current `SGHO` balance of the oracle pool.
     * @return The address of the token in surplus, or `address(0)` if no sync is possible.
     * @return The amount of the surplus token held above its own threshold.
     */
    function _evaluatePool(
        uint256 ghoBalance,
        uint256 sGhoBalance
    ) private view returns (address, uint256) {
        bool ghoShort = ghoBalance < minGhoBalance;
        bool sGhoShort = sGhoBalance < minSGhoBalance;

        if (ghoShort == sGhoShort) return (address(0), 0);

        address surplusToken = ghoShort ? SGHO : GHO;

        // The surplus side is at or above its own threshold, so neither branch can underflow.
        uint256 sendable = ghoShort
            ? sGhoBalance - minSGhoBalance
            : ghoBalance - minGhoBalance;

        if (sendable == 0) return (address(0), 0);

        return (surplusToken, sendable);
    }

    /**
     * @dev Returns both token balances of the oracle pool of the `CustomSender`.
     *
     * Requirements:
     *
     * - The oracle pool must be set, as checked by {_validateOracle}.
     *
     * @return The `GHO` balance of the oracle pool.
     * @return The `SGHO` balance of the oracle pool.
     */
    function _poolBalances() private view returns (uint256, uint256) {
        address pool = ICustomSender(CUSTOM_SENDER).getOraclePool();

        return (IERC20(GHO).balanceOf(pool), IERC20(SGHO).balanceOf(pool));
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
     * @return The maximum CCIP fee allowed for the origin to destination message.
     * @return Whether the fee is paid in `GHO` (`true`) or in native token (`false`).
     * @return The gas limit for executing the message on the destination chain.
     */
    function _decodeAndValidateFeeOtoD(
        bytes memory fee
    ) private pure returns (uint128, bool, uint32) {
        if (fee.length < 96) revert FeeOtoDTooShort(fee.length, 96);
        (uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD) = abi
            .decode(fee, (uint128, bool, uint32));

        if (gasLimitOtoD < MIN_PROCESS_MESSAGE_GAS) {
            revert InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS);
        }

        return (maxFeeOtoD, payInGhoOtoD, gasLimitOtoD);
    }

    /**
     * @dev Converts `amountIn` of `tokenIn` to the amount of the opposite token expected in return,
     * using the sGHO/GHO exchange rate feed.
     *
     * The feed answer is the amount of `GHO` assets per 1 `SGHO` share, scaled by
     * `10 ** feed.decimals()`, so the conversion runs in opposite directions per token: sending
     * `GHO` divides by the rate to get `SGHO` shares, sending `SGHO` multiplies by it to get `GHO`
     * assets.
     *
     * Requirements:
     *
     * - The feed answer must be greater than 0.
     * - The feed must have been updated at most {maxPriceStaleness} seconds ago.
     *
     * @param tokenIn The address of the token being sent, either `GHO` or `SGHO`.
     * @param amountIn The amount of `tokenIn` being sent.
     * @return The equivalent amount of the opposite token.
     */
    function _computeMinAmountOut(
        address tokenIn,
        uint256 amountIn
    ) private view returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(priceFeed);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();

        require(answer > 0, InvalidPrice(answer));
        require(
            block.timestamp - updatedAt <= maxPriceStaleness,
            StalePriceFeed(updatedAt, maxPriceStaleness)
        );

        uint256 rate = uint256(answer);
        uint256 scale = 10 ** feed.decimals();

        return
            tokenIn == GHO
                ? (amountIn * scale) / rate
                : (amountIn * rate) / scale;
    }
}
