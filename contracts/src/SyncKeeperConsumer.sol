// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";
import {ICustomSender} from "./interfaces/ICustomSender.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SyncKeeperConsumer
/// @notice CRE keeper pattern: `needsUpkeep()` reads oracle-pool token balance from `CustomSender`;
///         `_processReport` decodes sync args and calls `ICustomSender.sync` (grant `SYNC_ROLE` here).
/// @dev Vendored `ReceiverTemplate` from Chainlink CRE templates. Threshold is on-chain; fee/amount/dest stay in the report.
contract SyncKeeperConsumer is ReceiverTemplate {
    uint32 public constant MIN_PROCESS_MESSAGE_GAS = 75_000;

    error ZeroAddress();
    error ZeroSyncAmount();
    error FeeOtoDTooShort(uint256 length, uint256 minLength);
    error InsufficientGasLimit(uint32 gasLimit, uint32 minGas);
    error UpkeepNotNeeded();

    address public immutable customSender;
    uint256 public minOraclePoolBalance;

    event MinOraclePoolBalanceUpdated(uint256 previous, uint256 current);

    constructor(address forwarder, address customSender_, uint256 minOraclePoolBalance_)
        ReceiverTemplate(forwarder)
    {
        if (customSender_ == address(0)) revert ZeroAddress();
        customSender = customSender_;
        minOraclePoolBalance = minOraclePoolBalance_;
    }

    function setMinOraclePoolBalance(uint256 minBal) external onlyOwner {
        emit MinOraclePoolBalanceUpdated(minOraclePoolBalance, minBal);
        minOraclePoolBalance = minBal;
    }

    function _needsUpkeep() internal view returns (bool) {
        address pool = ICustomSender(customSender).getOraclePool();
        address token = ICustomSender(customSender).TOKEN();
        if (pool == address(0) || token == address(0)) return false;
        uint256 bal = IERC20(token).balanceOf(pool);
        return bal < minOraclePoolBalance;
    }

    /// @notice View used by the CRE workflow (same condition as enforced in `_processReport`).
    function needsUpkeep() external view returns (bool upkeepNeeded) {
        upkeepNeeded = _needsUpkeep();
    }

    function _processReport(bytes calldata report) internal override {
        if (!_needsUpkeep()) revert UpkeepNotNeeded();

        (uint64 destChainSelector, uint256 amount, bytes memory feeOtoD) =
            abi.decode(report, (uint64, uint256, bytes));

        if (amount == 0) revert ZeroSyncAmount();
        if (feeOtoD.length < 96) revert FeeOtoDTooShort(feeOtoD.length, 96);

        (uint128 maxFeeOtoD, bool payInLinkOtoD, uint32 gasLimitOtoD) =
            abi.decode(feeOtoD, (uint128, bool, uint32));
        if (gasLimitOtoD < MIN_PROCESS_MESSAGE_GAS) {
            revert InsufficientGasLimit(gasLimitOtoD, MIN_PROCESS_MESSAGE_GAS);
        }

        uint256 nativeAmount = payInLinkOtoD ? 0 : uint256(maxFeeOtoD);

        ICustomSender(customSender).sync{value: nativeAmount}(destChainSelector, amount, feeOtoD);
    }

    receive() external payable {}
}
