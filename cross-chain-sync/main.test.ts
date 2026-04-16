import { describe, expect } from "bun:test";
import { TxStatus, type Runtime } from "@chainlink/cre-sdk";
import { EvmMock, newTestRuntime, test } from "@chainlink/cre-sdk/test";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import type { Config } from "./config";
import { initWorkflow, onCronTrigger } from "./main";

/** ethereum-testnet-sepolia — same as EVMClient.SUPPORTED_CHAIN_SELECTORS */
const CHAIN_SELECTOR = 16015286601757825753n;

const feeOtoD = encodeAbiParameters(
  parseAbiParameters("uint128, bool, uint32"),
  [100000000000000000n, false, 400_000]
) as `0x${string}`;

/** Bufbuild `fromJson` for protobuf `bytes` expects base64, not `0x` hex (see EvmMock path). */
function callContractReturnBool(value: boolean): { data: string } {
  const hex = encodeAbiParameters(parseAbiParameters("bool"), [value]);
  return { data: Buffer.from(hex.slice(2), "hex").toString("base64") };
}

function baseConfig(over: Partial<Config> = {}): Config {
  return {
    schedule: "0 */4 * * *",
    chainSelectorName: "ethereum-testnet-sepolia",
    isTestnet: true,
    consumerAddress: "0x1111111111111111111111111111111111111111",
    gasLimit: "500000",
    destChainSelector: "5009297550715157269",
    syncAmount: "1",
    feeOtoD,
    ...over,
  };
}

describe("initWorkflow", () => {
  test("subscribes onCronTrigger to the configured cron schedule", () => {
    const config = baseConfig({ schedule: "0 */4 * * *" });
    const handlers = initWorkflow(config);

    expect(handlers).toHaveLength(1);
    expect(handlers[0].fn).toBe(onCronTrigger);
    const cronTrigger = handlers[0].trigger as { config?: { schedule?: string } };
    expect(cronTrigger.config?.schedule).toBe(config.schedule);
  });
});

describe("onCronTrigger", () => {
  test("skips write when needsUpkeep is false", () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => callContractReturnBool(false);

    const runtime = newTestRuntime();
    runtime.config = baseConfig();

    const out = onCronTrigger(runtime as Runtime<Config>);
    expect(out).toContain("Skip sync");
    expect(runtime.getLogs().some((l) => l.includes("needsUpkeep (on-chain): false"))).toBe(
      true
    );
  });

  test("submits writeReport when needsUpkeep is true", () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => callContractReturnBool(true);
    evmMock.writeReport = () =>
      ({
        txStatus: TxStatus.SUCCESS,
        txHash: `0x${"c3".repeat(32)}`,
      }) as unknown as ReturnType<NonNullable<(typeof evmMock)["writeReport"]>>;

    const runtime = newTestRuntime();
    runtime.config = baseConfig({ syncAmount: "42" });

    const out = onCronTrigger(runtime as Runtime<Config>);
    expect(out).toContain("Submitted sync");
    expect(out).toContain("tx=0x");
    expect(runtime.getLogs().some((l) => l.includes("Sync writeReport tx:"))).toBe(true);
  });
});

describe("EvmMock", () => {
  test("registers callContract + writeReport handlers for the chain selector", () => {
    const evmMock = EvmMock.testInstance(CHAIN_SELECTOR);
    evmMock.callContract = () => callContractReturnBool(true);
    evmMock.writeReport = () =>
      ({
        txStatus: TxStatus.SUCCESS,
        txHash: new Uint8Array(32),
      }) as unknown as ReturnType<NonNullable<(typeof evmMock)["writeReport"]>>;
    expect(typeof evmMock.callContract).toBe("function");
    expect(typeof evmMock.writeReport).toBe("function");
  });
});
