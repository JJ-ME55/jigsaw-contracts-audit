# contracts: JIG and the creator-coin stack

Foundry project. Spec: `../ECONOMICS-DRAFT.md` (signed off 15 Oct 2026) and the JIG build spec v1 both founders signed the same day. Phase 1 is built and live on Sepolia. Nothing is on mainnet.

## Live on Sepolia: tenth deploy, 15 Oct 2026, after the checklist audit

### Phase 1

| Contract | Address | What it does |
|---|---|---|
| JIG | `0x97C5271586312E772cbeea0E8da3D3d27151fC29` | fixed 1,000,000,000 supply, minted once: 90% to JIGLaunch, 10% to PotVault. No mint, no tax, no owner. Burnable |
| JIGLaunch | `0x54260c24840cC07BC4E4949bd54f4486CA7868aB` | created the JIG/ETH v4 pool, seeded it single-sided with 900M JIG, holds the LP NFT forever. No transfer or remove-liquidity function. `collectFees()` splits LP fees half to the team wallet, half to the pot; anyone can call |
| PotVault | `0x89a93423C953cf60E7DC0EB35d5910Eb16C4D284` | the JIG pot. Holds 100M JIG now; receives mint reserve ETH and hook slices later. Payouts are merkle claims and are switched off until `enablePayouts()` (one-way, owner only). Owner cannot withdraw |
| Vesting | `0x9502d687eF97504b04cf4a9925bc31282Bf49C18` | linear vesting with cliff for any ERC-20, irrevocable. Deployed but unused since creator vesting was dropped (15 Oct) |
| JIGLaunchHook | `0xfC44a44011d86Add3bC391934681F592cE222880` | the launch window: for 5 minutes after the pool opened, allowlisted tx.origin pays the normal 1.5%, anyone else 60%; then 1.5% for all. During those 5 minutes nobody but JIGLaunch can add liquidity, so a sniper cannot LP a band and earn their own tax back. Serves only the ETH/JIG dynamic-fee pool at the agreed spacing and start price, and only JIGLaunch may initialise it. CREATE2-mined address (flag bits 0x2880). This Sepolia deploy has no allowlist (everyone paid 60% in its window) |

### NFT launch

| Contract | Address | What it does |
|---|---|---|
| CollectionLauncher | `0xFecD6A04C981F530E6D50e24e83EA4585e88ca47` (18 Oct, round 9: refuses freeze with revealLater or an empty URI; `0x1fA4…f8CD` superseded; `0x46C9…e991` superseded; 17 Oct redesign; factory `0xbE4d…F50F`, operator and admin `0x7efa…5fDf`, no Safe on Sepolia; `0x2B43d404…0576` (4-argument `create`) and `0xFde2d1d7…FB15` are superseded) | creates a collection through the Loom NFT factory and, in the same transaction, sets its provenance hash and first URI (the unrevealed placeholder, or the base URI for an immediate reveal), with `freeze` (fifth argument, 17 Oct) freezes an immediate reveal's metadata in the same transaction (ignored for reveal-later: the reveal freezes), then `transferOwnership(operator)`; the operator calls `acceptOwnership()` (Ownable2Step). Only the operator may call `create()`; it holds nothing between calls; a zero provenance reverts `BadProvenance`. `admin` (immutable, the Safe on mainnets) may `reoffer(collection, to)` a collection the launcher still owns, for when the operator key is rotated or lost before `acceptOwnership()` (final audit, 17 Oct). Why: a clone is mintable from creation and `setProvenanceHash` refuses once anything is minted, so one outside mint between two transactions blocked the launch for good (replica review, 17 Oct). Verified on Sepolia through `0x2B43…0576`: collection `0x673d23b02A3C32Fc2834E97162383bE9608d00aa` created through it (tx `0x440379d7…`), ownership accepted, revealed (mint-end anchor block 11930118, drand round 33128545, the first round after it), frozen; a configure retry after the freeze sent nothing. The superseded launcher passed the same run with `0xa61Ab773…3b35` |
| JigsawCollection + JigsawCollectionFactory | impl `0x85c0834b6863fdC0E5bbE98091E82419978Ff8Ba` (round 8: recoverOwnership, freeze needs a URI; `0x43Ab…6ce3` superseded), factory `0xDC3cF2C3F91864f859e2EdC93685DB8015F4bEb5` (18 Oct, redeployed after the internal round; first deploy `0x5940…3239` / `0xd052…abB8` superseded; operator and owner `0x7efa…5fDf`, platform and reserve `0x7efa…5fDf` like the Loom collections) | our own NFT collection with timed mint phases (Jj, 17 Oct: VIP 10:00, WL 13:00, public 17:00). Up to 3 phases, each with a start, price, per-wallet allowance, optional phase supply and optional Merkle wallet list (OpenZeppelin double-hashed address leaves, as JIG's allowlist); a lifetime per-wallet cap across phases; a phase stays open once started, and a list-only phase may not follow an open one (`BadPhases`, also enforced by `setPhaseRoot`). Otherwise the Loom collection: 0.0005 ETH per mint split 40/40/20, provenance, placeholder, reveal seed once, base URI, freeze, pause, ERC-2981 royalty (max 10%), 1% reserve mint (at the first phase's price). The factory (operator-only `create`) clones and initialises in one transaction with provenance, first URI, phases and optional freeze, owned by the operator from the start, and registers it (`isCollection`); its owner (the Safe) may change the operator and the implementation for future clones. The owner may `setPhases` until the first phase starts and nothing but the owner's reserve is minted, and `setPhaseRoot(i, root)` until phase i starts. `mint(phase, qty, proof)`; Loom-style `mint(qty)` in an open current phase; `mintableNow(phase, wallet)`. Ownership cannot be renounced (`CannotRenounce`); `freeze` with `revealLater` and `freezeMetadata()` without a base URI revert `NothingToFreeze`; the factory refuses an implementation with no code (`NoCode`). Tests: `JigsawCollection.t.sol` (11), `Audit_Phased_*.t.sol` (11, internal round 18 Oct: 2 Low, 5 Info, no Critical/High/Medium; I-1 to I-5 fixed, L-1/L-2 below). Verified on Sepolia (`backend/scripts/sepolia-phases-e2e.mjs`): collection `0x64311F73B9cfD6C709FEf3fd78726E46E8eB4969` on the redeployed factory (first run `0xCd31…3e03`), refused before VIP, one mint each in VIP, WL and public as each opened, a fourth refused. **Known, accepted (L-1, L-2):** as on the Loom collection, the creator's share is pushed on every mint, so a creator address that rejects ETH blocks minting and one that burns gas makes minters pay for it; the server refuses a creator that cannot receive ETH (`canReceiveEth`) and the creator only harms their own collection. Internal round only; joins the external final round |

