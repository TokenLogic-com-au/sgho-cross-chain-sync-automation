// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {ICustomSender} from "./interfaces/ICustomSender.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SyncKeeperConsumer
/// @notice CRE keeper pattern: `needsUpkeep()` reads oracle-pool GHO balance from `CustomSender`;
///         `_processReport` derives `minAmountOut` from the sGHO/GHO Chainlink feed and calls
///         `ICustomSender.sync` (grant `SYNC_ROLE` here). Always syncs GHO.
/// @dev Vendored `ReceiverTemplate` from Chainlink CRE templates. `GHO`/`SGHO`/`customSender` are
///      immutable (cached from the sender at construction); sync params (`syncAmount`, `feeOtoD`,
///      `extraArgs`) and feed config (`priceFeed`, `maxPriceStaleness`) are owner-updatable. The
///      CRE report body is ignored.
contract SyncKeeperConsumer is ReceiverTemplate {
    uint32 public constant MIN_PROCESS_MESSAGE_GAS = 75_000;

    error ZeroAddress();
    error ZeroSyncAmount();
    error FeeOtoDTooShort(uint256 length, uint256 minLength);
    error InsufficientGasLimit(uint32 gasLimit, uint32 minGas);
    error InvalidPrice(int256 answer);
    error StalePriceFeed(uint256 updatedAt, uint256 maxStaleness);

    address public immutable customSender;
    address public immutable GHO;
    address public immutable SGHO;

    uint256 public minOraclePoolBalance;
    uint256 public syncAmount;

    address public priceFeed;
    uint256 public maxPriceStaleness;

    bytes private s_feeOtoD;
    bytes private s_extraArgs;

    event MinOraclePoolBalanceUpdated(uint256 previous, uint256 current);
    event SyncAmountUpdated(uint256 previous, uint256 current);
    event FeeOtoDUpdated(uint128 indexed maxFeeOtoD, bool indexed payInGhoOtoD, uint32 indexed gasLimitOtoD);
    event ExtraArgsUpdated(bytes extraArgs);
    event PriceFeedUpdated(address indexed previous, address indexed current);
    event MaxPriceStalenessUpdated(uint256 previous, uint256 current);
    event SyncSkippedOracleMisconfigured();
    event SyncSkippedUpkeepNotNeeded(uint256 poolBalance, uint256 minOraclePoolBalance);

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
        if (customSender_ == address(0) || priceFeed_ == address(0)) revert ZeroAddress();
        address pool = ICustomSender(customSender_).getOraclePool();
        address gho = ICustomSender(customSender_).GHO();
        address sgho = ICustomSender(customSender_).SGHO();
        if (pool == address(0) || gho == address(0) || sgho == address(0)) revert ZeroAddress();
        if (syncAmount_ == 0) revert ZeroSyncAmount();
        _decodeAndValidateFeeOtoD(feeOtoD_);

        customSender = customSender_;
        GHO = gho;
        SGHO = sgho;
        priceFeed = priceFeed_;
        maxPriceStaleness = maxPriceStaleness_;
        minOraclePoolBalance = minOraclePoolBalance_;
        syncAmount = syncAmount_;
        s_feeOtoD = feeOtoD_;
        s_extraArgs = extraArgs_;
    }

    function feeOtoD() external view returns (bytes memory) {
        return s_feeOtoD;
    }

    function extraArgs() external view returns (bytes memory) {
        return s_extraArgs;
    }

    function setMinOraclePoolBalance(uint256 minBal) external onlyOwner {
        emit MinOraclePoolBalanceUpdated(minOraclePoolBalance, minBal);
        minOraclePoolBalance = minBal;
    }

    function setSyncAmount(uint256 newAmount) external onlyOwner {
        if (newAmount == 0) revert ZeroSyncAmount();
        emit SyncAmountUpdated(syncAmount, newAmount);
        syncAmount = newAmount;
    }

    function setFeeOtoD(bytes calldata newFee) external onlyOwner {
        bytes memory feeMem = newFee;
        (uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD) = _decodeAndValidateFeeOtoD(feeMem);
        emit FeeOtoDUpdated(maxFeeOtoD, payInGhoOtoD, gasLimitOtoD);
        s_feeOtoD = newFee;
    }

    function setExtraArgs(bytes calldata newExtraArgs) external onlyOwner {
        emit ExtraArgsUpdated(newExtraArgs);
        s_extraArgs = newExtraArgs;
    }

    function setPriceFeed(address newFeed) external onlyOwner {
        if (newFeed == address(0)) revert ZeroAddress();
        emit PriceFeedUpdated(priceFeed, newFeed);
        priceFeed = newFeed;
    }

    function setMaxPriceStaleness(uint256 newStaleness) external onlyOwner {
        emit MaxPriceStalenessUpdated(maxPriceStaleness, newStaleness);
        maxPriceStaleness = newStaleness;
    }

    /// @dev Reverts if `fee` is shorter than one ABI word for `(uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD)` or gas limit is below `MIN_PROCESS_MESSAGE_GAS`.
    function _decodeAndValidateFeeOtoD(bytes memory fee)
        private
        pure
        returns (uint128 maxFeeOtoD, bool payInGhoOtoD, uint32 gasLimitOtoD)
    {
        if (fee.length < 96) revert FeeOtoDTooShort(fee.length, 96);
        (maxFeeOtoD, payInGhoOtoD, gasLimitOtoD) = abi.decode(fee, (uint128, bool, uint32));
        if (gasLimitOtoD < MIN_PROCESS_MESSAGE_GAS) {
            revert InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS);
        }
    }

    function _oracleEnvValid() internal view returns (bool) {
        return ICustomSender(customSender).getOraclePool() != address(0);
    }

    function _oraclePoolTokenBalance() private view returns (uint256) {
        address pool = ICustomSender(customSender).getOraclePool();
        return IERC20(GHO).balanceOf(pool);
    }

    /// @dev True when oracle pool GHO balance is strictly below `minOraclePoolBalance`. Preconditions: `_oracleEnvValid()`.
    function _needsUpkeep() internal view returns (bool) {
        return _oraclePoolTokenBalance() < minOraclePoolBalance;
    }

    /// @notice View used by the CRE workflow (oracle configured and pool balance below threshold).
    function needsUpkeep() external view returns (bool upkeepNeeded) {
        if (!_oracleEnvValid()) return false;
        upkeepNeeded = _needsUpkeep();
    }

    /// @dev Converts `ghoAmount` to its sGHO-equivalent using the Chainlink sGHO/GHO 4626 exchange-rate feed.
    ///      Treats the feed answer as GHO assets per 1 sGHO share (scaled by `10**feed.decimals()`):
    ///      `sGhoOut = ghoAmount * 10**feedDecimals / answer`. Reverts on non-positive answers or
    ///      when the last update is older than `maxPriceStaleness`.
    function _computeMinAmountOut(uint256 ghoAmount) private view returns (uint256) {
        IAggregatorV3 feed = IAggregatorV3(priceFeed);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (block.timestamp - updatedAt > maxPriceStaleness) {
            revert StalePriceFeed(updatedAt, maxPriceStaleness);
        }
        return (ghoAmount * (10 ** feed.decimals())) / uint256(answer);
    }

    function _processReport(bytes calldata /* report */) internal override {
        if (!_oracleEnvValid()) {
            emit SyncSkippedOracleMisconfigured();
            return;
        }
        if (!_needsUpkeep()) {
            emit SyncSkippedUpkeepNotNeeded(_oraclePoolTokenBalance(), minOraclePoolBalance);
            return;
        }

        bytes memory feeMem = s_feeOtoD;
        (uint128 maxFeeOtoD, bool payInGhoOtoD,) = _decodeAndValidateFeeOtoD(feeMem);

        uint256 nativeAmount = payInGhoOtoD ? 0 : uint256(maxFeeOtoD);
        uint256 amount = syncAmount;
        uint256 minAmountOut = _computeMinAmountOut(amount);

        ICustomSender(customSender).sync{value: nativeAmount}(
            GHO,
            amount,
            minAmountOut,
            feeMem,
            s_extraArgs
        );
    }

    receive() external payable {}
}
