// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for CRE + keeper consumer to read `CustomSender` and call `sync`.
interface ICustomSender {
    function getOraclePool() external view returns (address);

    function GHO() external view returns (address);

    function SGHO() external view returns (address);

    function sync(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata feeData,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId);
}