Pool on Sepolia: ETH / JIG, dynamic fee via the hook, tick spacing 200, launched 15 Oct 2026 with the agreed parameters below. Earlier Sepolia sets are superseded and can be ignored.

## Launch plan (agreed by Jj and Fish, 15 Oct 2026)

| | |
|---|---|
| Start FDV | about $4k, a pump.fun-style start: `START_TICK` 202,400 is about 1 ETH = 616M JIG (~$4k at ETH ~$2,460). Set `START_TICK` from the live ETH price on launch day (a multiple of 200) |
| Range | full range above the start price, single-sided JIG, no cap |
| First 5 minutes | allowlisted friends-and-family wallets buy at the normal 1.5%; any other wallet pays a 60% fee (sniper tax) |
| After 5 minutes | open to everyone, fee 1.5%. The LP is locked; collected fees split half to the team wallet, half to the pot. The 1.5% is also paid on the JIG leg of every coin buy from ETH |
| Contract address | `0x00000…c011ec7` through CreateX CREATE3 (salt bound to the JIG deployer, same address on every chain), `JIG_SALT`; see docs/JIG-VANITY.md |

The window is `JIGLaunchHook`: `beforeInitialize` records the clock and refuses any pool other than ETH/JIG dynamic-fee; `beforeSwap` returns a 1.5% override for a tx.origin that proves allowlist membership in `hookData` (merkle proof, OpenZeppelin double-hash leaves of `abi.encode(address)`), 60% otherwise, 1.5% for all after 5 minutes. tx.origin is deliberate: routers can lie about msg.sender, nobody can fake the signing EOA. Smart-contract wallets therefore can't be allowlisted; use EOAs for the FNF list.

**Allowlist root:** build the tree off chain (OpenZeppelin `merkletreejs` or `@openzeppelin/merkle-tree` with `["address"]` leaves), pass the root as `ALLOWLIST_ROOT` to the deploy script, and give each friend their proof for the front end to pass as hookData. The root is fixed once the pool exists.

