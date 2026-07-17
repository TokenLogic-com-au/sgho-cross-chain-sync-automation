// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ICustomSender Interface
 * @dev The minimal interface of the `CustomSender` contract. It exposes the oracle pool and token
 * addresses read by the keeper gate, and the {sync} function called to rebalance the oracle pool.
 */
interface ICustomSender {
    /**
     * @dev Rebalances the oracle pool by pulling `amount` of `token` from it and sending the tokens
     * to the mainnet vault via CCIP. The CCIP fee is paid by the caller and, as encoded in
     * `feeData`, can be paid in `GHO` or in native token.
     *
     * Requirements:
     *
     * - `msg.sender` must have the `SYNC_ROLE` on the `CustomSender`.
     * - `token` must be either `GHO` or `SGHO`.
     * - The oracle pool must be set.
     *
     * @param token The address of the token to be pulled and sent (`GHO` or `SGHO`).
     * @param amount The amount of `token` to be pulled and sent.
     * @param minAmountOut The minimum amount expected on the destination chain.
     * @param feeData The encoded CCIP fee data (max fee, fee payment token, and gas limit).
     * @param extraArgs The extra arguments forwarded to the CCIP router.
     * @return messageId The identifier of the CCIP message sent.
     */
    function sync(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata feeData,
        bytes calldata extraArgs
    ) external payable returns (bytes32 messageId);

    /**
     * @notice Returns the address of the `GHO` token on the deployed network.
     */
    function GHO() external view returns (address);

    /**
     * @notice Returns the address of the `SGHO` token on the deployed network.
     */
    function SGHO() external view returns (address);

    /**
     * @notice Returns the address of the oracle pool, or `address(0)` if none is set.
     */
    function getOraclePool() external view returns (address);
}
