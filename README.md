# contracts: JIG and the creator-coin stack

Foundry project. Spec: `../ECONOMICS-DRAFT.md` (signed off 15 Oct 2026) and the JIG build spec v1 both founders signed the same day. Phase 1 is built and live on Sepolia. Nothing is on mainnet.

## Phase 1, live on Sepolia (15 Oct 2026)

| Contract | Address | What it does |
|---|---|---|
| JIG | `0x1a69B9fb49b9B7F4366ec30b1138fF1A5BA561B1` | fixed 1,000,000,000 supply, minted once: 90% to JIGLaunch, 10% to PotVault. No mint, no tax, no owner. Burnable |
| JIGLaunch | `0x5fBd48c44E1Db17A33BE9237B0B8877e54A34090` | created the JIG/ETH v4 pool, seeded it single-sided with 900M JIG, holds LP NFT 40643 forever. No transfer or remove-liquidity function. `collectFees()` sends LP fees to the pot, anyone can call |
| PotVault | `0x6e92e81fD6Cb0Bf9cAb54422a64b407080fbd88B` | the JIG pot. Holds 100M JIG now; receives mint reserve ETH and hook slices later. Payouts are merkle claims and are switched off until `enablePayouts()` (one-way, owner only). Owner cannot withdraw |
| Vesting | `0x0AfF5b1441B0F861Aece35077Ed0B5A6C69cFE01` | linear vesting with cliff for any ERC-20, irrevocable. Unused until the coin factory |
| JIGLaunchHook | `0xcEA08441eeC642CF4fA6Acd9e4e99E7EB94De080` | the launch window: for 10 minutes after the pool opened, allowlisted tx.origin pays 1%, anyone else 60%, then 1% for all. Serves only the ETH/JIG dynamic-fee pool. CREATE2-mined address (flag bits 0x2080) |

Pool on Sepolia: ETH / JIG, dynamic fee via the hook, tick spacing 200, launched 15 Oct 2026 with the agreed parameters below. The Sepolia allowlist is a single leaf, the operating wallet, so the window could be exercised. The first Sepolia set (JIG `0x9B9D…353f`, no hook, 1 ETH = 5M JIG) is superseded and can be ignored.

## Launch plan (agreed by Jj and Fish, 15 Oct 2026)

| | |
|---|---|
| Start FDV | about $4k, a pump.fun-style start: 1 ETH = 625,000,000 JIG at $2,500 ETH. Recompute the sqrt price from the live ETH price on launch day |
| Range | full range above the start price, single-sided JIG, no cap |
| First 10 minutes | allowlisted friends-and-family wallets buy at the normal 1%; any other wallet pays a 60% fee, all of it to the pot (sniper tax) |
| After 10 minutes | open to everyone, fee 1%, all LP fees to the pot forever (LP locked, pot is the only sink) |
| Contract address | vanity prefix via a CREATE2 salt grind, on the final mainnet deploy only |

The window is `JIGLaunchHook`: `beforeInitialize` records the clock and refuses any pool other than ETH/JIG dynamic-fee; `beforeSwap` returns a 1% override for a tx.origin that proves allowlist membership in `hookData` (merkle proof, OpenZeppelin double-hash leaves of `abi.encode(address)`), 60% otherwise, 1% for all after 10 minutes. tx.origin is deliberate: routers can lie about msg.sender, nobody can fake the signing EOA. Smart-contract wallets therefore can't be allowlisted; use EOAs for the FNF list.

**Allowlist root:** build the tree off chain (OpenZeppelin `merkletreejs` or `@openzeppelin/merkle-tree` with `["address"]` leaves), pass the root as `ALLOWLIST_ROOT` to the deploy script, and give each friend their proof for the front end to pass as hookData. The root is fixed once the pool exists.

Pot owner is the operating wallet for now. Before mainnet it must be a 2-of-2 multisig of both founders.

Deploy cost on Sepolia: 0.000032 test ETH across six transactions, plus about 0.00002 wasted on two failed attempts (see gotcha below).

## Setup

`lib/` is not committed (62 MB). After cloning:

```bash
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge install Uniswap/v4-periphery --no-git
```

Foundry 1.8.3, solc 0.8.26, via-ir, cancun. v4-periphery was installed from its default branch on 15 Oct 2026; pin it to that date's commit if a later version changes the `Actions` encoding.

## Tests

```bash
forge test                                              # 14 unit tests: JIG, Vesting, PotVault
forge test --match-contract Fork --fork-url sepolia     # 11 tests on a Sepolia fork: launch, lock, real buys, window fees, sniper tax to pot
```

The fork test buys JIG with 1 ETH through the real v4 PoolManager and checks about 5M JIG arrives and 0.01 ETH of fees reaches the pot.

## Deploying

```bash
set -a; . ../backend/.env; set +a
forge script script/DeployJIG.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
```

