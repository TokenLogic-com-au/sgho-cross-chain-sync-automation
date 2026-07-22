// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
 * This contract must be granted the `SYNC_ROLE` on the `CustomSender`. To cover the CCIP fee it must
 * hold enough native token when the fee is paid in native, or enough `GHO` when the fee is paid in
 * `GHO`; for the latter it grants the `CustomSender` an unlimited `GHO` allowance at construction so
 * the sender can pull the fee.
 *
 * {CUSTOM_SENDER}, {GHO} and {SGHO} are immutable and cached from the `CustomSender` at
 * construction. The thresholds ({minGhoBalance}, {minSGhoBalance}), the sync parameters
 * ({syncAmount}, {minSyncAmount}, {settlementWindow}, {feeOtoD}) and the feed configuration
 * ({priceFeed}, {maxPriceStaleness}) are owner-updatable.
 */
contract SyncKeeperConsumer is ReceiverTemplate, ISyncKeeperConsumer {
    using SafeERC20 for IERC20;

    /// @inheritdoc ISyncKeeperConsumer
    uint32 public constant MIN_PROCESS_MESSAGE_GAS = 400_000;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable CUSTOM_SENDER;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable GHO;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable SGHO;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public minGhoBalance;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public minSGhoBalance;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public syncAmount;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public minSyncAmount;

    /// @inheritdoc ISyncKeeperConsumer
    address public priceFeed;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public maxPriceStaleness;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public settlementWindow;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public lastSyncAt;

    /// @dev The encoded CCIP fee data forwarded to `CustomSender.sync`.
    bytes private _feeOtoD;

    /**
     * @dev Sets the immutable values cached from the `CustomSender`, and the initial thresholds,
     * sync parameters and feed configuration.
     *
     * Requirements:
     *
     * - `customSender_`, `priceFeed_` and `expectedAuthor_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `customSender_` must not be the zero address.
     * - `minGhoBalance_`, `minSGhoBalance_`, `syncAmount_` and `minSyncAmount_` must be greater than
     *   0.
     * - `feeOtoD_` must be at least 96 bytes long and encode a gas limit of at least
     *   {MIN_PROCESS_MESSAGE_GAS}.
     *
     * `expectedAuthor_` pins the workflow owner whose reports {onReport} accepts, so that a report
     * from another workflow sharing the same forwarder cannot trigger a sync. It is required at
     * construction; the owner can later change it, or clear it, through the inherited
     * {setExpectedAuthor}, so operators must keep an author configured to preserve this protection.
     *
     * `settlementWindow_` may be 0, which disables the cooldown and allows back-to-back syncs.
     * For sensible sizing `minSyncAmount_` should be no greater than `syncAmount_`, though this is
     * not enforced.
     *
     * @param forwarder The address of the Chainlink Forwarder contract.
     * @param expectedAuthor_ The address of the workflow owner whose reports are accepted.
     * @param customSender_ The address of the `CustomSender` contract to sync.
     * @param priceFeed_ The address of the sGHO/GHO exchange rate feed.
     * @param maxPriceStaleness_ The maximum age tolerated for the price feed answer, in seconds.
     * @param minGhoBalance_ The `GHO` balance below which the pool is considered short of `GHO`.
     * @param minSGhoBalance_ The `SGHO` balance below which the pool is considered short of `SGHO`.
     * @param syncAmount_ The maximum amount of the surplus token sent on each sync.
     * @param minSyncAmount_ The minimum surplus above threshold required to perform a sync.
     * @param settlementWindow_ The minimum delay between syncs, in seconds (0 disables it).
     * @param feeOtoD_ The encoded CCIP fee data.
     */
    constructor(
        address forwarder,
        address expectedAuthor_,
        address customSender_,
        address priceFeed_,
        uint256 maxPriceStaleness_,
        uint256 minGhoBalance_,
        uint256 minSGhoBalance_,
        uint256 syncAmount_,
        uint256 minSyncAmount_,
        uint256 settlementWindow_,
        bytes memory feeOtoD_
    ) ReceiverTemplate(forwarder) {
        require(
            priceFeed_ != address(0) && expectedAuthor_ != address(0),
            ZeroAddress()
        );

        require(
            minGhoBalance_ > 0 &&
                minSGhoBalance_ > 0 &&
                syncAmount_ > 0 &&
                minSyncAmount_ > 0,
            ZeroAmount()
        );

        _decodeAndValidateFeeOtoD(feeOtoD_);
        _setExpectedAuthor(expectedAuthor_);

        (address gho, address sGho) = _readAndValidateSender(customSender_);

        CUSTOM_SENDER = customSender_;
        GHO = gho;
        SGHO = sGho;
        priceFeed = priceFeed_;
        maxPriceStaleness = maxPriceStaleness_;
        minGhoBalance = minGhoBalance_;
        minSGhoBalance = minSGhoBalance_;
        syncAmount = syncAmount_;
        minSyncAmount = minSyncAmount_;
        settlementWindow = settlementWindow_;
        _feeOtoD = feeOtoD_;

        IERC20(gho).forceApprove(customSender_, type(uint256).max);
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
    function setMinSyncAmount(uint256 newAmount) external override onlyOwner {
        require(newAmount > 0, ZeroAmount());

        uint256 previousAmount = minSyncAmount;
        minSyncAmount = newAmount;

        emit MinSyncAmountUpdated(previousAmount, newAmount);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSettlementWindow(
        uint256 newWindow
    ) external override onlyOwner {
        uint256 previousWindow = settlementWindow;
        settlementWindow = newWindow;

        emit SettlementWindowUpdated(previousWindow, newWindow);
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
    function setPriceFeed(address newFeed) external override onlyOwner {
        require(newFeed != address(0), ZeroAddress());

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
    function needsUpkeep() external view override returns (bool) {
        if (!_validateOracle()) return false;

        (uint256 ghoBalance, uint256 sGhoBalance) = _poolBalances();
        (address surplusToken, uint256 sendable) = _evaluatePool(
            ghoBalance,
            sGhoBalance
        );
        if (surplusToken == address(0)) return false;

        if (_inCooldown()) return false;

        uint256 amount = syncAmount < sendable ? syncAmount : sendable;
        (bool ok, ) = _quote(surplusToken, amount);

        return ok;
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
     * never flip the shortage over to the side it drew from. A surplus smaller than {minSyncAmount}
     * is not worth a CCIP fee, so {_evaluatePool} reports no surplus and the call skips.
     *
     * The counter-token received in exchange returns on a later, asynchronous CCIP message that is
     * invisible to the pool balances read here. To avoid stacking corrections on a pool that has not
     * yet been refilled, a sync starts a {settlementWindow} cooldown during which further reports
     * emit {SyncSkippedCooldown} and return.
     *
     * A stale or invalid price feed is treated as another unactionable state: the call emits
     * {SyncSkippedStalePrice} and returns instead of reverting, so that the report is not retried
     * while the feed is down. This mirrors {needsUpkeep}, which applies the same checks.
     *
     * Emits a {SyncPerformed} event, or a {SyncSkippedOracleMisconfigured},
     * {SyncSkippedUpkeepNotNeeded}, {SyncSkippedNoSurplus}, {SyncSkippedCooldown} or
     * {SyncSkippedStalePrice} event if no sync is performed.
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

        if (_inCooldown()) {
            emit SyncSkippedCooldown(lastSyncAt, settlementWindow);
            return;
        }

        uint256 amount = syncAmount;
        if (amount > sendable) amount = sendable;

        (bool ok, uint256 minAmountOut) = _quote(surplusToken, amount);
        if (!ok) {
            emit SyncSkippedStalePrice();
            return;
        }

        bytes memory feeMem = _feeOtoD;
        (uint128 maxFeeOtoD, bool payInGhoOtoD, ) = _decodeAndValidateFeeOtoD(
            feeMem
        );
        uint256 nativeAmount = payInGhoOtoD ? 0 : uint256(maxFeeOtoD);

        lastSyncAt = block.timestamp;

        ICustomSender(CUSTOM_SENDER).sync{value: nativeAmount}(
            surplusToken,
            amount,
            minAmountOut,
            feeMem,
            ""
        );

        emit SyncPerformed(surplusToken, amount, minAmountOut);
    }

    /**
     * @dev Reads the `GHO` and `SGHO` tokens from the `CustomSender` and validates its configuration.
     * Extracted from the constructor so the intermediate reads stay off the constructor's stack.
     *
     * Requirements:
     *
     * - `customSender_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `customSender_` must not be the zero address.
     *
     * @param customSender_ The address of the `CustomSender` contract to sync.
     * @return The `GHO` token cached from the `CustomSender`.
     * @return The `SGHO` token cached from the `CustomSender`.
     */
    function _readAndValidateSender(
        address customSender_
    ) private view returns (address, address) {
        require(customSender_ != address(0), ZeroAddress());

        address gho = ICustomSender(customSender_).GHO();
        address sGho = ICustomSender(customSender_).SGHO();

        require(
            ICustomSender(customSender_).getOraclePool() != address(0) &&
                gho != address(0) &&
                sGho != address(0),
            ZeroAddress()
        );

        return (gho, sGho);
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
     * never draw that side through its floor and flip the shortage over to it. A surplus below
     * {minSyncAmount} does not justify a fixed CCIP fee, so it is treated as no surplus; this also
     * keeps the amount strictly positive, since {minSyncAmount} is non-zero.
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

        uint256 sendable = ghoShort
            ? sGhoBalance - minSGhoBalance
            : ghoBalance - minGhoBalance;

        if (sendable < minSyncAmount) return (address(0), 0);

        return (surplusToken, sendable);
    }

    /**
     * @dev Returns whether a prior sync is still within its {settlementWindow} cooldown.
     * The counter-token from that sync is still settling over CCIP, so the pool balances do not yet
     * reflect it. `lastSyncAt` is never in the future, so the subtraction cannot underflow, and a
     * zero {settlementWindow} makes this always false, disabling the cooldown.
     *
     * @return True if the cooldown has not yet elapsed.
     */
    function _inCooldown() private view returns (bool) {
        return block.timestamp - lastSyncAt < settlementWindow;
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
        require(fee.length >= 96, FeeOtoDTooShort(fee.length, 96));
        (uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD) = abi
            .decode(fee, (uint128, bool, uint32));

        require(
            gasLimitOtoD >= MIN_PROCESS_MESSAGE_GAS,
            InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS)
        );

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
     * The price feed is the single precondition that {needsUpkeep} cannot check by reading balances
     * alone, so it is validated here and this helper is shared by both the gate and the executor:
     * the gate calls it to avoid signalling a sync the executor would skip, and the executor calls
     * it to decide between performing the sync and emitting {SyncSkippedStalePrice}. Because both
     * callers run identical logic, the gate and the executor cannot disagree on whether a sync is
     * possible. A feed answer that is non-positive, stale, or timestamped in the future yields
     * `ok == false` rather than a revert, upholding the no-revert-so-no-retry design.
     *
     * @param tokenIn The address of the token being sent, either `GHO` or `SGHO`.
     * @param amountIn The amount of `tokenIn` being sent.
     * @return Whether the feed answer is usable (positive and within {maxPriceStaleness}).
     * @return The equivalent amount of the opposite token, or 0 when the first return is false.
     */
    function _quote(
        address tokenIn,
        uint256 amountIn
    ) private view returns (bool, uint256) {
        IAggregatorV3 feed = IAggregatorV3(priceFeed);
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();

        if (answer <= 0) return (false, 0);
        if (
            updatedAt > block.timestamp ||
            block.timestamp - updatedAt > maxPriceStaleness
        ) {
            return (false, 0);
        }

        uint256 rate = uint256(answer);
        uint256 scale = 10 ** feed.decimals();

        uint256 minAmountOut = tokenIn == GHO
            ? (amountIn * scale) / rate
            : (amountIn * rate) / scale;
        bool ok = true;

        return (ok, minAmountOut);
    }
}
