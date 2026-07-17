// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC165} from "../src/interfaces/IERC165.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {MockReceiver} from "./mocks/MockReceiver.sol";

/**
 * @title TestReceiverTemplateBase
 * @notice Shared setup for the ReceiverTemplate unit tests
 * @dev Run with: forge test --match-path tests/TestReceiverTemplate.t.sol -vvv
 */
contract TestReceiverTemplateBase is Test {
    /// @dev Report metadata is the packed encoding of a bytes32 id, a bytes10 name and an address.
    uint256 public constant METADATA_LENGTH = 32 + 10 + 20;

    bytes32 public constant WORKFLOW_ID = keccak256("workflowId");

    string public constant WORKFLOW_NAME = "cross-chain-sync";
    /// @dev The first 10 characters of the hex encoded sha256 of {WORKFLOW_NAME}.
    bytes10 public constant WORKFLOW_NAME_HASH = bytes10("c66e010570");

    address public immutable WORKFLOW_OWNER = makeAddr("workflowOwner");
    address public immutable FORWARDER = makeAddr("forwarder");
    address public immutable USER = makeAddr("user");

    MockReceiver internal receiver;

    function setUp() public virtual {
        receiver = new MockReceiver(FORWARDER);
    }

    function _metadata(
        bytes32 workflowId,
        bytes10 workflowName,
        address workflowOwner
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, workflowName, workflowOwner);
    }

    function _defaultMetadata() internal view returns (bytes memory) {
        return _metadata(WORKFLOW_ID, WORKFLOW_NAME_HASH, WORKFLOW_OWNER);
    }

    function _submitReport(bytes memory metadata) internal {
        vm.prank(FORWARDER);
        receiver.onReport(metadata, "");
    }

    /// @dev Enables every optional workflow identity check.
    function _enableAllChecks() internal {
        receiver.setExpectedWorkflowId(WORKFLOW_ID);
        receiver.setExpectedAuthor(WORKFLOW_OWNER);
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);
    }
}

/**
 * @title ReceiverTemplateConstructorTest
 * @notice Unit tests for the ReceiverTemplate constructor
 * @dev Run with: forge test --match-contract ReceiverTemplateConstructorTest -vvv
 */
contract ReceiverTemplateConstructorTest is TestReceiverTemplateBase {
    function testConstructorZeroAddressForwarder() public {
        vm.expectRevert(IReceiver.InvalidForwarderAddress.selector);
        new MockReceiver(address(0));
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit IReceiver.ForwarderAddressUpdated(address(0), FORWARDER);
        MockReceiver r = new MockReceiver(FORWARDER);

        assertEq(r.getForwarderAddress(), FORWARDER, "forwarder");
        assertEq(r.owner(), address(this), "owner");
    }

    /// @dev Every optional permission field defaults to disabled.
    function testConstructorOptionalChecksDefaultToDisabled() public view {
        assertEq(receiver.getExpectedAuthor(), address(0), "author");
        assertEq(
            bytes32(receiver.getExpectedWorkflowName()),
            bytes32(0),
            "name"
        );
        assertEq(receiver.getExpectedWorkflowId(), bytes32(0), "id");
    }
}

/**
 * @title ReceiverTemplateOnReportTest
 * @notice Unit tests for ReceiverTemplate.onReport with no optional check configured
 * @dev Run with: forge test --match-contract ReceiverTemplateOnReportTest -vvv
 */
contract ReceiverTemplateOnReportTest is TestReceiverTemplateBase {
    function testOnReportInvalidSender() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReceiver.InvalidSender.selector,
                USER,
                FORWARDER
            )
        );
        receiver.onReport("", "");
    }

    function testOnReportForwardsReportBody() public {
        bytes memory report = abi.encode(uint256(42), "payload");

        vm.prank(FORWARDER);
        receiver.onReport(_defaultMetadata(), report);

        assertEq(receiver.processCallCount(), 1, "processed once");
        assertEq(receiver.lastReport(), report, "report body");
    }

    /// @dev With no check configured the metadata is never decoded, so any payload is accepted.
    function testOnReportIgnoresMetadataWhenNoChecksConfigured() public {
        _submitReport(hex"deadbeef");

        assertEq(receiver.processCallCount(), 1);
    }

    /// @dev A failing _processReport bubbles up so the report can be retried.
    function testOnReportPropagatesProcessReportRevert() public {
        receiver.setShouldRevert(true);

        vm.prank(FORWARDER);
        vm.expectRevert(MockReceiver.ProcessReportFailed.selector);
        receiver.onReport("", "");
    }
}

