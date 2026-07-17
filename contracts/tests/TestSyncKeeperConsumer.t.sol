// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdError} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {SyncKeeperConsumer} from "../src/SyncKeeperConsumer.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {ISyncKeeperConsumer} from "../src/interfaces/ISyncKeeperConsumer.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockCustomSender} from "./mocks/MockCustomSender.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title TestSyncKeeperConsumerBase
 * @notice Shared setup for the SyncKeeperConsumer unit tests
 * @dev Run with: forge test --match-path tests/TestSyncKeeperConsumer.t.sol -vvv
 */
contract TestSyncKeeperConsumerBase is Test {
    uint256 public constant MIN_GHO_BALANCE = 200_000 ether;
    uint256 public constant MIN_SGHO_BALANCE = 100_000 ether;
    uint256 public constant SYNC_AMOUNT = 10_000 ether;
    uint256 public constant MAX_PRICE_STALENESS = 1 days;
    uint128 public constant MAX_FEE = 1 ether;
    uint32 public constant GAS_LIMIT = 500_000;

    uint8 public constant FEED_DECIMALS = 18;
    /// @dev 1 sGHO share is worth exactly 1 GHO, so a sync converts 1:1 in either direction.
    int256 public constant FEED_ANSWER = 1e18;

    uint256 public constant MAX_FUZZ_AMOUNT = 1_000_000_000 ether;
    bytes public constant EXTRA_ARGS = hex"c0ffee";

    address public immutable FORWARDER = makeAddr("forwarder");
    address public immutable USER = makeAddr("user");
    address public immutable ORACLE_POOL = makeAddr("oraclePool");

    MockERC20 internal gho;
    MockERC20 internal sGho;
    MockCustomSender internal customSender;
    MockAggregatorV3 internal feed;
    SyncKeeperConsumer internal consumer;

    function setUp() public virtual {
        // Start at a non-zero timestamp so that tests can move the feed update time backwards.
        vm.warp(365 days);

        gho = new MockERC20("GHO", "GHO");
        sGho = new MockERC20("Staked GHO", "sGHO");
        customSender = new MockCustomSender(
            address(gho),
            address(sGho),
            ORACLE_POOL
        );
        feed = new MockAggregatorV3(FEED_DECIMALS, FEED_ANSWER);

        consumer = _deployConsumer();

        // Default to a balanced pool: both sides funded, so no upkeep is needed.
        _setPoolBalances(MIN_GHO_BALANCE * 2, MIN_SGHO_BALANCE * 2);
    }

    function _feeData(
        uint128 maxFee,
        bool payInGho,
        uint32 gasLimit
    ) internal pure returns (bytes memory) {
        return abi.encode(maxFee, payInGho, gasLimit);
    }

    /// @dev The default fee data pays the CCIP fee in native token.
    function _defaultFeeData() internal pure returns (bytes memory) {
        return _feeData(MAX_FEE, false, GAS_LIMIT);
    }

    function _deployConsumer() internal returns (SyncKeeperConsumer) {
        return
            new SyncKeeperConsumer(
                FORWARDER,
                address(customSender),
                address(feed),
                MAX_PRICE_STALENESS,
                MIN_GHO_BALANCE,
                MIN_SGHO_BALANCE,
                SYNC_AMOUNT,
                _defaultFeeData(),
                EXTRA_ARGS
            );
    }

    /// @dev Forces the oracle pool balances to exactly `ghoBalance` and `sGhoBalance`.
    function _setPoolBalances(
        uint256 ghoBalance,
        uint256 sGhoBalance
    ) internal {
        _setBalance(gho, ghoBalance);
        _setBalance(sGho, sGhoBalance);
    }

    function _setBalance(MockERC20 token, uint256 amount) private {
        uint256 current = token.balanceOf(ORACLE_POOL);
        if (amount > current) {
            token.mint(ORACLE_POOL, amount - current);
        } else if (amount < current) {
            token.burn(ORACLE_POOL, current - amount);
        }
    }

    /// @dev Pool is short of GHO, so sGHO is the surplus and should be sent.
    function _setGhoShort() internal {
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE * 5);
    }

    /// @dev Pool is short of sGHO, so GHO is the surplus and should be sent.
    function _setSGhoShort() internal {
        _setPoolBalances(MIN_GHO_BALANCE * 5, MIN_SGHO_BALANCE - 1);
    }

    /// @dev Submits a report as the trusted forwarder. Metadata is empty, as no workflow identity
    ///      check is configured by default.
    function _submitReport() internal {
        vm.prank(FORWARDER);
        consumer.onReport("", "");
    }

    /// @dev Sending GHO returns sGHO shares: divide by the GHO-per-share rate.
    function _expectedSGhoOut(
        uint256 ghoAmount,
        int256 answer
    ) internal pure returns (uint256) {
        return (ghoAmount * (10 ** FEED_DECIMALS)) / uint256(answer);
    }

    /// @dev Sending sGHO returns GHO assets: multiply by the GHO-per-share rate.
    function _expectedGhoOut(
        uint256 sGhoAmount,
        int256 answer
    ) internal pure returns (uint256) {
        return (sGhoAmount * uint256(answer)) / (10 ** FEED_DECIMALS);
    }
}

