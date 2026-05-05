

# Aave cross-chain sync automation

## Disclaimer

This code illustrates how to use Chainlink CRE and related on-chain interfaces. It is provided **“AS IS”** and **“AS AVAILABLE”** without warranties of any kind, has **not been audited** as a complete production system, and may omit checks or error handling that a live deployment would require.

**Do not deploy to production** without your organization’s own security review, testing, and operational controls. **We ask that Aave (or the deploying party responsible for the integration) perform its own audit and/or code review** before any production deployment, in addition to any third-party reviews you deem appropriate.

Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for unintended outcomes due to errors in this example or in how it is deployed or operated.


Example automation for topping up an oracle pool via cross-chain sync: a **Chainlink CRE** TypeScript workflow reads an on-chain **keeper-style** gate and, when needed, submits a signed report so **`SyncKeeperConsumer`** calls **`CustomSender.sync`** (CCIP-related parameters live on the consumer contract).

This repository is intended as **integration reference**, not a turnkey production deployment.

---

## Repository layout

| Path | Contents |
|------|----------|
| [`contracts/`](contracts/) | Foundry Solidity: `SyncKeeperConsumer`, vendored `ReceiverTemplate`, interfaces (`ICustomSender`, `IReceiver`). |
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
- **Ownership** — Owner-only setters on the consumer adjust thresholds, sync amount, and fee blob; protect owner keys.
- **`SYNC_ROLE`** — The consumer must be granted whatever role your `CustomSender` requires to call `sync`.
- **Threshold and CCIP params** — `minOraclePoolBalance`, destination selector, `syncAmount`, and `feeOtoD` are set on-chain (not only in workflow JSON). Align operator runbooks with [`cross-chain-sync/README.md`](cross-chain-sync/README.md).

**Duplicate rebalance (for Aave review):** `needsUpkeep()` stays true while the oracle pool GHO balance is **below** `minOraclePoolBalance`, so each cron tick can submit another `writeReport` / `sync` until that gate clears—often back-to-back if CCIP or settlement is slow. Outcomes also depend on **`CustomSender.sync`** (e.g. full `syncAmount` vs revert when liquidity is tight). We acknowledge this; we **did not** add a time-based cooldown on the consumer because real flows are **unpredictable** and a fixed gate could block legitimate top-ups—operators should tune cron, thresholds, and `syncAmount` instead.

---

