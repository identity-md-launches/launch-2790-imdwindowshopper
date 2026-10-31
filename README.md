IMDwindowshopper (`WWW`) is a fixed-supply ERC-20 token. The constructor mints
1,000,000,000 tokens with 18 decimals to the immediate deployer exactly once.

| Deployment parameter | Value |
| --- | --- |
| Source / Solidity identifier | `src/IMDwindowshopper.sol:IMDwindowshopper` |
| Name | `IMDwindowshopper` |
| Symbol | `WWW` |
| Decimals | `18` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None; empty ABI argument list `[]` |
| Constructor ETH value | `0` |
| Initial token recipient | Constructor `msg.sender` |
| Launch chain | Ethereum, chain ID `1` |
| Compiler / EVM target | Solidity `0.8.26` / Cancun |
| Optimizer / metadata hash | Enabled, 200 runs / `none` |

The token uses the vendored OpenZeppelin Contracts v5.4.0 ERC-20 implementation.
Only the constructor calls `_mint`. There is no external mint or burn function,
owner, administrator, pause, blacklist, seizure, tax, rebasing, upgrade mechanism,
external call, or post-deployment configuration. `INITIAL_SUPPLY` is the public
constant specifying the one-time issuance. Transfers do not change total supply.

Assumptions and transfer behavior:

- The brief specifies ordinary ERC-20 transfers; no additional transfer restrictions
  or token fees are assumed. A transfer delivers exactly the requested base units.
- Successful `transfer`, `approve`, and `transferFrom` calls return `true`.
  Invalid operations revert with ERC-6093 custom errors, leaving all state unchanged.
- Transfers to the zero address and approvals to the zero spender revert. Zero-value
  transfers between valid addresses and self-transfers succeed and emit `Transfer`.
- `approve` replaces the caller's allowance for a spender. Finite allowances decrease
  on `transferFrom`; `type(uint256).max` means unlimited allowance and is not decreased.
  `approve` emits `Approval`; spending an allowance emits only `Transfer`.
- Token transfers do not invoke recipient callbacks. Users must verify recipients
  can use their tokens; tokens sent to this token contract cannot be recovered.
- There is no payable entry point or native-currency recovery function.

Build and verify from the repository root with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xda1a339b7399a7c220fcbd0dcca290b9dfc24a3d1c0c26361251407d93fbb807 forge test
forge fmt --check
```

All Solidity dependencies and licenses are ordinary files in `lib/`; no network,
package installation, submodule, RPC, secret, FFI, or filesystem cheatcode permission
is needed to compile or run the tests. See [dependency provenance](lib/README.md).
The Foundry compiler is pinned by version, not by a machine-specific path.

Tests check metadata, the exact constructor mint and event, CREATE2 deployment to a
factory, exact 10% / 70% / 20% transfer amounts, distributor claims, transfers in both
directions, approvals, revocation, insufficient balances and allowances, failure
atomicity, rejected administrative calls, and zero/self/maximum-value edge cases.
Five fuzz tests exercise amounts and recipients at 256 cases each. Two stateful
invariants run 128 sequences of 64 calls each over four actors, checking fixed supply
and an independent balance/allowance ledger after transfers, approvals, delegated
spends, and deliberately rejected spends. Tests do not read or change environment
variables and have no order dependencies. The local pool-address transfer test is
not a Uniswap swap simulation; the supplied protected integration harness performs
the real PoolManager seed and swap checks in the network's verification stage.

Deployment and operational responsibilities:

- Deploy the compiled `IMDwindowshopper` creation bytecode with no appended arguments
  and no ETH. Direct creation by an account assigns the entire supply to that account;
  creation by a factory assigns the entire supply to that factory, never to `tx.origin`.
  There is no initializer or required external contract during construction.
- For the designated launch, the network's factory deploys the token and handles
  distribution: 10% (100,000,000 WWW) to its distributor, 70% (700,000,000 WWW) for
  liquidity, and 20% (200,000,000 WWW) to the requester-specified remainder recipient
  `0xee2aaa315cf7ed169f93148d30d24af9318dbb66`. These allocations are not token logic.
- Launch orchestration pairs WWW with IMD at
  `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, applies pool fee `12500` (1.25%) and
  tick spacing `60`, and derives the opening price from the specified initial market
  cap `2000000000000000000000` in paired-token base units (2,000 IMD). The pool fee is
  external to WWW and is not a transfer tax. The network's later manifest step owns
  these values; this project supplies only the token and does not deploy a pool.
- The launch operator is responsible for the manifest, source/bytecode verification,
  correct chain and factory, and checking the constructor `Transfer` event, metadata,
  total supply, and distribution receipts. No deployment or broadcast is performed
  by this project. No application contracts or deployment keys are required here.
- After launch: there are no setters, administrative accounts, keepers, or scheduled
  actions. Holders manage their own transfers and allowances. Use bounded approvals
  where practical; revoke an existing allowance to zero before replacing it when
  coordinating with an untrusted spender, and account for already-pending spends.
- No privileged recovery is possible for mistaken transfers or compromised accounts.
  Changes require a separately deployed contract and voluntary migration.

Security review of this implementation found no external interaction, custom
arithmetic, signature, oracle, privileged runtime path, or mutable dependency to
review beyond standard ERC-20 behavior. Local unit, fuzz, and invariant tests are
the validation performed here; they are not an independent audit. Independent
adversarial review and the launch's protected checks remain release responsibilities.
Slither and Mythril were not run in this assignment.