/**
 * @title ReceiverTemplateWorkflowChecksTest
 * @notice Unit tests for the ReceiverTemplate workflow identity checks and metadata decoding
 * @dev Run with: forge test --match-contract ReceiverTemplateWorkflowChecksTest -vvv
 */
contract ReceiverTemplateWorkflowChecksTest is TestReceiverTemplateBase {
    function testMetadataLayoutIsPacked() public view {
        assertEq(_defaultMetadata().length, METADATA_LENGTH, "packed length");
    }

    /// @dev Pins all three assembly read offsets at once: a wrong offset for any field would fail
    ///      its own check even though the other two match.
    function testOnReportDecodesAllMetadataFields() public {
        _enableAllChecks();

        _submitReport(_defaultMetadata());

        assertEq(receiver.processCallCount(), 1, "all fields decoded");
    }

    function testOnReportInvalidWorkflowId() public {
        _enableAllChecks();
        bytes32 wrongId = keccak256("wrongId");

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReceiver.InvalidWorkflowId.selector,
                wrongId,
                WORKFLOW_ID
            )
        );
        receiver.onReport(
            _metadata(wrongId, WORKFLOW_NAME_HASH, WORKFLOW_OWNER),
            ""
        );
    }

    function testOnReportInvalidAuthor() public {
        _enableAllChecks();
        address wrongOwner = makeAddr("wrongOwner");

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReceiver.InvalidAuthor.selector,
                wrongOwner,
                WORKFLOW_OWNER
            )
        );
        receiver.onReport(
            _metadata(WORKFLOW_ID, WORKFLOW_NAME_HASH, wrongOwner),
            ""
        );
    }

    function testOnReportInvalidWorkflowName() public {
        _enableAllChecks();
        bytes10 wrongName = bytes10("0000000000");

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReceiver.InvalidWorkflowName.selector,
                wrongName,
                WORKFLOW_NAME_HASH
            )
        );
        receiver.onReport(
            _metadata(WORKFLOW_ID, wrongName, WORKFLOW_OWNER),
            ""
        );
    }

    /// @dev The name check is only meaningful alongside the author check, and the setter does not
    ///      enforce that, so the receiver rejects every report until an author is also set.
    function testOnReportWorkflowNameRequiresAuthorValidation() public {
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);

        vm.prank(FORWARDER);
        vm.expectRevert(IReceiver.WorkflowNameRequiresAuthorValidation.selector);
        receiver.onReport(_defaultMetadata(), "");
    }

    function testOnReportWorkflowNameAcceptedOnceAuthorIsSet() public {
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);
        receiver.setExpectedAuthor(WORKFLOW_OWNER);

        _submitReport(_defaultMetadata());

        assertEq(receiver.processCallCount(), 1);
    }

    function testOnReportOnlyIdCheck() public {
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        // Name and owner are irrelevant while their checks are disabled.
        _submitReport(_metadata(WORKFLOW_ID, bytes10(0), address(0)));

        assertEq(receiver.processCallCount(), 1);
    }

    function testOnReportOnlyAuthorCheck() public {
        receiver.setExpectedAuthor(WORKFLOW_OWNER);

        _submitReport(_metadata(bytes32(0), bytes10(0), WORKFLOW_OWNER));

        assertEq(receiver.processCallCount(), 1);
    }

    /// @dev _decodeMetadata reads at fixed offsets without validating the length, so a truncated
    ///      payload carrying only the id still satisfies the id check.
    function testOnReportShortMetadataIsNotLengthValidated() public {
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        _submitReport(abi.encodePacked(WORKFLOW_ID));

        assertEq(receiver.processCallCount(), 1, "truncated metadata accepted");
    }

    /// @dev Trailing bytes beyond the three known fields are ignored.
    function testOnReportLongMetadataIsAccepted() public {
        _enableAllChecks();

        _submitReport(
            abi.encodePacked(_defaultMetadata(), hex"deadbeefdeadbeef")
        );

        assertEq(receiver.processCallCount(), 1);
    }

    function testOnReportDecodesWorkflowId(bytes32 workflowId) public {
        receiver.setExpectedWorkflowId(workflowId);
        vm.assume(workflowId != bytes32(0));

        _submitReport(_metadata(workflowId, bytes10(0), address(0)));

        assertEq(receiver.processCallCount(), 1);
    }

    function testOnReportDecodesAuthor(address workflowOwner) public {
        vm.assume(workflowOwner != address(0));
        receiver.setExpectedAuthor(workflowOwner);

        _submitReport(_metadata(bytes32(0), bytes10(0), workflowOwner));

        assertEq(receiver.processCallCount(), 1);
    }
}

