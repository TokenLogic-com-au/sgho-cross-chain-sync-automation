// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {ExtraArgsCodec} from "./libraries/ExtraArgsCodec.sol";
import {FeeCodec} from "./libraries/FeeCodec.sol";
import {FinalityCodec} from "./libraries/FinalityCodec.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ISwapHandler} from "./interfaces/ISwapHandler.sol";
import {ISyncKeeperConsumer} from "./interfaces/ISyncKeeperConsumer.sol";

/**
 * @title SyncKeeperConsumer Contract
 * @dev The keeper-style consumer that rebalances the two sided oracle pool of a `SwapHandler`
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
 * re-derives which token is in surplus, and calls `SwapHandler.sync`. The body of the report is
 * ignored, as every parameter of the sync is derived on chain.
 *
 * This contract must be granted the `SYNC_ROLE` on the `SwapHandler`. To cover the CCIP fee it must
 * hold enough native token when the fee is paid in native, or enough `GHO` when the fee is paid in
 * `GHO`; for the latter it grants the `SwapHandler` an unlimited `GHO` allowance at construction so
 * the sender can pull the fee.
 *
 * {SWAP_HANDLER}, {GHO} and {SGHO} are immutable and cached from the `SwapHandler` at
 * construction. The thresholds ({minGhoBalance}, {minSGhoBalance}), the sync parameters
 * ({syncAmount}, {minSyncAmount}, {settlementWindow}, {feeData}) and the feed configuration
 * ({priceFeed}, {maxPriceStaleness}) are owner-updatable.
 */
