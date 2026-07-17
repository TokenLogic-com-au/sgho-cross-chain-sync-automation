// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICustomSender} from "../../src/interfaces/ICustomSender.sol";

/// @dev Records the arguments of the last {sync} call so tests can assert on them.
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

    constructor(address gho, address sgho, address oraclePool) {
        GHO = gho;
        SGHO = sgho;
        _oraclePool = oraclePool;
    }

    function setOraclePool(address oraclePool) external {
        _oraclePool = oraclePool;
    }

    function setGho(address gho) external {
        GHO = gho;
    }

    function setSgho(address sgho) external {
        SGHO = sgho;
    }

    function sync(
        address token,
        uint256 amount,
        uint256 minAmountOut,
        bytes calldata feeData,
        bytes calldata extraArgs
    ) external payable override returns (bytes32 messageId) {
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
