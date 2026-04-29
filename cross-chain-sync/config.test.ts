import { describe, expect, test } from "bun:test";
import { configSchema } from "./config";

describe("configSchema", () => {
  const base = {
    schedule: "0 */4 * * *",
    chainSelectorName: "ethereum-testnet-sepolia",
    isTestnet: true,
    consumerAddress: "0x1111111111111111111111111111111111111111",
    gasLimit: "500000",
  } as const;

  test("accepts minimal valid config", () => {
    const parsed = configSchema.parse(base);
    expect(parsed.consumerAddress).toBe(base.consumerAddress);
    expect(parsed.gasLimit).toBe("500000");
  });

  test("accepts optional evmCallFrom", () => {
    const parsed = configSchema.parse({
      ...base,
      evmCallFrom: "0x2222222222222222222222222222222222222222",
    });
    expect(parsed.evmCallFrom).toBe("0x2222222222222222222222222222222222222222");
  });

  test("rejects invalid consumer address", () => {
    expect(() =>
      configSchema.parse({
        ...base,
        consumerAddress: "0x123",
      })
    ).toThrow();
  });

  test("rejects non-numeric gasLimit", () => {
    expect(() =>
      configSchema.parse({
        ...base,
        gasLimit: "abc",
      })
    ).toThrow();
  });
});
