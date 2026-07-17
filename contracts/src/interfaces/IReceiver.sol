// SPDX-License-Identifier: MIT
// Source: https://docs.chain.link/cre
pragma solidity ^0.8.0;

import {IERC165} from "./IERC165.sol";

/**
 * @title IReceiver Interface
 * @dev The interface of a contract that receives keystone reports from a Chainlink CRE workflow.
 * Implementations must advertise support for this interface through ERC-165.
 */
interface IReceiver is IERC165 {
    /// @dev The forwarder address provided at construction is the zero address.
    error InvalidForwarderAddress();

    /**
     * @dev The caller is not the configured forwarder.
     * @param sender The address that called the function.
     * @param expected The address of the configured forwarder.
     */
    error InvalidSender(address sender, address expected);

    /**
     * @dev The report was produced by a workflow owned by an address other than the expected author.
     * @param received The workflow owner encoded in the report metadata.
     * @param expected The address of the expected workflow author.
     */
    error InvalidAuthor(address received, address expected);

    /**
     * @dev The report was produced by a workflow whose name is not the expected one.
     * @param received The workflow name encoded in the report metadata.
     * @param expected The expected workflow name.
     */
    error InvalidWorkflowName(bytes10 received, bytes10 expected);

    /**
     * @dev The report was produced by a workflow whose id is not the expected one.
     * @param received The workflow id encoded in the report metadata.
     * @param expected The expected workflow id.
     */
    error InvalidWorkflowId(bytes32 received, bytes32 expected);

    /// @dev The workflow name check is enabled while the workflow author check is not.
    error WorkflowNameRequiresAuthorValidation();

    /**
     * Emitted when the forwarder address is updated.
     * @param previousForwarder The address of the previous forwarder.
     * @param newForwarder The address of the new forwarder.
     */
    event ForwarderAddressUpdated(
        address indexed previousForwarder,
        address indexed newForwarder
    );

    /**
     * Emitted when the expected workflow author is updated.
     * @param previousAuthor The address of the previous expected author.
     * @param newAuthor The address of the new expected author, or `address(0)` if the check is
     * disabled.
     */
    event ExpectedAuthorUpdated(
        address indexed previousAuthor,
        address indexed newAuthor
    );

    /**
     * Emitted when the expected workflow name is updated.
     * @param previousName The previous expected workflow name.
     * @param newName The new expected workflow name, or `bytes10(0)` if the check is disabled.
     */
    event ExpectedWorkflowNameUpdated(
        bytes10 indexed previousName,
        bytes10 indexed newName
    );

    /**
     * Emitted when the expected workflow id is updated.
     * @param previousId The previous expected workflow id.
     * @param newId The new expected workflow id, or `bytes32(0)` if the check is disabled.
     */
    event ExpectedWorkflowIdUpdated(
        bytes32 indexed previousId,
        bytes32 indexed newId
    );

    /**
     * Emitted when a configuration change leaves the contract without a security check.
     * @param message The human readable description of the warning.
     */
    event SecurityWarning(string message);

    /**
     * @dev Handles an incoming keystone report.
     * If this call reverts, it can be retried with a higher gas limit. The receiver is responsible
     * for discarding stale reports.
     *
     * Requirements:
     *
     * - `msg.sender` must be the configured forwarder, if one is set.
     * - `metadata` must match every configured workflow check.
     *
     * @param metadata The metadata of the report.
     * @param report The encoded workflow report.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