On Sepolia the pot owner is the operating wallet. On Robinhood it is the founders' Safe (`POT_OWNER`, required by the script there).

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
forge test --fork-url sepolia                            # 136 tests (unit + Sepolia fork), incl. low-JIG reruns of the flywheel and regression suites
forge test --match-contract Fork --fork-url sepolia     # 11 tests on a Sepolia fork: launch, lock, real buys, window fees, sniper tax to pot
```

The fork test buys JIG with 1 ETH through the real v4 PoolManager and checks about 5M JIG arrives and 0.01 ETH of fees reaches the pot.

## Deploying

If `forge script --broadcast` fails with `ABI decoding failed: buffer overrun` on a CREATE2 deploy, the build cache is stale: `forge clean && forge build`, then rerun (16 Oct).

```bash
set -a; . ../backend/.env; set +a
forge script script/DeployJIG.s.sol --rpc-url sepolia --broadcast --slow --skip-simulation
```

Every script refuses Ethereum and Robinhood Chain (4663) unless `ALLOW_MAINNET_DEPLOY=1`; on those chains each role is required (DeployJIG: `POT_OWNER`, `PLATFORM`, `ALLOWLIST_ROOT`, `JIG_SALT`; DeployCoins: `PLATFORM`, `LAUNCH_FEE_WEI`; DeployDeepening: `KEEPER`; DeployLauncher: `NFT_FACTORY`, `OPERATOR`, `ADMIN`). DeployPayouts is gone (17 Oct); DeployCoins renounces AirdropClaim after `setFactory`, so there is no `AIRDROP_OWNER` and no `acceptOwnership`. Robinhood's Uniswap v4 addresses are in each script's `_v4()`. The whole go-day sequence is rehearsed on a local Robinhood fork by `script/rehearse-mainnet.sh` (roles read back from chain; since 18 Oct it also covers the Loom NFT factory, CollectionLauncher and DeployPhased, and drills the by-hand finish of a DeployJIG stopped halfway).

**JigsawCollectionFactory** (phased mints): `PLATFORM=<fee wallet> RESERVE=<reserve wallet> OPERATOR=<operating wallet> ADMIN=<the Safe> forge script script/DeployPhased.s.sol --rpc-url <chain> --broadcast --slow --skip-simulation`, then set `SEPOLIA_PHASED_FACTORY` / `RH_PHASED_FACTORY` on the server. Launches with `phases` go through it; the coin side accepts its collections (`isOurCollection` checks both factories).

**CollectionLauncher** comes right after the NFT factory (`backend/scripts/deploy-nft-factory.mjs`): `NFT_FACTORY=<factory> OPERATOR=<operating wallet> ADMIN=<the Safe> forge script script/DeployLauncher.s.sol --rpc-url <chain> --broadcast --slow --skip-simulation`. All three are required on every chain (`admin` is immutable; on Sepolia it is the operating wallet); the script checks the factory has code. Then set `RH_LAUNCHER` (or `SEPOLIA_LAUNCHER`, `MAINNET_LAUNCHER`) on the server. The server refuses to create a collection on Ethereum or Robinhood without one.

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

Residual trust, by design: the sweep keeper can still buy its own listing at up to the cap (there is no on-chain floor); tx.origin allowlisting can be relayed by a friend for strangers; third parties can LP into the JIG pool after the 5-minute window and share its fees with the pot; anyone can open a hookless pool for a creator coin and trade there fee-free (the locked liquidity and price discovery stay on the hooked pool, as with Zora coins); a donate() to a creator pool is lost to the factory's locked position (donor's loss only); keeper modules must not run inside the JIG pool's 5-minute window (LPDeepening.run reverts WindowLocked, sales pay 60%); the hook's nested coin-to-JIG sale is at the post-trade price with no slippage bound (small amounts, the Zora pattern); a keeper's run can be front-run in the mempool up to the minimum-out tolerance it passes. The 5-minute windows rely on the sequencer's clock on an L2. ETH is assumed native (currency0 == address(0)) everywhere; a chain with a custom gas token needs changes. HolderDrip requires a collection with sequential ids from 1 whose totalSupply never decreases (LoomCollection).

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
| Low | The keeper can sandwich its own runs, and deepening adds liquidity at the post-sale spot | accepted: the keeper is the platform; bounded by the hook fee and the keeper's minimum out. **Premise no longer holds on the mainnet plan** (keeper = hot wallet, platform = Safe): final audit Medium 1, Known risks |
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

## Swarm audit round 3, 16 Oct 2026 (job 0c246e1d, public repo d3d943ca)

35 minutes, 0.5 IMD. No critical, high or medium; every round-2 fix verified. Full report: `swarm-audit-report-3.md`.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Low | `LPDeepening.run` collected before its own sale, so that sale's LP fee was still netted into the position | collect after the sale and the min-out check | `Flywheels::test_lp_deepening_pays_accrued_fees_before_adding` (JIG to team/pot asserted) |
| 2 | Low | creator pools took liquidity from anyone, so an LP band traded coin for JIG at spot with no fee and no anti-snipe | **Jj, 16 Oct: factory-only liquidity, permanently.** `CreatorFeeHook` has the before-add-liquidity flag (bits 0x2844); the factory calls `seal(key)` after seeding and the hook refuses every later add | `Regressions::test_creator_pool_takes_no_liquidity_but_the_seed` |
| 3 | Low | the factory accepted an AirdropClaim already bound to another factory (every launch would revert) | constructor also requires `factory() == 0`; the deploy script no longer swallows a failed `setFactory` | `Regressions::test_factory_refuses_an_airdrop_claim_bound_to_another_factory` |
| 5 | Info | a dust buy every 7 days kept a stale balance from being recycled | staleness runs from the first unclaimed credit (`Earned.firstCredit`) | `Regressions::test_recycle_clock_runs_from_the_first_unclaimed_credit` |
| 6 | Info | `launch` required the exact fee, so a fee update mined first reverted a quoted launch | `msg.value >= fee`, excess refunded | `Regressions::test_launch_overpayment_is_refunded` |
| 7 | Info | stale 0x2080 in the launch hook header | corrected | |
| 8 | Info | keeper modules inside the JIG 5-minute window revert or pay 60% | operational rule, residual-trust list; the keeper job must start after `windowEnd` | |
| 4, 9, 10, 11 | Info | exact-input buys with real price impact pay above nominal (by construction); L2 notes; hookless pools are fee-free; stale Vesting header | documented; Vesting header corrected | |

## Swarm audit round 4, 16 Oct 2026 (job ae115cf4, public repo ec8476c8)

37 minutes, 0.5 IMD. No critical, high or medium. Two of the three lows were introduced by round-3 fixes. Full report: `swarm-audit-report-4.md`.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Low | round 3's `firstCredit` clock let `recycle` sweep fresh credits along with the stale one, and chain creator → flywheel → pot in one block | credits are bucketed by day; `recycle` folds exactly the buckets at least 7 days old and nothing younger; `recyclable(key, who)` shows stale/fresh | `Regressions::test_recycle_takes_only_the_stale_part_and_does_not_chain` |
| 2 | Low | exact-input buys with real price impact pay the fee at the post-trade price: 2x nominal at half the pool, 10x at 90% (exact-output buys pay exactly f) | **Jj, 16 Oct: cap at nominal.** The hook converts only enough coin to recover f of the JIG spent (exact-output nested swap), charges the buyer that coin and leaves them the rest; at the range edge it falls back to the old full charge with the remainder parked | `Regressions::test_exact_input_buy_pays_nominal_fee_at_every_size` |
| 3 | Low | round 3's `msg.value >= fee` refund removed the creator's bound on the fee: a fee raised before the launch mined took the whole `msg.value` | `LaunchParams.maxFeeWei`: the launch reverts if the fee exceeds it; the fee is read once and used for the check, the payment and the refund (also closes Info 4) | `Regressions::test_launch_fee_above_the_creators_maximum_reverts` |
| 5 | Info | `_converting` is unreachable: v4 skips `afterSwap` for a hook's own swap | kept as belt and braces; comments and README corrected | |
| 6 | Info | a coin registered before `setDeepening` could name the future LPDeepening as its flywheel | accepted: `setDeepening` is called in the deploy script before any launch | |
| 7 | Info | `recycle` re-splits with the platform band of the current fee, not the band when earned; only the platform can lose, after a `lowerFee` | accepted, residual trust | |
| 8 | Info | `HolderDrip.pull` booked the full amount but the accumulator floors, so up to live−1 wei per pull was owed to nobody | ~~books only what the accumulator can pay~~ **reverted in round 5**: that change bricked the drip (High below). Full booking is correct; the dust is unclaimable by design | |

## Swarm audit round 5, 16 Oct 2026 (job 374e2a1a, public repo cfd5cb83)

45 minutes, 0.5 IMD. Every finding was in code written for round 4; the base from round 3 was clean. Full report: `swarm-audit-report-5.md`.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | **High** | round 4's "book only what the accumulator can pay" let per-token claims exceed `accounted`, so `undistributed()` underflowed and `pull()` bricked for good | reverted: book the full amount (sum of per-token floors is always ≤ it) | `Regressions::test_holder_drip_survives_lossy_pulls_and_claims` |
| 2 | Medium | the fee cap sized the conversion from the JIG *requested*, not spent: a price-limited buy paid f of the request (5x), and a large request on a young pool reverted `CurrencyNotSettled` | target = f of the specified-side delta (JIG actually spent); the partial-fill branch charges max(fee, spent) so the hook is never short of claims | `Regressions::test_partial_exact_input_buy_pays_f_of_what_it_spent` |
| 3 | Low | day buckets made the grace as short as 6 days + 1 s | a bucket is stale only when its last second is 7 days old: grace is 7 to 8 days, never less | `Regressions::test_recycle_grace_is_never_under_seven_days` |
| 4 | Low | a claim made the next swapper pay to `delete` the whole ledger (4.4M gas after 400 idle days) | old entries are abandoned by moving `head`, never deleted; `recycle` folds at most 64 buckets per call | `Regressions::test_claim_does_not_make_the_next_swap_delete_the_ledger` |
| 5 | Info | anyone can `claimFor(creator)` the block before a recycle, so recycling is a liveness backstop, not an enforceable redistribution | accepted and documented; funds only ever reach the credited address | |

## Swarm audit round 6, 16 Oct 2026 (job b47cb5dc, public repo 3a9f3d28)

50 minutes, 0.5 IMD. No critical, high or medium; every round-5 fix verified. Full report: `swarm-audit-report-6.md`.

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Low | `HolderDrip.pull` spread JIG over today's supply, so a mint right before a pull took a share of JIG that accrued before it existed (a free `reserveMint` could farm a large unpulled slice) | the pull spreads over the supply the *previous* pull recorded; a token earns from the pull after the first pull that saw it; burns before a token's first pull are folded in once it is covered. The keeper should pull on every accrual worth claiming, so the lag is minutes | `Regressions::test_mint_right_before_a_pull_takes_nothing_from_it` |
| 2 | Info | `_staleCutoff` underflowed on a chain younger than 8 days (local harnesses only) | returns "nothing stale" instead | covered by the existing recycle tests |
| 3 | Info | a buy too small to owe any JIG was still charged its coin fee into `pendingCoin` | charged nothing | `Regressions::test_dust_buy_is_charged_nothing` |
| 4 | Info | `donate()` is allowed on creator pools and the donation accrues to the factory's locked position with no collect path | accepted, residual trust: only the donor loses; gating it means another re-mine (bits 0x2864) for no user benefit | |

## Replica review, 17 Oct 2026

A review of the whole base, contracts and the back end's money paths together. Contracts: 118 tests pass. Back end: 59 tests pass.

| Severity | Finding | Fix | Test |
|---|---|---|---|
| Medium | a clone is mintable from creation and `setProvenanceHash` refuses once anything is minted, so one outside mint between the create and the commit blocked a launch for good (never happened live) | `CollectionLauncher`: create, provenance and first URI in one transaction, ownership offered to the operator; the server goes through it where configured and refuses mainnets without it | `CollectionLauncher.fork.t.sol` (the old two-step launch blocked by one mint; the launcher commits before any mint) |
| Low | `HolderDrip`'s first pull spread over the supply at that pull, so tokens minted after fees accrued shared JIG earned before they existed | `lastSupply` recorded in the constructor: the first pull spreads over the tokens that existed when the module went live | `HolderDripFirstPull.t.sol` |

Back-end findings, fixed in the same pass:

| Finding | Fix |
|---|---|
| a reveal interrupted after `freezeMetadata` could never finish (every retry reverted) | `configureClone` accepts pending ownership first and skips every step already on chain |
| a deploy that reverted on chain blocked the launch's retry | the reverted hash is forgotten and the deploy is sent again |
| CoinFactory is open to any contract that names a creator, so a hostile collection could stall the keeper or fill the vanity queue | the keeper and the COLLECT grind serve only EIP-1167 clones of our NFT factory's implementation (`isOurCollection`); others get vanity `unavailable` |
| the keeper trusted a module's own `undistributed()`, quoted min-out minutes before the send, had no gas bound, and a flat daily cap starved newer coins | drip amount from the hook's claimable and the JIG balance only; min-out re-quoted right before the send; gas = estimate x1.3, refused above `KEEPER_GAS_CAP` (3,000,000); daily cap `KEEPER_MAX_TX_PER_DAY` + `KEEPER_TX_PER_COIN` per serviced coin |
| an unknown JIG price skipped a whole payout window when `minRoundUsd` > 0; a lagging node's missing receipt was called "replaced" at once | the round waits for the next pass; "replaced" only after 3 passes |
| snapshots indexed to `latest` (a reorg leaves phantom balances); the platform fee wallet counted as a coin holder; no size limit; proofs O(n²) | index to the `safe` block; `PLATFORM_ADDRESS` excluded; `PAYOUT_MAX_HOLDERS` (200,000) and `AIRDROP_MAX_NFTS` (50,000) refuse larger snapshots; proofs O(n log n) |
| allowlist additions after the root was on the hook broke every proof | refused once the hook has a root; proofs withheld if the file no longer builds the on-chain root |
| `creatorOf` fell back to `owner()` on a zero `creator()` or an RPC error, unlike CoinFactory | follows CoinFactory exactly: `creator()` if it answers (zero = nobody, 403); `owner()` only if `creator()` does not exist; an RPC error is an error |
| an early reveal timed its seed round from the server clock after the mint pause, which nobody outside could check | the seed is the first drand round after the later of the trigger and the block that confirmed the pause (`pausedUnix` recorded) |

## Swarm audit round 9, 18 Oct 2026 (job c68a3cd2, public repo 840d2a1)

Scope: round 8's fixes and what they introduced. Result: **no critical, high or medium**; 4 low, 2 info (`swarm-audit-report-9.md`), all in the round-8 fixes, all fixed with a regression test first (`test/Audit9_*.t.sol` are the auditors' proofs; `Audit8_Rest.t.sol::Audit9DustTest`; `backend/test/rewards-code.test.mjs`).

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Low | `_excluded()` asked a plain-wallet airdrop recipient for `pot()`, so launch/predictCoin reverted for that (allowed, never used) configuration | `pot()` only when the recipient has code |
| 2 | Low | CollectionLauncher could still freeze a Loom collection with an empty URI | reverts `NothingToFreeze` |
| 3 | Low | the keeper marked a coin's airdrop done while contract-held ids remained, so an NFT leaving an escrow later was never pushed | done only when no contract-held or unreadable ids remain; until then it looks again hourly |
| 4 | Low | the public airdrop view re-read every owner and ran one `eth_getCode` per holder per request | the site's delivery status is cached 60 s; code checks run 25 in parallel and are cached an hour |
| 5 | Info | a failed `eth_getCode` counted as a wallet, so the keeper sent pushes that pushed nothing | a failed read is "unknown": not pushed, not counted as done |
| 6 | Info | division dust made every quiet day's pull call `notifyReward(0)` and reset the stream for nothing | re-stream only when carry ≥ DURATION wei (can pay ≥ 1 wei a second) |

Redeployed on Sepolia 18 Oct: AirdropClaim `0xF73dee9A177c5D5399344A6Adb66f1FD102E1ED8` (renounced), CreatorFeeHook `0x36Fc51F5C315fFF7e7140F169BAA787147AB2844`, CoinFactory `0x6D45B52031e0051ac6D68A19f07c8120081fBe3c`, LPDeepening `0x486F0dA82702b1C65343E412A80E17e43D75Cc33`, CollectionLauncher `0xFecD6A04C981F530E6D50e24e83EA4585e88ca47`. End to end: rewards coin `0x3CC60E20699582d5d59D1656057d890d84e0f4dd` (airdrop pushed, 0.278 JIG/min, pot excluded). 171 contract tests, 85 back-end tests.

## Swarm audit round 8, 18 Oct 2026 (job 70fa509e, public repo 4e652a0)

Scope: everything since round 7: on-chain holder rewards (1-day stream), RewardsForwarder, per-NFT AirdropClaim with push, setKeeper, CollectionLauncher freeze, JigsawCollection + factory (phased mints), go-day scripts, off-chain keeper (price check), rewards, phases, flywheels. Result: 1 high, 1 medium, 3 low, 5 info (`swarm-audit-report-8.md`). Each fix has a regression test first (`test/Audit8_*.t.sol`; the High and Medium use the auditors' own proofs).

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | High | PotVault was not excluded from holder rewards: the swept airdrop remainder earned JIG nobody could claim (45% of a stream in the auditors' case) | `CoinFactory._excluded()` adds `AirdropClaim.pot()` | `Audit8_PotStranded.t.sol` |
| 2 | Medium | `AirdropClaim.claimFor` pushed a share into whatever contract held the NFT (escrow, vault, bridge) and marked it claimed | `claimFor` skips owners with code; they claim themselves. The keeper no longer queues contract-held ids (`rewards.pushableIds` → `contractHeld`); `/coins/:coin/airdrop` gives `selfClaim` | `Audit8_AirdropPushToEscrow.t.sol` |
| 3 | Low | `JigsawCollection.initialize` could freeze with an empty base URI | reverts `NothingToFreeze` | `Audit8_Rest::test_low3_…` |
| 4 | Low | AirdropClaim assumes ids 1..maxSupply (a 0-based collection's token 0 cannot claim) | accepted: every collection we make (Loom, Jigsaw) is 1-based, and the site and keeper serve only ours | |
| 5 | Low | phased clones had no recovery if the operator key is lost | `JigsawCollection.recoverOwnership(newOwner)`, only the factory's owner (the Safe), as `CollectionLauncher.reoffer` | `Audit8_Rest::test_low5_…` |
| 6 | Info | CoinFactory does not read the isCollection registry on chain: a self-made collection's launcher can take its own coin's 5% airdrop | accepted: it moves only that coin's own airdrop to its own creator; the site, keeper and vanity grinder refuse unregistered collections | |
| 7 | Info | CollectionLauncher ignored `freeze` with `revealLater` | reverts `NothingToFreeze`, as the phased path | `Audit8_Rest::test_info7_…` |
| 8 | Info | RewardsForwarder comments said 7 days | corrected; MIN_INTERVAL == DURATION noted as the invariant | |
| 9 | Info | a pause batches up to 14 days of fees into one 1-day stream | accepted: pauses are emergency-only (Safe, 2 of 2), documented | |
| 10 | Info | carry was only re-streamed by a pull with new JIG | `pull()` with no new JIG calls `notifyReward(0)` when the coin has carry (and is not paused) | `Audit8_Rest::test_info10_…` |

Redeployed on Sepolia 18 Oct: AirdropClaim `0x21D7EE82F510b96e9d81693b4A5bb0494B075255` (renounced), CreatorFeeHook `0xB267c81bF3c41E209Fd9817241e204cD8f102844`, CoinFactory `0xB011DF99640E06c90c9fD8c42585e9F45699c2C8`, LPDeepening `0x917f6E6AdC371c670426d70F7163Ee26fFaF6191`, CollectionLauncher `0x1fA4cDa77D2641D8f778fa747a96B87c421Ef8CD`, JigsawCollection implementation `0x85c0834b6863fdC0E5bbE98091E82419978Ff8Ba` (factory `0xDC3c…bEb5` unchanged, `setImplementation`). End to end: rewards coin `0x73390911fB780B2708F90935BDeEDDAC38c94035` (airdrop pushed, 0.278 JIG/min, `excluded(PotVault) == true`), phased collection `0x3C8e1b747Af5993D22EFfcF81c2D95c9A2Cd03Ca` (VIP/WL/public, fourth refused). 168 contract tests, 84 back-end tests.

## Final audit, 17 Oct 2026 (job e587fdcb, public repo 63e94356)

The last paid round: contracts and, for the first time, the off-chain money paths (keeper, sender, payouts, coin settings, swap, vanity, JIG allowlist, reveal, launch). Four specialists and a judge, 28 minutes, 0.5 IMD. No critical or high; the judge did not run forge (`lib/` is not in the audit repo). Full report: `swarm-audit-report-7.md`. Contracts: 121 tests pass. Back end: 59 tests pass. Sepolia: launcher redeployed (`0x2B43d404…0576`) and the end-to-end launch, reveal and freeze run again.

| # | Severity | Finding | Fix | Test / verification |
|---|---|---|---|---|
| 1 | Medium | a leaked operating key can sandwich its own `LPDeepening.run(0)` / `BuybackAndBurn.run(0)`: the only price floor is the caller's, `keeper` is immutable in both, and on the mainnet plan the keeper is the hot wallet, not the platform | **addressed 17 Oct:** `setKeeper` by the platform (the Safe) in both; a leaked key can still sandwich until the Safe swaps it (Known risks) | |
| 2 | Medium | a creator could place a holder-payout snapshot by switching cadence minutes before a window edge (a cadence change drew a new random moment in what was left of the current window) | `keeper.mjs`: a cadence change after a round closes the current window; the next round is random in the next one | back end |
| 3 | Medium | a deploy whose hash was persisted but never mined (RPC refused it, or it was dropped) pinned the build in `failed`: every retry waited 10 min and failed | `launch.deployNonce` persisted with the hash; `collectionFromTx` forgets a deploy the node does not know when another transaction took its nonce or nothing is pending at it; the build records `launch.droppedDeployTx` and the retry redeploys | back end; RUNBOOK failure table |
| 4 | Low | the keeper counted a drip's distributed-but-unclaimed JIG as pullable, sending a no-op `pull()` every 4-8 h | amount = claimable + balance above (`accounted` - `paidOut`) | back end |
| 5 | Low | a reveal of a sold-out or already-paused mint took its drand round from the server clock, so the operator could choose among published rounds | the anchor is a block: the pause tx, else the mint of the last token, else the earlier `Paused` event; stored as `reveal.mintEnded.anchor` {block, unix, source} so anyone can recompute the round | Sepolia: `0x673d23b0…00aa`, anchor block 11930118, drand round 33128545 (first round after it) |
| 6 | Low | swap quotes ran with tx.origin = 0, so an allowlisted wallet was quoted the 60% window fee and its minOut set ~60% low | `quoteGross` passes `account`; the keeper quotes as the operating wallet | back end |
| 7 | Low | `CollectionLauncher` offered ownership to an immutable operator with no re-offer: a key rotation between `create()` and `acceptOwnership()` stranded the collection's owner functions | immutable `admin` (the Safe) and admin-only `reoffer(collection, to)`; constructor takes 3 args, `DeployLauncher` needs `ADMIN` | `CollectionLauncherAdminFork::test_admin_reoffers_a_stranded_collection_and_nobody_else_can`; Sepolia end to end |
| 8 | Low | HolderDrip's first pull excluded tokens minted between the module's deployment and the launch | operational: the keeper makes a drip's first pull at once, whatever its value, recording the supply at launch | back end |
| 9 | Low | `configureClone` skipped `setRevealSeed` silently when a different seed was already on chain | throws if the collection records a different reveal seed | back end |
| 10 | Low | `HolderDrip._foldBurns` was unbounded: a few hundred burns above the supply pushed `pull()` over the keeper's gas cap, thousands over a block | at most `MAX_FOLD` (64) per pull, the rest on later pulls; solvency unaffected | `HolderDripFoldBound.t.sol` |
| 11 | Low | one spot-price dip under `minRoundUsd` closed the creator's whole round window | the round retries on later passes; the window closes by itself | back end |
| 12 | Low | `isOurCollection` accepted any EIP-1167 clone of the implementation, so a self-deployed clone passed the keeper and vanity gates | the factory's own registry, `factory.isCollection(collection)` | back end |
| 13 | Low | airdrop snapshot failures backed off up to 16 h near the 7-day unset deadline; five failures swept the holders' 5% to the pot | after day 5 of the unset window the airdrop retries at most every 10 min; each multicall batch is retried 3 times | back end |
| 14 | Low | a prepared round record could be overwritten with a new snapshot while its first declare could still be mined | a non-final record is re-sent with its own tree (same root and total, fresh expiry) | back end |
| 15 | Info | `sender.mjs` has no gas-bump path: one stuck nonce stalls every send on that chain | **not fixed**: recovery by hand in RUNBOOK | |
| 16 | Info | `expiredRounds` read every round of every coin on every pass | the keeper keeps the lowest unsettled index (`settleFrom`) | back end |
| 17 | Info | collections that reveal immediately are never frozen, so the hot wallet can rewrite their metadata | **done 17 Oct:** every mainnet collection is frozen with an `ipfs://` base URI: an immediate reveal in `CollectionLauncher.create` (`freeze`), a reveal-later one at the reveal | `CollectionLauncher.fork.t.sol::test_an_immediate_reveal_can_be_frozen_at_creation` |
| 18 | Info | without the `safe` tag the holder index fell back to `latest` | `REORG_DEPTH` (default 1200) blocks behind latest, logged | back end |
| 19 | Info | `CollectionLauncher` committed a zero provenance, which LoomCollection treats as committed forever | `create()` reverts `BadProvenance` | `CollectionLauncherAdminFork::test_zero_provenance_is_refused` |
| 20, 21 | Info | threat model for the one hot wallet; scope answers (sound bar the findings above) | Known risks below | |

