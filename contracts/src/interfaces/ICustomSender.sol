// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for CRE + keeper consumer to read `CustomSender` and call `sync`.
interface ICustomSender {
    function getOraclePool() external view returns (address);

    function TOKEN() external view returns (address);

    function sync(uint64 destChainSelector, uint256 amount, bytes calldata feeOtoD)
        external
        payable
        returns (bytes32 messageId);
}