/**
 * @title ConstructorTest
 * @notice Unit tests for the SyncKeeperConsumer constructor
 * @dev Run with: forge test --match-contract ConstructorTest -vvv
 */
contract ConstructorTest is TestSyncKeeperConsumerBase {
    function testConstructorZeroAddressForwarder() public {
        vm.expectRevert(IReceiver.InvalidForwarderAddress.selector);
        new SyncKeeperConsumer(
            address(0),
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorZeroAddressCustomSender() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(0),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorZeroAddressPriceFeed() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(0),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorZeroAddressOraclePool() public {
        customSender.setOraclePool(address(0));

        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        _deployConsumer();
    }

    function testConstructorZeroAddressGho() public {
        customSender.setGho(address(0));

        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        _deployConsumer();
    }

    function testConstructorZeroAddressSGho() public {
        customSender.setSGho(address(0));

        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        _deployConsumer();
    }

    function testConstructorZeroMinGhoBalance() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            0,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorZeroMinSGhoBalance() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            0,
            SYNC_AMOUNT,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorZeroSyncAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            0,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorFeeOtoDTooShort() public {
        bytes memory shortFee = abi.encode(MAX_FEE, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.FeeOtoDTooShort.selector,
                shortFee.length,
                96
            )
        );
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            shortFee,
            EXTRA_ARGS
        );
    }

    function testConstructorInsufficientGasLimit() public {
        uint32 tooLittleGas = 400_000 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.InsufficientGasLimit.selector,
                tooLittleGas,
                400_000
            )
        );
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE,
            SYNC_AMOUNT,
            _feeData(MAX_FEE, false, tooLittleGas),
            EXTRA_ARGS
        );
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit IReceiver.ForwarderAddressUpdated(address(0), FORWARDER);
        SyncKeeperConsumer c = _deployConsumer();

        assertEq(c.getForwarderAddress(), FORWARDER, "forwarder");
        assertEq(c.owner(), address(this), "owner");
        assertEq(c.CUSTOM_SENDER(), address(customSender), "customSender");
        assertEq(c.GHO(), address(gho), "gho");
        assertEq(c.SGHO(), address(sGho), "sGho");
        assertEq(c.priceFeed(), address(feed), "priceFeed");
        assertEq(c.maxPriceStaleness(), MAX_PRICE_STALENESS, "maxStaleness");
        assertEq(c.minGhoBalance(), MIN_GHO_BALANCE, "minGhoBalance");
        assertEq(c.minSGhoBalance(), MIN_SGHO_BALANCE, "minSGhoBalance");
        assertEq(c.syncAmount(), SYNC_AMOUNT, "syncAmount");
        assertEq(c.feeOtoD(), _defaultFeeData(), "feeOtoD");
        assertEq(c.extraArgs(), EXTRA_ARGS, "extraArgs");
        assertEq(c.MIN_PROCESS_MESSAGE_GAS(), 400_000, "minProcessMessageGas");
    }

    /// @dev The GHO and SGHO addresses are cached at construction, so later changes on the sender
    ///      do not affect an already deployed consumer.
    function testConstructorCachesTokensFromSender() public {
        SyncKeeperConsumer c = _deployConsumer();
        customSender.setGho(makeAddr("otherGho"));

        assertEq(c.GHO(), address(gho), "gho stays cached");
    }
}