## Known risks

**Addressed 17 Oct (Jj): the hot key no longer owns payouts or the airdrop.** It owned HolderPayouts and AirdropClaim on the mainnet plan, so a leak could declare a one-leaf round or drop paying itself. Now coin-holder rewards stream on chain from the coin (only its notifier module adds; the platform can only pause adding and claiming), HolderPayouts is retired, and AirdropClaim is per NFT with its owner renounced after `setFactory`. Nobody declares a root any more.

**Addressed 17 Oct (Jj): the keeper of LPDeepening and every BuybackAndBurn is replaceable** (final audit, Medium 1). `run(minOut)` still takes its only price floor from the caller, so a leaked keeper key can call `run(0)` between two trades of its own and take the accrued JIG, bounded by pool depth and the hook fees, **until the Safe calls `setKeeper`** with a new key. Watch for unexpected `run` calls; rotating is one Safe transaction per module.

**Addressed 17 Oct: immediate reveals are frozen on mainnet** (final audit, Info 17). The back end freezes every mainnet collection with an `ipfs://` base URI (`launch.mjs` `finalBase`): an immediate reveal in the creating transaction, a reveal-later one at the reveal. Sepolia keeps the web-gateway URI and freezes only on request.

## Audit status

**Plan of record, 15 Oct 2026 (Jj):** build the whole contract base on Sepolia first, no audits during the build. Then push the contracts to a throwaway public repo, have the IMD swarm audit the full base from it (the swarm cannot read a private repo and refuses requests with source embedded), fix findings, re-audit, launch nothing, delete the throwaway repo after sign-off. A single 0.5 IMD job can carry several agents, so the brief asks for two independent reviews of the repo inside the job, with the output a compiled list of each reviewer's findings and fixes. When everything has passed, tell Fish the back end is ready and go to mainnet in one sequence: JIG, then the NFT factory, then the creator-coin side. Then make the repo private again. External audit deferred; the fee hook and factory carry every coin's money, so that stays the main open risk.

