# Cross-chain sync (CRE) — Oracle pool rebalance (keeper pattern)

> **DISCLAIMER:** This code represents an example of using a Chainlink product or service and is provided to help you understand how to interact with Chainlink's systems and services so that you can integrate them into your own. This code is provided "AS IS" and "AS AVAILABLE" without warranties of any kind, has not been audited, and may be missing key checks or error handling to make the usage of the product more clear. Do not use the code in this example in a production environment without completing your own audits and application of best practices. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outputs that are generated due to errors in code.

TypeScript [Chainlink CRE](https://docs.chain.link/cre) workflow on a schedule: it calls **`needsUpkeep()`** on your on-chain consumer (same idea as the [keeper-bot template](https://github.com/smartcontractkit/cre-templates/tree/main/starter-templates/keeper-bot/keeper-bot-ts)). That view reads **`CustomSender`’s oracle pool** and **`GHO()`** balance and compares it to an **on-chain threshold**. Only if upkeep is needed does the workflow **`writeReport`**; the consumer’s **`ReceiverTemplate`** path runs **`_processReport`**, which calls **`CustomSender.sync`** with CCIP fee bytes from the report.

**Solidity (`../contracts/`)**

- [`../contracts/src/interfaces/ICustomSender.sol`](../contracts/src/interfaces/ICustomSender.sol) — `getOraclePool()`, `GHO()`, `sync(uint64,uint256,bytes)`.
- [`../contracts/src/ReceiverTemplate.sol`](../contracts/src/ReceiverTemplate.sol) — vendored from [Chainlink CRE templates](https://github.com/smartcontractkit/cre-templates/blob/main/starter-templates/keeper-bot/keeper-bot-ts/contracts/evm/src/ReceiverTemplate.sol) (Keystone forwarder + optional workflow checks).
- [`../contracts/src/SyncKeeperConsumer.sol`](../contracts/src/SyncKeeperConsumer.sol) — extends `ReceiverTemplate`: `needsUpkeep()`, `setMinOraclePoolBalance`, `_processReport` → `sync`.

**TypeScript (this folder)**

- [`main.ts`](main.ts) — cron → `needsUpkeep` read → optional `writeReport`.
- [`evm.ts`](evm.ts) — `callContract` (`needsUpkeep`) and `writeReport` helpers.
- [`config.ts`](config.ts) — Zod schema (threshold is **not** in JSON; it lives on the consumer).

**Further reading**

- [Writing data onchain (CRE)](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/writing-data-onchain)
- [Building consumer contracts](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts)
- [Forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory) (Keystone forwarder address per chain)

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| [Bun](https://bun.sh/) ≥ 1.2 | Install deps, run tests, compile workflow |
| [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`) | Build and deploy Solidity |
| [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation) (`cre`) | Simulate / deploy workflows |
| RPC URL + wallet | On-chain reads; for **simulation with writes**, a **funded** key (see below) |

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

| Field | Description |
|-------|-------------|
| `schedule` | Cron expression, e.g. `0 */4 * * *` (every 4 hours at minute 0). |
| `chainSelectorName` | CRE / chain-selectors name, e.g. `ethereum-testnet-sepolia`, `ethereum-mainnet`. |
| `isTestnet` | Passed to `getNetwork()` (must match the chain you use). |
| `consumerAddress` | Deployed **`SyncKeeperConsumer`** (IReceiver); target of `writeReport` and of `needsUpkeep` reads. |
| `gasLimit` | Gas limit string for `writeReport`, e.g. `"750000"`. |
| `destChainSelector` | Decimal string `uint64` CCIP destination chain selector for `sync`. |
| `syncAmount` | Decimal string `uint256` passed as `amount` to `sync`. |
| `feeOtoD` | `0x`-hex ABI blob (e.g. from your `FeeCodec.encodeCCIP(maxFee, payInLink, gasLimit)`). |
| `evmCallFrom` | Optional; `from` address for **read** `callContract`. Defaults to `consumerAddress`. |

**On-chain (not in this JSON)** — set at deploy / via owner on `SyncKeeperConsumer`:

- **`minOraclePoolBalance`** — `IERC20(CustomSender.GHO()).balanceOf(CustomSender.getOraclePool()) < minOraclePoolBalance` ⇒ `needsUpkeep() == true`. Update with `setMinOraclePoolBalance` (owner).

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

| Script | Command | What it does |
|--------|---------|----------------|
| **Tests** | `bun run test` | Runs [`main.test.ts`](main.test.ts) with Bun + CRE `EvmMock`. |
| **Typecheck** | `bun run typecheck` | `tsc --noEmit` on workflow sources. |
| **Contracts build** | `bun run contracts:build` | `forge build` in `../contracts`. |
| **Contracts clean** | `bun run contracts:clean` | Removes `../contracts/out` and `../contracts/cache`. |
| **Simulate (staging)** | `bun run simulate:staging` | Runs CRE simulator from **repo root** with staging target. |
| **Simulate (production)** | `bun run simulate:production` | Same for production target. |

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
export CUSTOM_SENDER="0x..."                                         # your CustomSender proxy/impl address
export MIN_ORACLE_POOL_BALANCE_WEI="1000000000000000000000"          # initial on-chain threshold (wei, decimal string)
```

Never commit real keys. Prefer a hardware wallet or CI secret store for production.

**Dependencies:** `contracts/lib/` is **not** committed. After clone, from `contracts/`:

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
```

(`foundry.toml` already sets the `@openzeppelin/contracts` remapping.)

### 3. Deploy `SyncKeeperConsumer`

Constructor: `(address forwarder, address customSender, uint256 minOraclePoolBalance)`.

**`forge create`**

```bash
cd ../contracts

forge create src/SyncKeeperConsumer.sol:SyncKeeperConsumer \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --constructor-args "$KEYSTONE_FORWARDER" "$CUSTOM_SENDER" "$MIN_ORACLE_POOL_BALANCE_WEI"
```

Save the **deployed contract address** as your workflow **`consumerAddress`**.

To change the threshold later (owner):

```bash
cast send "$CONSUMER_ADDRESS" "setMinOraclePoolBalance(uint256)" "$NEW_MIN_BALANCE_WEI" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$OWNER_PRIVATE_KEY"
```

### 4. Post-deploy (on-chain ops)

1. **`SYNC_ROLE` on `CustomSender`**  
   Grant to the **consumer** contract address (not the CRE workflow). Example with OpenZeppelin `AccessControl` / `grantRole` (adjust to your admin key and ABI):

   ```bash
   # SYNC_ROLE = keccak256("SYNC_ROLE") — confirm on your CustomSender
   export SYNC_ROLE=$(cast keccak "SYNC_ROLE")
   cast send "$CUSTOM_SENDER" \
     "grantRole(bytes32,address)" "$SYNC_ROLE" "$CONSUMER_ADDRESS" \
     --rpc-url "$SEPOLIA_RPC_URL" \
     --private-key "$ADMIN_PRIVATE_KEY"
   ```

2. **Fund the consumer** with enough native token to cover **`msg.value`** implied by `feeOtoD` when paying CCIP fees in native (native leg of encoded `feeOtoD` in `SyncKeeperConsumer`).

3. **Update workflow config**  
   Set `consumerAddress` in `config.staging.json` (or production) to the deployed **`SyncKeeperConsumer`**.

4. **Optional hardening (recommended for production)**  
   Use `ReceiverTemplate` setters (`setExpectedAuthor`, `setExpectedWorkflowId`, etc.) from the [consumer contracts guide](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts) so only your CRE workflow can trigger reports.

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
- `config.*.json` → real `consumerAddress` (deployed `SyncKeeperConsumer` with correct on-chain `minOraclePoolBalance`), plus `syncAmount` / `feeOtoD` for a dry run.

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
2. **Read** `needsUpkeep()` on `SyncKeeperConsumer` via `EVMClient.callContract` (oracle pool and GHO token configured on `CustomSender`, and pool token balance below on-chain `minOraclePoolBalance`).
3. If `needsUpkeep` is **false** → log and return (no write).
4. Else **encode** report `(uint64 destChainSelector, uint256 amount, bytes feeOtoD)`, **`runtime.report`**, then **`writeReport`** to `consumerAddress`.
5. On-chain, **`ReceiverTemplate.onReport`** validates the Keystone forwarder (and optional workflow metadata if configured), then **`SyncKeeperConsumer._processReport`** re-checks the same conditions: if oracle addresses are missing or balance is not below the threshold it **emits** `SyncSkippedOracleMisconfigured` or `SyncSkippedUpkeepNotNeeded` and **returns** without reverting; otherwise it decodes the report and calls **`CustomSender.sync`** with native fee.

---

## Troubleshooting

| Symptom | Things to check |
|---------|-------------------|
| `Network not found` | `chainSelectorName` + `isTestnet` vs [`getNetwork`](https://docs.chain.link/cre/reference/sdk/core-ts) data. |
| `writeReport` reverts | Receiver not `IReceiver` / wrong forwarder / insufficient gas / consumer not granted `SYNC_ROLE` / wrong `feeOtoD` encoding vs `CustomSender`. |
| `callContract` reverts | `evmCallFrom` / RPC / wrong `consumerAddress` / `CustomSender` missing `getOraclePool` or `GHO`. |
| Simulation can’t find project | Run `cre` from directory containing **`project.yaml`**. |
| Tests fail on `bytes` mocks | Use **base64** for `CallContractReply.data` in mocks (see tests). |

---

## License

See [`package.json`](package.json) (`UNLICENSED` unless you change it).
