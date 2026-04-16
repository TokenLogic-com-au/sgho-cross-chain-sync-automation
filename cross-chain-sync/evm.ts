import {
  type Runtime,
  EVMClient,
  TxStatus,
  bytesToHex,
  getNetwork,
  hexToBase64,
  encodeCallMsg,
} from "@chainlink/cre-sdk";
import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  toHex,
  type Address,
  type Hex,
} from "viem";
import type { Config } from "./config";

const needsUpkeepAbi = [
  {
    type: "function",
    name: "needsUpkeep",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "upkeepNeeded", type: "bool" }],
  },
] as const;

function callFrom(cfg: Config): Address {
  return (cfg.evmCallFrom ?? cfg.consumerAddress) as Address;
}

/** On-chain gate: `SyncKeeperConsumer.needsUpkeep()` (oracle pool balance vs contract threshold). */
export function readNeedsUpkeep(runtime: Runtime<Config>, cfg: Config): boolean {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: cfg.chainSelectorName,
    isTestnet: cfg.isTestnet,
  });
  if (!network) {
    throw new Error(`Unknown chain: ${cfg.chainSelectorName} (isTestnet=${cfg.isTestnet})`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const data = encodeFunctionData({
    abi: needsUpkeepAbi,
    functionName: "needsUpkeep",
    args: [],
  });

  const reply = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: callFrom(cfg),
        to: cfg.consumerAddress as Address,
        data: data as Hex,
      }),
    })
    .result();

  const raw = reply.data;
  if (raw === undefined || raw === null) {
    throw new Error("needsUpkeep returned empty data");
  }
  const hex: Hex = typeof raw === "string" ? (raw as Hex) : toHex(raw as Uint8Array);

  if (hex === "0x") {
    throw new Error("needsUpkeep returned empty data");
  }

  const [upkeepNeeded] = decodeAbiParameters(parseAbiParameters("bool"), hex);
  return upkeepNeeded;
}

export function submitSyncReport(
  runtime: Runtime<Config>,
  cfg: Config,
  amount: bigint,
  destChainSelector: bigint
): string {
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: cfg.chainSelectorName,
    isTestnet: cfg.isTestnet,
  });
  if (!network) {
    throw new Error(`Unknown chain: ${cfg.chainSelectorName}`);
  }

  const feeOtoD = cfg.feeOtoD as Hex;
  const reportData = encodeAbiParameters(
    parseAbiParameters("uint64 destChainSelector, uint256 amount, bytes feeOtoD"),
    [destChainSelector, amount, feeOtoD]
  );

  const report = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  const evmClient = new EVMClient(network.chainSelector.selector);
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: cfg.consumerAddress,
      report,
      gasConfig: { gasLimit: cfg.gasLimit },
    })
    .result();

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(
      `writeReport failed: ${writeResult.errorMessage ?? String(writeResult.txStatus)}`
    );
  }

  const txHash = bytesToHex(writeResult.txHash ?? new Uint8Array(32));
  if (!writeResult.txHash || writeResult.txHash.length === 0) {
    throw new Error("writeReport succeeded but tx hash missing");
  }

  return txHash;
}