| Contract | Written by | Swarm audit | External audit |
|---|---|---|---|
| JIG, Vesting, PotVault, JIGLaunch, JIGLaunchHook, CreatorFeeHook, CoinFactory, CreatorCoin, HolderDrip, AirdropClaim, SweepAndBurn, BuybackAndBurn, LPDeepening | Claude, 15 Oct, with 71 passing tests (14 unit, 57 on a Sepolia fork), three adversarial review passes and the checklist audit above. The NFT collection and factory stay as the swarm wrote and audited them at launch 1746 (the v2 referral was dropped) | swarm audit 1 (job fbe44d90, 15 Oct, 0.5 IMD): 1 High (dust order outside the range captured the nested fee conversion), 5 Medium/Low, all fixed and pinned by `test/Regressions.fork.t.sol::test_dust_order_outside_range_cannot_capture_the_fee`; see `swarm-audit-report.md`. Full set redeployed 16 Oct after each round (addresses above). Swarm audit 2 (job 489901b6, 16 Oct, 0.5 IMD): no critical/high, 3 medium, 3 low, all fixed (section above); 58 tests. Round 3 (job 0c246e1d, 16 Oct, 0.5 IMD): no critical/high/medium, 3 low, 8 info, all fixed (section above); 62 tests. Round 4 (job ae115cf4, 16 Oct, 0.5 IMD): no critical/high/medium, 3 low, 5 info; all fixed. Round 5 (job 374e2a1a): 1 High, 1 Medium, 2 Low, 1 Info, every one in round-4 code, all fixed. Round 6 (job b47cb5dc): no critical/high/medium, 1 Low (pre-existing drip timing), 3 Info, all fixed or accepted (section above); 71 tests. Pre-audit review fixes (16 Oct): 112 tests. Replica review fixes (17 Oct, section above): 118 tests. Final round (job e587fdcb, public repo 63e94356, 0.5 IMD, contracts and the off-chain money paths): no critical/high, 3 medium, 11 low, 7 info; all fixed but Medium 1, Info 15 and Info 17 (Known risks, RUNBOOK); see `swarm-audit-report-7.md`; 121 tests. Holder-rewards redesign (17 Oct, after the final round: CreatorCoin stream, RewardsForwarder, per-NFT AirdropClaim, `setKeeper`, launcher `freeze`): 136 tests, not yet swarm audited | before mainnet |

