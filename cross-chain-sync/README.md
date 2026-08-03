# Cross-chain sync (CRE) — Oracle pool rebalance (keeper pattern)

> **DISCLAIMER:** This code represents an example of using a Chainlink product or service and is provided to help you understand how to interact with Chainlink's systems and services so that you can integrate them into your own. This code is provided "AS IS" and "AS AVAILABLE" without warranties of any kind, has not been audited, and may be missing key checks or error handling to make the usage of the product more clear. Do not use the code in this example in a production environment without completing your own audits and application of best practices. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outputs that are generated due to errors in code.

TypeScript [Chainlink CRE](https://docs.chain.link/cre) workflow on a schedule: it calls **`needsUpkeep()`** on your on-chain consumer (same idea as the [keeper-bot template](https://github.com/smartcontractkit/cre-templates/tree/main/starter-templates/keeper-bot/keeper-bot-ts)). That view reads the **`GHO`** and **`SGHO`** balances of **`SwapHandler`’s oracle pool** and returns true when exactly one side is below its threshold, the other holds a sendable surplus, no cooldown is in force, and the price feed is fresh. Only then does the workflow **`writeReport`**; the consumer’s **`ReceiverTemplate`** path runs **`_processReport`**, which re-derives which token is in surplus and calls **`SwapHandler.sync`** — sending the surplus token and requesting the short token back, priced from the sGHO/GHO feed, with the CCIP fee bytes stored on the consumer (the CRE report body is empty / ignored).

**Solidity (`../contracts/`)**

- [`../contracts/src/interfaces/ISwapHandler.sol`](../contracts/src/interfaces/ISwapHandler.sol) — `getOraclePool()`, `GHO()`, `SGHO()`, `sync(address token, uint256 amount, uint256 minAmountOut, bytes feeData, bytes extraArgs)`.
- [`../contracts/src/interfaces/IAggregatorV3.sol`](../contracts/src/interfaces/IAggregatorV3.sol) — the minimal Chainlink feed interface used to read the sGHO/GHO exchange rate.
- [`../contracts/src/ReceiverTemplate.sol`](../contracts/src/ReceiverTemplate.sol) — vendored from [Chainlink CRE templates](https://github.com/smartcontractkit/cre-templates/blob/main/starter-templates/keeper-bot/keeper-bot-ts/contracts/evm/src/ReceiverTemplate.sol) (Keystone forwarder + optional workflow checks).
- [`../contracts/src/SyncKeeperConsumer.sol`](../contracts/src/SyncKeeperConsumer.sol) — extends `ReceiverTemplate`: `needsUpkeep()`, per-token threshold / amount / feed setters, `_processReport` → `sync`.

**TypeScript (this folder)**

- [`main.ts`](main.ts) — cron → `needsUpkeep` read → optional `writeReport`.
- [`evm.ts`](evm.ts) — `callContract` (`needsUpkeep`) and `writeReport` helpers.
- [`config.ts`](config.ts) — Zod schema (thresholds, amounts, price feed, and `feeData` are **not** in JSON; they live on the consumer).

**Further reading**

- [Writing data onchain (CRE)](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/writing-data-onchain)
- [Building consumer contracts](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts)
- [Forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory) (Keystone forwarder address per chain)

---

## Prerequisites

| Tool                                                                                 | Purpose                                                                      |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| [Bun](https://bun.sh/) ≥ 1.2                                                         | Install deps, run tests, compile workflow                                    |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) | Build and deploy Solidity                                                    |
| [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation) (`cre`)      | Simulate / deploy workflows                                                  |
| RPC URL + wallet                                                                     | On-chain reads; for **simulation with writes**, a **funded** key (see below) |

---

## Repository layout

```text
aave-cross-chain-sync-automation/     ← CRE **project root** (contains project.yaml)
├── project.yaml                      ← RPCs, targets (staging / production)
├── cross-chain-sync/                 ← **This** workflow package
│   ├── main.ts
│   ├── evm.ts
│   ├── config.ts
│   ├── config.staging.json
│   ├── config.production.json
│   ├── workflow.yaml                 ← workflow-path, config-path per target
│   └── package.json
└── contracts/                        ← Foundry project (`lib/` is gitignored; run `forge install` after clone)
    ├── foundry.toml
    └── src/
        ├── ReceiverTemplate.sol
        ├── SyncKeeperConsumer.sol
        └── interfaces/
```

Simulation and most `cre` commands expect your **current working directory** to be the **repository root** (`aave-cross-chain-sync-automation/`), where `project.yaml` lives.

---

## Configuration

### Workflow JSON (`config.staging.json` / `config.production.json`)

Validated by [`config.ts`](config.ts). All addresses are checksummed `0x` + 40 hex chars.

| Field               | Description                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| `schedule`          | Cron expression, e.g. `0 */4 * * *` (every 4 hours at minute 0).                                   |
| `chainSelectorName` | CRE / chain-selectors name, e.g. `ethereum-testnet-sepolia`, `ethereum-mainnet`.                   |
| `isTestnet`         | Passed to `getNetwork()` (must match the chain you use).                                           |
| `consumerAddress`   | Deployed **`SyncKeeperConsumer`** (IReceiver); target of `writeReport` and of `needsUpkeep` reads. |
| `gasLimit`          | Gas limit string for `writeReport`, e.g. `"750000"`.                                               |
| `evmCallFrom`       | Optional; `from` address for **read** `callContract`. Defaults to `consumerAddress`.               |

**On-chain (not in this JSON)** — set at deploy / via owner on `SyncKeeperConsumer`:

- **`expectedAuthor`** — the workflow owner whose reports are accepted; required non-zero at construction. Change with `setExpectedAuthor` (owner); never clear it.
- **`minGhoBalance` / `minSGhoBalance`** — per-token thresholds. `needsUpkeep()` is true when exactly one side is below its threshold and the other holds at least `minSyncAmount` above its own threshold. Update with `setMinGhoBalance` / `setMinSGhoBalance` (owner, non-zero).
- **`syncAmount`** — the maximum surplus token sent per sync (capped at what the surplus side holds above its threshold). Update with `setSyncAmount` (owner, non-zero).
- **`minSyncAmount`** — the minimum surplus above threshold worth a sync; a smaller imbalance is skipped so dust does not spend a CCIP fee. Update with `setMinSyncAmount` (owner, non-zero).
- **`settlementWindow`** — cooldown (seconds) after a sync during which further reports are skipped while the CCIP return leg settles; `0` disables it. Update with `setSettlementWindow` (owner).
- **`priceFeed` / `maxPriceStaleness`** — the sGHO/GHO exchange-rate feed used to price `minAmountOut`, and the maximum tolerated age of its answer. Update with `setPriceFeed` / `setMaxPriceStaleness` (owner).
- **`slippageToleranceBps`** — slippage tolerance (basis points) subtracted from the quoted `minAmountOut`. The sGHO ERC4626 vault keeps accruing while the sync settles over CCIP, so the mainnet deposit leg mints against a slightly higher rate than quoted; this buffer stops it reverting with `MinimumOutputNotMet`. Defaults to **200 (2%)**; update with `setSlippageTolerance(uint256)` (owner, ≤ 10_000).
- **`feeData`** — CCIP fee blob, `FeeCodec.encodeCCIP`-packed (21 bytes), set in the constructor; update with `setFeeData(uint128 maxFee, bool payInGho, uint32 gasLimit)` (owner) when fee caps or gas limits need to change.

### `project.yaml` (repo root)

- **`rpcs`**: RPC URL per `chain-name` must match the chain in your config (`ethereum-testnet-sepolia`, etc.). Use `${VAR}` for secrets.
- **`workflow.yaml`** (here): maps each **target** to `workflow-path`, `config-path`, and workflow registry name.

---

## Install

From **this directory**:

```bash
bun install
```

---

## Scripts (this package)

Run from `cross-chain-sync/` unless noted.

| Script                    | Command                       | What it does                                                  |
| ------------------------- | ----------------------------- | ------------------------------------------------------------- |
| **Tests**                 | `bun run test`                | Runs [`main.test.ts`](main.test.ts) with Bun + CRE `EvmMock`. |
| **Typecheck**             | `bun run typecheck`           | `tsc --noEmit` on workflow sources.                           |
| **Contracts build**       | `bun run contracts:build`     | `forge build` in `../contracts`.                              |
| **Contracts clean**       | `bun run contracts:clean`     | Removes `../contracts/out` and `../contracts/cache`.          |
| **Simulate (staging)**    | `bun run simulate:staging`    | Runs CRE simulator from **repo root** with staging target.    |
| **Simulate (production)** | `bun run simulate:production` | Same for production target.                                   |

Implementation detail: simulate scripts `cd ..` so `cre` sees [`project.yaml`](../project.yaml).

---

## Run tests

```bash
cd cross-chain-sync
bun run test
```

Optional: run repeatedly to check for flakiness.

```bash
bun run test -- --watch
```

**Note:** `EvmMock` + protobuf `bytes` fields expect **base64** in JSON for `CallContract` replies (see [`main.test.ts`](main.test.ts) helper `callContractReturnBool`). Production RPC responses are unpacked to binary by the SDK.

---

## Build and deploy contracts

All commands below use the Foundry project in **`../contracts/`** (from `cross-chain-sync`, go up one level).

### 1. Build

```bash
bun run contracts:build
# or
cd ../contracts && forge build
```

### 2. Environment for deployment

Set (examples):

```bash
export SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"   # or your RPC
export PRIVATE_KEY="0x..."                                             # deployer (hex, no 0x sometimes accepted — use cast format)
export KEYSTONE_FORWARDER="0x..."                                    # from Forwarder Directory for your chain
export EXPECTED_AUTHOR="0x..."                                       # workflow owner address whose reports are accepted
export SWAP_HANDLER="0x..."                                         # your SwapHandler proxy/impl address
export PRICE_FEED="0x..."                                            # sGHO/GHO exchange-rate Chainlink feed
export MAX_PRICE_STALENESS="86400"                                  # max feed answer age in seconds (e.g. 1 day)
export MIN_GHO_BALANCE_WEI="1000000000000000000000"                 # GHO threshold (wei, decimal string)
export MIN_SGHO_BALANCE_WEI="1000000000000000000000"               # SGHO threshold (wei, decimal string)
export SYNC_AMOUNT_WEI="1000000000000000000"                        # max surplus token sent per sync (wei)
export MIN_SYNC_AMOUNT_WEI="100000000000000000"                    # minimum surplus worth a sync (wei, non-zero)
export SETTLEMENT_WINDOW="0"                                        # cooldown seconds between syncs (0 disables)
export SLIPPAGE_TOLERANCE_BPS="200"                                 # slippage tolerance on minAmountOut, in bps (2%); post-deploy setter only
export MAX_FEE_WEI="100000000000000000"                            # max CCIP fee per sync (wei)
export PAY_IN_GHO="false"                                          # pay the CCIP fee in GHO (true) or native token (false)
export CCIP_GAS_LIMIT="500000"                                     # destination gas limit (must be >= MIN_PROCESS_MESSAGE_GAS)
export FEE_DATA=$(cast abi-encode --packed "f(uint128,bool,uint32)" "$MAX_FEE_WEI" "$PAY_IN_GHO" "$CCIP_GAS_LIMIT")  # FeeCodec.encodeCCIP packing (21 bytes)
```

Never commit real keys. Prefer a hardware wallet or CI secret store for production.

**Dependencies:** `contracts/lib/` is **not** committed. After clone, from `contracts/`:

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
```

(`foundry.toml` already sets the `@openzeppelin/contracts` remapping.)

### 3. Deploy `SyncKeeperConsumer`

Constructor: `(address forwarder, address expectedAuthor, address swapHandler, address priceFeed, uint256 maxPriceStaleness, uint256 minGhoBalance, uint256 minSGhoBalance, uint256 syncAmount, uint256 minSyncAmount, uint256 settlementWindow, bytes feeData)`. `feeData` is the `FeeCodec.encodeCCIP`-packed CCIP fee (16-byte `maxFee` ++ 1-byte `payInGho` ++ 4-byte `gasLimit` = 21 bytes).

**`forge create`**

```bash
cd ../contracts

forge create src/SyncKeeperConsumer.sol:SyncKeeperConsumer \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --constructor-args \
    "$KEYSTONE_FORWARDER" \
    "$EXPECTED_AUTHOR" \
    "$SWAP_HANDLER" \
    "$PRICE_FEED" \
    "$MAX_PRICE_STALENESS" \
    "$MIN_GHO_BALANCE_WEI" \
    "$MIN_SGHO_BALANCE_WEI" \
    "$SYNC_AMOUNT_WEI" \
    "$MIN_SYNC_AMOUNT_WEI" \
    "$SETTLEMENT_WINDOW" \
    "$FEE_DATA"
```

Save the **deployed contract address** as your workflow **`consumerAddress`**.

Owner-only setters to adjust configuration later (each reverts for a non-owner; amount setters require non-zero):

```bash
cast send "$CONSUMER_ADDRESS" "setMinGhoBalance(uint256)"   "$MIN_GHO_BALANCE_WEI"  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setMinSGhoBalance(uint256)"  "$MIN_SGHO_BALANCE_WEI" --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setSyncAmount(uint256)"      "$SYNC_AMOUNT_WEI"      --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setMinSyncAmount(uint256)"   "$MIN_SYNC_AMOUNT_WEI"  --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setSettlementWindow(uint256)" "$SETTLEMENT_WINDOW"   --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setPriceFeed(address)"       "$PRICE_FEED"           --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setMaxPriceStaleness(uint256)" "$MAX_PRICE_STALENESS" --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setSlippageTolerance(uint256)" "$SLIPPAGE_TOLERANCE_BPS" --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
cast send "$CONSUMER_ADDRESS" "setFeeData(uint128,bool,uint32)" "$MAX_FEE_WEI" "$PAY_IN_GHO" "$CCIP_GAS_LIMIT" --rpc-url "$SEPOLIA_RPC_URL" --private-key "$OWNER_PRIVATE_KEY"
```

### 4. Post-deploy (on-chain ops)

1. **`SYNC_ROLE` on `SwapHandler`**  
   Grant to the **consumer** contract address (not the CRE workflow). Example with OpenZeppelin `AccessControl` / `grantRole` (adjust to your admin key and ABI):

   ```bash
   # SYNC_ROLE = keccak256("SYNC_ROLE") — confirm on your SwapHandler
   export SYNC_ROLE=$(cast keccak "SYNC_ROLE")
   cast send "$SWAP_HANDLER" \
     "grantRole(bytes32,address)" "$SYNC_ROLE" "$CONSUMER_ADDRESS" \
     --rpc-url "$SEPOLIA_RPC_URL" \
     --private-key "$ADMIN_PRIVATE_KEY"
   ```

2. **Fund the consumer** with enough native token to cover **`msg.value`** implied by `feeData` when paying CCIP fees in native (native leg of encoded `feeData` in `SyncKeeperConsumer`).

3. **Update workflow config**  
   Set `consumerAddress` in `config.staging.json` (or production) to the deployed **`SyncKeeperConsumer`**.

4. **Additional workflow pinning (optional)**  
   The expected workflow **author** is already required at construction. For a stricter match you can also pin the workflow **id** and/or **name** via the `ReceiverTemplate` setters (`setExpectedWorkflowId`, `setExpectedWorkflowName`) from the [consumer contracts guide](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts).

---

## Simulate the CRE workflow

Simulation uses **`project.yaml`** + **`cross-chain-sync/workflow.yaml`** and executes your TypeScript locally against configured RPCs (and optional wallet for writes).

### 1. Environment

From **repo root**, create or edit `.env` (do not commit secrets):

```bash
# Required for simulation that performs chain writes (writeReport)
CRE_ETH_PRIVATE_KEY=0x...   # funded key on the chain matching project.yaml RPC

# If your workflow does NOT write, a dummy non-zero key is often enough:
# CRE_ETH_PRIVATE_KEY=0000000000000000000000000000000000000000000000000000000000000001
```

CRE CLI loads `.env` from the working directory where you invoke `cre`.

### 2. Align `project.yaml` and config

- `project.yaml` → `rpcs[].chain-name` must match `chainSelectorName` / network in your JSON config.
- `config.*.json` → real `consumerAddress` (deployed `SyncKeeperConsumer` with correct on-chain thresholds, `syncAmount`, `minSyncAmount`, `settlementWindow`, `priceFeed`, and `feeData`).

### 3. Run simulator

**From repository root** (`aave-cross-chain-sync-automation/`):

**Staging target** (uses `config.staging.json` per `workflow.yaml`):

```bash
cre workflow simulate cross-chain-sync --target=staging-settings
```

**Production target:**

```bash
cre workflow simulate cross-chain-sync --target=production-settings
```

Or from `cross-chain-sync/` using the npm scripts (they `cd ..` first):

```bash
cd cross-chain-sync
bun run simulate:staging
bun run simulate:production
```

If the CLI flags differ slightly for your CRE version, run `cre workflow simulate --help` and adjust.

---

## Workflow behavior (summary)

1. **Cron** fires per `schedule`.
2. **Read** `needsUpkeep()` on `SyncKeeperConsumer` via `EVMClient.callContract`. It returns true only when the oracle pool is set, exactly one side (`GHO` or `SGHO`) is below its threshold while the other holds at least `minSyncAmount` above its own threshold, no `settlementWindow` cooldown is in force, and the price feed is usable.
3. If `needsUpkeep` is **false** → log and return (no write).
4. Else **`runtime.report`** with an **empty** payload, then **`writeReport`** to `consumerAddress`.
5. On-chain, **`ReceiverTemplate.onReport`** validates the Keystone forwarder and the pinned workflow **author** (plus id/name if configured), then **`SyncKeeperConsumer._processReport`** re-reads both balances and re-derives the surplus token. Any unactionable state is a **no-op that emits a reason and returns** (never reverts, so the report is not retried): `SyncSkippedOracleMisconfigured`, `SyncSkippedUpkeepNotNeeded`, `SyncSkippedNoSurplus`, `SyncSkippedCooldown`, or `SyncSkippedStalePrice`. Otherwise it prices `minAmountOut` from the sGHO/GHO feed and calls **`SwapHandler.sync`** with the surplus token and the on-chain `feeData` (native fee when not paid in `GHO`), emitting `SyncPerformed`.

---

## Troubleshooting

| Symptom                       | Things to check                                                                                                                                                                                                                                                                                                                  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Network not found`           | `chainSelectorName` + `isTestnet` vs [`getNetwork`](https://docs.chain.link/cre/reference/sdk/core-ts) data.                                                                                                                                                                                                                     |
| `writeReport` reverts         | Receiver not `IReceiver` / wrong forwarder / **report author ≠ pinned `expectedAuthor`** / insufficient gas / consumer not granted `SYNC_ROLE` / on-chain `feeData` encoding vs `SwapHandler` mismatch. Note most unactionable states (no surplus, cooldown, stale price) do **not** revert — they emit a `SyncSkipped*` event. |
| `callContract` reverts        | `evmCallFrom` / RPC / wrong `consumerAddress` / `SwapHandler` missing `getOraclePool`, `GHO`, or `SGHO` / `priceFeed` call reverting.                                                                                                                                                                                           |
| Simulation can’t find project | Run `cre` from directory containing **`project.yaml`**.                                                                                                                                                                                                                                                                          |
| Tests fail on `bytes` mocks   | Use **base64** for `CallContractReply.data` in mocks (see tests).                                                                                                                                                                                                                                                                |

---

## License

See [`package.json`](package.json) (`UNLICENSED` unless you change it).