contract SyncKeeperConsumer is ReceiverTemplate, ISyncKeeperConsumer {
    using SafeERC20 for IERC20;

    /// @inheritdoc ISyncKeeperConsumer
    uint32 public constant MIN_PROCESS_MESSAGE_GAS = 400_000;

    /// @dev Basis-point denominator representing 100%.
    uint256 private constant MAX_BPS = 10_000;

    /// @inheritdoc ISyncKeeperConsumer
    address public immutable SWAP_HANDLER;

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
    uint256 public slippageToleranceBps;

    /// @inheritdoc ISyncKeeperConsumer
    uint256 public lastSyncAt;

    /// @dev The encoded CCIP fee data forwarded to `SwapHandler.sync`.
    bytes private _feeData;

    /// @dev The encoded extra arguments forwarded to the CCIP router.
    bytes private _extraArgs = "";

    /**
     * @dev Sets the immutable values cached from the `SwapHandler`, and the initial thresholds,
     * sync parameters and feed configuration.
     *
     * Requirements:
     *
     * - `swapHandler_`, `priceFeed_` and `expectedAuthor_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `swapHandler_` must not be the zero address.
     * - `minGhoBalance_`, `minSGhoBalance_`, `syncAmount_` and `minSyncAmount_` must be greater than
     *   0.
     * - `feeData_` must be a {FeeCodec}-encoded CCIP fee (at least 21 bytes) whose gas limit is at
     *   least {MIN_PROCESS_MESSAGE_GAS}.
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
     * `settlementWindow_` may be 0, which disables the cooldown and allows back-to-back syncs.
     * For sensible sizing `minSyncAmount_` should be no greater than `syncAmount_`, though this is
     * not enforced.
     *
     * @param forwarder The address of the Chainlink Forwarder contract.
     * @param expectedAuthor_ The address of the workflow owner whose reports are accepted.
     * @param swapHandler_ The address of the `SwapHandler` contract to sync.
     * @param priceFeed_ The address of the sGHO/GHO exchange rate feed.
     * @param maxPriceStaleness_ The maximum age tolerated for the price feed answer, in seconds.
     * @param minGhoBalance_ The `GHO` balance below which the pool is considered short of `GHO`.
     * @param minSGhoBalance_ The `SGHO` balance below which the pool is considered short of `SGHO`.
     * @param syncAmount_ The maximum amount of the surplus token sent on each sync.
     * @param minSyncAmount_ The minimum surplus above threshold required to perform a sync.
     * @param settlementWindow_ The minimum delay between syncs, in seconds (0 disables it).
     * @param feeData_ The encoded CCIP fee data.
     */
    constructor(
        address forwarder,
        address expectedAuthor_,
        address swapHandler_,
        address priceFeed_,
        uint256 maxPriceStaleness_,
        uint256 minGhoBalance_,
        uint256 minSGhoBalance_,
        uint256 syncAmount_,
        uint256 minSyncAmount_,
        uint256 settlementWindow_,
        bytes memory feeData_
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

        _decodeAndValidateFeeData(feeData_);
        _setExpectedAuthor(expectedAuthor_);

        (address gho, address sGho) = _readAndValidateSender(swapHandler_);

        SWAP_HANDLER = swapHandler_;
        GHO = gho;
        SGHO = sGho;
        priceFeed = priceFeed_;
        maxPriceStaleness = maxPriceStaleness_;
        minGhoBalance = minGhoBalance_;
        minSGhoBalance = minSGhoBalance_;
        syncAmount = syncAmount_;
        minSyncAmount = minSyncAmount_;
        settlementWindow = settlementWindow_;
        slippageToleranceBps = 200; // 2% default
        _feeData = feeData_;

        IERC20(gho).forceApprove(swapHandler_, type(uint256).max);
    }

    /**
     * @dev Receives the native token used to pay the CCIP fee when it is not paid in `GHO`, and the
     * excess refunded by the `SwapHandler` after each sync.
     */
    receive() external payable {}

    /// @inheritdoc ISyncKeeperConsumer
    function setExtraArgs(
        uint32 gasLimit,
        bytes4 finalityConfig
    ) external onlyOwner {
        require(gasLimit >= MIN_PROCESS_MESSAGE_GAS, InvalidGasLimit());
        FinalityCodec._validateRequestedFinality(finalityConfig);

        _extraArgs = ExtraArgsCodec._getBasicEncodedExtraArgsV3(
            gasLimit,
            finalityConfig
        );
        emit ExtraArgsUpdated(_extraArgs);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMinGhoBalance(uint256 minBal) external onlyOwner {
        require(minBal > 0, ZeroAmount());

        uint256 previousMinBal = minGhoBalance;
        minGhoBalance = minBal;

        emit MinGhoBalanceUpdated(previousMinBal, minBal);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMinSGhoBalance(uint256 minBal) external onlyOwner {
        require(minBal > 0, ZeroAmount());

        uint256 previousMinBal = minSGhoBalance;
        minSGhoBalance = minBal;

        emit MinSGhoBalanceUpdated(previousMinBal, minBal);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSyncAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, ZeroAmount());

        uint256 previousAmount = syncAmount;
        syncAmount = newAmount;

        emit SyncAmountUpdated(previousAmount, newAmount);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMinSyncAmount(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, ZeroAmount());

        uint256 previousAmount = minSyncAmount;
        minSyncAmount = newAmount;

        emit MinSyncAmountUpdated(previousAmount, newAmount);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSettlementWindow(uint256 newWindow) external onlyOwner {
        uint256 previousWindow = settlementWindow;
        settlementWindow = newWindow;

        emit SettlementWindowUpdated(previousWindow, newWindow);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setFeeData(
        uint128 maxFee,
        bool payInGho,
        uint32 gasLimit
    ) external onlyOwner {
        require(
            gasLimit >= MIN_PROCESS_MESSAGE_GAS,
            InsufficientGasLimit(gasLimit, MIN_PROCESS_MESSAGE_GAS)
        );

        _feeData = FeeCodec.encodeCCIP(maxFee, payInGho, gasLimit);

        emit FeeDataUpdated(maxFee, payInGho, gasLimit);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setPriceFeed(address newFeed) external onlyOwner {
        require(newFeed != address(0), ZeroAddress());

        address previousFeed = priceFeed;
        priceFeed = newFeed;

        emit PriceFeedUpdated(previousFeed, newFeed);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setMaxPriceStaleness(uint256 newStaleness) external onlyOwner {
        uint256 previousStaleness = maxPriceStaleness;
        maxPriceStaleness = newStaleness;

        emit MaxPriceStalenessUpdated(previousStaleness, newStaleness);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function setSlippageTolerance(uint256 newToleranceBps) external onlyOwner {
        require(newToleranceBps <= MAX_BPS, InvalidSlippageTolerance());

        uint256 previousTolerance = slippageToleranceBps;
        slippageToleranceBps = newToleranceBps;

        emit SlippageToleranceUpdated(previousTolerance, newToleranceBps);
    }

    /// @inheritdoc ISyncKeeperConsumer
    function feeData() external view returns (bytes memory) {
        return _feeData;
    }

    /// @inheritdoc ISyncKeeperConsumer
    function extraArgs() external view returns (bytes memory) {
        return _extraArgs;
    }

    /// @inheritdoc ISyncKeeperConsumer
    function needsUpkeep() external view returns (bool) {
        if (!_validateOracle()) return false;

        (uint256 ghoBalance, uint256 sGhoBalance) = _poolBalances();
        (address surplusToken, uint256 sendable) = _evaluatePool(
            ghoBalance,
            sGhoBalance
        );
        if (surplusToken == address(0)) return false;

        // The previous sync's return leg is still settling over CCIP during the window, so signal
        // no upkeep to avoid stacking corrections on a not-yet-refilled pool.
        if (_inCooldown()) return false;

        // Apply the same price gate the executor applies, so the gate never signals a sync that
        // {_processReport} would skip on a stale or invalid feed.
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

        bytes memory feeMem = _feeData;
        (uint128 maxFee, bool payInGho, ) = _decodeAndValidateFeeData(feeMem);
        uint256 nativeAmount = payInGho ? 0 : uint256(maxFee);

        lastSyncAt = block.timestamp;

        ISwapHandler(SWAP_HANDLER).sync{value: nativeAmount}(
            surplusToken,
            amount,
            minAmountOut,
            feeMem,
            _extraArgs
        );

        emit SyncPerformed(surplusToken, amount, minAmountOut);
    }

    /**
     * @dev Reads the `GHO` and `SGHO` tokens from the `SwapHandler` and validates its configuration.
     * Extracted from the constructor so the intermediate reads stay off the constructor's stack.
     *
     * Requirements:
     *
     * - `swapHandler_` must not be the zero address.
     * - The oracle pool, `GHO` and `SGHO` of `swapHandler_` must not be the zero address.
     *
     * @param swapHandler_ The address of the `SwapHandler` contract to sync.
     * @return The `GHO` token cached from the `SwapHandler`.
     * @return The `SGHO` token cached from the `SwapHandler`.
     */
    function _readAndValidateSender(
        address swapHandler_
    ) private view returns (address, address) {
        require(swapHandler_ != address(0), ZeroAddress());

        address gho = ISwapHandler(swapHandler_).GHO();
        address sGho = ISwapHandler(swapHandler_).SGHO();

        require(
            ISwapHandler(swapHandler_).getOraclePool() != address(0) &&
                gho != address(0) &&
                sGho != address(0),
            ZeroAddress()
        );

        return (gho, sGho);
    }

    /**
     * @dev Returns whether the oracle pool is set on the `SwapHandler`.
     * The oracle pool can be unset by the `SwapHandler` admin at any time, so it is checked before
     * every read of the pool balances.
     *
     * @return True if the oracle pool is set.
     */
    function _validateOracle() internal view returns (bool) {
        return ISwapHandler(SWAP_HANDLER).getOraclePool() != address(0);
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
     * @dev Returns both token balances of the oracle pool of the `SwapHandler`.
     *
     * Requirements:
     *
     * - The oracle pool must be set, as checked by {_validateOracle}.
     *
     * @return The `GHO` balance of the oracle pool.
     * @return The `SGHO` balance of the oracle pool.
     */
    function _poolBalances() private view returns (uint256, uint256) {
        address pool = ISwapHandler(SWAP_HANDLER).getOraclePool();

        return (IERC20(GHO).balanceOf(pool), IERC20(SGHO).balanceOf(pool));
    }

    /**
     * @dev Decodes and validates the {FeeCodec}-encoded CCIP fee data.
     *
     * Requirements:
     *
     * - `fee` must be a {FeeCodec}-encoded CCIP fee (at least 21 bytes).
     * - The gas limit encoded in `fee` must be at least {MIN_PROCESS_MESSAGE_GAS}.
     *
     * @param fee The encoded CCIP fee data.
     * @return The maximum CCIP fee allowed for the origin to destination message.
     * @return Whether the fee is paid in `GHO` (`true`) or in native token (`false`).
     * @return The gas limit for executing the message on the destination chain.
     */
    function _decodeAndValidateFeeData(
        bytes memory fee
    ) private pure returns (uint128, bool, uint32) {
        (uint128 maxFee, bool payInGho, uint32 gasLimit) = FeeCodec
            .decodeCCIPMemory(fee);

        require(
            gasLimit >= MIN_PROCESS_MESSAGE_GAS,
            InsufficientGasLimit(gasLimit, MIN_PROCESS_MESSAGE_GAS)
        );

        return (maxFee, payInGho, gasLimit);
    }

    /**
     * @dev Converts `amountIn` of `tokenIn` to the amount of the opposite token expected in return,
     * using the sGHO/GHO exchange rate feed.
     *
     * The feed answer is the amount of `GHO` assets per 1 `SGHO` share, scaled by
     * `10 ** feed.decimals()`, so the conversion runs in opposite directions per token: sending
     * `GHO` divides by the rate to get `SGHO` shares, sending `SGHO` multiplies by it to get `GHO`
     * assets. The result is then reduced by {slippageToleranceBps}: the `SGHO` vault is an ERC4626
     * whose exchange rate keeps accruing while the sync settles over CCIP, so the mainnet vault mints
     * against a higher rate than quoted here; without this buffer the `GHO`-to-`SGHO` deposit leg
     * would revert with `MinimumOutputNotMet` and force a cross-chain refund.
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
     * @return The equivalent amount of the opposite token less {slippageToleranceBps}, or 0 when the
     *         first return is false.
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

        uint256 expectedOut = tokenIn == GHO
            ? (amountIn * scale) / rate
            : (amountIn * rate) / scale;

        uint256 minAmountOut = (expectedOut *
            (MAX_BPS - slippageToleranceBps)) / MAX_BPS;

        return (true, minAmountOut);
    }
}