Audit scope notes for whoever runs it: JIGLaunch's `collectFees` encodes `DECREASE_LIQUIDITY` with zero liquidity then `TAKE_PAIR`; check the PositionManager version on the target chain still treats that as fee collection. PotVault leaf format is `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` (OpenZeppelin standard double hash).

## Phase 2, live on Sepolia (15 Oct 2026; coin side redeployed 17 Oct)

| Contract | Address | What it does |
|---|---|---|
| CreatorFeeHook | `0x36Fc51F5C315fFF7e7140F169BAA787147AB2844` (18 Oct, after swarm round 9; was `0xB267…2844`, `0x3fc1…E844`, `0x1d64…e844`, `0x37d8…2844`, `0x36F3…A844`) | the one shared hook for every creator coin. Takes the creator's fee (1 to 10%, lower-only) from every swap's unspecified currency; if that is the coin it sells it for JIG in the same transaction; credits creator / flywheel / platform / pot / deepening as claimable JIG. Anti-snipe: 60% decaying to the chosen fee over the first 10 seconds. Address flag bits 0x2844. After the factory seeds a pool nobody can add liquidity to it, ever (Jj, 16 Oct) |
| CoinFactory | `0x6D45B52031e0051ac6D68A19f07c8120081fBe3c` (18 Oct, round 9; excludes the pot; was `0xB011…c2C8`, `0x3ead…30Bf`, `0xD06a…4a70`, `0xBD5f…8EdC`, `0xe074…59aA`) | one call launches a coin: 1B fixed supply, coin/JIG pool (LP fee 0) on the hook, seeded single-sided, LP NFT held by the factory forever, 5% airdrop share, 0 to 5% to the creator's wallet (their choice) and an optional dev buy with JIG in the same transaction, launch fee in ETH settable by the platform. Names the coin's flywheel as its reward notifier (once) and excludes the pool manager, hook and airdrop claim from rewards |
| CreatorCoin | deployed per launch | fixed-supply ERC-20 with the collection address baked in, burnable. **Holder rewards (17 Oct):** streams JIG to holders over 24 hours, pro rata to balance x time (StakingRewards pattern, every transfer updates both sides); holders call `claim()`. Excluded: factory, pool manager, hook, airdrop claim, the coin, the dead address. Only `notifier` (the flywheel module, set once by the factory) can `notifyReward`; the platform (`factory.platform()`, the Safe on mainnet) can `setRewardsPaused` (adding and claiming) and nothing else; accrual and trading carry on while paused |
| AirdropClaim | `0xF73dee9A177c5D5399344A6Adb66f1FD102E1ED8` (18 Oct, round 9; no push into contracts; owner renounced; was `0x21D7…5255`, `0x690B…788e`, `0x9C7f…dfc9`, `0x58fc…fC2`, `0xB71B…262a`) | shared, per NFT (17 Oct): the factory parks each coin's 5% here and `notify` splits it as 5% / the collection's `maxSupply` (or `totalSupply` without one) per token id. The owner of NFT #id claims once with `claim(coin, ids[])` for `CLAIM_WINDOW` (30 days); then anyone may `sweep` the rest (unclaimed, unminted ids, dust) to the pot. No roots, no `setDrop`, no withdraw Push airdrop: `claimFor(coin, ids)`, callable by anyone, sends each id's share to the NFT's current owner and skips claimed, unminted and burned ids (the keeper pushes in batches of 15; ~130-150k gas per NFT on Sepolia). |
| HolderDrip | one per coin, deployed by the back end before launch and passed as `flywheel` | pulls the flywheel slice from the hook and accrues it per NFT; holders claim in JIG for the tokens they own. Anyone may pull |
| SweepAndBurn | one per coin, same | keeper-only: sells JIG for ETH on the JIG/ETH pool with a keeper-supplied minimum out, pays an approved marketplace order, checks the NFT arrived, sends it to the dead address. The creator approves marketplaces and sets the price cap |
| BuybackAndBurn | one per collection, same | keeper-only, at random times the back end picks: buys the collection's coin (resolved from the factory) on its own pool with the whole balance (keeper-supplied minimum out), burns it. `setKeeper` by `hook.platform()` (the Safe), 17 Oct |
| RewardsForwarder | one per collection, passed as `flywheel` (17 Oct) | "fees to coin holders": `pull()` claims the slice from the hook and calls `coin.notifyReward`, which restarts the 24-hour stream with it plus what is left. Anyone may pull; no key, no snapshot. Replaces SnapshotForwarder + HolderPayouts |
| HolderPayouts, SnapshotForwarder | retired 17 Oct (`0xe31f…4D68` no longer used) | snapshot rounds with merkle roots declared by a hot key; replaced by the on-chain stream above |
| LPDeepening | `0x486F0dA82702b1C65343E412A80E17e43D75Cc33` (18 Oct, round 9; was `0x917f…6191`, `0x8B65…7F7e`, `0x60D4…60bc`, `0x9F1d…bc45`, `0x8642…1da8`) | shared, keeper-only; `setKeeper` by the platform (the Safe), 17 Oct. The deepening slice of every coin fee: sells half for ETH on the JIG/ETH pool (keeper-supplied minimum out) and adds both as full-range liquidity to a position it holds forever. LP fees it earns split half team, half pot like the JIG pool's. Bound to the hook once via `setDeepening` |

