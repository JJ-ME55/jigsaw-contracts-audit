# Audit Report: JIG and the creator-coin stack (contracts/src, 15 contracts)

**Date:** 2026-10-15
**Auditor:** Claude (checklist-driven, Solodit-anchored)
**Checklist version:** 370 items across 13 categories
**Commit audited:** `f887d10` (third-pass fixes) on `main`; `lib/` v4-periphery at `5fa38cd` (15 Oct 2026), OpenZeppelin 5.1.0, Foundry 1.8.3, solc 0.8.26 via-ir cancun

---

## Scope

Foundry project `C:\Users\johnk\hackathon-entry\contracts`. Every file under `src/` was read line by line: `JIG.sol`, `JIGLaunch.sol`, `JIGLaunchHook.sol`, `PotVault.sol`, `Vesting.sol`, `CreatorFeeHook.sol`, `CoinFactory.sol`, `CreatorCoin.sol`, `HolderDrip.sol`, `SweepAndBurn.sol`, `BuybackAndBurn.sol`, `LPDeepening.sol`, `AirdropClaim.sol`, `HolderPayouts.sol`, `SnapshotForwarder.sol` (2,156 lines). The external code they call was read where the behaviour matters rather than assumed: Uniswap v4 core `PoolManager.swap/mint/burn/unlock` and `Hooks.afterSwap` (the hook-delta accounting and the `msg.sender == hook` short-circuit), `Pool.swap` zero-liquidity stepping, `ERC6909Claims`, v4 periphery `PositionManager._decrease/_modifyLiquidity` (fee collection with zero liquidity) and `LiquidityAmounts`, Permit2 `AllowanceTransfer`, OpenZeppelin 5.1 (`Ownable2Step`, `ReentrancyGuard`, `MerkleProof`, `SafeERC20`, `ERC20Permit`, `ERC20Burnable`). The swarm-written `LoomCollection.sol` (loom/jobs/launch-1527) was read for the only two things our code relies on, `owner()`/`creator()` and `totalSupply()` semantics, plus `LoomFactory.sol` and `backend/lib/launch.mjs` to learn who those roles actually are. Design intent came from `README.md` (three in-house adversarial passes), `DRIFT.md` and `ECONOMICS-DRAFT.md`.

In one sentence: a fixed-supply platform token (JIG) fair-launched into a locked single-sided Uniswap v4 pool with a 5-minute sniper-tax hook, plus a factory that launches one creator coin per NFT collection into a coin/JIG pool on one shared v4 hook that takes a 1-10% fee on every swap, converts it to JIG inside the swap, and splits it among creator, flywheel module, platform, pot and LP-deepening as pull-only ERC-6909-backed claims.

**In scope:** everything above, the deploy scripts as evidence of role assignment, chain assumptions for Sepolia now and Robinhood Chain (Arbitrum Orbit, id 4663) later. **Out of scope:** the Loom NFT contracts themselves (only the two interface facts were verified), the back end's keeper and snapshot logic (treated as open questions), the front end.

**Roles:** platform wallet (fee recipient in the hook; launch-fee setter; keeper of BuybackAndBurn, LPDeepening and SweepAndBurn; owner of AirdropClaim and HolderPayouts; and, as this review found, `owner()` of every LoomCollection); pot owner (PotVault, Ownable2Step); hook owner (one-shot `setFactory`, `setDeepening`); JIGLaunch launcher; JIGLaunchHook owner (allowlist root before init); per-coin creator (slider, lower-only fee); per-coin SweepAndBurn owner (markets, cap). No upgradeability anywhere.

**External/public state-changing surface reviewed (access in brackets):** CreatorFeeHook `setDeepening`[owner] `setFactory`[owner] `register`[factory] `setCreatorShare`[creator] `lowerFee`[creator] `recycle`[anyone] `claim`[anyone, pays self] `claimFor`[anyone, pays target] `unlockCallback`[PoolManager] `beforeInitialize`/`afterSwap`[PoolManager]; CoinFactory `setLaunchFee`[platform] `launch`[collection owner()/creator(), payable] `unlockCallback`[PoolManager]; JIGLaunch `setJig`[launcher] `launch`[launcher] `collectFees`[anyone]; JIGLaunchHook `setAllowlist`[owner] `beforeInitialize`/`beforeSwap`[PoolManager]; PotVault `enablePayouts`/`declare`[owner] `claim`[anyone] `notifyDeposit`[anyone, event only]; Vesting `create`/`release`[anyone]; HolderDrip `pull`/`claim`/`markBurned`[anyone]; SweepAndBurn `pull`[anyone] `setMaxPrice`/`setMarket`[owner] `sweep`[sweeper] `unlockCallback`[PoolManager]; BuybackAndBurn `run`[keeper] `unlockCallback`[PoolManager]; LPDeepening `run`[keeper] `collectFees`[anyone] `unlockCallback`[PoolManager]; AirdropClaim `setFactory`/`setDrop`[owner] `notify`[factory] `sweepUnset`/`claim`/`sweep`[anyone]; HolderPayouts `fund`[anyone] `declare`[owner] `claim`/`settle`[anyone]; SnapshotForwarder `pull`[anyone]; JIG/CreatorCoin: OZ ERC20 + permit + burn/burnFrom.

**Reference files loaded and why:** all thirteen. `attacker-s-mindset.md`, `basics.md`, `heuristics.md` (always); `defi.md` (AMM, fee splitting, reward accrual, keeper swaps); `token.md` (own ERC-20s, ERC-721 handling in drip/sweep); `integrations.md` (Uniswap v4 is the core dependency); `external-call.md` (unlock callbacks, low-level `call` to platform/airdrop/marketplace, staticcalls to collections); `hash-merkle-tree.md` (four merkle claim paths); `centralization-risk.md` and `timelock.md` (owner-authored trees, keeper powers, one-shot bindings); `multi-chain-cross-chain.md` (Sepolia now, an Orbit L2 later, timestamps and tx.origin); `signature.md` (ERC-2612 permit on both tokens; no custom signatures, loaded so the dismissal is explicit); `low-level.md` (no assembly, loaded for the "call to address without code" item).

**Tooling:** `forge test --fork-url sepolia`: 53/53 existing tests pass at block ~11,922,321. New PoCs in `test/Audit_Findings.t.sol` (6 tests, all pass; results quoted inline). Nothing under `src/` was modified.

**Method note:** the three in-house passes in README.md were taken as the floor. Each of their fixes was re-derived from the code and found to hold (see Acknowledged non-issues). The second, adversarial pass below concentrates on what those passes did not look at: who the roles really are once the Loom contracts are plugged in, keeper economics measured rather than asserted, first-trade and parameter-edge states of a fresh pool, value flow across hook claims / claimFor / recycle / modules, and L2 assumptions.

## Checklist coverage

- Categories walked: Attacker's Mindset (25), Basics (135), Centralization Risk (7), DeFi (63), External Call (14), Hash/Merkle (5), Heuristics (17), Integrations (56), Low Level (5), Multi-chain (13), Signature (5), Timelock (1), Token (24)
- Items reviewed: **370** (every item in every loaded file, in order, tables below)
- Items applicable: **154** (applicable and OK: 110; applicable with an issue or note: 44, mapped to the 8 findings and 21 informational items below)
- Items not applicable: **216** (each with a one-line reason)

Severity rubric used: Critical = direct loss of funds, no preconditions; High = loss of funds with realistic preconditions; Medium = griefing, DoS, value leak or a trust assumption the owners have not consciously made; Low = bounded value leak or unlikely edge case; Informational = no security impact.

### Walk: Attacker's Mindset (25)

