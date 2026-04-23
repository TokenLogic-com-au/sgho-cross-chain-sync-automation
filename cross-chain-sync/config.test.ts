import { describe, expect, test } from "bun:test";
import { encodeAbiParameters, parseAbiParameters } from "viem";
import { configSchema } from "./config";

const feeOtoD = encodeAbiParameters(
  parseAbiParameters("uint128, bool, uint32"),
  [100000000000000000n, false, 400_000]
) as `0x${string}`;

describe("configSchema", () => {
  const base = {
    schedule: "0 */4 * * *",
    chainSelectorName: "ethereum-testnet-sepolia",
    isTestnet: true,
    consumerAddress: "0x1111111111111111111111111111111111111111",
    gasLimit: "500000",
    destChainSelector: "5009297550715157269",
    syncAmount: "1",
    feeOtoD,
  } as const;

  test("accepts boundary uint64 max", () => {
    const max = (1n << 64n) - 1n;
    const parsed = configSchema.parse({
      ...base,
      destChainSelector: max.toString(),
      syncAmount: "42",
    });
    expect(parsed.destChainSelector).toBe(max.toString());
  });

  test("accepts uint64 zero dest", () => {
    const parsed = configSchema.parse({
      ...base,
      destChainSelector: "0",
    });
    expect(parsed.destChainSelector).toBe("0");
  });

  test("rejects dest above uint64", () => {
    const tooBig = (1n << 64n).toString();
    expect(() =>
      configSchema.parse({
        ...base,
        destChainSelector: tooBig,
      })
    ).toThrow(/uint64/i);
  });

  test("rejects zero syncAmount", () => {
    expect(() =>
      configSchema.parse({
        ...base,
        syncAmount: "0",
      })
    ).toThrow(/non-zero/i);
  });

  test("rejects non-decimal destChainSelector", () => {
    expect(() =>
      configSchema.parse({
        ...base,
        destChainSelector: "12a",
      })
    ).toThrow();
  });
});