/**
 * @title ReceiveTest
 * @notice Unit tests for the SyncKeeperConsumer native token receive hook
 * @dev Run with: forge test --match-contract ReceiveTest -vvv
 */
contract ReceiveTest is TestSyncKeeperConsumerBase {
    function testReceiveAcceptsNative() public {
        vm.deal(USER, 1 ether);

        vm.prank(USER);
        (bool success, ) = address(consumer).call{value: 1 ether}("");

        assertTrue(success, "native transfer rejected");
        assertEq(address(consumer).balance, 1 ether, "balance");
    }
}

/**
 * @title SetMinGhoBalanceTest
 * @notice Unit tests for SyncKeeperConsumer.setMinGhoBalance
 * @dev Run with: forge test --match-contract SetMinGhoBalanceTest -vvv
 */
contract SetMinGhoBalanceTest is TestSyncKeeperConsumerBase {
    function testSetMinGhoBalanceNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setMinGhoBalance(1 ether);
    }

    function testSetMinGhoBalanceZeroAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        consumer.setMinGhoBalance(0);
    }

    function testSetMinGhoBalance() public {
        uint256 newValue = 777 ether;

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.MinGhoBalanceUpdated(
            MIN_GHO_BALANCE,
            newValue
        );
        consumer.setMinGhoBalance(newValue);

        assertEq(consumer.minGhoBalance(), newValue);
    }

    /// @dev The two thresholds are independent.
    function testSetMinGhoBalanceLeavesSGhoThreshold() public {
        consumer.setMinGhoBalance(777 ether);

        assertEq(consumer.minSGhoBalance(), MIN_SGHO_BALANCE);
    }
}

/**
 * @title SetMinSGhoBalanceTest
 * @notice Unit tests for SyncKeeperConsumer.setMinSGhoBalance
 * @dev Run with: forge test --match-contract SetMinSGhoBalanceTest -vvv
 */
contract SetMinSGhoBalanceTest is TestSyncKeeperConsumerBase {
    function testSetMinSGhoBalanceNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setMinSGhoBalance(1 ether);
    }

    function testSetMinSGhoBalanceZeroAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        consumer.setMinSGhoBalance(0);
    }

    function testSetMinSGhoBalance() public {
        uint256 newValue = 555 ether;

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.MinSGhoBalanceUpdated(
            MIN_SGHO_BALANCE,
            newValue
        );
        consumer.setMinSGhoBalance(newValue);

        assertEq(consumer.minSGhoBalance(), newValue);
    }

    function testSetMinSGhoBalanceLeavesGhoThreshold() public {
        consumer.setMinSGhoBalance(555 ether);

        assertEq(consumer.minGhoBalance(), MIN_GHO_BALANCE);
    }
}

/**
 * @title SetSyncAmountTest
 * @notice Unit tests for SyncKeeperConsumer.setSyncAmount
 * @dev Run with: forge test --match-contract SetSyncAmountTest -vvv
 */
contract SetSyncAmountTest is TestSyncKeeperConsumerBase {
    function testSetSyncAmountNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setSyncAmount(1 ether);
    }

    function testSetSyncAmountZeroAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        consumer.setSyncAmount(0);
    }

    function testSetSyncAmount() public {
        uint256 newValue = 555 ether;

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncAmountUpdated(SYNC_AMOUNT, newValue);
        consumer.setSyncAmount(newValue);

        assertEq(consumer.syncAmount(), newValue);
    }
}

/**
 * @title SetFeeOtoDTest
 * @notice Unit tests for SyncKeeperConsumer.setFeeOtoD
 * @dev Run with: forge test --match-contract SetFeeOtoDTest -vvv
 */
