// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title FeeCodec Library.
 * @dev A library for encoding and decoding fee-related data.
 */
library FeeCodec {
    /**
     * @dev Error thrown when the length of the packed data is invalid.
     * @param length The actual length of the provided data.
     * @param expectedLength The length that was expected (minimum or exact, depending on the caller).
     */
    error FeeCodecInvalidDataLength(uint256 length, uint256 expectedLength);

    /**
     * @dev Encodes the fee data for a Cross-Chain Interoperability Protocol (CCIP) transfer.
     * The layout is: 16 bytes `maxFee`, 1 byte `payInLink`, 4 bytes `gasLimit` (21 bytes total).
     * @param maxFee The maximum fee that the sender is willing to pay.
     * @param payInLink Whether the fee should be paid in LINK tokens (true) or in the native token of the source chain (false).
     * @param gasLimit The minimum amount of gas that should be used to execute the transaction on the destination chain.
     * @return The encoded CCIP fee data.
     */
    function encodeCCIP(
        uint128 maxFee,
        bool payInLink,
        uint32 gasLimit
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(maxFee, payInLink, gasLimit);
    }

    /**
     * @dev Decodes the fee data for a Cross-Chain Interoperability Protocol (CCIP) transfer.
     * Reads 16 bytes for `maxFee`, 1 byte for `payInLink`, and 4 bytes for `gasLimit`.
     *
     * Requirements:
     *
     * - `feeData` must have a length of 21 bytes.
     *
     * @param feeData The encoded CCIP fee data to decode.
     * @return maxFee The maximum fee that the sender is willing to pay.
     * @return payInLink Whether the fee should be paid in LINK tokens (true) or in the native token of the source chain (false).
     * @return gasLimit The minimum amount of gas that should be used to execute the transaction on the destination chain.
     */
    function decodeCCIP(
        bytes calldata feeData
    ) internal pure returns (uint128 maxFee, bool payInLink, uint32 gasLimit) {
        if (feeData.length != 21)
            revert FeeCodecInvalidDataLength(feeData.length, 21);
        maxFee = uint128(bytes16(feeData[0:16]));
        payInLink = feeData[16] != 0;
        gasLimit = uint32(bytes4(feeData[17:21]));
    }

    /**
     * @dev Memory variant of {decodeCCIP}. Decodes the fee data for a CCIP transfer,
     * reading 16 bytes for `maxFee`, 1 byte for `payInLink`, and 4 bytes for `gasLimit`.
     *
     * Requirements:
     *
     * - `feeData` must have a length of at least 21 bytes.
     *
     * @param feeData The encoded CCIP fee data to decode.
     * @return maxFee The maximum fee that the sender is willing to pay.
     * @return payInLink Whether the fee should be paid in LINK tokens (true) or in the native token of the source chain (false).
     * @return gasLimit The minimum amount of gas that should be used to execute the transaction on the destination chain.
     */
    function decodeCCIPMemory(
        bytes memory feeData
    ) internal pure returns (uint128 maxFee, bool payInLink, uint32 gasLimit) {
        if (feeData.length < 21)
            revert FeeCodecInvalidDataLength(feeData.length, 21);
        bytes32 value = bytes32(feeData);

        maxFee = uint128(bytes16(value));
        payInLink = uint8(uint256(value) >> 120) != 0;
        gasLimit = uint32(uint256(value) >> 88);
    }
}
