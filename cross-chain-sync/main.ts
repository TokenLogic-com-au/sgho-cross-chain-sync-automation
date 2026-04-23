import {
  CronCapability,
  Runner,
  handler,
  type Runtime,
} from "@chainlink/cre-sdk";
import { configSchema, type Config } from "./config";
import { readNeedsUpkeep, submitSyncReport } from "./evm";

export type { Config } from "./config";

export const onCronTrigger = (runtime: Runtime<Config>): string => {
  const cfg = runtime.config;

  const upkeepNeeded = readNeedsUpkeep(runtime, cfg);
  runtime.log(`needsUpkeep (on-chain): ${upkeepNeeded}`);

  if (!upkeepNeeded) {
    return "Skip sync: needsUpkeep is false (oracle pool balance >= on-chain threshold)";
  }

  const amount = BigInt(cfg.syncAmount);
  const dest = BigInt(cfg.destChainSelector);

  const txHash = submitSyncReport(runtime, cfg, amount, dest);
  runtime.log(`Sync writeReport tx: ${txHash}`);
  return `Submitted sync amount=${amount.toString()} dest=${dest.toString()} tx=${txHash}`;
};

export const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [
    handler(cron.trigger({ schedule: config.schedule }), onCronTrigger),
  ];
};

export async function main() {
  const runner = await Runner.newRunner<Config>({
    configSchema,
  });
  await runner.run(initWorkflow);
}