Fee split, in basis points of the fee: pot 300 and deepening 200 fixed; platform 2500 / 3000 / 3500 / 4000 by fee band (1% / 2-3% / 4-6% / 7-10%); the rest (7000 / 6500 / 6000 / 5500) is the creator+flywheel block, which the creator divides with `setCreatorShare` (default flywheel 2000, creator the remainder). A creator's or flywheel's balance untouched for 7 days can be folded back through the same split by anyone (`recycle`). Anti-snipe on creator coins: 60% decaying to the chosen fee over 10 seconds.

Design notes an auditor should know:

- **Fees are held as ERC-6909 claims inside the PoolManager**, not as ERC-20 in the hook. `take` would fail on a fresh chain because the swapper's input is settled after `afterSwap` runs; claims need no physical balance. `claim()` burns the claims and takes real JIG through an `unlock` callback.
- **The coin-side conversion is a nested swap on the same pool inside `afterSwap`.** It is not charged again because v4's `Hooks.afterSwap` skips callbacks for a hook's own swaps (noSelfCall); the `_converting` flag is belt and braces. This is the Zora pattern.
- The hook has one-shot `setFactory` and `setDeepening` bindings because the hook, factory and deepening module reference each other. Verify both bindings on chain before trusting a deploy.
- **Holder drip pays in JIG, not ETH.** The hook holds JIG; converting to ETH per claim would cost every holder a swap. The economics doc said ETH; this is the deviation.
- **SweepAndBurn trusts the platform keeper to pick the listing.** Which listing is cheapest is not knowable on chain. The contract limits the keeper to real NFTs of the right collection at or under the max price, so the worst case is overpaying for a real burn, never taking funds.
- **The early max-wallet from the spec is not built.** The decaying 60% fee is the anti-snipe measure.
- **hook.setFactory is one-shot**, because the hook and factory reference each other.

