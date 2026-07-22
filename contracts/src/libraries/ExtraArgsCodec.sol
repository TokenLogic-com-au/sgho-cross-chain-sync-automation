// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

library ExtraArgsCodec {
    bytes4 public constant GENERIC_EXTRA_ARGS_V3_TAG = 0xa69dd4aa;

    struct GenericExtraArgsV3 {
        /// @notice Gas limit for the callback on the destination chain. If the gas limit is zero and the message data
        /// length is also zero, no callback will be performed, even if a receiver is specified. A gas limit of zero is
        /// useful when only token transfers are desired, or when the receiver is an EOA account instead of a contract.
        /// Besides this gasLimit check, there are other checks on the destination chain that may prevent the callback from
        /// being executed, depending on the destination chain family.
        /// @dev The sender is billed for the gas specified, not the gas actually used. Any unspent gas is not refunded.
        /// There are various ways to estimate the gas required for a callback on the destination chain, depending on the
        /// chain family. Please refer to the documentation for each chain for more details.
        uint32 gasLimit;
        /// @notice The finality config, see FinalityCodec for encoding details.
        /// @dev May be zero to indicate waiting for finality is desired.
        bytes4 requestedFinalityConfig;
        /// @notice An array of CCV addresses representing the cross-chain verifiers to be used for the message.
        /// @dev May be empty to specify the default verifier(s) should be used.
        address[] ccvs;
        /// @notice Optional arguments that are passed into the CCV without modification or inspection. CCIP itself does not
        /// interpret these arguments: they are encoded in whatever format the CCV has decided.
        /// @dev Must be the same length as the `ccvs` array. May have empty bytes as arguments.
        bytes[] ccvArgs;
        /// @notice Address of the executor contract on the source chain. The executor is responsible for executing the
        /// message on the destination chains once a quorum of CCVs have verified the message.
        /// @dev May be address(0) to indicate the default executor should be used.
        address executor;
        /// @notice Destination chain family specific arguments for the executor. This field is passed to the destination
        /// chain as part of the message itself and these args are therefore fully protected through the message ID. The
        /// format of this field is specific to each chain family and is not interpreted by CCIP itself, only by the
        /// executor. Things that may be included here are Solana accounts or Sui object IDs, which must be secured through
        /// the message ID as passing in incorrect values can lead to loss of funds.
        /// @dev May be empty depending on the destination chain.
        bytes executorArgs;
        /// @notice Address of the token receiver on the destination chain, in bytes format. If an empty bytes array is
        /// provided, the receiver address from the message itself is used for token transfers. This field allows for
        /// scenarios where the token receiver is different from the message receiver.
        /// @dev May be empty, the behavior differs depending on if there is a token transfer or not:
        /// - If there is a token transfer, the receiver from the message is used.
        /// - If there is no token transfer, this field should be empty.
        bytes tokenReceiver;
        /// @notice Additional arguments for token transfers. This field is passed into the token pool on the source chain
        /// and is not inspected by CCIP itself. The format of this field is therefore specific to the token pool being used
        /// and may vary between different pools.
        /// @dev May be empty depending on the token pool.
        bytes tokenArgs;
    }
}