| Item | Verdict | Note |
|---|---|---|
| SOL-AM-DOSA-1 | OK | Every payout is pull: hook `claim/claimFor`, PotVault/AirdropClaim/HolderPayouts `claim`, HolderDrip `claim`, Vesting `release`. |
| SOL-AM-DOSA-2 | Issue (I-1) | No minimum swap: a swap whose unspecified amount is under 100 wei pays no fee (`fee == 0` early return); fees under 4 wei skip pot/platform/creator and go wholly to the flywheel. Uneconomic to abuse. PoC `test_I_micro_swap_pays_no_fee`. |
| SOL-AM-DOSA-3 | N/A | Only JIG, CreatorCoin (plain OZ ERC-20s, no blacklist) and native ETH are handled. |
| SOL-AM-DOSA-4 | Issue (L-6) | `PotVault.available()` loops over every distribution ever declared; `declare` and `available` grow unboundedly. Owner-created only. |
| SOL-AM-DOSA-5 | N/A | All tokens are 18 decimals and ours. |
| SOL-AM-DOSA-6 | OK | `posm.initializePool` swallows reverts, checked via `type(int24).max`; collection `owner()/creator()` are guarded staticcalls with `ret.length == 32`; `ownerOf` in `_heldHere` is try/catch. The `notify` call is unchecked, see L-5. |
| SOL-AM-DA-1 | OK | Balance-based accounting is deliberate (HolderDrip `undistributed`, modules spend `balanceOf`) and no share price is derived from it, so donations only enrich recipients. |
| SOL-AM-FrA-1 | Issue (M-1) | `launch` is get-or-create for a collection's coin and is one-shot per collection; two parties qualify (owner() and creator()) and the first to call wins the creator role forever. |
| SOL-AM-FrA-2 | Issue (L-5) | `AirdropClaim.setDrop` (owner) versus `sweepUnset` (anyone) after 7 days: a late root loses the whole 5% to the pot. |
| SOL-AM-FrA-3 | OK | Dust cannot block anything: `register` is factory-only, `recycle` is amount-agnostic, claims are per leaf. |
| SOL-AM-FrA-4 | N/A | No commit-reveal; the allowlist is a merkle proof bound to `tx.origin`, so a mempool-copied proof is useless to another origin. |
| SOL-AM-GA-1 | Issue (L-2) | `recycle` lets anyone fold a module's slice after 7 quiet days; BuybackAndBurn has no permissionless `pull`, only `claimFor` defuses it. |
| SOL-AM-GA-2 | OK | No fixed-gas calls. The `notify` call forwards all gas but the callee is our AirdropClaim. |
| SOL-AM-MA-1 | OK | Timing: 10 s snipe decay, 5 min JIG window, 7 d recycle/airdrop sweep. Seconds-level manipulation is immaterial on L1 (fixed slots); on the L2 the sequencer is trusted anyway (noted in README). |
| SOL-AM-MA-2 | N/A | No on-chain randomness (raffle flywheel not built). |
| SOL-AM-MA-3 | Issue (L-3) | Keeper runs are ordering-sensitive with only a keeper-supplied minimum out; measured bound in L-3. |
| SOL-AM-PMA-1 | N/A | No price is derived from balance ratios. |
| SOL-AM-PMA-2 | Issue (L-4) | `LPDeepening.run` sizes its liquidity add from `getSlot0` spot after its own sale; the hook's nested sale is also at spot with no bound (acknowledged in README). |
| SOL-AM-ReentrancyAttack-1 | OK | `claimable`/`totalClaimable` are zeroed before `unlock`, so `heldJig()` and `totalClaimable()` agree during the callback (invariant test `test_invariant_held_claims_equal_total_claimable`). |
| SOL-AM-ReentrancyAttack-2 | OK | CEI plus `nonReentrant` on every path that moves value; `afterSwap` makes no call to untrusted code; a re-entered `unlock` reverts `AlreadyUnlocked` (PoolManager.sol:105). |
| SOL-AM-ReplayAttack-1 | OK | `hasClaimed` per (id/coin/round, account); `Vesting.released`; `claimEpoch` invalidates stale recycle entries. |
| SOL-AM-ReplayAttack-2 | Issue (I-13) | Merkle leaves are `(account, amount)` with no chain id, contract or round; only matters if an owner reuses a root across deployments. |
| SOL-AM-RP-1 | Issue (M-2) | No admin withdraw exists, but owner-authored merkle roots (PotVault, AirdropClaim, HolderPayouts) can name the owner; accepted by Jj, but all three roots plus the keeper roles sit behind one hot key today. |
| SOL-AM-SandwichAttack-1 | Issue (L-3, L-4) | User swaps carry their own router slippage. Keeper runs carry a keeper-chosen minimum only; the deepening add has none; the nested conversion has none (acknowledged). |
| SOL-AM-SybilAttack-1 | OK | Nothing counts users: drip is per token, payouts per leaf. Snapshot composition is off-chain (open question 3). |

### Walk: Basics (135)

| Item | Verdict | Note |
|---|---|---|
| SOL-Basics-AC-1 | Issue (M-1) | Actors listed in Scope. The one the in-house passes did not resolve: `LoomCollection.owner()` is the platform's operating wallet (LoomFactory.sol:54 passes `msg.sender`; launch.mjs:45 launches from the operating account), not the artist. |
| SOL-Basics-AC-2 | OK | Every state-changing function has the intended guard; the permissionless ones (`claimFor`, `recycle`, `pull`, `markBurned`, `collectFees`, `sweep*`, `settle`) can only move value to its ledgered owner or to the pot. |
| SOL-Basics-AC-3 | OK | Factory, deepening, keeper, sweeper, marketplaces are explicit allowlists. |
| SOL-Basics-AC-4 | Issue (M-2) | Vault owners are Ownable2Step; hook `owner`, `platform`, `pot`, module `keeper`/`sweeper`/`owner`, factory `platform` are immutable with no rotation path. |
| SOL-Basics-AC-5 | OK | Nothing depends on the pending-owner state. |
| SOL-Basics-AC-6 | OK | Inherited surface: `renounceOwnership` on PotVault/AirdropClaim/HolderPayouts would brick `declare`/`setDrop` (I-9); `burnFrom` on the tokens is intended. |
| SOL-Basics-AC-7 | OK | `tx.origin` in JIGLaunchHook is deliberate and documented (relay-for-strangers accepted). |
| SOL-Basics-AL-1 | OK | HolderDrip binary search handles `lo == n` (token newer than every checkpoint) and index 0. |
| SOL-Basics-AL-4 | N/A | No array removals. |
| SOL-Basics-AL-5 | OK | Array indexes (distribution id, round, schedule id, launch index) are append-only. |
| SOL-Basics-AL-6 | OK | `_split` and `recycle` compute the last share as the remainder, so parts sum exactly. |
| SOL-Basics-AL-7 | OK | Duplicate token ids in `HolderDrip.claim` pay once (second pass reads `owed == 0`). |
| SOL-Basics-AL-8 | OK | As AL-1. |
| SOL-Basics-AL-9 | Issue (L-6) | `PotVault.available` unbounded. |
| SOL-Basics-AL-10 | OK | No external calls inside loops. |
| SOL-Basics-AL-11 | N/A | `msg.value` is never read in a loop. |
| SOL-Basics-AL-12 | OK | Remainders go to the flywheel (`_split`) or pot/flywheel (`recycle`); drip dust stays in the module (I-1). |
| SOL-Basics-AL-13 | N/A | No break/continue. |
| SOL-Basics-BR-1 | OK | CreatorCoin is CREATE-deployed, but HolderDrip binds to the collection and the forwarder/buyback resolve the coin from the factory, so a reorg cannot bind a module to the wrong coin (third-pass fix verified). |
| SOL-Basics-Event-1 | Issue (I-5) | `JIGLaunch.setJig` emits nothing; `FeesCollected` logs the whole held balance, not the amount collected. |
| SOL-Basics-Function-1 | OK | Fee steps, slider bound, range side, creator cap, flywheel blacklist, root/total/expiry checks all present. Blacklist is partial (I-7). |
| SOL-Basics-Function-2 | OK | Swap outputs checked against min-out before transfer; `got == 0` rejected. |
| SOL-Basics-Function-3 | Issue (M-1, L-5) | `launch` race between owner() and creator(); `setDrop` versus `sweepUnset`. |
| SOL-Basics-Function-4 | Issue (I-4) | Comment drift: JIG window is 5 min in code, "10 minutes" in README/CLAUDE tables; "sniper tax fills the pot" but half goes to the team; `_converting` comment describes a guard v4 already provides; Vesting docstring says it is used by the factory. |
| SOL-Basics-Function-5 | OK | Zero and max inputs: zero amounts short-circuit, `creatorShareBps` sentinel, `tickLower >= tickUpper` rejected, `total > uint128` rejected. |
| SOL-Basics-Function-6 | OK | The only arbitrary-data call is `SweepAndBurn.sweep` to an owner-approved market, guarded by JIG-balance and NFT-arrival checks (first-pass fix verified; Seaport self-offer impossible, see non-issues). |
| SOL-Basics-Function-7 | OK | Visibilities appropriate. |
| SOL-Basics-Function-8 | OK | No EOA checks; the tx.origin allowlist knowingly excludes smart wallets. |
| SOL-Basics-Function-9 | OK | See AC-2. |
| SOL-Basics-Inheritance-1 | OK | As AC-6. |
| SOL-Basics-Inheritance-2 | OK | `IHooks` fully implemented (unused hooks revert); `IUnlockCallback` implemented by all four callers. |
| SOL-Basics-Inheritance-3 | OK | `onERC721Received` present where a PositionManager NFT or swept NFT can arrive. |
| SOL-Basics-Inheritance-4 | OK | Linearisation of ERC20/ERC20Permit/ERC20Burnable is the OZ-documented order. |
| SOL-Basics-Initialization-1 | OK | `deepening` defaults to `pot`; `launchedAt` set in `register`; `tokenId == 0` sentinel valid because PositionManager ids start at 1. |
| SOL-Basics-Initialization-2 | N/A | No Initializable. |
| SOL-Basics-Initialization-3 | OK | The post-deploy one-shots (`setFactory`, `setDeepening`, `setJig`, `setAllowlist`, AirdropClaim `setFactory`) are owner-gated, so not front-runnable. |
| SOL-Basics-Map-1 | N/A | No struct deletes. |
| SOL-Basics-Math-1 | OK | Verified by hand: exact-input fee `abs*f/1e6`, exact-output `abs*f/(1e6-f)` gives the same effective rate; decay `600000 - (600000-f)*t/10`; split sums; recycle redistributes exactly `amount`. |
| SOL-Basics-Math-2 | OK | Decay is per second over a 10 s window (10 steps), intended. |
| SOL-Basics-Math-3 | N/A | Time literals are only used against `uint64`/`uint256`. |
| SOL-Basics-Math-4 | OK | Multiply before divide throughout. |
| SOL-Basics-Math-5 | Issue (I-1) | Fee rounds down (favours swapper by <1 wei); shares round down with the flywheel taking the dust; drip accumulator dust stays in the module. |
| SOL-Basics-Math-6 | OK | Divisors: `SNIPE_WINDOW`, `PIPS - feePips` (>= 900,000), `live` guarded by `live == 0` return, `s.duration != 0`. |
| SOL-Basics-Math-7 | OK | `uint128 e.amount` and `uint96 supply` bounded by 1e27 supply and collection size; `uint160 accBefore` bounded by 1e45 < 2^160. |
| SOL-Basics-Math-8 | OK | Negative deltas are negated before the `uint128` cast in every callback. |
| SOL-Basics-Math-9 | N/A | No `unchecked` in src. |
| SOL-Basics-Math-10 | OK | `elapsed >= SNIPE_WINDOW`, `expiry <= block.timestamp` rejections, `tickUpper > startTick`, `feePips >= c.feePips` all on the intended side. |
| SOL-Basics-Math-11 | N/A | No assembly. |
| SOL-Basics-Math-12 | OK | Max fee 60% exact-output = 1.5x input, fits `int128` for any supply below 2^126. |
| SOL-Basics-Payment-1 | OK | ETH goes only to `platform` and `pot` (ours) and to merkle leaves (their own problem); a reverting platform wallet would block `collectFees` and `launch` (I-9). |
| SOL-Basics-Payment-2 | OK | `msg.value == launchFeeWei` exact. |
| SOL-Basics-Payment-3 | OK | Force-fed ETH is simply used (LPDeepening, SweepAndBurn) or forwarded (JIGLaunch). |
| SOL-Basics-Payment-4 | Issue (I-1) | No minimums; see DOSA-2. |
| SOL-Basics-Payment-5 | OK | Pull everywhere. |
| SOL-Basics-Payment-6 | OK | `call` used for ETH. |
| SOL-Basics-Payment-7 | Issue (L-1) | ETH cannot be locked (forwarded in full), but unspent dev-buy JIG is locked in CoinFactory. |
| SOL-Basics-PU-1 .. PU-10 | N/A (10) | No proxies or upgradeability anywhere. |
| SOL-Basics-Type-1 | OK | Casts: `uint24(SNIPE_FEE - ...)` bounded by 600,000; `uint128(fee)`, `uint64(block.timestamp)`, `uint96(supply)`, `uint160(acc)` bounded as above. |
| SOL-Basics-Type-2 | OK | `7 days`/`10 seconds`/`5 minutes` assigned to `uint64` constants. |
| SOL-Basics-VI-EAI-1 | N/A | No `selfdestruct`. |
| SOL-Basics-VI-OVI-1 .. OVI-18 | N/A (18) | OpenZeppelin 5.1.0; none of ERC2771Context, Governor*, ECDSA.recover on bytes, ERC777, MerkleProof multiproof, TransparentUpgradeableProxy, ERC721Consecutive, ERC165Checker, LibArbitrumL2, SignatureChecker, Initializable, ERC1155, UUPS, TimelockController is used. |
| SOL-Basics-VI-SVI-4 | OK | `abi.encodePacked` only packs two `uint8` action ids; all hashed leaves use `abi.encode`. |
| SOL-Basics-VI-SVI-1..3, 5..48 | N/A (47) | solc 0.8.26 is outside every affected range. |

