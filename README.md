

# Aave cross-chain sync automation

## Disclaimer

This code illustrates how to use Chainlink CRE and related on-chain interfaces. It is provided **“AS IS”** and **“AS AVAILABLE”** without warranties of any kind, has **not been audited** as a complete production system, and may omit checks or error handling that a live deployment would require.

**Do not deploy to production** without your organization’s own security review, testing, and operational controls. **We ask that Aave (or the deploying party responsible for the integration) perform its own audit and/or code review** before any production deployment, in addition to any third-party reviews you deem appropriate.

Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outcomes due to errors in this example or in how it is deployed or operated.


Example automation for rebalancing a **two-sided oracle pool** via cross-chain sync: a **Chainlink CRE** TypeScript workflow reads an on-chain **keeper-style** gate and, when one side of the pool (`GHO` or `SGHO`) runs short, submits a signed report so **`SyncKeeperConsumer`** sends the **surplus** token to the mainnet vault through **`SwapHandler.sync`** and receives the short token back. All sync parameters (thresholds, amounts, price feed, CCIP fee) live on the consumer contract; the CRE report body is empty and ignored.

This repository is intended as **integration reference**, not a turnkey production deployment.

---

## Repository layout

| Path | Contents |
|------|----------|
| [`contracts/`](contracts/) | Foundry Solidity: `SyncKeeperConsumer`, vendored `ReceiverTemplate`, interfaces (`ISwapHandler`, `IReceiver`, `IAggregatorV3`, `ISyncKeeperConsumer`), and tests. |
| [`cross-chain-sync/`](cross-chain-sync/) | CRE workflow (`main.ts`, `evm.ts`, `config.ts`), workflow config JSON, tests. |
| [`project.yaml`](project.yaml) | CRE project settings (RPCs, staging/production targets). |

**Detailed workflow documentation** (configuration tables, simulation, troubleshooting) lives in [`cross-chain-sync/README.md`](cross-chain-sync/README.md).

---

## Quick start

1. **Solidity** — Install [Foundry](https://book.getfoundry.sh/getting-started/installation). From `contracts/`, run `forge install` if dependencies are missing (`lib/` may be gitignored), then `forge build`.
2. **Workflow** — Install [Bun](https://bun.sh/) (≥ 1.2). From `cross-chain-sync/`, run `bun install`, then `bun test` / `bun run typecheck` as needed.
3. **CRE CLI** — Install the [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation). Most `cre` commands expect the **repository root** as the working directory (where `project.yaml` lives). See [`cross-chain-sync/package.json`](cross-chain-sync/package.json) for `simulate:staging` / `simulate:production` scripts.

---

## Security and operations

- **Forwarder** — `ReceiverTemplate` restricts `onReport` to the configured Chainlink Keystone forwarder; deploy with the correct forwarder for your chain ([forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory)).
- **Workflow author** — The consumer pins the expected workflow owner (`expectedAuthor`) at construction, so a different workflow sharing the same forwarder cannot trigger a sync. It can be changed by the owner but should never be cleared.
- **Ownership** — Owner-only setters on the consumer adjust the per-token thresholds, sync amounts, settlement window, price feed, and fee blob; protect owner keys.
- **`SYNC_ROLE`** — The consumer must be granted whatever role your `SwapHandler` requires to call `sync`.
- **Rebalance params** — `minGhoBalance`, `minSGhoBalance`, `syncAmount`, `minSyncAmount`, `settlementWindow`, `priceFeed`, `maxPriceStaleness`, and `feeData` are set on-chain (not in workflow JSON). Align operator runbooks with [`cross-chain-sync/README.md`](cross-chain-sync/README.md).
- **Destination adapter asset fee** — `minAmountOut` is quoted from the **gross** amount sent (the sGHO/GHO rate less `slippageToleranceBps`) and carries no term for the fee the mainnet `CrossChainERC4626Adapter` charges on a return-to-source transfer. The adapter subtracts that fixed asset fee before comparing against `minAmountOut`, and it lives on another chain under separate administration, so the consumer can neither read nor enforce it. **Before enabling the workflow, verify the adapter's configured asset fee for this lane is zero**, and re-check it if the adapter's fee policy ever changes: a non-zero fee makes the destination leg fail once it exceeds `slippageToleranceBps` of the dispatched amount (2% by default), after the source leg has already pulled the tokens and paid the CCIP fee. Because each sync is capped at the surplus above the sending side's threshold, a small transfer makes even a small fixed fee enough to breach the tolerance.
- **Price feed domain** — The consumer prices a sync against the **mainnet sGHO vault's** exchange rate, not against the oracle pool's capped rate, and this split is deliberate. The pool clips upward answers to a growth cap and rejects answers below the last one it accepted, but that guard covers the pool's **local swaps**: a sync pulls inventory through the pool's balance-checked withdrawal, which never reads the price, and `minAmountOut` is enforced on the mainnet leg by the adapter converting through the real ERC-4626 vault. So `_quote` validates only the sign and age of the answer, with no cap or monotonic check: the quote is **defense in depth against a grossly wrong conversion, not a value guarantee**. A sync sent with `minAmountOut == 0` would still settle at whatever rate the vault gives, so the worst case from a fresh-but-wrong answer is a destination leg that misses its minimum and parks the transfer in the adapter's failed-message state for operator recovery. **Deployment must point `priceFeed` at the feed tracking the mainnet sGHO vault rate, quoted as GHO assets per share and _not_ inverted** — a reciprocal feed (e.g. one wrapped with inversion for the pool) prices every sync backwards.

**Repeated rebalance (for Aave review):** `needsUpkeep()` stays true while one side of the pool is short (and the other holds a surplus to send), so in principle each cron tick could submit another `writeReport` / `sync`. The consumer bounds this in three ways: the token received in exchange returns on a **later, asynchronous CCIP message** invisible to the current pool balances, so a **`settlementWindow` cooldown** blocks further syncs until that return should have settled (set `settlementWindow = 0` to disable it if your flow tolerates back-to-back syncs); a **`minSyncAmount` floor** stops a dust imbalance from spending a full CCIP fee; and the amount sent is always capped at the surplus **above the sending side's own threshold**, so a sync can never flip the shortage to the other side. `needsUpkeep()` and the on-chain executor run the **same** checks (balances, cooldown, price freshness), so the gate never signals a sync the executor would then skip. Outcomes still depend on **`SwapHandler.sync`** (e.g. available liquidity); operators tune cron, thresholds, `syncAmount`, and `settlementWindow` to their flow.

---