/**
 * @title ReceiverTemplateSetForwarderAddressTest
 * @notice Unit tests for ReceiverTemplate.setForwarderAddress
 * @dev Run with: forge test --match-contract ReceiverTemplateSetForwarderAddressTest -vvv
 */
contract ReceiverTemplateSetForwarderAddressTest is TestReceiverTemplateBase {
    function testSetForwarderAddressNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        receiver.setForwarderAddress(USER);
    }

    function testSetForwarderAddress() public {
        address newForwarder = makeAddr("newForwarder");

        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ForwarderAddressUpdated(FORWARDER, newForwarder);
        receiver.setForwarderAddress(newForwarder);

        assertEq(receiver.getForwarderAddress(), newForwarder);
    }

    function testSetForwarderAddressRejectsPreviousForwarder() public {
        receiver.setForwarderAddress(makeAddr("newForwarder"));

        vm.prank(FORWARDER);
        vm.expectRevert();
        receiver.onReport("", "");
    }

    /// @dev Zeroing the forwarder disables the check entirely, which the contract warns about.
    function testSetForwarderAddressZeroWarnsAndDisablesCheck() public {
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.SecurityWarning(
            "Forwarder address set to zero - contract is now INSECURE"
        );
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ForwarderAddressUpdated(FORWARDER, address(0));
        receiver.setForwarderAddress(address(0));

        assertEq(receiver.getForwarderAddress(), address(0), "forwarder");

        // Any caller can now submit reports.
        vm.prank(USER);
        receiver.onReport("", "");

        assertEq(receiver.processCallCount(), 1, "unauthenticated report");
    }
}

/**
 * @title ReceiverTemplateSetExpectedAuthorTest
 * @notice Unit tests for ReceiverTemplate.setExpectedAuthor
 * @dev Run with: forge test --match-contract ReceiverTemplateSetExpectedAuthorTest -vvv
 */
contract ReceiverTemplateSetExpectedAuthorTest is TestReceiverTemplateBase {
    function testSetExpectedAuthorNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        receiver.setExpectedAuthor(WORKFLOW_OWNER);
    }

    function testSetExpectedAuthor() public {
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedAuthorUpdated(address(0), WORKFLOW_OWNER);
        receiver.setExpectedAuthor(WORKFLOW_OWNER);

        assertEq(receiver.getExpectedAuthor(), WORKFLOW_OWNER);
    }

    function testSetExpectedAuthorZeroDisablesCheck() public {
        receiver.setExpectedAuthor(WORKFLOW_OWNER);

        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedAuthorUpdated(WORKFLOW_OWNER, address(0));
        receiver.setExpectedAuthor(address(0));

        assertEq(receiver.getExpectedAuthor(), address(0), "author");

        // A report from an unrelated owner is now accepted.
        _submitReport(_metadata(bytes32(0), bytes10(0), makeAddr("anyone")));

        assertEq(receiver.processCallCount(), 1);
    }
}