contract SetFeeOtoDTest is TestSyncKeeperConsumerBase {
    function testSetFeeOtoDNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setFeeOtoD(_defaultFeeData());
    }

    function testSetFeeOtoDTooShort() public {
        bytes memory shortFee = abi.encode(MAX_FEE, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.FeeOtoDTooShort.selector,
                shortFee.length,
                96
            )
        );
        consumer.setFeeOtoD(shortFee);
    }

    function testSetFeeOtoDInsufficientGasLimit() public {
        uint32 tooLittleGas = 400_000 - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.InsufficientGasLimit.selector,
                tooLittleGas,
                400_000
            )
        );
        consumer.setFeeOtoD(_feeData(MAX_FEE, false, tooLittleGas));
    }

    function testSetFeeOtoDAtMinimumGasLimit() public {
        bytes memory newFee = _feeData(MAX_FEE, false, 400_000);
        consumer.setFeeOtoD(newFee);

        assertEq(consumer.feeOtoD(), newFee, "minimum gas limit accepted");
    }

    function testSetFeeOtoD() public {
        uint128 newMaxFee = 2 ether;
        bytes memory newFee = _feeData(newMaxFee, true, GAS_LIMIT);

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.FeeOtoDUpdated(newMaxFee, true, GAS_LIMIT);
        consumer.setFeeOtoD(newFee);

        assertEq(consumer.feeOtoD(), newFee);
    }
}

/**
 * @title SetExtraArgsTest
 * @notice Unit tests for SyncKeeperConsumer.setExtraArgs
 * @dev Run with: forge test --match-contract SetExtraArgsTest -vvv
 */
contract SetExtraArgsTest is TestSyncKeeperConsumerBase {
    function testSetExtraArgsNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setExtraArgs(hex"dead");
    }

    function testSetExtraArgs() public {
        bytes memory newArgs = hex"deadbeef";

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.ExtraArgsUpdated(newArgs);
        consumer.setExtraArgs(newArgs);

        assertEq(consumer.extraArgs(), newArgs);
    }

    function testSetExtraArgsEmpty() public {
        consumer.setExtraArgs("");

        assertEq(consumer.extraArgs(), "", "empty extra args accepted");
    }
}

/**
 * @title SetPriceFeedTest
 * @notice Unit tests for SyncKeeperConsumer.setPriceFeed
 * @dev Run with: forge test --match-contract SetPriceFeedTest -vvv
 */
contract SetPriceFeedTest is TestSyncKeeperConsumerBase {
    function testSetPriceFeedNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setPriceFeed(makeAddr("newFeed"));
    }

    function testSetPriceFeedZeroAddress() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        consumer.setPriceFeed(address(0));
    }

    function testSetPriceFeed() public {
        address newFeed = makeAddr("newFeed");

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.PriceFeedUpdated(address(feed), newFeed);
        consumer.setPriceFeed(newFeed);

        assertEq(consumer.priceFeed(), newFeed);
    }
}

/**
 * @title SetMaxPriceStalenessTest
 * @notice Unit tests for SyncKeeperConsumer.setMaxPriceStaleness
 * @dev Run with: forge test --match-contract SetMaxPriceStalenessTest -vvv
 */
contract SetMaxPriceStalenessTest is TestSyncKeeperConsumerBase {
    function testSetMaxPriceStalenessNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setMaxPriceStaleness(1 hours);
    }

    function testSetMaxPriceStaleness() public {
        uint256 newValue = 2 hours;

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.MaxPriceStalenessUpdated(
            MAX_PRICE_STALENESS,
            newValue
        );
        consumer.setMaxPriceStaleness(newValue);

        assertEq(consumer.maxPriceStaleness(), newValue);
    }
}

/**
 * @title NeedsUpkeepTest
 * @notice Unit tests for SyncKeeperConsumer.needsUpkeep across all four pool states
 * @dev Run with: forge test --match-contract NeedsUpkeepTest -vvv
 */
