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
    uint256 public constant MIN_ORACLE_POOL_BALANCE = 100_000 ether;
    uint256 public constant SYNC_AMOUNT = 10_000 ether;
    uint256 public constant MAX_PRICE_STALENESS = 1 days;
    uint128 public constant MAX_FEE = 1 ether;
    uint32 public constant GAS_LIMIT = 500_000;

    uint8 public constant FEED_DECIMALS = 18;
    /// @dev 1 sGHO share is worth exactly 1 GHO, so `minAmountOut` equals the synced amount.
    int256 public constant FEED_ANSWER = 1e18;

    uint256 public constant MAX_FUZZ_AMOUNT = 1_000_000_000 ether;
    bytes public constant EXTRA_ARGS = hex"c0ffee";

    address public immutable FORWARDER = makeAddr("forwarder");
    address public immutable USER = makeAddr("user");
    address public immutable ORACLE_POOL = makeAddr("oraclePool");

    MockERC20 internal gho;
    MockERC20 internal sgho;
    MockCustomSender internal customSender;
    MockAggregatorV3 internal feed;
    SyncKeeperConsumer internal consumer;

    function setUp() public virtual {
        // Start at a non-zero timestamp so that tests can move the feed update time backwards.
        vm.warp(365 days);

        gho = new MockERC20("GHO", "GHO");
        sgho = new MockERC20("Staked GHO", "sGHO");
        customSender = new MockCustomSender(
            address(gho),
            address(sgho),
            ORACLE_POOL
        );
        feed = new MockAggregatorV3(FEED_DECIMALS, FEED_ANSWER);

        consumer = _deployConsumer();
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
                MIN_ORACLE_POOL_BALANCE,
                SYNC_AMOUNT,
                _defaultFeeData(),
                EXTRA_ARGS
            );
    }

    /// @dev Forces the GHO balance of the oracle pool to exactly `amount`.
    function _setPoolBalance(uint256 amount) internal {
        uint256 current = gho.balanceOf(ORACLE_POOL);
        if (amount > current) {
            gho.mint(ORACLE_POOL, amount - current);
        } else if (amount < current) {
            gho.burn(ORACLE_POOL, current - amount);
        }
    }

    /// @dev Submits a report as the trusted forwarder. Metadata is empty, as no workflow identity
    ///      check is configured by default.
    function _submitReport() internal {
        vm.prank(FORWARDER);
        consumer.onReport("", "");
    }

    function _expectedMinAmountOut(
        uint256 ghoAmount,
        int256 answer
    ) internal pure returns (uint256) {
        return (ghoAmount * (10 ** FEED_DECIMALS)) / uint256(answer);
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
            MIN_ORACLE_POOL_BALANCE,
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
            MIN_ORACLE_POOL_BALANCE,
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
            MIN_ORACLE_POOL_BALANCE,
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

    function testConstructorZeroAddressSgho() public {
        customSender.setSgho(address(0));

        vm.expectRevert(ISyncKeeperConsumer.ZeroAddress.selector);
        _deployConsumer();
    }

    function testConstructorZeroSyncAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        new SyncKeeperConsumer(
            FORWARDER,
            address(customSender),
            address(feed),
            MAX_PRICE_STALENESS,
            MIN_ORACLE_POOL_BALANCE,
            0,
            _defaultFeeData(),
            EXTRA_ARGS
        );
    }

    function testConstructorFeeOtoDTooShort() public {
        // Two words instead of the three required to decode (uint128, bool, uint32).
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
            MIN_ORACLE_POOL_BALANCE,
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
            MIN_ORACLE_POOL_BALANCE,
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
        assertEq(c.SGHO(), address(sgho), "sgho");
        assertEq(c.priceFeed(), address(feed), "priceFeed");
        assertEq(c.maxPriceStaleness(), MAX_PRICE_STALENESS, "maxStaleness");
        assertEq(
            c.minOraclePoolBalance(),
            MIN_ORACLE_POOL_BALANCE,
            "minOraclePoolBalance"
        );
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
 * @title SetMinOraclePoolBalanceTest
 * @notice Unit tests for SyncKeeperConsumer.setMinOraclePoolBalance
 * @dev Run with: forge test --match-contract SetMinOraclePoolBalanceTest -vvv
 */
contract SetMinOraclePoolBalanceTest is TestSyncKeeperConsumerBase {
    function testSetMinOraclePoolBalanceNonOwner() public {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                USER
            )
        );
        consumer.setMinOraclePoolBalance(1 ether);
    }

    function testSetMinOraclePoolBalanceZeroAmount() public {
        vm.expectRevert(ISyncKeeperConsumer.ZeroAmount.selector);
        consumer.setMinOraclePoolBalance(0);
    }

    function testSetMinOraclePoolBalance() public {
        uint256 newValue = 777 ether;

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.MinOraclePoolBalanceUpdated(
            MIN_ORACLE_POOL_BALANCE,
            newValue
        );
        consumer.setMinOraclePoolBalance(newValue);

        assertEq(consumer.minOraclePoolBalance(), newValue);
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
 * @notice Unit tests for SyncKeeperConsumer.needsUpkeep
 * @dev Run with: forge test --match-contract NeedsUpkeepTest -vvv
 */
contract NeedsUpkeepTest is TestSyncKeeperConsumerBase {
    function testNeedsUpkeepOraclePoolNotSet() public {
        _setPoolBalance(0);
        customSender.setOraclePool(address(0));

        assertFalse(consumer.needsUpkeep(), "unset pool must not need upkeep");
    }

    function testNeedsUpkeepBalanceAboveThreshold() public {
        _setPoolBalance(MIN_ORACLE_POOL_BALANCE + 1);

        assertFalse(consumer.needsUpkeep());
    }

    /// @dev The gate is strictly below the threshold, so an exact match needs no upkeep.
    function testNeedsUpkeepBalanceAtThreshold() public {
        _setPoolBalance(MIN_ORACLE_POOL_BALANCE);

        assertFalse(consumer.needsUpkeep());
    }

    function testNeedsUpkeepBalanceBelowThreshold() public {
        _setPoolBalance(MIN_ORACLE_POOL_BALANCE - 1);

        assertTrue(consumer.needsUpkeep());
    }

    function testNeedsUpkeep(uint256 balance) public {
        balance = bound(balance, 0, MAX_FUZZ_AMOUNT);
        _setPoolBalance(balance);

        assertEq(consumer.needsUpkeep(), balance < MIN_ORACLE_POOL_BALANCE);
    }
}

/**
 * @title OnReportTest
 * @notice Unit tests for the SyncKeeperConsumer report processing path
 * @dev Run with: forge test --match-contract OnReportTest -vvv
 */
contract OnReportTest is TestSyncKeeperConsumerBase {
    function setUp() public override {
        super.setUp();

        // Default to a pool that needs topping up, and a consumer funded for a native fee.
        _setPoolBalance(MIN_ORACLE_POOL_BALANCE - 1);
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
        _setPoolBalance(MIN_ORACLE_POOL_BALANCE);

        vm.expectEmit(true, true, true, true, address(consumer));
        emit ISyncKeeperConsumer.SyncSkippedUpkeepNotNeeded(
            MIN_ORACLE_POOL_BALANCE,
            MIN_ORACLE_POOL_BALANCE
        );
        _submitReport();

        assertEq(customSender.syncCallCount(), 0, "must not sync");
    }

    function testOnReportSyncsPayingInNative() public {
        _submitReport();

        assertEq(customSender.syncCallCount(), 1, "sync count");
        assertEq(customSender.lastToken(), address(gho), "always syncs GHO");
        assertEq(customSender.lastAmount(), SYNC_AMOUNT, "amount");
        assertEq(
            customSender.lastMinAmountOut(),
            _expectedMinAmountOut(SYNC_AMOUNT, FEED_ANSWER),
            "minAmountOut"
        );
        assertEq(customSender.lastFeeData(), _defaultFeeData(), "feeData");
        assertEq(customSender.lastExtraArgs(), EXTRA_ARGS, "extraArgs");
        assertEq(customSender.lastValue(), MAX_FEE, "native fee forwarded");
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
            _expectedMinAmountOut(SYNC_AMOUNT, answer),
            "minAmountOut"
        );
    }

    /// @dev A sGHO share worth more than 1 GHO buys fewer shares for the same GHO amount.
    function testOnReportMinAmountOutAboveParity() public {
        feed.setAnswer(2e18);

        _submitReport();

        assertEq(customSender.lastMinAmountOut(), SYNC_AMOUNT / 2);
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

    /// @dev needsUpkeep stays true until the pool is topped up, so reports can stack.
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
