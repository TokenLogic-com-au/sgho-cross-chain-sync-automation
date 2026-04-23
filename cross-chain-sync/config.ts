import { z } from "zod";

const address = z
  .string()
  .regex(/^0x[a-fA-F0-9]{40}$/, "must be a 0x-prefixed 20-byte address");

const hexBytes = z
  .string()
  .regex(/^0x[a-fA-F0-9]*$/, "must be 0x-prefixed hex")
  .refine((h) => (h.length - 2) % 2 === 0, "hex length must be even");

const uint64Max = (1n << 64n) - 1n;

/** Decimal string; must parse to a value in [0, uint64]. */
const destChainSelectorString = z
  .string()
  .regex(/^\d+$/, "CCIP chain selector as decimal string")
  .refine((s) => {
    const n = BigInt(s);
    return n >= 0n && n <= uint64Max;
  }, "destChainSelector must fit uint64");

/** Decimal string; must be non-zero when passed to on-chain `sync`. */
const syncAmountString = z
  .string()
  .regex(/^\d+$/, "amount passed to sync, as decimal string")
  .refine((s) => BigInt(s) !== 0n, "syncAmount must be non-zero");

export const configSchema = z.object({
  schedule: z.string().min(1),
  chainSelectorName: z.string().min(1),
  isTestnet: z.boolean(),
  /** Deployed `SyncKeeperConsumer` (IReceiver + keeper gate). */
  consumerAddress: address,
  gasLimit: z.string().regex(/^\d+$/),
  destChainSelector: destChainSelectorString,
  syncAmount: syncAmountString,
  feeOtoD: hexBytes,
  evmCallFrom: address.optional(),
});

export type Config = z.infer<typeof configSchema>;

export function parseConfigJson(text: string): Config {
  return configSchema.parse(JSON.parse(text) as unknown);
}