/**
 * @title ReceiverTemplateSetExpectedWorkflowNameTest
 * @notice Unit tests for ReceiverTemplate.setExpectedWorkflowName
 * @dev Run with: forge test --match-contract ReceiverTemplateSetExpectedWorkflowNameTest -vvv
 */
contract ReceiverTemplateSetExpectedWorkflowNameTest is
    TestReceiverTemplateBase
{
    function testSetExpectedWorkflowNameNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);
    }

    /// @dev The name is stored as the first 10 characters of the hex encoded sha256 of the string.
    function testSetExpectedWorkflowName() public {
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedWorkflowNameUpdated(
            bytes10(0),
            WORKFLOW_NAME_HASH
        );
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);

        assertEq(
            bytes32(receiver.getExpectedWorkflowName()),
            bytes32(WORKFLOW_NAME_HASH)
        );
    }

    /// @dev A second known vector, guarding the hex conversion against an off-by-one.
    function testSetExpectedWorkflowNameKnownVector() public {
        receiver.setExpectedWorkflowName("my-workflow");

        assertEq(
            bytes32(receiver.getExpectedWorkflowName()),
            bytes32(bytes10("889158b6ac"))
        );
    }

    function testSetExpectedWorkflowNameEmptyDisablesCheck() public {
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);

        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedWorkflowNameUpdated(
            WORKFLOW_NAME_HASH,
            bytes10(0)
        );
        receiver.setExpectedWorkflowName("");

        assertEq(
            bytes32(receiver.getExpectedWorkflowName()),
            bytes32(0),
            "name cleared"
        );
    }

    /// @dev Distinct names must not collide in the truncated hash.
    function testSetExpectedWorkflowNameDiffersPerName() public {
        receiver.setExpectedWorkflowName(WORKFLOW_NAME);
        bytes10 first = receiver.getExpectedWorkflowName();

        receiver.setExpectedWorkflowName("my-workflow");
        bytes10 second = receiver.getExpectedWorkflowName();

        assertTrue(first != second, "names must hash differently");
    }
}

/**
 * @title ReceiverTemplateSetExpectedWorkflowIdTest
 * @notice Unit tests for ReceiverTemplate.setExpectedWorkflowId
 * @dev Run with: forge test --match-contract ReceiverTemplateSetExpectedWorkflowIdTest -vvv
 */
contract ReceiverTemplateSetExpectedWorkflowIdTest is TestReceiverTemplateBase {
    function testSetExpectedWorkflowIdNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        receiver.setExpectedWorkflowId(WORKFLOW_ID);
    }

    function testSetExpectedWorkflowId() public {
        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedWorkflowIdUpdated(bytes32(0), WORKFLOW_ID);
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        assertEq(receiver.getExpectedWorkflowId(), WORKFLOW_ID);
    }

    function testSetExpectedWorkflowIdZeroDisablesCheck() public {
        receiver.setExpectedWorkflowId(WORKFLOW_ID);

        vm.expectEmit(true, true, true, true, address(receiver));
        emit IReceiver.ExpectedWorkflowIdUpdated(WORKFLOW_ID, bytes32(0));
        receiver.setExpectedWorkflowId(bytes32(0));

        assertEq(receiver.getExpectedWorkflowId(), bytes32(0), "id cleared");

        _submitReport(_metadata(keccak256("other"), bytes10(0), address(0)));

        assertEq(receiver.processCallCount(), 1);
    }
}

/**
 * @title ReceiverTemplateSupportsInterfaceTest
 * @notice Unit tests for ReceiverTemplate ERC-165 support
 * @dev Run with: forge test --match-contract ReceiverTemplateSupportsInterfaceTest -vvv
 */
contract ReceiverTemplateSupportsInterfaceTest is TestReceiverTemplateBase {
    function testSupportsInterfaceReceiver() public view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
    }

    function testSupportsInterfaceErc165() public view {
        assertTrue(receiver.supportsInterface(type(IERC165).interfaceId));
    }

    function testSupportsInterfaceUnknown() public view {
        assertFalse(receiver.supportsInterface(0xffffffff));
    }
}