contract NeedsUpkeepTest is TestSyncKeeperConsumerBase {
    function testNeedsUpkeepOraclePoolNotSet() public {
        _setGhoShort();
        customSender.setOraclePool(address(0));

        assertFalse(consumer.needsUpkeep(), "unset pool must not need upkeep");
    }

    function testNeedsUpkeepBothSidesFunded() public {
        _setPoolBalances(MIN_GHO_BALANCE, MIN_SGHO_BALANCE);

        assertFalse(consumer.needsUpkeep(), "at threshold is funded");
    }

    function testNeedsUpkeepGhoShort() public {
        _setGhoShort();

        assertTrue(consumer.needsUpkeep());
    }

    function testNeedsUpkeepSGhoShort() public {
        _setSGhoShort();

        assertTrue(consumer.needsUpkeep());
    }

    /// @dev With both sides short there is no surplus token to send, so there is no safe move and
    ///      the workflow must not waste a report.
    function testNeedsUpkeepBothSidesShort() public {
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE - 1);

        assertFalse(consumer.needsUpkeep(), "both short has no surplus");
    }

    /// @dev Each threshold is strictly below, so an exact match counts as funded.
    function testNeedsUpkeepAtThresholdIsFunded() public {
        _setPoolBalances(MIN_GHO_BALANCE, MIN_SGHO_BALANCE * 5);

        assertFalse(consumer.needsUpkeep());
    }

    /// @dev A short side with a counterpart sitting exactly on its own threshold has nothing spare
    ///      to send, so no report should be submitted.
    function testNeedsUpkeepSurplusExactlyAtFloor() public {
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE);

        assertFalse(consumer.needsUpkeep(), "nothing spare above the floor");
    }

    function testNeedsUpkeep(uint256 ghoBalance, uint256 sGhoBalance) public {
        ghoBalance = bound(ghoBalance, 0, MAX_FUZZ_AMOUNT);
        sGhoBalance = bound(sGhoBalance, 0, MAX_FUZZ_AMOUNT);
        _setPoolBalances(ghoBalance, sGhoBalance);

        bool ghoShort = ghoBalance < MIN_GHO_BALANCE;
        bool sGhoShort = sGhoBalance < MIN_SGHO_BALANCE;

        // Upkeep is needed exactly when one side is short and the other holds something above its
        // own threshold to send.
        bool expected = false;
        if (ghoShort != sGhoShort) {
            uint256 sendable = ghoShort
                ? sGhoBalance - MIN_SGHO_BALANCE
                : ghoBalance - MIN_GHO_BALANCE;
            expected = sendable > 0;
        }

        assertEq(consumer.needsUpkeep(), expected);
    }
}

/**
 * @title OnReportTest
 * @notice Unit tests for the SyncKeeperConsumer report processing and rebalance path
 * @dev Run with: forge test --match-contract OnReportTest -vvv
 */