Reads `LAUNCH_PK` (deployer and launcher) and optional `POT_OWNER`. Refuses chain id 1. Robinhood Chain needs its v4 PositionManager and Permit2 addresses added to `_v4()` first.

**Gotcha, Sepolia gas:** contract creation on Sepolia now costs about 8x what Foundry's local simulation computes (a 144-byte contract: 65k simulated, 497k real). Without `--skip-simulation` forge sets the gas limit from its own simulation and every deploy fails with all gas consumed and no revert reason. `--skip-simulation` makes it ask the node. Expect the same on any chain that has had the 2026 gas repricing.

## Audit status

**Plan of record, 15 Oct 2026 (Jj):** build the whole contract base on Sepolia first, no audits during the build. Then flip the repo public, have the IMD swarm audit the full base from the repo (the swarm cannot read a private repo and refuses requests with source embedded), fix findings, re-audit, launch nothing. When everything has passed, tell Fish the back end is ready and go to mainnet in one sequence: JIG, then the NFT factory, then the creator-coin side. Then make the repo private again. External audit deferred; the fee hook and factory carry every coin's money, so that stays the main open risk.

| Contract | Written by | Swarm audit | External audit |
|---|---|---|---|
| JIG, Vesting, PotVault, JIGLaunch, JIGLaunchHook, CreatorFeeHook, CoinFactory, CreatorCoin | Claude, 15 Oct, with 34 passing tests (14 unit, 20 on a Sepolia fork) | pending: needs 0.5 IMD in the operating wallet, then one `job.open` audit job | before mainnet |

Audit scope notes for whoever runs it: JIGLaunch's `collectFees` encodes `DECREASE_LIQUIDITY` with zero liquidity then `TAKE_PAIR`; check the PositionManager version on the target chain still treats that as fee collection. PotVault leaf format is `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (OpenZeppelin standard double hash).

## Phase 2, live on Sepolia (15 Oct 2026)

| Contract | Address | What it does |
|---|---|---|
| CreatorFeeHook | `0x2c416Cf88f853a593171c30D879aBd7c29986044` | the one shared hook for every creator coin. Takes the creator's fee (1 to 10%, lower-only) from every swap's unspecified currency; if that is the coin it sells it for JIG in the same transaction; credits creator / flywheel / launch referral / trade referral / platform / pot / deepening as claimable JIG. Anti-snipe: 60% decaying to the chosen fee over the first 10 minutes. Address flag bits 0x2044 |
| CoinFactory | `0x9e9b33e0a9254526CB08b63448EA22A5f4Ea0e27` | one call launches a coin: 1B fixed supply, coin/JIG pool (LP fee 0) on the hook, 90% seeded single-sided, LP NFT held by the factory forever, 5% creator vesting (6 months), 5% airdrop share, 0.01 ETH launch fee to platform |
| CreatorCoin | deployed per launch | fixed-supply ERC-20 with the collection address baked in, burnable |

Fee split, in basis points of the fee: flywheel 2000, launch referral 1000, trade referral 1000, pot 300, deepening 200, platform 1500 / 2000 / 2500 / 3000 by fee band (1% / 2-3% / 4-6% / 7-10%), creator the remainder. Referrals default to platform. The trade referral is the address passed as `hookData` with the swap (the front end passes its own address).

Design notes an auditor should know:

- **Fees are held as ERC-6909 claims inside the PoolManager**, not as ERC-20 in the hook. `take` would fail on a fresh chain because the swapper's input is settled after `afterSwap` runs; claims need no physical balance. `claim()` burns the claims and takes real JIG through an `unlock` callback.
- **The coin-side conversion is a nested swap on the same pool inside `afterSwap`**, guarded by `_converting` so the nested swap is not charged again. This is the Zora pattern.
- **Placeholders until their contracts exist:** the deepening slice and the 5% airdrop share both go to the PotVault. The LP-deepening module and AirdropClaim contract replace those addresses in a redeploy of the hook and factory (both are immutables on purpose).
- **The early max-wallet from the spec is not built.** The decaying 60% fee is the anti-snipe measure.
- **hook.setFactory is one-shot**, because the hook and factory reference each other.

Tests: `forge test --match-contract CreatorCoinFork --fork-url sepolia` runs 9 end-to-end tests on a Sepolia fork: launch and lock, supply split, the snipe decay, a buy with coin-side fee converted to JIG and split seven ways, a sell with the fee in JIG, referral defaults, the 5% band, pull claims, lower-only fee changes.

Deploy: `script/DeployCoins.s.sol`, bound to the JIG set above by env vars.

## Still to build

Holder drip, sweep and burn, airdrop claim, NFT contract v2 (mint referral), sweep and raffle, buyback and burn, LP deepening. Then the audit round per the plan of record.
