# contracts: JIG and the creator-coin stack

Foundry project. Spec: `../ECONOMICS-DRAFT.md` (signed off 15 Oct 2026) and the JIG build spec v1 both founders signed the same day. Phase 1 is built and live on Sepolia. Nothing is on mainnet.

## Phase 1, live on Sepolia (15 Oct 2026)

| Contract | Address | What it does |
|---|---|---|
| JIG | `0x9B9D82af0209dC740447c805596EA146f8f9353f` | fixed 1,000,000,000 supply, minted once: 90% to JIGLaunch, 10% to PotVault. No mint, no tax, no owner. Burnable |
| JIGLaunch | `0x9635ff10CC5088fF4146B36a438f95e4268609c8` | created the JIG/ETH v4 pool, seeded it single-sided with 900M JIG, holds LP NFT 40640 forever. No transfer or remove-liquidity function. `collectFees()` sends LP fees to the pot, anyone can call |
| PotVault | `0x291e8E0D64D00CC19d66982EE14A3c3AC179f12A` | the JIG pot. Holds 100M JIG now; receives mint reserve ETH and hook slices later. Payouts are merkle claims and are switched off until `enablePayouts()` (one-way, owner only). Owner cannot withdraw |
| Vesting | `0xC58B4abCCf1d8669e32c6104CA63a8E4Decf2862` | linear vesting with cliff for any ERC-20, irrevocable. Unused until the coin factory |

Pool: ETH / JIG, 1% fee, tick spacing 200, no hook (anti-snipe hook is phase 2). Start price 1 ETH = 5,000,000 JIG (200 ETH fully diluted). Seeded range from the start price to about 1000x, so buying JIG with ETH walks the price up through that range; nothing can be sold into the pool below the start price because there is no ETH there yet.

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
forge test --match-contract Fork --fork-url sepolia     # 4 tests on a Sepolia fork: launch, lock, a real 1 ETH buy, fees to pot
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

| Contract | Written by | Swarm audit | External audit |
|---|---|---|---|
| JIG, Vesting, PotVault, JIGLaunch | Claude, 15 Oct, with 18 passing tests | pending: needs 0.5 IMD in the operating wallet, then one `job.open` audit job | before mainnet |

Audit scope notes for whoever runs it: JIGLaunch's `collectFees` encodes `DECREASE_LIQUIDITY` with zero liquidity then `TAKE_PAIR`; check the PositionManager version on the target chain still treats that as fee collection. PotVault leaf format is `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (OpenZeppelin standard double hash).

## Phase 2 (not started)

Fee hook (shared, creator-set fee 1 to 10%, six-way split, converts to JIG), coin factory, holder drip, sweep and burn. Spec section 6.
