# contracts: JIG and the creator-coin stack

Foundry project. Spec: `../ECONOMICS-DRAFT.md` (signed off 15 Oct 2026) and the JIG build spec v1 both founders signed the same day. Phase 1 is built and live on Sepolia. Nothing is on mainnet.

## Live on Sepolia: tenth deploy, 15 Oct 2026, after the checklist audit

### Phase 1

| Contract | Address | What it does |
|---|---|---|
| JIG | `0xa8eFA939b1f7D275DD4b208FE89cd4b9a749A9B0` | fixed 1,000,000,000 supply, minted once: 90% to JIGLaunch, 10% to PotVault. No mint, no tax, no owner. Burnable |
| JIGLaunch | `0x674628D15234eeeb1d5287791e238Cc46934703b` | created the JIG/ETH v4 pool, seeded it single-sided with 900M JIG, holds the LP NFT forever. No transfer or remove-liquidity function. `collectFees()` splits LP fees half to the team wallet, half to the pot; anyone can call |
| PotVault | `0x91942C0a2d2C57AA7766072135834495A1d70Dbe` | the JIG pot. Holds 100M JIG now; receives mint reserve ETH and hook slices later. Payouts are merkle claims and are switched off until `enablePayouts()` (one-way, owner only). Owner cannot withdraw |
| Vesting | `0x33A85E32Fb2f14deECc045Be6801b10DFff7487f` | linear vesting with cliff for any ERC-20, irrevocable. Deployed but unused since creator vesting was dropped (15 Oct) |
| JIGLaunchHook | `0x68BD71455076064AA301523e28ED1f71a637E080` | the launch window: for 5 minutes after the pool opened, allowlisted tx.origin pays the normal 1.5%, anyone else 60%; then 1.5% for all. During those 5 minutes nobody but JIGLaunch can add liquidity, so a sniper cannot LP a band and earn their own tax back. Serves only the ETH/JIG dynamic-fee pool at the agreed spacing and start price, and only JIGLaunch may initialise it. CREATE2-mined address (flag bits 0x2880). This Sepolia deploy has no allowlist (everyone paid 60% in its window) |

Pool on Sepolia: ETH / JIG, dynamic fee via the hook, tick spacing 200, launched 15 Oct 2026 with the agreed parameters below. Earlier Sepolia sets are superseded and can be ignored.

## Launch plan (agreed by Jj and Fish, 15 Oct 2026)

| | |
|---|---|
| Start FDV | about $4k, a pump.fun-style start: 1 ETH = 625,000,000 JIG at $2,500 ETH. Recompute the sqrt price from the live ETH price on launch day |
| Range | full range above the start price, single-sided JIG, no cap |
| First 5 minutes | allowlisted friends-and-family wallets buy at the normal 1.5%; any other wallet pays a 60% fee (sniper tax) |
| After 5 minutes | open to everyone, fee 1.5%. The LP is locked; collected fees split half to the team wallet, half to the pot. The 1.5% is also paid on the JIG leg of every coin buy from ETH |
| Contract address | vanity prefix via a CREATE2 salt grind, on the final mainnet deploy only |

The window is `JIGLaunchHook`: `beforeInitialize` records the clock and refuses any pool other than ETH/JIG dynamic-fee; `beforeSwap` returns a 1.5% override for a tx.origin that proves allowlist membership in `hookData` (merkle proof, OpenZeppelin double-hash leaves of `abi.encode(address)`), 60% otherwise, 1.5% for all after 5 minutes. tx.origin is deliberate: routers can lie about msg.sender, nobody can fake the signing EOA. Smart-contract wallets therefore can't be allowlisted; use EOAs for the FNF list.

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

## Adversarial review, 15 Oct 2026

Before the swarm round, three independent reviewers (our own, each writing Foundry proofs) read the base: whole base, fee hook in depth, factory and modules. Everything below is fixed in the live set and pinned by `test/Regressions.fork.t.sol`.