Tests: `forge test --match-contract CreatorCoinFork --fork-url sepolia` runs 9 end-to-end tests; `FlywheelsFork` runs the drip, airdrop, sweep, buyback and deepening end to end; `RegressionsFork` pins the review fixes; `CreatorCoinRewards` covers the stream, exclusions, notifier and pause. 136 tests in all (`forge test --fork-url sepolia`). On a Sepolia fork they cover: launch and lock, supply split, the snipe decay, a buy with coin-side fee converted to JIG and split seven ways, a sell with the fee in JIG, referral defaults, the 5% band, pull claims, lower-only fee changes.

Deploy: `script/DeployCoins.s.sol` (hook + factory, CREATE2-mined; `SALT_SEED` to redeploy with identical args), `script/DeployRest.s.sol` (AirdropClaim, owned by the deployer only until DeployCoins binds it and renounces) and `script/DeployDeepening.s.sol` (LPDeepening + binding; `KEEPER`), all driven by env vars.

## Flywheel menu

| Option | Module | Status |
|---|---|---|
| Fees to the team wallet | none (flywheel = creator) | built |
| Floor sweep and burn | SweepAndBurn | built |
| Fees to NFT holders | HolderDrip | built |
| Fees to coin holders | RewardsForwarder (the coin streams it on chain, 17 Oct) | built |
| Split NFT holders and coin holders | was SnapshotForwarder + HolderPayouts | retired 17 Oct with HolderPayouts; no module yet |
| Buyback and burn | BuybackAndBurn | built |
| Floor sweep and raffle | needs verifiable randomness (Chainlink VRF) on the target chain | not built |

## Still to build

Sweep and raffle only. It needs verifiable randomness (Chainlink VRF) on the target chain; Robinhood Chain's VRF availability is unconfirmed, so it waits for the chain decision. Everything else in the signed spec is on Sepolia. Next: the throwaway-repo swarm audit round per the plan of record.