### Walk: Centralization Risk (7)

| Item | Verdict | Note |
|---|---|---|
| SOL-CR-1 | OK | No special states in our contracts; a paused LoomCollection (platform-owned) would make `SweepAndBurn.sweep`'s `transferFrom` revert but never trap funds (noted under M-2). |
| SOL-CR-2 | N/A | No pause mechanism in scope. |
| SOL-CR-3 | Issue (M-2) | No withdraw, but three owner-authored merkle roots and keeper min-outs are value-routing powers behind one key. |
| SOL-CR-4 | Issue (M-2) | `setLaunchFee`, `setDrop`, `declare`, `setMaxPrice`, `setMarket` take effect immediately (no-delay decision is Jj's, 15 Oct). |
| SOL-CR-5 | Issue (I-5) | `JIGLaunch.setJig` has no event. |
| SOL-CR-6 | Issue (M-2) | Immutable `platform`/`keeper`/`sweeper`/hook `owner`; the vaults are two-step. |
| SOL-CR-7 | Issue (I-6) | `setLaunchFee` and `setMaxPrice` are unbounded. |

### Walk: DeFi (63)

| Item | Verdict | Note |
|---|---|---|
| SOL-Defi-AS-1 | Issue (L-4) | The nested coin-to-JIG sale and the deepening add use extreme price limits; the sale is acknowledged, the add is not. |
| SOL-Defi-AS-2 | OK | User swaps go through routers with deadlines; keeper runs have none, acceptable for an operator (I-14). |
| SOL-Defi-AS-3 | N/A | Nothing is lent. |
| SOL-Defi-AS-4 | N/A | Uniswap v4 is a dependency, not a fork. |
| SOL-Defi-AS-5 | OK | v4's own rounding; ours covered under Math-5. |
| SOL-Defi-AS-6 | OK | Only `sweep` (approved market, see Function-6). |
| SOL-Defi-AS-7 | Issue (L-3) | Keeper-chosen minimum only. |
| SOL-Defi-AS-8 | N/A | Own 18-decimal tokens only. |
| SOL-Defi-AS-9 | N/A | No fee-on-transfer (Vesting rejects it explicitly). |
| SOL-Defi-AS-10 | N/A | No rebasing. |
| SOL-Defi-AS-11 | OK | Quoted off-chain by the keeper (README). |
| SOL-Defi-AS-12 | OK | All four `unlockCallback`s and both hooks check `msg.sender == poolManager`; `beforeInitialize` of the JIG hook also checks `sender == launch`. |
| SOL-Defi-AS-13 | OK | Off-chain. |
| SOL-Defi-AS-14 | OK | `coinBurned`/`ethGot` measured on balance after `take`, then compared. |
| SOL-Defi-FlashLoan-1 | N/A | No deposits. |
| SOL-Defi-FlashLoan-2 | N/A | No ERC-4626. |
| SOL-Defi-General-1 | N/A | 18 decimals. |
| SOL-Defi-General-2 | N/A | No deposited assets earn elsewhere. |
| SOL-Defi-General-3 | OK | Direct transfers are absorbed by design (balance accounting, second-pass fix verified). |
| SOL-Defi-General-4 | Issue (L-1) | First-trade state: the dev buy can consume a narrow seeded range entirely; price can park at the tick limit via a zero-liquidity sell (recovers on the next buy, verified). |
| SOL-Defi-General-5 | N/A | No pegs. |
| SOL-Defi-General-6 | N/A | Approvals are exact. |
| SOL-Defi-General-7 | OK | 1-wei states: fee 0, `pendingCoin` retry, `live == 0` return. |
| SOL-Defi-General-8 | N/A | No deposit/withdraw cycle. |
| SOL-Defi-General-9 | N/A | Only our tokens and ETH. |
| SOL-Defi-Lending-1 .. 12 | N/A (12) | No lending. |
| SOL-Defi-LSD-1 .. 9 | N/A (9) | No liquid staking. |
| SOL-Defi-Oracle-1 .. 12, 14 | N/A (13) | No oracle consumed. |
| SOL-Defi-Oracle-13 | Issue (L-4) | `getSlot0` spot drives `LPDeepening`'s liquidity amounts. |
| SOL-Defi-Staking-1 | N/A | No stake locks. |
| SOL-Defi-Staking-2 | Issue (L-2) | Distribution timing is in other hands: `recycle` after 7 quiet days, owner-timed rounds, keeper-timed runs. |
| SOL-Defi-Staking-3 | OK | HolderDrip updates the accumulator on every pull and reads it live on claim; checkpoints make late mints earn nothing retroactively (first/second-pass fix verified). |

### Walk: External Call (14)

| Item | Verdict | Note |
|---|---|---|
| SOL-EC-1 | OK | Re-entering a different function during an unlock: `claim/claimFor` revert (`AlreadyUnlocked`), `recycle` is harmless, modules are guarded. |
| SOL-EC-2 | N/A | No multicall with value. |
| SOL-EC-3 | N/A | No delegatecall. |
| SOL-EC-4 | OK | Each external call is necessary; `notify` is optional by design (but see L-5). |
| SOL-EC-5 | OK | Marketplaces allowlisted by the module owner; everything else is a fixed, known address. |
| SOL-EC-6 | OK | No fixed gas. |
| SOL-EC-7 | OK | Only `notify` could burn gas and it is our contract. |
| SOL-EC-8 | N/A | No large payloads to unknown addresses. |
| SOL-EC-9 | OK | Staticcall return lengths checked. |
| SOL-EC-10 | N/A | No delegatecall. |
| SOL-EC-11 | N/A | No delegatecall. |
| SOL-EC-12 | Issue (L-5) | `p.collection.code.length` is checked, but `airdropRecipient.call("notify")` succeeds silently against a misbound or non-contract recipient. |
| SOL-EC-13 | OK | CEI: `claimable = 0` before `unlock`; `launched = true` before posm; drip state before transfer; `coinOf` before the coin is created. |
| SOL-EC-14 | OK | `sender == factory` in `afterSwap` can only be produced by `CoinFactory.unlockCallback`, which only `launch` reaches; `msgSender()` in PositionManager is the module itself. |

### Walk: Hash / Merkle Tree (5)

| Item | Verdict | Note |
|---|---|---|
| SOL-HMT-1 | OK | Roots are set by owners; the only race is L-5. |
| SOL-HMT-2 | Issue (I-11) | `claim` does not require `msg.sender == account`; funds still go to `account`, so this only lets a third party time someone's claim. |
| SOL-HMT-3 | OK | Zero roots rejected; a zero proof against a double-hashed leaf cannot verify. |
| SOL-HMT-4 | OK | OZ sorted-pair verification with double-hashed leaves; `hasClaimed` per account blocks a duplicated leaf from paying twice. |
| SOL-HMT-5 | OK | Leaves hash `(account, amount)`. |

### Walk: Heuristics (17)

| Item | Verdict | Note |
|---|---|---|
| SOL-Heuristics-1 | Issue (I-8) | The sell-JIG-for-ETH `unlockCallback` is copied in three modules; the 50/50 payout is copied in JIGLaunch and LPDeepening. |
| SOL-Heuristics-2 | N/A | No nested-struct deletes. |
| SOL-Heuristics-3 | OK | `flywheel == creator` and `flywheel == address(0)` paths handled in `_split` and `recycle`. |
| SOL-Heuristics-4 | OK | `nonReentrant` is the only modifier used. |
| SOL-Heuristics-5 | OK | The one try/catch wraps a view. |
| SOL-Heuristics-6 | OK | ERC-6909 claims, ERC-2612 via OZ, ERC-721 receiver, EIP-1153 reliance via v4 (open question 1). |
| SOL-Heuristics-7 | OK | `supply >= tokenId` is the right inclusive bound for ids from 1; `lo == n` handled. |
| SOL-Heuristics-8 | OK | `specifiedIs0 = zeroForOne == (amountSpecified < 0)` verified for all four swap kinds. |
| SOL-Heuristics-9 | Issue (M-1, I-7) | Protocol contracts as actors: the platform as a coin's creator; flywheel may be jig/coin/collection/AirdropClaim/HolderPayouts/JIGLaunch. |
| SOL-Heuristics-10 | Issue (I-1) | Dust routing can be repeated but costs more gas than it moves. |
| SOL-Heuristics-11 | OK | `registered`, `launched`, `initialized`, `tokenId == 0` are all safe sentinels. |
| SOL-Heuristics-12 | OK | Repeated `recycle` reverts `NotStale`; `markBurned`/`settle` idempotent; `claim` zeroes. |
| SOL-Heuristics-13 | OK | Storage pointers used throughout. |
| SOL-Heuristics-14 | OK | Native ETH only, `currency0 == address(0)` assumed and documented. |
| SOL-Heuristics-15 | N/A | No sensitive data. |
| SOL-Heuristics-16 | Issue (I-10) | No way to unset a drop, change a flywheel, or sweep an idle HolderPayouts balance; by design but asymmetric. |
| SOL-Heuristics-17 | Issue (I-1) | Splitting a trade changes only rounding, except across the 10 s decay where later seconds are cheaper by design. |

### Walk: Integrations (56)

| Item | Verdict | Note |
|---|---|---|
| SOL-Integrations-AC-1 .. 9 | N/A (9) | No Aave/Compound. |
| SOL-Integrations-Balancer-1 .. 4 | N/A (4) | No Balancer. |
| SOL-Integrations-Chainlink-CCIP-1 .. 8 | N/A (8) | No CCIP. |
| SOL-Integrations-Chainlink-VRF-1 .. 4 | N/A (4) | No VRF (raffle flywheel not built). |
| SOL-Integrations-GS-1 .. 2 | N/A (2) | No Safe modules. |
| SOL-Integrations-LayerZero-1 .. 7 | N/A (7) | No LayerZero. |
| SOL-Integrations-LSD-cbETH-1 .. 2, rETH-1 .. 5, sfrxETH-1 .. 2, stETH-1 .. 3 | N/A (12) | No LSDs. |
| SOL-Integrations-Uniswap-1 | OK | Slippage computed off-chain by the keeper. |
| SOL-Integrations-Uniswap-2 | Issue (L-1) | No refund of unspent dev-buy input. |
| SOL-Integrations-Uniswap-3 | OK | Ordering decided at runtime by address comparison; both orientations handled in hook, factory and buyback; JIG pool fixed as ETH/JIG. |
| SOL-Integrations-Uniswap-4 | OK | Pool keys are built in-contract; the hook only serves registered ids; the JIG hook only its one pool. |
| SOL-Integrations-Uniswap-5 | N/A | No reserve reads. |
| SOL-Integrations-Uniswap-6 | OK | `PoolManager.swap` is called directly inside our own `unlock` callbacks by design; callers enforce min-out on the final balance. |
| SOL-Integrations-Uniswap-7 | OK | No `unchecked`; libraries used unmodified. |
| SOL-Integrations-Uniswap-8 | OK | Min-out is the last check before burn/use. |
| SOL-Integrations-Uniswap-9 | Issue (L-4) | `getSlot0` in `LPDeepening.run`. |
| SOL-Integrations-Uniswap-10 | N/A | v4 keys are fixed by design (fee 0 / dynamic flag). |

### Walk: Low Level (5)

| Item | Verdict | Note |
|---|---|---|
| SOL-LL-1 | N/A | No assembly. |
| SOL-LL-2 | N/A | No custom dispatch. |
| SOL-LL-3 | Issue (L-5) | `airdropRecipient.call` is not preceded by a code check (collection is). |
| SOL-LL-4 | N/A | No precompile calls. |
| SOL-LL-5 | N/A | No assembly division. |

### Walk: Multi-chain / Cross-chain (13)

| Item | Verdict | Note |
|---|---|---|
| SOL-McCc-1 | OK | Timestamps are only compared within one chain. |
| SOL-McCc-2 | Issue (open question 1) | Robinhood Chain: v4 PoolManager/PositionManager/Permit2 are not known to the scripts; the hook addresses must be re-mined per chain. |
| SOL-McCc-3 | Issue (open question 1) | v4 core needs EIP-1153 transient storage (cancun). Arbitrum Orbit chains need ArbOS 30+ (Cancun) / 40 (Prague); confirm for id 4663. |
| SOL-McCc-4 | OK | `tx.origin`/`msg.sender` semantics are unchanged on Arbitrum; L1-to-L2 retryables alias the origin and are irrelevant to the allowlist. |
| SOL-McCc-5 | Issue (I-1) | Cheap L2 gas makes dust trades cheaper but each still moves under 100 wei of value. |
| SOL-McCc-6 | N/A | Own tokens, same decimals everywhere. |
| SOL-McCc-7 | N/A | No upgradeability. |
| SOL-McCc-8 | N/A | No cross-chain messaging. |
| SOL-McCc-9 | N/A | No cross-chain messaging. |
| SOL-McCc-10 | N/A | zkSync not targeted. |
| SOL-McCc-11 | OK | Windows are in seconds, not blocks, so block cadence does not matter; sequencer timestamp trust documented. |
| SOL-McCc-12 | OK | PUSH0 is supported on Arbitrum (ArbOS 11+); confirm for the target chain with item 3. |
| SOL-McCc-13 | N/A | No bridged assets. |

### Walk: Signature (5)

| Item | Verdict | Note |
|---|---|---|
| SOL-Signature-1 | OK | The only signatures are ERC-2612 permits on JIG/CreatorCoin via OZ `ERC20Permit` (EIP-712 domain with chain id, nonces). |
| SOL-Signature-2 | OK | OZ 5.1 ECDSA rejects malleable `s`. |
| SOL-Signature-3 | OK | OZ checks recovered signer == owner. |
| SOL-Signature-4 | OK | As above. |
| SOL-Signature-5 | OK | Permit deadline enforced by OZ. |

### Walk: Timelock (1)

| Item | Verdict | Note |
|---|---|---|
| SOL-Timelock-1 | Issue (M-2) | No timelock on any owner action; the no-delay decision is recorded in README, but see M-2 for why it matters more once the roles are mapped. |

### Walk: Token (24)

| Item | Verdict | Note |
|---|---|---|
| SOL-Token-FE-1 | OK | SafeERC20 everywhere; the raw `coin.approve` in `_seed` targets our own OZ token. |
| SOL-Token-FE-2 | OK | `forceApprove` / exact approvals to Permit2 and HolderPayouts. |
| SOL-Token-FE-3 .. 9 | N/A (7) | Own 18-decimal OZ tokens: no decimals mismatch, blacklist, multiple addresses, fee-on-transfer, ERC-777 hooks, Solmate lib or flash mint. |
| SOL-Token-FE-10 | OK | Zero-amount transfers are skipped (`if (amount > 0)` guards). |
| SOL-Token-FE-11 | OK | OZ `ERC20Permit` exposes `DOMAIN_SEPARATOR()`. |
| SOL-Token-FE-12 | N/A | No restricted receivers. |
| SOL-Token-FE-13 | OK | `forceApprove` resets to zero first where it matters; own token elsewhere. |
| SOL-Token-FE-14 | OK | No `type(uint256).max` approvals in src. |
| SOL-Token-FE-15 | N/A | Not pausable. |
| SOL-Token-FE-16 | N/A | OZ semantics. |
| SOL-Token-NfE1-1 | OK | PositionManager mints with plain `_mint` to contracts that also implement `onERC721Received`; `SweepAndBurn` uses `transferFrom` to the dead address deliberately. |
| SOL-Token-NfE1-2 | OK | `onERC721Received` is `pure`; no state runs in it. |
| SOL-Token-NfE1-3 | OK | No `safeTransferFrom` to user addresses in src. |
| SOL-Token-NfE1-4 | OK | `HolderDrip.claim` requires `ownerOf == msg.sender`; `SweepAndBurn` only moves what it holds. |
| SOL-Token-NfE1-5 | N/A | No NFT contract in scope. |
| SOL-Token-NfE1-6 | N/A | ERC-721 only. |
| SOL-Token-NfE1-7 | Issue (I-12) | NFTs sitting in a marketplace escrow cannot claim the drip while listed; accrual is kept, so nothing is lost. |
| SOL-Token-NfE1-8 | N/A | CryptoPunks-style collections are not supported (sweep needs `ownerOf`/`transferFrom`). |

## Findings

No Critical or High finding. The in-house fixes hold. The two Mediums are about who the roles really are once the Loom contracts and the deploy defaults are plugged in; the Lows are bounded value leaks measured on a Sepolia fork.

### [Medium] M-1: The platform wallet is `owner()` of every LoomCollection, so it can launch any artist's coin first and be its creator forever  (ref: SOL-Basics-AC-1, SOL-AM-FrA-1, SOL-Basics-Function-3, SOL-Heuristics-9)

- **Location:** `src/CoinFactory.sol:113` (`_controlsCollection`), `:202-208`; role source: `loom/jobs/launch-1527/LoomFactory.sol:54` (`initialize(..., creator, royaltyBps, msg.sender)`), `backend/lib/launch.mjs:45` (`owner: account.address`, the operating wallet). `src/CreatorFeeHook.sol:182-192` makes `creator` permanent; `CoinFactory.sol:112` makes the coin per collection permanent.
- **Impact:** The reviewer fix "the caller must be the collection's owner() or creator()" (README, DRIFT #21) was written on the assumption that both are the artist. They are not: LoomFactory hands ownership of every clone to whoever called it, which is the back end's operating wallet (the same hot key that sits in the Render environment). That wallet can therefore launch a coin for any collection the artist never asked for, become `creator` (default 50% of every fee at 1%, up to the whole creator+flywheel block via the slider), pick the flywheel, the fee band and the start price, and the artist can never launch their own or take the role back. A compromised operating key does the same to every collection at once. It also means the artist's `creator()` path races the platform's `owner()` path.
- **Exploit path:** 1. Artist mints a collection through the site; `owner()` = platform wallet, `creator()` = artist. 2. Platform wallet (or its thief) calls `CoinFactory.launch({collection, flywheel: attackerModule, feePips: 100_000, creatorShareBps: 5500, ...})` paying the launch fee to itself. 3. `_controlsCollection(platform, collection)` passes on the `owner()` branch. 4. `hook.register` stores `creator = platform`. 5. Artist's later `launch` reverts `CollectionHasCoin`; `setCreatorShare`/`lowerFee` revert `NotCreator`.
- **Proof of Concept:** `test/Audit_Findings.t.sol::test_M1_platform_wallet_can_take_any_collection_coin` (passes on the Sepolia fork): a collection mirroring LoomCollection's role layout is launched by `platform`; `hook.pools(id).creator == platform`; the artist's launch reverts `CollectionHasCoin` and `setCreatorShare` reverts `NotCreator`.
- **Recommendation:** Decide who the creator is and encode exactly that. If the artist is meant to launch, accept only `creator()`; if the platform must be able to launch on the artist's behalf, make the artist the recorded creator and have the platform call with an explicit `creator` argument plus an artist signature or a one-time on-chain consent. Separately, LoomFactory should probably give collection ownership to the artist (owner also controls `pause` and the fee-free reserve mint, see I-15), but that is a Loom change.

```solidity
// before (CoinFactory.sol:113, 202-208)
if (!_controlsCollection(msg.sender, p.collection)) revert NotCollectionOwner();
...
function _controlsCollection(address who, address collection) internal view returns (bool) {
    (bool ok, bytes memory ret) = collection.staticcall(abi.encodeWithSignature("owner()"));
    if (ok && ret.length == 32 && abi.decode(ret, (address)) == who) return true;
    (ok, ret) = collection.staticcall(abi.encodeWithSignature("creator()"));
    if (ok && ret.length == 32 && abi.decode(ret, (address)) == who) return true;
    return false;
}

// after: the artist (creator()) is the only party that can launch, and is always the recorded creator
if (_creatorOf(p.collection) != msg.sender) revert NotCollectionCreator();
...
function _creatorOf(address collection) internal view returns (address) {
    (bool ok, bytes memory ret) = collection.staticcall(abi.encodeWithSignature("creator()"));
    if (!ok || ret.length != 32) {
        (ok, ret) = collection.staticcall(abi.encodeWithSignature("owner()")); // non-Loom collections
        if (!ok || ret.length != 32) return address(0);
    }
    return abi.decode(ret, (address));
}
```

### [Medium] M-2: One hot key holds every privileged role, several of which route value immediately and without bound  (ref: SOL-CR-3, SOL-CR-4, SOL-CR-6, SOL-CR-7, SOL-Timelock-1, SOL-AM-RP-1, SOL-Basics-AC-4)

- **Location:** `script/DeployCoins.s.sol:29` (`PLATFORM` defaults to the deployer), `script/DeployRest.s.sol:20`, `script/DeployPayouts.s.sol:15`, `script/DeployDeepening.s.sol:35` (`KEEPER` defaults to the deployer); `src/CreatorFeeHook.sol:75` (`platform` immutable), `src/CoinFactory.sol:43,102`, `src/AirdropClaim.sol:76`, `src/HolderPayouts.sol:61`, `src/BuybackAndBurn.sol:34`, `src/LPDeepening.sol:45`, `src/SweepAndBurn.sol:41`; plus LoomCollection ownership per M-1.
- **Impact:** The CLAUDE.md operating wallet (key in the Render Environment tab) is, by the deploy defaults, at once: the hook's `platform` fee recipient; the launch-fee setter (can set it to `type(uint256).max` and stop all launches, or to 0); the `keeper`/`sweeper` of every module (chooses `minOut`, timing and the sweep listing); the owner of AirdropClaim (one root per coin for 5% of every coin's supply) and HolderPayouts (every coin-holder round); and `owner()` of every collection (M-1, including `pause`, which makes `SweepAndBurn.sweep` revert on `transferFrom`). README requires a 2-of-2 multisig for the pot owner before mainnet but says nothing about these. A single key compromise therefore reaches 5% of every coin, all holder payouts, all module balances (within the L-3 bound), the platform's own JIG, and the creator role of every collection. None of the roles can be rotated: `platform`, `keeper`, `sweeper`, hook `owner` are immutable, so recovery from a compromise means redeploying the hook and factory and stranding every existing pool on the old pair. The platform also has a standing conflict of interest in `recycle` (it takes 25-40% of any stale balance and controls whether keeper-only modules go stale, see L-2).
- **Exploit path (key compromise):** 1. `AirdropClaim.setDrop(coin, rootPayingAttacker, balance, far)` for every coin with an unset drop. 2. `HolderPayouts.declare(coin, rootPayingAttacker, balance[coin], far)` for every funded coin. 3. `hook.claim()` for the platform slice. 4. `BuybackAndBurn.run(1)` / `LPDeepening.run(1)` / `SweepAndBurn.sweep(ownListingAtCap)` to extract what L-3 allows. 5. `CoinFactory.setLaunchFee(type(uint256).max)` to freeze launches while this happens.
- **Recommendation:** Split the roles and make the valuable ones rotatable behind a multisig: platform fee recipient, AirdropClaim/HolderPayouts owner, launch-fee setter and collection ownership to the founders' multisig; a separate low-value keeper EOA for `run`/`sweep` (the module constructors already take a separate `keeper_`; the scripts should stop defaulting it to the deployer). Add a bounded `setLaunchFee` (max, and a max step per call) and a `setKeeper` on the modules guarded by the multisig. Consider a short delay on `setDrop`/`declare` (even 24 h gives holders a chance to see a root that pays the wrong people); README records Jj's choice of no delay, so this is a recommendation to revisit, not a defect.

```solidity
// before (CoinFactory.sol:101-106)
function setLaunchFee(uint256 launchFeeWei_) external {
    if (msg.sender != platform) revert NotPlatform();
    launchFeeWei = launchFeeWei_;
    emit LaunchFeeSet(launchFeeWei_);
}

// after: bounded, and the setter is the (multisig) admin, not the fee recipient
uint256 public constant MAX_LAUNCH_FEE = 0.5 ether;
address public admin; // founders' multisig; two-step rotation
function setLaunchFee(uint256 launchFeeWei_) external {
    if (msg.sender != admin) revert NotAdmin();
    if (launchFeeWei_ > MAX_LAUNCH_FEE) revert FeeTooHigh();
    launchFeeWei = launchFeeWei_;
    emit LaunchFeeSet(launchFeeWei_);
}

// modules: before
address public immutable keeper;
// after
address public keeper; address public immutable admin;
function setKeeper(address k) external { if (msg.sender != admin) revert NotAdmin(); keeper = k; emit KeeperSet(k); }
```

### [Low] L-1: Unspent dev-buy JIG is stranded in CoinFactory, and a creator-chosen narrow range lets the launch transaction buy out the pool  (ref: SOL-Integrations-Uniswap-2, SOL-Basics-Payment-7, SOL-Defi-General-4)

- **Location:** `src/CoinFactory.sol:170-175` (`_devBuy` pulls `jigIn`, spends `spent <= jigIn`, never refunds), `:128-130` (any range on the correct side is accepted), `:329` of the hook (`sender == factory` pays the chosen fee, not the snipe fee).
- **Impact:** Two bounded, creator-inflicted effects. (a) If the seeded range cannot absorb `devBuyJig`, the difference stays in the factory with no rescue path. (b) Because the range width and start price are free parameters and the dev buy is exempt from the 60% decay, a creator can seed a 200-tick range and buy 94% of supply in the launch transaction at the 1% fee; the "LP locked forever, no rug" statement then describes a pool holding only JIG, with the creator holding almost all the coin. No third-party funds are at risk, but the front end's trust claim is only true for full-range launches.
- **Exploit path / edge case:** creator passes `tickLower = startTick + 200, tickUpper = tickLower + 200` (coinIs0) and `devBuyJig = 2,000,000e18`.
- **Proof of Concept:** `test_L1_dev_buy_leftover_jig_is_stranded_in_factory`: creator receives 940,499,999 coin (94% of supply) and 1,013,107 JIG remain in the factory with the creator's JIG balance at 0.
- **Recommendation:** Refund the unspent input and constrain the range in the factory, since the factory is what signs the "locked liquidity" promise.

```solidity
// before (CoinFactory.sol:170-175)
function _devBuy(PoolKey memory key, bool coinIs0, address coinAddr, uint256 jigIn, uint256 minOut) internal returns (uint256 got) {
    jig.safeTransferFrom(msg.sender, address(this), jigIn);
    got = abi.decode(poolManager.unlock(abi.encode(key, coinIs0, jigIn)), (uint256));
    if (got < minOut || got == 0) revert TooLittleOut();
    IERC20(coinAddr).safeTransfer(msg.sender, got);
}
// after
    (got, spent) = abi.decode(poolManager.unlock(abi.encode(key, coinIs0, jigIn)), (uint256, uint256)); // callback returns both
    if (got < minOut || got == 0) revert TooLittleOut();
    IERC20(coinAddr).safeTransfer(msg.sender, got);
    if (jigIn > spent) jig.safeTransfer(msg.sender, jigIn - spent);

// before (CoinFactory.sol:129-130)
if (p.tickLower >= p.tickUpper) revert RangeWrongSide();
if (coinIs0 ? p.tickLower <= startTick : p.tickUpper > startTick) revert RangeWrongSide();
// after: full range on the coin side, as the launch plan says
if (coinIs0 ? (p.tickLower <= startTick || p.tickUpper != 887_200) : (p.tickUpper > startTick || p.tickLower != -887_200)) revert RangeWrongSide();
```

### [Low] L-2: A keeper-only module with no permissionless pull can have its slice recycled by anyone after 7 quiet days, and the platform is paid for letting that happen  (ref: SOL-AM-GA-1, SOL-Defi-Staking-2)

- **Location:** `src/CreatorFeeHook.sol:243-268` (`recycle` accepts the pool's flywheel as `from`), `src/BuybackAndBurn.sol:74-87` (only `keeper` can call `run`, which is the only path that claims), `CreatorFeeHook.sol:400` (`lastCredit` is reset by every credit, so "stale" means "no trade for 7 days", not "unclaimed for 7 days").
- **Impact:** For a coin that goes quiet (no trade for 7 days) with a BuybackAndBurn flywheel, anyone can call `recycle(key, module)`: the flywheel slice is folded 25-40% to the platform, 3% pot, 2% deepening and the rest to the pot; holders lose the buyback. The only defuses are the keeper running (platform's choice) or someone calling `hook.claimFor(module)`, which is undocumented. The platform's band of the recycled amount is a direct incentive not to run quiet coins. SweepAndBurn/HolderDrip/SnapshotForwarder have `pull()`, so they are only exposed if nobody bothers.
- **Proof of Concept:** `test_L2_anyone_can_recycle_a_quiet_buyback_module`: after one trade and 7 days, a third party recycles the module's slice; `claimable(module) == 0` and `claimable(platform)` grows by exactly 25% of it.
- **Recommendation:** Exempt registered flywheel modules from `recycle` (they cannot "forget" to claim), or add `pull()` to BuybackAndBurn and document `claimFor` as the public defuse. If recycling modules is wanted, measure staleness from the oldest unclaimed credit, not the latest.

```solidity
// before (CreatorFeeHook.sol:247-248)
address fly = c.flywheel == address(0) ? c.creator : c.flywheel;
if (from != c.creator && from != fly) revert NotStale();
// after: only a wallet creator can go stale; a module's balance is reachable by anyone through claimFor
if (from != c.creator) revert NotStale();
if (c.flywheel != address(0) && from == c.flywheel) revert NotStale();
```

### [Low] L-3: The keeper can sandwich its own runs; the hook's fee bounds the take to a few percent of the module balance  (ref: SOL-AM-MA-3, SOL-AM-SandwichAttack-1, SOL-Defi-AS-7)

- **Location:** `src/BuybackAndBurn.sol:74-87`, `src/LPDeepening.sol:81-90`, `src/SweepAndBurn.sol:103-120` (`minOut` is a keeper argument; nothing on chain relates it to a price).
- **Impact:** README states the residual trust as "a keeper's run can be front-run up to the minimum-out tolerance it passes"; it does not say what a keeper that passes `minOut = 1` can take. Measured on the fork with a 20,481 JIG BuybackAndBurn balance on a fresh 1%-fee pool: front-run 50k JIG, run, back-run: keeper nets +594 JIG, burn drops 7%; front-run 200k: keeper nets +1,207 JIG (5.9% of the module balance), burn drops 25%; front-run 500k: keeper loses 1,174 JIG, burn drops 47%; front-run 2M: keeper loses 46,419 JIG, burn drops 78%. The 1% fee on both legs caps profitable extraction at single-digit percent of the module balance; the larger harm available is destroying the burn (or the deepening ratio) at the keeper's own expense. For a 10%-fee coin the bound is tighter still; for the JIG pool (1.5%) the deepening and sweep legs are similarly bounded.
- **Proof of Concept:** `test_L3_keeper_self_sandwich_is_bounded_by_the_hook_fee` (numbers above are its logs).
- **Recommendation:** Keep the min-out, add an on-chain cap on price impact that the keeper cannot set in the same transaction: record the pool's sqrt price at the start of `run` and require the post-swap price to be within a constant band of it (this bounds the back-run, since the module's own swap is what moves the price), and cap each run to a fraction of the pool's active liquidity so a run is never the dominant trade. Separate the keeper key from the fee recipient (M-2) so a self-sandwich is theft from the platform, not accounting.

```solidity
// after (BuybackAndBurn.unlockCallback), bound the module's own impact
uint24 public constant MAX_IMPACT_BPS = 300; // 3%
(uint160 p0,,,) = poolManager.getSlot0(k.toId());
BalanceDelta d = poolManager.swap(k, SwapParams({..., sqrtPriceLimitX96: _limit(p0, zeroForOne, MAX_IMPACT_BPS)}), "");
// _limit scales p0 by sqrt(1 +/- impact); a run that would move the price more than 3% partially fills and the rest waits
```

### [Low] L-4: LPDeepening adds liquidity at the post-sale spot price; the keeper's minimum bounds only the sale leg and only downward manipulation  (ref: SOL-Integrations-Uniswap-9, SOL-Defi-Oracle-13, SOL-AM-PMA-2, SOL-Defi-AS-1)

- **Location:** `src/LPDeepening.sol:93-96` (`getSlot0` then `getLiquidityForAmounts`), `:116` (`modifyLiquidities` with `amount0Max = balance`, `amount1Max = jigLeft`).
- **Impact:** A front-run that pushes JIG *up* makes the sale pass `minEthOut` comfortably and then has the module add full-range liquidity at the inflated price; the back-run sells JIG into that liquidity. Loss is proportional to the module's added liquidity times the deviation, and the attacker pays 1.5% twice on the JIG pool plus impact against 900M JIG of depth, so in practice it is uneconomic at the module's scale (same bound as L-3). The acknowledged nested conversion in the hook (`CreatorFeeHook.sol:354-362`, limit at the tick extreme) shares the pattern but is tiny per trade and the hook's own money.
- **Recommendation:** Pass `minSqrtPrice`/`maxSqrtPrice` (quoted off-chain with the min-out) into `run` and check `getSlot0` against them before the add.

```solidity
// before
function run(uint256 minEthOut) external nonReentrant { ... (uint160 sqrtP,,,) = poolManager.getSlot0(jigPool.toId()); ...
// after
function run(uint256 minEthOut, uint160 minSqrtP, uint160 maxSqrtP) external nonReentrant {
    ...
    (uint160 sqrtP,,,) = poolManager.getSlot0(jigPool.toId());
    if (sqrtP < minSqrtP || sqrtP > maxSqrtP) revert PriceOutOfBand();
```

### [Low] L-5: The airdrop's unset-drop clock depends on an unchecked call, and the 7-day sweep races the owner's root  (ref: SOL-EC-12, SOL-LL-3, SOL-AM-FrA-2, SOL-HMT-1)

- **Location:** `src/CoinFactory.sol:141-142` (`airdropRecipient.call(notify)` result discarded), `src/AirdropClaim.sol:62-73` (`receivedAt` only via `notify`; `sweepUnset` after 7 days), `script/DeployCoins.s.sol:38-41` (binding attempted in a try/catch with a console warning).
- **Impact:** If `AirdropClaim.factory` is not bound to the live factory (the script tolerates that), every coin's 5% lands in AirdropClaim with `receivedAt == 0`: `sweepUnset` is impossible forever and the tokens move only if the owner sets a drop. If it is bound, the opposite edge: the owner has exactly 7 days from launch to publish a root, after which any bot sends the 5% to the pot and the holders get nothing. Both are operational rather than attacker-driven, but the first is silent. On Sepolia the hook's `factory` and AirdropClaim's `factory` should be verified to be the same address before trusting a deploy (README says the same for hook bindings).
- **Recommendation:** Make the factory require the notify to succeed, or let AirdropClaim start the clock itself when it observes a new balance.

```solidity
// before (CoinFactory.sol:141-142)
(bool noted,) = airdropRecipient.call(abi.encodeWithSignature("notify(address)", coinAddr));
noted;
// after
IAirdropClaim(airdropRecipient).notify(coinAddr); // reverts the launch if the binding is wrong

// AirdropClaim: let anyone start the clock once the balance exists, so a misbinding is recoverable
function noteReceived(address coin) external {
    if (receivedAt[coin] == 0 && IERC20(coin).balanceOf(address(this)) > 0) receivedAt[coin] = uint64(block.timestamp);
}
```

### [Low] L-6: `PotVault.available()` iterates every distribution ever declared  (ref: SOL-AM-DOSA-4, SOL-Basics-AL-9)

- **Location:** `src/PotVault.sol:94-102`, called by `declare` at `:67`.
- **Impact:** Only the owner creates distributions, so this is a slow self-DoS: after a few thousand declarations `declare` runs out of gas and no further payouts can be declared. Not reachable by an attacker.
- **Recommendation:** Keep a running `reserved[token]` updated on declare and claim, and release expired reservations lazily.

```solidity
// after
mapping(address => uint256) public reserved;
function declare(...) { ... if (total > _balance(token) - reserved[token]) revert BadDistribution(); reserved[token] += total; ... }
function claim(...) { ... reserved[d.token] -= amount; ... }
function release(uint256 id) external { Distribution storage d = distributions[id]; if (block.timestamp <= d.expiry || d.released) revert; d.released = true; reserved[d.token] -= d.total - d.claimed; }
```

## Informational

| # | Location | Note |
|---|---|---|
| I-1 | `CreatorFeeHook.sol:332-333, 378-382` | Fees under 100 wei of unspecified amount are zero; fees under 4 wei route entirely to the flywheel (or creator); `HolderDrip` accumulator dust (`amount*1e18/live` remainder) stays in the module. All uneconomic to farm (PoC `test_I_micro_swap_pays_no_fee`). |
| I-2 | `CreatorFeeHook.sol:89, 320, 353, 363` | `_converting` is dead code: v4's `Hooks.afterSwap` returns early when `msg.sender == address(self)` (Hooks.sol), so the nested swap never re-enters `afterSwap`. Harmless; remove or keep as belt-and-braces with a comment that says so. |
| I-3 | `CreatorFeeHook.sol:166-168` | Flywheel blacklist omits `jig`, the coin, the collection, AirdropClaim, HolderPayouts and JIGLaunch. Naming any of them only loses the creator's own slice (JIGLaunch would split it 50/50 team/pot on `collectFees`), so a UI restriction suffices. |
| I-4 | README/CLAUDE tables vs `JIGLaunchHook.sol:37` | Window is 5 minutes in code; some tables say 10. README "sniper tax fills the pot": `JIGLaunch.collectFees` sends half to the team. `Vesting.sol:12-13` says it is used by the factory; it is not. |
| I-5 | `JIGLaunch.sol:72-77, 138` | `setJig` emits no event; `FeesCollected` logs the contract's whole balance (including anything force-fed) rather than what the call collected. |
| I-6 | `CoinFactory.sol:102`, `SweepAndBurn.sol:84` | `setLaunchFee` and `setMaxPrice` have no bounds (folded into M-2). |
| I-7 | `CreatorFeeHook.sol:197-204` | The creator can set `creatorBps` to the whole block at any time, so "fees to NFT holders / buyback" is a promise the creator can revoke per trade. By design (slider), but the site should show the live split. |
| I-8 | `SweepAndBurn.sol:143-158`, `LPDeepening.sol:153-168`, `BuybackAndBurn.sol:89-113`, `JIGLaunch.sol:143-157`, `LPDeepening.sol:138-148` | Same sell-JIG callback in three modules and the same 50/50 payout in two contracts; one library would cut audit surface. |
| I-9 | `PotVault`, `AirdropClaim`, `HolderPayouts` (Ownable2Step) | `renounceOwnership` is exposed; calling it freezes `declare`/`setDrop` forever. Override to revert. A reverting `platform` wallet (if ever a contract) would block `JIGLaunch.collectFees`, `LPDeepening.collectFees` and `CoinFactory.launch`. |
| I-10 | `HolderPayouts.sol` | No idle-balance sweep: JIG funded for a coin whose rounds are never declared sits forever (AirdropClaim has `sweepUnset`; this does not). |
| I-11 | `PotVault.claim`, `AirdropClaim.claim`, `HolderPayouts.claim` | Anyone can submit a proof for any `account`; funds go to the leaf, so this only lets a third party choose the claim's timing (e.g. push ETH to a contract account at an inconvenient moment). |
| I-12 | `HolderDrip.sol:110` | Tokens held by an escrow (listed on a marketplace) cannot claim until returned; accrual is preserved. |
| I-13 | all merkle leaves | `(account, amount)` with no chain id, contract or round binding; harmless unless an owner reuses a root across deployments or chains. |
| I-14 | modules | Keeper runs have no deadline; a stale pending transaction executes at today's price with yesterday's min-out. Private sequencer submission on the L2 makes this moot. |
| I-15 | `HolderDrip.sol:78` + LoomCollection owner (platform) | The drip trusts `totalSupply()`; the collection owner can reserve-mint 1% of supply fee-free (LoomCollection.sol:132-138) just before a `pull` and earn on it. Equivalent power to M-1/M-2; disappears when ownership is the artist's. |
| I-16 | `CreatorFeeHook` claims | ERC-6909 claims transferred to the hook by third parties inflate `heldJig()` above `totalClaimable()`; unclaimable dust, no accounting effect. |
| I-17 | `CoinFactory.sol:159-160`, `JIGLaunch.sol:115-116`, `LPDeepening.sol:99-100` | Permit2 allowances are exact and expire in 1 h; the few wei of rounding residue stay allowed to the PositionManager until expiry. Harmless (only the approver's own `modifyLiquidities` can spend them). |
| I-18 | `CreatorFeeHook.sol:400` | "Unclaimed for 7 days" is measured from the last credit; an actively traded pool's creator balance is never recyclable however old. Matches DRIFT #10 wording loosely; document it. |
| I-19 | design | Anyone can open a hookless coin/JIG or coin/ETH pool on v4; volume that migrates there pays no creator/platform fee. Inherent to the Zora pattern; the locked liquidity keeps the hook pool the deepest, but a creator holding 5% plus JIG can seed a rival pool. |
| I-20 | v4 protocol fee | Uniswap governance may set a protocol fee (up to 0.1%) on any pool including fee-0 coin pools; the hook's math is unaffected but swappers would pay it on top. |
| I-21 | `JIGLaunchHook.sol:136-140` | Malformed `hookData` of 32+ bytes makes `abi.decode` revert the swap; the swapper's own problem, but routers that pass unrelated hookData will fail in the window. |

## Acknowledged non-issues

Checked and cleared, including every fix from the three in-house passes:

1. **Hook claim invariant.** `heldJig() == totalClaimable()` after exact-input and exact-output buys and sells in and out of the snipe window, `claim`, `claimFor` and `recycle` (`test_invariant_held_claims_equal_total_claimable`); `pendingCoin` stays 0 in normal trading. The hook's net delta inside `afterSwap` is zero in both the JIG-fee and coin-fee paths (mint `fee`, nested swap `-owed/+jigOut`, burn `owed`, mint `jigOut`, return `+fee`).
2. **Nested swap re-entrancy.** `Hooks.afterSwap` short-circuits when the hook is the swapper, so the nested sale cannot re-enter `afterSwap`, charge a second fee, or reach `beforeSwap` (not enabled). `_converting` is redundant (I-2), not wrong.
3. **`sender == factory` spoofing.** `afterSwap` receives `msg.sender` of `PoolManager.swap`; only `CoinFactory.unlockCallback` (reachable only from `launch`, `nonReentrant`) swaps as the factory, and only on the key it just created. The dev-buy exemption cannot be borrowed.
4. **Exact-output parity** (first-pass Medium): `abs*f/(1e6-f)` on the input side gives the same effective rate as `abs*f/1e6` on the output side, including at 60%.
5. **Per-pool recycle ledger** (third-pass High): `earned[pool][addr]` with `claimEpoch` invalidation; `claimable[addr] >= sum of current-epoch earned` holds because every ledgered credit also credits `claimable` and every reduction either bumps the epoch (`_claim`) or reduces both (`recycle`). A junk coin naming a victim as flywheel can only recycle what the victim earned on the junk pool; a stale creator balance feeds the flywheel and a stale flywheel balance feeds the pot, so the recycler never gains (regression tests re-run, pass).
6. **`claimFor` stranding** (second-pass High): HolderDrip, SnapshotForwarder, BuybackAndBurn, SweepAndBurn and LPDeepening all act on `balanceOf`, so a pushed balance is distributed or spent on the next pull/run.
7. **HolderDrip checkpoints** (first/second-pass Highs): a token earns only from pulls whose checkpoint `supply >= tokenId`; `uint160` accumulator cannot truncate below 1e45; solvency holds because `live` tokens each receive `amount/live` and marked-burned tokens' accrual goes to the pot. LoomCollection mints sequential ids from 1 (`_mintBatch`, `firstTokenId = totalSupply + 1`) and has no burn, so `totalSupply` never decreases (verified in `loom/jobs/launch-1527/LoomCollection.sol:208-213`).
8. **PositionManager fee collection.** `_decrease` with `liquidity = 0` calls `_modifyLiquidity(0)` and returns `feesAccrued`; `TAKE_PAIR` then takes them (v4-periphery `5fa38cd`). `collectFees` in JIGLaunch and LPDeepening is correct on this version; README's note to re-check on the target chain stands.
9. **Liquidity amount rounding.** `getLiquidityForAmount0/1` round liquidity down and the pool's `getAmount0/1Delta(roundUp)` is a nested ceiling of the same real quantity, so the required amount never exceeds the amount the liquidity was computed from; `MaximumAmountExceeded` cannot fire in `_seed`, `launch` or `run`.
10. **Price-limit edge states.** A zero-liquidity sell parks the price at `MIN_SQRT_PRICE+1` / `MAX_SQRT_PRICE-1`; the next buy moves it back and the nested sale then has room. An exact-output sell that would exhaust the pool reverts (`PriceLimitAlreadyExceeded` in the nested sale) instead of partially filling; the state is not persisted, so nothing is bricked.
11. **Unlock composition.** `claim`/`claimFor` called from inside anyone's `unlock` revert `AlreadyUnlocked`; `claimable` zeroing is rolled back with the revert.
12. **SweepAndBurn marketplace abuse** (first-pass High): a Seaport order with the module as offerer skips signature checks, but the module never grants Seaport/conduit approvals and `JigMoved` rejects any JIG movement; native-ETH offers by the offerer are not a Seaport construct; the NFT must arrive and must not have been here before.
13. **CREATE-deployed coins and reorgs.** Modules bind by collection or resolve from the factory (third-pass Low), so a reorg cannot point a module at a different coin.
14. **Hook permission bits.** 0x2044 (BEFORE_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA) and 0x2080 (BEFORE_INITIALIZE | BEFORE_SWAP) match the implemented hooks; `validateHookPermissions` runs in both constructors; unused hooks revert.
15. **Dynamic/override fee on the JIG pool.** `fee | OVERRIDE_FEE_FLAG` with 600,000 and 15,000 is within `MAX_LP_FEE`; only JIGLaunch can initialise, only the expected key and price are accepted.
16. **Reentrancy through ERC-20/721.** JIG and CreatorCoin are plain OZ (no hooks); `onERC721Received` is `pure`; HolderDrip's `ownerOf` is a view on the creator's own collection.
17. **Underflow in `_split`.** `creatorBps <= block` guarantees `potA + deep + plat + creator <= amount` since each term rounds down.
18. **Permit2 scope.** Only `modifyLiquidities` called by the approver can spend the Permit2 allowance (PositionManager pays from `msgSender()`).

## Open questions for the developer

1. **Robinhood Chain (id 4663):** which ArbOS version (v4 core needs EIP-1153 transient storage; `cancun` is the compile target), is ETH the gas token (native `currency0 == address(0)` is assumed throughout), and are canonical PoolManager/PositionManager/Permit2 deployed there or will you deploy them? The hook addresses must be re-mined per chain because the PoolManager address is in the init code.
2. **Collection ownership (M-1):** is it intended that every LoomCollection's `owner()` is the operating wallet? If so, which party is meant to launch the coin, and should the artist's consent be on chain?
3. **Snapshot composition** for HolderPayouts and AirdropClaim roots: the off-chain script must exclude the PoolManager (pool reserves), the hook's ERC-6909 claims, AirdropClaim and HolderPayouts balances, the modules and the dead address, or those balances dilute holders. Is that implemented?
4. **Recycle policy for modules (L-2):** was "7 days unclaimed" meant to include keeper-only modules, and is the platform's 25-40% of recycled balances an intended incentive?
5. **Launch parameters (L-1):** will the front end force full-range seeding, and is a dev buy large enough to empty the range an acceptable creator choice?
6. **Keeper separation (M-2):** will `KEEPER`/`sweeper` be a different key from `PLATFORM` on mainnet, and will `PLATFORM`, AirdropClaim and HolderPayouts ownership be the founders' multisig (README only commits the pot owner)?
7. **7-day `sweepUnset` window (L-5):** is a week always enough for the snapshot-and-root process after a launch, including weekends and a stuck back end?
8. **Protocol fee:** if Uniswap governance enables a protocol fee on fee-0 pools, is passing it through to swappers acceptable, or should the hook pool fee be set to a nominal LP fee it can control?
