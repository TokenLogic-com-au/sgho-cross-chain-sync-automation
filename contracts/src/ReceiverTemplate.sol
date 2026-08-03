// SPDX-License-Identifier: MIT
// Source: https://docs.chain.link/cre
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC165} from "./interfaces/IERC165.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

/**
 * @title ReceiverTemplate Contract
 * @dev The abstract base contract for all contracts receiving keystone reports from a Chainlink CRE
 * workflow. It validates incoming reports against a set of permission fields before handing the
 * report body to {_processReport}, which derived contracts implement with their business logic.
 *
 * The forwarder address is required at construction. The remaining permission fields are optional,
 * default to disabled, and can be configured by the owner after deployment. Each field is only
 * enforced when it is set to a non-zero value.
 */
abstract contract ReceiverTemplate is IReceiver, Ownable {
    /// @dev The lookup table used to convert a byte to its two hex characters.
    bytes private constant HEX_CHARS = "0123456789abcdef";

    /// @dev The address allowed to call {onReport}. If set to `address(0)`, the check is disabled.
    address private _forwarderAddress;

    /// @dev The workflow owner accepted by {onReport}. If set to `address(0)`, the check is disabled.
    address private _expectedAuthor;

    /// @dev The workflow name accepted by {onReport}. Only validated when `_expectedAuthor` is set.
    bytes10 private _expectedWorkflowName;

    /// @dev The workflow id accepted by {onReport}. If set to `bytes32(0)`, the check is disabled.
    bytes32 private _expectedWorkflowId;

    /**
     * @dev Sets `msg.sender` as the owner and sets the forwarder address.
     * The forwarder address is required at construction, as it is the check that ensures only
     * verified reports are processed.
     *
     * Requirements:
     *
     * - `forwarderAddress` must not be the zero address.
     *
     * Emits a {ForwarderAddressUpdated} event.
     *
     * @param forwarderAddress The address of the Chainlink Forwarder contract.
     */
    constructor(address forwarderAddress) Ownable(msg.sender) {
        require(forwarderAddress != address(0), InvalidForwarderAddress());
        _forwarderAddress = forwarderAddress;

        emit ForwarderAddressUpdated(address(0), forwarderAddress);
    }

    /// @inheritdoc IReceiver
    /// @dev Performs the validation checks for each permission field that is set, then forwards
    ///      `report` to {_processReport}.
    function onReport(
        bytes calldata metadata,
        bytes calldata report
    ) external override {
        // Security Check 1: Verify caller is the trusted Chainlink Forwarder (if configured)
        if (
            _forwarderAddress != address(0) && msg.sender != _forwarderAddress
        ) {
            revert InvalidSender(msg.sender, _forwarderAddress);
        }

        // Security Checks 2-4: Verify workflow identity - ID, owner, and/or name (if any are configured)
        if (
            _expectedWorkflowId != bytes32(0) ||
            _expectedAuthor != address(0) ||
            _expectedWorkflowName != bytes10(0)
        ) {
            (
                bytes32 workflowId,
                bytes10 workflowName,
                address workflowOwner
            ) = _decodeMetadata(metadata);

            if (
                _expectedWorkflowId != bytes32(0) &&
                workflowId != _expectedWorkflowId
            ) {
                revert InvalidWorkflowId(workflowId, _expectedWorkflowId);
            }
            if (
                _expectedAuthor != address(0) &&
                workflowOwner != _expectedAuthor
            ) {
                revert InvalidAuthor(workflowOwner, _expectedAuthor);
            }

            if (_expectedWorkflowName != bytes10(0)) {
                if (_expectedAuthor == address(0)) {
                    revert WorkflowNameRequiresAuthorValidation();
                }
                if (workflowName != _expectedWorkflowName) {
                    revert InvalidWorkflowName(
                        workflowName,
                        _expectedWorkflowName
                    );
                }
            }
        }

        _processReport(report);
    }

    /**
     * @dev Sets the address allowed to call {onReport}.
     * Setting `forwarder` to the zero address disables the check and allows any address to submit
     * reports, which is why doing so also emits a {SecurityWarning} event.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits a {ForwarderAddressUpdated} event, and a {SecurityWarning} event if the check is
     * disabled.
     *
     * @param forwarder The address of the new forwarder.
     */
    function setForwarderAddress(address forwarder) external onlyOwner {
        address previousForwarder = _forwarderAddress;
        if (forwarder == address(0)) {
            emit SecurityWarning(
                "Forwarder address set to zero - contract is now INSECURE"
            );
        }
        _forwarderAddress = forwarder;
        emit ForwarderAddressUpdated(previousForwarder, forwarder);
    }

    /**
     * @dev Sets the workflow owner accepted by {onReport}.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits an {ExpectedAuthorUpdated} event.
     *
     * @param author The address of the new expected author, or `address(0)` to disable the check.
     */
    function setExpectedAuthor(address author) external onlyOwner {
        _setExpectedAuthor(author);
    }

    /**
     * @dev Sets the workflow owner accepted by {onReport}, without an access check.
     * Available to derived contracts so they can set the expected author at construction, before
     * the public setter's `onlyOwner` context is usable.
     *
     * Emits an {ExpectedAuthorUpdated} event.
     *
     * @param author The address of the new expected author, or `address(0)` to disable the check.
     */
    function _setExpectedAuthor(address author) internal {
        address previousAuthor = _expectedAuthor;
        _expectedAuthor = author;

        emit ExpectedAuthorUpdated(previousAuthor, author);
    }

    /**
     * @dev Sets the workflow name accepted by {onReport} from its plaintext form.
     * The name is stored as the first 10 hex characters of its SHA-256 hash, which is the encoding
     * used in the report metadata. The check is only enforced when the expected author is also set.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits an {ExpectedWorkflowNameUpdated} event.
     *
     * @param name The name of the workflow, or an empty string to disable the check.
     */
    function setExpectedWorkflowName(string calldata name) external onlyOwner {
        bytes10 previousName = _expectedWorkflowName;

        if (bytes(name).length == 0) {
            _expectedWorkflowName = bytes10(0);
            emit ExpectedWorkflowNameUpdated(previousName, bytes10(0));
            return;
        }

        bytes32 hash = sha256(bytes(name));
        bytes memory hexString = _bytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            first10[i] = hexString[i];
        }
        _expectedWorkflowName = bytes10(first10);
        emit ExpectedWorkflowNameUpdated(previousName, _expectedWorkflowName);
    }

    /**
     * @dev Sets the workflow id accepted by {onReport}.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner.
     *
     * Emits an {ExpectedWorkflowIdUpdated} event.
     *
     * @param id The new expected workflow id, or `bytes32(0)` to disable the check.
     */
    function setExpectedWorkflowId(bytes32 id) external onlyOwner {
        bytes32 previousId = _expectedWorkflowId;
        _expectedWorkflowId = id;
        emit ExpectedWorkflowIdUpdated(previousId, id);
    }

    /**
     * @notice Returns the address allowed to call {onReport}, or `address(0)` if the check is
     * disabled.
     */
    function getForwarderAddress() external view returns (address) {
        return _forwarderAddress;
    }

    /**
     * @notice Returns the workflow owner accepted by {onReport}, or `address(0)` if the check is
     * disabled.
     */
    function getExpectedAuthor() external view returns (address) {
        return _expectedAuthor;
    }

    /**
     * @notice Returns the workflow name accepted by {onReport}, or `bytes10(0)` if the check is
     * disabled.
     */
    function getExpectedWorkflowName() external view returns (bytes10) {
        return _expectedWorkflowName;
    }

    /**
     * @notice Returns the workflow id accepted by {onReport}, or `bytes32(0)` if the check is
     * disabled.
     */
    function getExpectedWorkflowId() external view returns (bytes32) {
        return _expectedWorkflowId;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IReceiver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /**
     * @dev Processes the body of a report that passed every configured permission check.
     * Derived contracts must implement this function with their business logic.
     *
     * @param report The encoded workflow report.
     */
    function _processReport(bytes calldata report) internal virtual;

    /**
     * @dev Decodes the workflow identity from the metadata of a report.
     * The metadata is a packed encoding of the three returned fields, so it is read directly from
     * memory rather than through `abi.decode`.
     *
     * @param metadata The metadata of the report.
     * @return The id of the workflow that produced the report.
     * @return The name of the workflow that produced the report.
     * @return The address of the owner of the workflow that produced the report.
     */
    function _decodeMetadata(
        bytes memory metadata
    ) internal pure returns (bytes32, bytes10, address) {
        bytes32 workflowId;
        bytes10 workflowName;
        address workflowOwner;
        assembly {
            workflowId := mload(add(metadata, 32))
            workflowName := mload(add(metadata, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }
        return (workflowId, workflowName, workflowOwner);
    }

    /**
     * @dev Converts `data` to its lowercase hex representation, without a `0x` prefix.
     * @param data The bytes to convert.
     * @return The hex representation of `data`, twice as long as `data`.
     */
    function _bytesToHexString(
        bytes memory data
    ) private pure returns (bytes memory) {
        bytes memory hexString = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
            hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
        }
        return hexString;
    }
}