| Severity | Finding | Fix |
|---|---|---|
| High | SweepAndBurn's keeper could drain the module: the marketplace call was arbitrary and the only check was that the NFT was here afterwards | marketplaces must be approved by the module owner (creator or multisig) and may not be a contract the module holds a balance in; the NFT must not be here before the call; JIG may only leave through the swap; the price cap is set by the owner, not the keeper; one sweep per 10 minutes |
| High | HolderDrip paid tokens minted after a payout a full share of it, making the module insolvent for earlier holders | checkpoints per pull: a token earns only from pulls made while it existed; burned tokens can be marked so later pulls split among live ones |
| High | Anyone could launch the coin for any collection and become its creator forever | the caller must be the collection's owner() or creator(), and the collection must be a contract |
| High | Anyone could initialise the JIG pool before our launch, locking out the hook or burning the window early | only JIGLaunch may initialise, at the agreed spacing and start price; JIGLaunch initialises directly and verifies the price |
| High | The pot could never collect its 3% (and deepening its 2%): claims paid the caller only | claimFor(address): anyone can push a balance to its owner |
| Medium | Exact-output swaps paid a lower effective fee, a 36% discount on the 60% sniper fee | the input-side fee is scaled so both directions pay the same rate |
| Medium | Swappers and minters could name themselves as referral and rebate 10% of their own fee | referrals removed entirely (Jj, 15 Oct) |
| Medium | Buyback and deepening runs were sandwichable with no price bound | runs are keeper-only at times the back end picks, spend the whole balance, and carry a keeper-supplied minimum out (Jj's direction: no caps, no cooldowns) |
| Medium | Pot and airdrop owners could declare a tree paying themselves, instantly | accepted (Jj, 15 Oct): no delay; the owner must be the founders' multisig |
| Medium | Airdrop shares were stuck forever if no drop was ever set | sweepUnset to the pot after 7 days |
| Low | Partial coin-side conversions stranded coin claims | retried on the next conversion |
| Low | Vesting schedules near the uint64 limit could brick | checked in create |
| Low | The first JIG buy was 1.4% off the stated start price | start price set exactly at the range top |

Jj's decisions after the reviews (15 Oct) are in `../DRIFT.md`: no referrals, no payout delays, 7-day recycling and airdrop sweep, keeper-only modules with a minimum out, creator slider, 10-second coin snipe, 5-minute JIG window at 1.5% split 50/50 team/pot, no creator vesting, settable launch fee.

Second pass, over the fixes themselves:

| Severity | Finding | Fix |
|---|---|---|
| High | Anyone could strand HolderDrip's income by pushing its balance to it with claimFor before it pulled; the drip only counted what its own claim returned | accounting by balance: everything held and not yet distributed is spread on the next pull |
| High | HolderDrip's checkpoint stored the accumulator in 128 bits; past about 340 JIG per token it truncated and reopened the over-claim | 160-bit field, enough for the maximum possible value |
| Medium | The 3% price bound was measured against the spot price, which the caller sets in the same transaction, so it capped our own impact rather than a sandwich | superseded: bounds removed, runs are keeper-only with a minimum out |
| Medium | SweepAndBurn's JIG sale had no bound at all, and held ETH let a bad swap pass the price check | keeper-supplied minimum out; the swap in a sweep must itself cover the price |
| Low | A zero-fill run burned the cooldown | cooldowns removed; a run that buys nothing reverts |
| Low | Anyone could start the airdrop's 180-day unset clock early for a predicted coin address | only the bound factory can notify |

Third pass, over the post-decision code:

| Severity | Finding | Fix |
|---|---|---|
| High | Balances were kept per address but recycling was keyed per pool, so anyone could launch a junk coin naming a victim's wallet or module as its flywheel and, after 7 quiet days, fold the victim's stale balance through their own 70/30 split | a per-pool recycle ledger: only what the creator or flywheel earned on that pool is recyclable; platform, pot, deepening, the hook, the pool manager and the factory cannot be named as a flywheel |
| Medium | A creator could set the slider to 70 and then recycle holders' accrued flywheel slice to themselves | a stale creator balance feeds the flywheel; a stale flywheel balance feeds the pot; the recycler never gains |
| Medium | The creator's dev buy at launch paid the 60% sniper fee | the factory's own buy pays the chosen fee |
| Low | Forwarder and buyback modules bound to a predicted coin address could end up pointing at the wrong coin | they resolve the coin and pool from the factory by collection |
| Low | A creator could not ask for "everything to the flywheel" at launch | a sentinel value means default; 0 means all to the flywheel |

Note on the 10-second creator-coin snipe window: on a 12-second chain that is one block; on a 2-second L2 it is five. Jj chose seconds deliberately.

Operational note: BuybackAndBurn, LPDeepening and SweepAndBurn are keeper-only. The back end picks random times, quotes the swap off chain, and passes the quote minus a tolerance as the minimum out. Each run spends the module's whole balance.

Residual trust, by design: the sweep keeper can still buy its own listing at up to the cap (there is no on-chain floor); tx.origin allowlisting can be relayed by a friend for strangers; third parties can LP into the JIG pool after the 5-minute window and share its fees with the pot; the hook's nested coin-to-JIG sale is at the post-trade price with no slippage bound (small amounts, the Zora pattern); a keeper's run can be front-run in the mempool up to the minimum-out tolerance it passes. The 5-minute windows rely on the sequencer's clock on an L2. ETH is assumed native (currency0 == address(0)) everywhere; a chain with a custom gas token needs changes. HolderDrip requires a collection with sequential ids from 1 whose totalSupply never decreases (LoomCollection).

## Checklist audit, 15 Oct 2026

After the three adversarial passes, a 370-item checklist audit (Solodit-derived categories: attacker's mindset, basics, heuristics, DeFi, tokens, integrations, external calls, merkle, centralisation, cross-chain, signatures) was run over the whole base. Full report: `audit-report.md`. 370 items walked, 154 applicable, no Critical or High; every earlier fix verified to hold. What it found and what changed:

| Severity | Finding | Fix |
|---|---|---|
| Medium | The platform wallet is `owner()` of every site-launched collection (the NFT factory makes the launcher the owner), so it could launch any artist's coin first and be its creator forever | the coin factory checks `creator()` first and only falls back to `owner()` for collections without a creator field |
| Medium | One hot key holds every privileged role | operational: the 2-of-2 founders' multisig (DRIFT item 10, Jj) before mainnet |
| Low | Unspent dev-buy JIG stranded in the factory on a partial fill | refunded to the creator in the same transaction |
| Low | Keeper-only modules with no permissionless pull could have their slice recycled after 7 quiet days | `pull()` on BuybackAndBurn and LPDeepening, anyone may call |
| Low | The airdrop notify call was unchecked, so a mis-bound AirdropClaim would silently never start its clock | the factory requires a contract recipient to accept the notification |
| Low | `PotVault.available()` looped over every distribution ever declared | a reserved counter; `settle(id)` releases an expired distribution's remainder |
| Low | The keeper can sandwich its own runs, and deepening adds liquidity at the post-sale spot | accepted: the keeper is the platform; bounded by the hook fee and the keeper's minimum out |
| Low | The 7-day airdrop sweep races the owner setting the root | operational: the back end sets drops within 7 days |

## Swarm audit round 2, 16 Oct 2026 (job 489901b6, public repo 2b03ffed)

Four specialists (math, permissions, economics, control flow) and a judge, 38 minutes, 0.5 IMD. No critical or high; every round-1 fix verified. Full report: `swarm-audit-report-2.md`. Everything below is fixed in this commit and pinned by a test.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Medium | an exact-output sell took its fee in coin and sold it at the post-trade price: a large unwind paid ~55% of the exact-input fee | `CreatorFeeHook.afterSwap` refuses exact-output sells (`ExactOutputSell`); routers fall back to exact-input, which pays f of the JIG output. Exact-output buys unchanged | `Regressions::test_exact_output_sell_is_refused_exact_input_sell_pays_full_fee` |
| 2 | Medium | `LPDeepening.run` added liquidity without collecting first, so accrued LP fees were compounded into the locked position (team/pot never paid) or the run reverted | `run()` calls `_collectFees()` before anything else | `Flywheels::test_lp_deepening_pays_accrued_fees_before_adding` |
| 3 | Medium | the 60% sniper tax is an LP fee, so a sniper who LPs a thin JIG band under the price earned ~40% of their own tax back | `JIGLaunchHook` now has the before-add-liquidity flag (address bits 0x2880): once JIGLaunch has minted its position (`markSeeded`) nobody can add liquidity until the window closes | `JIGLaunchHook::test_nobody_else_can_add_liquidity_during_the_window` |
| 4 | Low | `LPDeepening.run` sized its add with the whole ETH balance, including ETH booked as `platformOwedEth` | working ETH = balance − platformOwedEth, like JIGLaunch | covered by #2's test (`platformOwedEth` stays 0) |
| 5 | Low | `SweepAndBurn` reverted on any JIG balance change during the marketplace call, so a seller calling `hook.claimFor(module)` could veto a sweep | the guard is `<` (an inflow is harmless) | `Flywheels::test_sweep_survives_a_jig_inflow_during_the_market_call` |
| 6 | Low | `DeployCoins` defaulted the airdrop recipient to the pot, which cannot take `notify()`: a factory deployed that way bricks every launch and consumes the hook's one-shot `setFactory` | `AIRDROP` is required; `CoinFactory`'s constructor refuses a contract recipient that does not answer `pot()` | deploy-time check |
| 7 | Info | README said a 10-minute window at 1% | corrected: 5 minutes, 1.5% ongoing, 60% for non-allowlisted inside the window | |
| 8 | Info | the collection contract was not in the repo; HolderDrip assumes 1-based sequential ids | `reference/LoomCollection.sol` added (reference only); the collection mints `totalSupply + 1` and its supply is a monotone counter, so the assumption holds and is now documented in HolderDrip | |
| 9 | Info | L2 notes for Robinhood Chain: CREATE2 proxy must exist, 4337/Safe wallets pay 60% on tx.origin, sequencer timestamps, v4 addresses needed in `_v4()` | carried into the chain decision | |

## Audit status

**Plan of record, 15 Oct 2026 (Jj):** build the whole contract base on Sepolia first, no audits during the build. Then push the contracts to a throwaway public repo, have the IMD swarm audit the full base from it (the swarm cannot read a private repo and refuses requests with source embedded), fix findings, re-audit, launch nothing, delete the throwaway repo after sign-off. A single 0.5 IMD job can carry several agents, so the brief asks for two independent reviews of the repo inside the job, with the output a compiled list of each reviewer's findings and fixes. When everything has passed, tell Fish the back end is ready and go to mainnet in one sequence: JIG, then the NFT factory, then the creator-coin side. Then make the repo private again. External audit deferred; the fee hook and factory carry every coin's money, so that stays the main open risk.

| Contract | Written by | Swarm audit | External audit |
|---|---|---|---|
| JIG, Vesting, PotVault, JIGLaunch, JIGLaunchHook, CreatorFeeHook, CoinFactory, CreatorCoin, HolderDrip, AirdropClaim, SweepAndBurn, BuybackAndBurn, LPDeepening | Claude, 15 Oct, with 58 passing tests (14 unit, 44 on a Sepolia fork), three adversarial review passes and the checklist audit above. The NFT collection and factory stay as the swarm wrote and audited them at launch 1746 (the v2 referral was dropped) | swarm audit 1 (job fbe44d90, 15 Oct, 0.5 IMD): 1 High (dust order outside the range captured the nested fee conversion), 5 Medium/Low, all fixed and pinned by `test/Regressions.fork.t.sol::test_dust_order_outside_range_cannot_capture_the_fee`; see `swarm-audit-report.md`. Full set redeployed 16 Oct (addresses above). Swarm audit 2 (job 489901b6, 16 Oct, 0.5 IMD): no critical/high, 3 medium, 3 low, all fixed (section above); 58 tests. Round 3 on the fixed commit: next | before mainnet |

Audit scope notes for whoever runs it: JIGLaunch's `collectFees` encodes `DECREASE_LIQUIDITY` with zero liquidity then `TAKE_PAIR`; check the PositionManager version on the target chain still treats that as fee collection. PotVault leaf format is `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (OpenZeppelin standard double hash).

## Phase 2, live on Sepolia (15 Oct 2026)

| Contract | Address | What it does |
|---|---|---|
| CreatorFeeHook | `0x958Dd830b76E8a84757B045E1dd1D7A798536044` | the one shared hook for every creator coin. Takes the creator's fee (1 to 10%, lower-only) from every swap's unspecified currency; if that is the coin it sells it for JIG in the same transaction; credits creator / flywheel / platform / pot / deepening as claimable JIG. Anti-snipe: 60% decaying to the chosen fee over the first 10 seconds. Address flag bits 0x2044 |
| CoinFactory | `0x81Ddd9ff0C23d26bA3e957cafa786e54778676c3` | one call launches a coin: 1B fixed supply, coin/JIG pool (LP fee 0) on the hook, seeded single-sided, LP NFT held by the factory forever, 5% airdrop share, 0 to 5% to the creator's wallet (their choice) and an optional dev buy with JIG in the same transaction, launch fee in ETH settable by the platform |
| CreatorCoin | deployed per launch | fixed-supply ERC-20 with the collection address baked in, burnable |
| AirdropClaim | `0x39C1a9D9DD239f546C0b4b637a943C30Db024e7F` | shared merkle claim for every coin's 5% airdrop; the factory parks each coin's 5% here; platform sets one root per coin from a holder snapshot with a window; leftovers sweep to the pot, as does a share with no drop set within 7 days; there is no withdraw |
| HolderDrip | one per coin, deployed by the back end before launch and passed as `flywheel` | pulls the flywheel slice from the hook and accrues it per NFT; holders claim in JIG for the tokens they own. Anyone may pull |
| SweepAndBurn | one per coin, same | keeper-only: sells JIG for ETH on the JIG/ETH pool with a keeper-supplied minimum out, pays an approved marketplace order, checks the NFT arrived, sends it to the dead address. The creator approves marketplaces and sets the price cap |
| BuybackAndBurn | one per collection, same | keeper-only, at random times the back end picks: buys the collection's coin (resolved from the factory) on its own pool with the whole balance (keeper-supplied minimum out), burns it |
| HolderPayouts | `0x5438437d28B24E948867AD3EfE23C24380D02b06` | shared. Snapshot rounds for the "fees to coin holders" and "split NFT and coin holders" flywheels: a per-coin SnapshotForwarder delivers the slice here; the platform snapshots holders at a random moment and declares a round (merkle root, total, 7-day window); holders claim; unclaimed returns to the coin's balance for the next round. No withdraw. No staking anywhere (Jj, 15 Oct) |
| SnapshotForwarder | one per collection, passed as `flywheel` | pulls the slice from the hook and funds HolderPayouts under the collection's coin, resolved from the factory. Anyone may pull |
| LPDeepening | `0x5526b6b08dC2a3AacFde0f219A82501704e3Cb36` | shared, keeper-only. The deepening slice of every coin fee: sells half for ETH on the JIG/ETH pool (keeper-supplied minimum out) and adds both as full-range liquidity to a position it holds forever. LP fees it earns split half team, half pot like the JIG pool's. Bound to the hook once via `setDeepening` |

Fee split, in basis points of the fee: pot 300 and deepening 200 fixed; platform 2500 / 3000 / 3500 / 4000 by fee band (1% / 2-3% / 4-6% / 7-10%); the rest (7000 / 6500 / 6000 / 5500) is the creator+flywheel block, which the creator divides with `setCreatorShare` (default flywheel 2000, creator the remainder). A creator's or flywheel's balance untouched for 7 days can be folded back through the same split by anyone (`recycle`). Anti-snipe on creator coins: 60% decaying to the chosen fee over 10 seconds.

Design notes an auditor should know:

- **Fees are held as ERC-6909 claims inside the PoolManager**, not as ERC-20 in the hook. `take` would fail on a fresh chain because the swapper's input is settled after `afterSwap` runs; claims need no physical balance. `claim()` burns the claims and takes real JIG through an `unlock` callback.
- **The coin-side conversion is a nested swap on the same pool inside `afterSwap`**, guarded by `_converting` so the nested swap is not charged again. This is the Zora pattern.
- The hook has one-shot `setFactory` and `setDeepening` bindings because the hook, factory and deepening module reference each other. Verify both bindings on chain before trusting a deploy.
- **Holder drip pays in JIG, not ETH.** The hook holds JIG; converting to ETH per claim would cost every holder a swap. The economics doc said ETH; this is the deviation.
- **SweepAndBurn trusts the platform keeper to pick the listing.** Which listing is cheapest is not knowable on chain. The contract limits the keeper to real NFTs of the right collection at or under the max price, so the worst case is overpaying for a real burn, never taking funds.
- **The early max-wallet from the spec is not built.** The decaying 60% fee is the anti-snipe measure.
- **hook.setFactory is one-shot**, because the hook and factory reference each other.

Tests: `forge test --match-contract CreatorCoinFork --fork-url sepolia` runs 9 end-to-end tests; `FlywheelsFork` runs the drip, airdrop, sweep, buyback and deepening end to end; `RegressionsFork` pins the review fixes. 53 tests in all. on a Sepolia fork: launch and lock, supply split, the snipe decay, a buy with coin-side fee converted to JIG and split seven ways, a sell with the fee in JIG, referral defaults, the 5% band, pull claims, lower-only fee changes.

Deploy: `script/DeployCoins.s.sol` (hook + factory, CREATE2-mined; `SALT_SEED` to redeploy with identical args), `script/DeployRest.s.sol` (AirdropClaim) and `script/DeployDeepening.s.sol` (LPDeepening + binding; `KEEPER`), all driven by env vars.

## Flywheel menu

| Option | Module | Status |
|---|---|---|
| Fees to the team wallet | none (flywheel = creator) | built |
| Floor sweep and burn | SweepAndBurn | built |
| Fees to NFT holders | HolderDrip | built |
| Fees to coin holders | SnapshotForwarder + HolderPayouts | built |
| Split NFT holders and coin holders | SnapshotForwarder + HolderPayouts (the snapshot lists both) | built |
| Buyback and burn | BuybackAndBurn | built |
| Floor sweep and raffle | needs verifiable randomness (Chainlink VRF) on the target chain | not built |

## Still to build

Sweep and raffle only. It needs verifiable randomness (Chainlink VRF) on the target chain; Robinhood Chain's VRF availability is unconfirmed, so it waits for the chain decision. Everything else in the signed spec is on Sepolia. Next: the throwaway-repo swarm audit round per the plan of record.
