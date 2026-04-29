// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {ICustomSender} from "./interfaces/ICustomSender.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SyncKeeperConsumer
/// @notice CRE keeper pattern: `needsUpkeep()` reads oracle-pool token balance from `CustomSender`;
///         `_processReport` uses on-chain sync params and calls `ICustomSender.sync` (grant `SYNC_ROLE` here).
/// @dev Vendored `ReceiverTemplate` from Chainlink CRE templates. Threshold, dest, amount, and fee blob are on-chain;
///      the CRE report body is ignored (minimal payload from the workflow).
contract SyncKeeperConsumer is ReceiverTemplate {
    uint32 public constant MIN_PROCESS_MESSAGE_GAS = 75_000;

    error ZeroAddress();
    error ZeroSyncAmount();
    error FeeOtoDTooShort(uint256 length, uint256 minLength);
    error InsufficientGasLimit(uint32 gasLimit, uint32 minGas);

    address public immutable customSender;
    uint256 public minOraclePoolBalance;

    uint64 public immutable destChainSelector;
    uint256 public immutable syncAmount;

    bytes private s_feeOtoD;

    event MinOraclePoolBalanceUpdated(uint256 previous, uint256 current);
    event FeeOtoDUpdated(uint128 indexed maxFeeOtoD, bool indexed payInLinkOtoD, uint32 indexed gasLimitOtoD);
    event SyncSkippedOracleMisconfigured();
    event SyncSkippedUpkeepNotNeeded(uint256 poolBalance, uint256 minOraclePoolBalance);

    constructor(
        address forwarder,
        address customSender_,
        uint256 minOraclePoolBalance_,
        uint64 destChainSelector_,
        uint256 syncAmount_,
        bytes memory feeOtoD_
    ) ReceiverTemplate(forwarder) {
        if (customSender_ == address(0)) revert ZeroAddress();
        address pool = ICustomSender(customSender_).getOraclePool();
        address token = ICustomSender(customSender_).GHO();
        if (pool == address(0) || token == address(0)) revert ZeroAddress();
        if (syncAmount_ == 0) revert ZeroSyncAmount();
        _decodeAndValidateFeeOtoD(feeOtoD_);

        customSender = customSender_;
        minOraclePoolBalance = minOraclePoolBalance_;
        destChainSelector = destChainSelector_;
        syncAmount = syncAmount_;
        s_feeOtoD = feeOtoD_;
    }

    function feeOtoD() external view returns (bytes memory) {
        return s_feeOtoD;
    }

    function setMinOraclePoolBalance(uint256 minBal) external onlyOwner {
        emit MinOraclePoolBalanceUpdated(minOraclePoolBalance, minBal);
        minOraclePoolBalance = minBal;
    }

    function setFeeOtoD(bytes calldata newFee) external onlyOwner {
        bytes memory feeMem = newFee;
        (uint128 maxFeeOtoD, bool payInLinkOtoD, uint32 gasLimitOtoD) = _decodeAndValidateFeeOtoD(feeMem);
        emit FeeOtoDUpdated(maxFeeOtoD, payInLinkOtoD, gasLimitOtoD);
        s_feeOtoD = newFee;
    }

    /// @dev Reverts if `fee` is shorter than one ABI word for `(uint128,bool,uint32)` or gas limit is below `MIN_PROCESS_MESSAGE_GAS`.
    function _decodeAndValidateFeeOtoD(bytes memory fee)
        private
        pure
        returns (uint128 maxFeeOtoD, bool payInLinkOtoD, uint32 gasLimitOtoD)
    {
        if (fee.length < 96) revert FeeOtoDTooShort(fee.length, 96);
        (maxFeeOtoD, payInLinkOtoD, gasLimitOtoD) = abi.decode(fee, (uint128, bool, uint32));
        if (gasLimitOtoD < MIN_PROCESS_MESSAGE_GAS) {
            revert InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS);
        }
    }
    function _oracleEnvValid() internal view returns (bool) {
        address pool = ICustomSender(customSender).getOraclePool();
        address token = ICustomSender(customSender).GHO();
        return pool != address(0) && token != address(0);
    }

    function _oraclePoolTokenBalance() private view returns (uint256) {
        address pool = ICustomSender(customSender).getOraclePool();
        address token = ICustomSender(customSender).GHO();
        return IERC20(token).balanceOf(pool);
    }

    /// @dev True when oracle pool token balance is strictly below `minOraclePoolBalance`. Preconditions: `_oracleEnvValid()`.
    function _needsUpkeep() internal view returns (bool) {
        return _oraclePoolTokenBalance() < minOraclePoolBalance;
    }

    /// @notice View used by the CRE workflow (oracle configured and pool balance below threshold).
    function needsUpkeep() external view returns (bool upkeepNeeded) {
        if (!_oracleEnvValid()) return false;
        upkeepNeeded = _needsUpkeep();
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
        (uint128 maxFeeOtoD, bool payInLinkOtoD,) = _decodeAndValidateFeeOtoD(feeMem);

        uint256 nativeAmount = payInLinkOtoD ? 0 : uint256(maxFeeOtoD);

        ICustomSender(customSender).sync{value: nativeAmount}(destChainSelector, syncAmount, feeMem);
    }

    receive() external payable {}
}