contract OnReportTest is TestSyncKeeperConsumerBase {
    function setUp() public override {
        super.setUp();

        // Default to a pool short of GHO, and a consumer funded for a native fee.
        _setGhoShort();
        vm.deal(address(consumer), 10 ether);
    }

    function testOnReportInvalidSender() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReceiver.InvalidSender.selector,
                USER,
                FORWARDER
            )
        );
        consumer.onReport("", "");
    }

    function testOnReportOracleMisconfigured() public {
        customSender.setOraclePool(address(0));

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncSkippedOracleMisconfigured();
        _submitReport();

        assertEq(customSender.syncCallCount(), 0, "must not sync");
    }

    function testOnReportUpkeepNotNeeded() public {
        _setPoolBalances(MIN_GHO_BALANCE, MIN_SGHO_BALANCE);

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncSkippedUpkeepNotNeeded(
            MIN_GHO_BALANCE,
            MIN_SGHO_BALANCE
        );
        _submitReport();

        assertEq(customSender.syncCallCount(), 0, "must not sync");
    }

    /// @dev Sending either token would deepen the other side's deficit, so nothing is sent.
    function testOnReportNoSurplus() public {
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE - 1);

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncSkippedNoSurplus(
            MIN_GHO_BALANCE - 1,
            MIN_SGHO_BALANCE - 1
        );
        _submitReport();

        assertEq(customSender.syncCallCount(), 0, "must not sync");
    }

    /// @dev Short of GHO: send the surplus sGHO to retrieve GHO.
    function testOnReportGhoShortSendsSGho() public {
        _setGhoShort();

        _submitReport();

        assertEq(customSender.syncCallCount(), 1, "sync count");
        assertEq(customSender.lastToken(), address(sGho), "sends sGHO");
        assertEq(customSender.lastAmount(), SYNC_AMOUNT, "amount");
        assertEq(
            customSender.lastMinAmountOut(),
            _expectedGhoOut(SYNC_AMOUNT, FEED_ANSWER),
            "minAmountOut priced as sGHO -> GHO"
        );
        assertEq(customSender.lastFeeData(), _defaultFeeData(), "feeData");
        assertEq(customSender.lastExtraArgs(), EXTRA_ARGS, "extraArgs");
        assertEq(customSender.lastValue(), MAX_FEE, "native fee forwarded");
    }

    /// @dev Short of sGHO: send the surplus GHO to retrieve sGHO.
    function testOnReportSGhoShortSendsGho() public {
        _setSGhoShort();

        _submitReport();

        assertEq(customSender.syncCallCount(), 1, "sync count");
        assertEq(customSender.lastToken(), address(gho), "sends GHO");
        assertEq(customSender.lastAmount(), SYNC_AMOUNT, "amount");
        assertEq(
            customSender.lastMinAmountOut(),
            _expectedSGhoOut(SYNC_AMOUNT, FEED_ANSWER),
            "minAmountOut priced as GHO -> sGHO"
        );
    }

    function testOnReportEmitsSyncPerformed() public {
        _setGhoShort();

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncPerformed(
            address(sGho),
            SYNC_AMOUNT,
            _expectedGhoOut(SYNC_AMOUNT, FEED_ANSWER)
        );
        _submitReport();
    }

    /// @dev The two directions must price inversely. At a rate above parity, sending sGHO returns
    ///      MORE GHO, while sending GHO returns FEWER sGHO.
    function testOnReportPricesDirectionsInversely() public {
        feed.setAnswer(2e18); // 1 sGHO share is worth 2 GHO

        _setGhoShort();
        _submitReport();
        assertEq(
            customSender.lastMinAmountOut(),
            SYNC_AMOUNT * 2,
            "sGHO -> GHO multiplies"
        );

        _setSGhoShort();
        _submitReport();
        assertEq(
            customSender.lastMinAmountOut(),
            SYNC_AMOUNT / 2,
            "GHO -> sGHO divides"
        );
    }

    /// @dev The amount is capped at what the surplus side holds ABOVE its own threshold, so
    ///      OraclePool.pull cannot revert and the surplus side is never drawn through its floor.
    function testOnReportCapsAmountAtSurplusAboveFloor() public {
        // sGHO is the surplus but holds only a quarter of syncAmount above its threshold.
        uint256 spare = SYNC_AMOUNT / 4;
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE + spare);

        _submitReport();

        assertEq(customSender.lastToken(), address(sGho), "sends sGHO");
        assertEq(customSender.lastAmount(), spare, "capped at spare above floor");
        assertEq(
            customSender.lastMinAmountOut(),
            _expectedGhoOut(spare, FEED_ANSWER),
            "minAmountOut uses the capped amount"
        );
    }

    /// @dev The anti-drift property: a sync must never draw the surplus side below its own
    ///      threshold, which would flip the shortage over and oscillate on the next tick.
    function testOnReportNeverDrawsSurplusBelowItsFloor() public {
        // syncAmount is far larger than the spare sGHO above the threshold.
        consumer.setSyncAmount(MIN_SGHO_BALANCE * 100);
        uint256 spare = 1 ether;
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE + spare);

        _submitReport();

        assertEq(customSender.lastAmount(), spare, "sends only the spare");

        uint256 remaining = sGho.balanceOf(ORACLE_POOL) -
            customSender.lastAmount();
        assertEq(remaining, MIN_SGHO_BALANCE, "surplus side lands on its floor");
        assertGe(remaining, MIN_SGHO_BALANCE, "never below its floor");
    }

    /// @dev A funded side sitting exactly on its threshold has nothing spare, so there is no safe
    ///      sync even though the other side is short.
    function testOnReportSurplusExactlyAtFloorHasNothingToSend() public {
        _setPoolBalances(MIN_GHO_BALANCE - 1, MIN_SGHO_BALANCE);

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncSkippedNoSurplus(
            MIN_GHO_BALANCE - 1,
            MIN_SGHO_BALANCE
        );
        _submitReport();

        assertEq(customSender.syncCallCount(), 0, "must not sync");
    }

    function testOnReportSyncsPayingInGho() public {
        consumer.setFeeOtoD(_feeData(MAX_FEE, true, GAS_LIMIT));

        _submitReport();

        assertEq(customSender.syncCallCount(), 1, "sync count");
        assertEq(customSender.lastValue(), 0, "no native value when paying GHO");
    }

    /// @dev The consumer holds no native token, so forwarding the fee fails.
    function testOnReportRevertsWithoutNativeBalance() public {
        vm.deal(address(consumer), 0);

        vm.prank(FORWARDER);
        vm.expectRevert();
        consumer.onReport("", "");
    }

    function testOnReportInvalidPriceZero() public {
        feed.setAnswer(0);

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(ISyncKeeperConsumer.InvalidPrice.selector, 0)
        );
        consumer.onReport("", "");
    }

    function testOnReportInvalidPriceNegative() public {
        feed.setAnswer(-1);

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.InvalidPrice.selector,
                -1
            )
        );
        consumer.onReport("", "");
    }

    function testOnReportStalePriceFeed() public {
        uint256 updatedAt = block.timestamp - MAX_PRICE_STALENESS - 1;
        feed.setUpdatedAt(updatedAt);

        vm.prank(FORWARDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyncKeeperConsumer.StalePriceFeed.selector,
                updatedAt,
                MAX_PRICE_STALENESS
            )
        );
        consumer.onReport("", "");
    }

    /// @dev An answer exactly at the staleness limit is still accepted.
    function testOnReportPriceAtStalenessLimit() public {
        feed.setUpdatedAt(block.timestamp - MAX_PRICE_STALENESS);

        _submitReport();

        assertEq(customSender.syncCallCount(), 1, "sync count");
    }

    /// @dev A feed reporting a timestamp in the future underflows instead of reverting cleanly.
    function testOnReportFutureUpdatedAt() public {
        feed.setUpdatedAt(block.timestamp + 1);

        vm.prank(FORWARDER);
        vm.expectRevert(stdError.arithmeticError);
        consumer.onReport("", "");
    }

    function testOnReportMinAmountOut(int256 answer) public {
        answer = bound(answer, 1, int256(1_000e18));
        feed.setAnswer(answer);

        _submitReport();

        assertEq(
            customSender.lastMinAmountOut(),
            _expectedGhoOut(SYNC_AMOUNT, answer),
            "minAmountOut"
        );
    }

    function testOnReportSyncsUpdatedAmount() public {
        uint256 newAmount = 42 ether;
        consumer.setSyncAmount(newAmount);

        _submitReport();

        assertEq(customSender.lastAmount(), newAmount, "uses updated amount");
    }

    /// @dev The report body is ignored, so an arbitrary payload still syncs.
    function testOnReportIgnoresReportBody() public {
        vm.prank(FORWARDER);
        consumer.onReport("", abi.encode(uint256(1234), "junk"));

        assertEq(customSender.syncCallCount(), 1, "sync count");
    }

    /// @dev The gate is re-derived on chain, so a report submitted while GHO was short but executed
    ///      after the pool refilled is a no-op rather than a wrong-direction sync.
    function testOnReportReDerivesStateAtExecution() public {
        _setSGhoShort();

        _submitReport();

        assertEq(customSender.lastToken(), address(gho), "re-derived to GHO");
    }

    /// @dev needsUpkeep stays true until the short side is refilled, so reports can stack.
    function testOnReportSyncsRepeatedly() public {
        _submitReport();
        _submitReport();

        assertEq(customSender.syncCallCount(), 2, "no cooldown between syncs");
    }
}

/**
 * @title SupportsInterfaceTest
 * @notice Unit tests for SyncKeeperConsumer ERC-165 support
 * @dev Run with: forge test --match-contract SupportsInterfaceTest -vvv
 */
contract SupportsInterfaceTest is TestSyncKeeperConsumerBase {
    function testSupportsInterfaceReceiver() public view {
        assertTrue(consumer.supportsInterface(type(IReceiver).interfaceId));
    }

    function testSupportsInterfaceErc165() public view {
        assertTrue(consumer.supportsInterface(type(IERC165).interfaceId));
    }

    function testSupportsInterfaceUnknown() public view {
        assertFalse(consumer.supportsInterface(0xffffffff));
    }
}
