// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICustomSender} from "../../src/interfaces/ICustomSender.sol";

/// @dev Records the arguments of the last {sync} call so tests can assert on them. When the fee data
///      says to pay in `GHO`, it pulls the fee from the caller like the real `CustomSender`, so the
///      caller's `GHO` allowance to this contract is genuinely exercised.
contract MockCustomSender is ICustomSender {
    address public override GHO;
    address public override SGHO;

    address internal _oraclePool;
    bytes32 internal _messageId = bytes32(uint256(0xB0B));

    uint256 public syncCallCount;
    uint256 public lastValue;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public lastMinAmountOut;
    bytes public lastFeeData;
    bytes public lastExtraArgs;

    constructor(address gho, address sGho, address oraclePool) {
        GHO = gho;
        SGHO = sGho;
        _oraclePool = oraclePool;
    }

    function setOraclePool(address oraclePool) external {
        _oraclePool = oraclePool;
    }

    function setGho(address gho) external {
        GHO = gho;
    }

    function setSGho(address sGho) external {
        SGHO = sGho;
    }

    function sync(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata feeData,
        bytes calldata extraArgs
    ) external payable override returns (bytes32 messageId) {
        (uint128 maxFee, bool payInGho, ) = abi.decode(
            feeData,
            (uint128, bool, uint32)
        );
        if (payInGho) {
            IERC20(GHO).transferFrom(msg.sender, address(this), maxFee);
        }

        syncCallCount++;
        lastValue = msg.value;
        lastToken = token;
        lastAmount = amount;
        lastMinAmountOut = minAmountOut;
        lastFeeData = feeData;
        lastExtraArgs = extraArgs;

        return _messageId;
    }

    function getOraclePool() external view override returns (address) {
        return _oraclePool;
    }
}
