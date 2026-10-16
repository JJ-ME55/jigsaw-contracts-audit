# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. This is the third round. Round 1 (job fbe44d90) and round 2 (job 489901b6) findings and their fixes are tabled in README.md and in swarm-audit-report.md / swarm-audit-report-2.md. Round 2 fixes in this commit: CreatorFeeHook refuses exact-output sells (ExactOutputSell); JIGLaunchHook has BEFORE_ADD_LIQUIDITY (flags 0x2880) and refuses all liquidity but JIGLaunch's until windowEnd (markSeeded); LPDeepening.run collects fees first and sizes with balance minus platformOwedEth; SweepAndBurn JigMoved guard is "<"; CoinFactory constructor probes the airdrop recipient. Verify each fix holds, look hard for anything the fixes introduced (especially: can the exact-output refusal be bypassed through a different swap shape, hookData or a router; can markSeeded be front-run or the liquidity lock be bypassed via donate/initialize/another pool; does _collectFees inside run reenter or misaccount), then do the full scopes below. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, reference/LoomCollection.sol (reference copy, not compiled: check the 1-based sequential id, monotone totalSupply and transferFrom-to-dead assumptions HolderDrip and SweepAndBurn make). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection: do the id/supply/burn assumptions hold; anything in its owner powers or mint path that affects HolderDrip or SweepAndBurn. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `d3d943ca4818cf3eecfbbf6fadfae9e5db5218aa` |
| Job | `0c246e1d-d121-4da0-9708-a7df0d1ee399` |
| Judged | 2026-10-16 07:37 UTC |
| Findings | 3 low · 8 info |

Four agents audited the code as it is at `d3d943c`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Low: LPDeepening.run collects fees before its own JIG sale, so the LP fee that sale pays the deepening position is netted into INCREASE_LIQUIDITY and never reaches team/pot (round-2 fix #2 incomplete)

`src/LPDeepening.sol:90`

```
        if (tokenId != 0) _collectFees(); // pay out accrued LP fees first; INCREASE_LIQUIDITY would otherwise lock them (swarm audit 2)
```

Merged from audit_math and audit_flow (same mechanism, same fix). run() calls _collectFees() first (line 90), then sells `half` JIG into the JIG/ETH pool via poolManager.unlock (line 96). The deepening position is a full-range LP of that pool, so it is always in range and earns its pro-rata share of the 1.5% LP fee on run()'s own sale, in JIG, AFTER the collect. INCREASE_LIQUIDITY then goes through PositionManager._increase (lib/v4-periphery/src/PositionManager.sol:299-302), whose liquidityDelta from PoolManager.modifyLiquidity already includes feesAccrued and whose slippage check is on principal only; SETTLE_PAIR settles the net, so the fresh fee is netted against the module's debt instead of being paid 50/50 to platform and pot as the contract header promises. The slice stays as the module's 'working balance' and is half-sold/half-locked on the next run; `jigAdded` and FeesCollected are both understated by it. Amount per run = share_of_in_range_liquidity * 1.5% * half, growing as the position deepens. Keeper-only, no outsider gain, so Low. Fix (keeps behaviour): move the collect after the sale: do hook.claim(), the unlock sale and the minEthOut check first, then `if (tokenId != 0) _collectFees();`, then read balances and size liquidity (the collect measures its own before/after deltas, so ethGot and the team/pot split stay correct). Keeping an additional collect at the top is harmless.

**Reproduction**

Local harness test/scratch/DeepeningHarness.t.sol (PoolManager + real PositionManager/Permit2 deployed in-test, no fork; compile needs the upstream optimizer setting: FOUNDRY_OPTIMIZER_RUNS=44444444 FOUNDRY_OUT=out-scratch forge test --match-path test/scratch/DeepeningHarness.t.sol -vv, because v4-core's Pool.swap does not compile under via-ir with optimizer_runs=800). Setup: hookless ETH/JIG pool fee 15_000 spacing 200 at tick 138000 seeded full-range with 100 ETH / 1e8 JIG by a third party; LPDeepening deployed; 1,000,000 JIG sent; keeper run(1) mints tokenId (liquidity 496505577270826396134); another 1,000,000 JIG sent. vm.snapshotState. Branch A (counterfactual): a third party sells exactly 500,000 JIG (the `half` run would sell), then deep.collectFees(): platform+pot receive 37.353807794460017475 JIG. vm.revertToState. Branch B (actual): keeper run(1) then deep.collectFees(): platform+pot receive 0 JIG; module JIG went 1,005,034.82 -> 5,109.98 (the netted fee stayed inside the module). Expected per the header ('LP fees it earns go half to the team wallet, half to the pot'): about 37.35 JIG to team+pot in branch B as well. Actual: 0.

### 2. Low: CreatorFeeHook does not gate liquidity: anyone can LP inside the seeded range of a creator pool and trade coin for JIG at spot with no creator fee and no 60% anti-snipe fee, including as counterparty

`src/CreatorFeeHook.sol:134`

```
            beforeAddLiquidity: false,
```

The pool's LP fee is 0 and the hook charges swappers only (afterSwap), and nothing on the nested conversion swap (line 327 returns 0 while _converting). Liquidity provision is open (beforeAddLiquidity: false), so a participant who wants to sell coin during the 10-second snipe window (or any time, to avoid the 1-10% fee) adds a one-spacing band containing the current tick; the next buyer's swap takes the band's coin at spot, the hook charges the buyer, the LP is never charged, and the LP withdraws JIG. Symmetrically a band of JIG below the post-trade price is the counterparty of _sellCoinForJig and acquires f*output coin at spot with no fee. The hook still receives full value for the fee it takes, so the protocol's accounting is exact; what fails is the anti-snipe intent ('coin leaving the pool in the window costs 60%') and the fee base (sophisticated sellers route through LP positions, fee-free). Not in the README's residual-trust list. Fix options preserving the design: (a) add beforeAddLiquidity (new mined address with 0x0800, i.e. 0x2844) and refuse adds from anyone but the factory while block.timestamp < launchedAt + SNIPE_WINDOW, mirroring JIGLaunchHook's launch lock; optionally refuse all non-factory liquidity permanently if fee-free LP trading is unacceptable; or (b) document it as residual trust.

**Reproduction**

Local harness test/scratch/HookHarness.t.sol::test_lpBandGetsCoinFromConversionWithoutFee (PoolManager deployed in-test, hook via deployCodeTo at a 0x2044 address, pool registered at 10% with 900M coin seeded single-sided at 0.001 JIG/coin, coin is currency1 in this run; same compile override as above). At t = launch (currentFee = 600_000): a buyer buys with 10,000 JIG (price to tick 68915); an LP adds band [68800, 69000] with 20,000,000 coin and ~14,935 JIG via PoolModifyLiquidityTest (no revert: no liquidity gate); a buyer then buys with 100,000 JIG; the LP removes the band. LP balances: coin 20,000,000 -> 20,000,000 remaining outside the band (band fully consumed), JIG 49,985,065.14 -> 50,020,451.67, i.e. the LP sold 20,000,000 coin for 35,386.53 JIG at spot. Hook fee events: one FeeTaken, 62,091.60 JIG, all charged to the buyer. Expected under the anti-snipe design: anyone converting coin to JIG in the window pays 60% to the hook (a swapper selling 20M coin exact-input would have ~60% of the JIG output taken). Actual: 0 fee charged to the LP.

### 3. Low: CoinFactory's constructor probe accepts an AirdropClaim already bound to another factory; every launch() then reverts NotFactory and the hook's one-shot setFactory is consumed

`src/CoinFactory.sol:152`

```
        if (airdropRecipient.code.length > 0) IAirdropNotify(airdropRecipient).notify(coinAddr); // a contract recipient must accept the clock
```

Round-2 fix #6 probes pot() (lines 103-105) but not the condition notify() actually enforces: AirdropClaim.notify requires msg.sender == factory and AirdropClaim.setFactory is one-shot (AirdropClaim.sol:56-65). A CoinFactory constructed with an AirdropClaim whose factory slot is already set passes the constructor, can be bound to the hook with the hook's one-shot setFactory, and every launch() reverts at line 152 with AirdropClaim.NotFactory. Neither binding can be undone, so hook + factory (+ AirdropClaim) must be redeployed. Liveness/deploy-order trap only; no fund loss. Fix: in the constructor, alongside pot(), staticcall factory() and revert BadAirdropRecipient unless it returns address(0) (or address(this) is impossible at construction, so require zero); and in script/DeployCoins require AirdropClaim.setFactory(factory) to succeed instead of swallowing it.

**Reproduction**

Local harness test/scratch/HookHarness.t.sol::test_factoryAcceptsBoundAirdrop (passes on this code, demonstrating the trap): AirdropClaim a = new AirdropClaim(owner, pot); a.setFactory(oldFactory); CoinFactory f = new CoinFactory(posmMock, permit2, hook, jig, platform, address(a), 0) succeeds (pot() answers); vm.prank(address(f)); a.notify(coin) reverts AirdropClaim.NotFactory, which is the exact call launch() makes at line 152 after deploying the coin, registering and seeding the pool, so launch() always reverts; a.setFactory(address(f)) reverts FactorySet. Expected: constructor refuses an AirdropClaim it can never notify. Actual: accepted.

### 4. Info: Exact-input buys pay more than the nominal fee once price impact is real (1867 bps effective at a 10% fee on a 1M JIG buy); exact-output buys and exact-input sells pay exactly f

`src/CreatorFeeHook.sol:353`

```
        if (feeIsCoin) jigAmount = _sellCoinForJig(key, c, fee);
```

On an exact-input buy the fee is f of the coin output, which _sellCoinForJig immediately sells back into the same pool from the post-trade price. That sale retraces the most expensive part of the buyer's own trade, so the JIG the hook receives is f of the coin valued at the top of the curve, well above f of the JIG the buyer spent. This is the mirror image of the round-2 exact-output-sell finding, in the protocol's favour; nobody under-pays and the ERC-6909 accounting stays exact (heldJig == totalClaimable verified before and after). It is undisclosed fee behaviour: routers quoting exact-input buys will show a lower all-in price than the user pays, and in the 60% window an exact-input sniper pays far more than 60% while an exact-output sniper pays exactly 60%. Fix: document in README/natspec that exact-input buys are charged at the post-trade conversion price and have the front end quote and execute buys exact-output; or (design decision) take buy fees from the JIG input in beforeSwap with BEFORE_SWAP_RETURNS_DELTA so no coin is ever converted.

**Reproduction**

Local harness test/scratch/HookHarness.t.sol::test_exactInputBuyOvercharge (same setup as above, 11 s after launch so the fee is the chosen 10%): exact-input buy of 1,000 JIG: hook credits 100.096 JIG (1000 bps). Exact-input buy of 1,000,000 JIG: buyer receives 431,254,317 coin, hook credits 186,707.47 JIG = 1867 bps of the JIG spent (expected 1000 bps). heldJig() == totalClaimable() == creator+flywheel+platform+pot claims after each step; pendingCoin == 0. Exact-output sell of 1e18 JIG reverts (ExactOutputSell), confirming the round-2 fix holds (test_exactOutputSellReverts).

### 5. Info: recycle() can be kept unavailable forever with a dust buy every 7 days, because any non-zero credit refreshes lastCredit

`src/CreatorFeeHook.sol:416`

```
        e.lastCredit = uint64(block.timestamp);
```

_creditEarned stamps lastCredit on every credit however small, and recycle() requires block.timestamp >= lastCredit + RECYCLE_AFTER. A creator (or a flywheel operator) whose balance would become recyclable keeps it un-recyclable by buying 1e12 wei of JIG on their pool once a week (fee 1e11 wei, split and credited to both creator and flywheel). Gas-only cost. Impact is limited to disabling the stale-balance backstop (the recycler never gains), so informational. Fix: measure staleness from the first unclaimed credit of the current epoch (store firstCredit when e.amount goes 0 -> non-zero), or ignore credits below a floor when stamping lastCredit.

**Reproduction**

Local harness test/scratch/HookHarness.t.sol::test_recycleBlockedByDust: after a 1,000 JIG buy credits the creator, warp 7 days + 1 s; a third party buys with 1e12 wei JIG; hook.recycle(key, creator) reverts NotStale() although the creator's balance sat unclaimed for more than 7 days. Expected per README ('untouched for 7 days can be folded back'): recycle succeeds.

### 6. Info: launch() requires msg.value to equal launchFeeWei exactly, so a setLaunchFee() landing before a pending launch reverts it

`src/CoinFactory.sol:119`

```
        if (msg.value != launchFeeWei) revert WrongFee();
```

The platform updates launchFeeWei to track a dollar price. A creator who quoted the fee and submits launch{value: oldFee} has the whole launch revert with WrongFee if setLaunchFee is mined first. UX/liveness only; the revert is atomic and no funds are at risk. Fix: accept msg.value >= launchFeeWei and refund the excess after the platform payout, or add an expectedFeeWei parameter and accept if within a tolerance.

**Reproduction**

Factory with launchFeeWei = 0.01 ether. vm.prank(platform); factory.setLaunchFee(0.012 ether); vm.prank(creator); factory.launch{value: 0.01 ether}(p) reverts CoinFactory.WrongFee() (line 119 is the first check in launch). Expected: the creator paid the fee quoted a moment earlier and the launch goes through.

### 7. Info: JIGLaunchHook header still documents address flags 0x2080; since round 2 the hook requires 0x2880 (BEFORE_ADD_LIQUIDITY added), and the setAllowlist @notice sits above markSeeded

`src/JIGLaunchHook.sol:30`

```
/// Address must carry exactly BEFORE_INITIALIZE_FLAG | BEFORE_SWAP_FLAG (0x2080) in
```

getHookPermissions() (lines 72-89) sets beforeInitialize, beforeAddLiquidity and beforeSwap, so the required low-14-bit pattern is 0x2000 | 0x0800 | 0x0080 = 0x2880; script/DeployJIG.s.sol and README already say 0x2880, the contract header says 0x2080. Fail-closed (Hooks.validateHookPermissions in the constructor reverts), so only a wasted deployment and a misleading spec for whoever mines the Robinhood Chain salt from the contract docs. Also line 91 ('Set or replace the allowlist. Only before the pool exists.') now documents markSeeded() instead of setAllowlist(). Fix: update the header to BEFORE_INITIALIZE_FLAG | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG (0x2880) and move line 91 above setAllowlist.

**Reproduction**

Deploy JIGLaunchHook at an address whose low 14 bits are 0x2080 as the comment says. Expected per the comment: success. Actual: constructor reverts HookAddressNotValid because Hooks.validateHookPermissions requires bit 0x0800 (beforeAddLiquidity: true at line 76). An address with low bits 0x2880 (as the deploy script and the Sepolia deployment 0x...2880 use) succeeds.

### 8. Info: Keeper modules inside the 5-minute JIG window: LPDeepening.run reverts WindowLocked and SweepAndBurn/LPDeepening JIG sales pay the 60% outsider fee

`src/JIGLaunchHook.sol:168`

```
        if (seeded && block.timestamp < windowEnd) revert WindowLocked();
```

The liquidity lock and the tx.origin fee apply to the platform's own modules: while block.timestamp < windowEnd, (1) LPDeepening.run's MINT_POSITION/INCREASE_LIQUIDITY on the JIG pool hits beforeAddLiquidity and reverts WindowLocked (the whole run reverts, nothing lost); (2) SweepAndBurn.sweep and LPDeepening.run sell JIG with hookData '' and a keeper tx.origin, so beforeSwap returns OUTSIDER_FEE and 60% of the sale goes to JIGLaunch's position (half team, half pot). Benign and in-system; recorded so the back end does not schedule runs/sweeps inside the window. This is also why the markSeeded lock cannot be bypassed by a 'friendly' LP: the check has no sender exemption. Fix (operational): do not run modules before windowEnd, or pass an allowlist proof as hookData from the modules.

**Reproduction**

State: JIGLaunch.launch() at T (windowEnd = T+300, seeded = true). At T+100 keeper calls LPDeepening.run(minEthOut) with JIG in the module: unlockCallback sells half at 60% fee, then posm.modifyLiquidities -> PoolManager.modifyLiquidity -> JIGLaunchHook.beforeAddLiquidity reverts WindowLocked (line 168 has no sender exemption); whole run reverts. SweepAndBurn.sweep at T+100 with jigToSell = 1e21 and hookData '' (SweepAndBurn.sol:147): beforeSwap returns 600_000 | OVERRIDE_FEE_FLAG; ETH received is ~40% of an off-window quote so a keeper minEthOut from that quote reverts TooLittleOut. Expected per README: modules trade at 1.5%.

### 9. Info: L2 (Robinhood Chain / Arbitrum Orbit) portability: tx.origin allowlist, CREATE2 proxy and re-mined salts, Cancun transient storage, native-ETH-as-currency0, sequencer timestamps

`src/JIGLaunchHook.sol:148`

```
                bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(tx.origin))));
```

Items that change behaviour on an Orbit-style L2 and are hard-coded: (1) tx.origin allowlisting: ERC-4337 bundlers, Safes and smart-wallet relayers make the relayer the tx.origin, so allowlisted users on such wallets pay 60% in the window and an allowlisted relayer EOA whitelists everyone it relays (README documents EOAs only). (2) Both hooks are mined for the 0x4e59b44847b379578588920cA78FbF26c0B4956C CREATE2 proxy and the init-code hash includes poolManager/jig/launch addresses, so salts must be re-mined per chain; without the proxy `new X{salt}` uses the deployer's own CREATE2 and the predicted-address check fails. (3) foundry.toml targets cancun; PoolManager and the ERC-6909 claim flow rely on transient storage, so ArbOS must be Cancun-enabled. (4) currency0 == address(0) is assumed for ETH in JIGLaunch, LPDeepening, SweepAndBurn and the JIGLaunchHook pool check; a custom-gas-token Orbit chain breaks all four. (5) WINDOW (300 s) and SNIPE_WINDOW (10 s) use sequencer block.timestamp; on a 250 ms chain the 10 s decay spans ~40 blocks. (6) PositionManager/Permit2 addresses must be added to the scripts' _v4() table. None is a Solidity defect; they are deployment preconditions, answered here as the brief asked.

**Reproduction**

State: swap on the JIG pool during the window from a Safe (tx.origin = relayer R, R not in the tree, hookData = a valid proof for the Safe's address). beforeSwap computes the leaf from tx.origin = R (line 148), MerkleProof.verify fails, fee = 600_000. Expected by the user: 15_000. Actual: 60%.

### 10. Info: Creator fees are enforced only on the one hooked pool; anyone can initialise a hookless coin/JIG or coin/ETH pool and trades there pay no creator fee

`src/CreatorCoin.sol:12`

```
contract CreatorCoin is ERC20, ERC20Permit, ERC20Burnable {
```

CreatorCoin is a plain ERC-20 and CreatorFeeHook only sees swaps on the pool the factory registered. Anyone can PoolManager.initialize the same coin against JIG or ETH with hooks = address(0), seed it from coin they bought, and route trades there with zero creator/platform/pot/deepening fee. The factory's locked liquidity stays in the hooked pool, so price discovery still runs through it and arbitrage between pools pays the hook fee, but secondary pools dilute the fee base. Inherent to the chosen design (same as Zora coins), not a code defect; listed because the README residual-trust list does not mention it and the economics assume every trade pays.

**Reproduction**

Anyone: poolManager.initialize(PoolKey{currency0: min(coin,jig), currency1: max(coin,jig), fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))}, price) succeeds (no hook, so no registration check), then posm MINT with coin+JIG and swap on it. Expected per the economics doc: every creator-coin trade pays the creator's fee. Actual: no FeeTaken, nothing credited in CreatorFeeHook.claimable.

### 11. Info: Vesting's header says the coin factory uses it for creator allocations, but CoinFactory sends the creator's share straight to the wallet

`src/Vesting.sol:12`

```
///         Used by the coin factory for creator allocations (5%, 6 months) and for
```

CoinFactory.launch (src/CoinFactory.sol:147-150) transfers up to 5% of supply directly to msg.sender; nothing in src/ or script/ calls Vesting.create (script/DeployJIG.s.sol only deploys it). Vesting itself is correct (anyone funds, only the beneficiary receives, linear with cliff, non-revocable, balance-checked transfer-in), so threat-model item (d) holds; the comment describes a lock that does not exist. Fix: update the comment, or wire the factory to Vesting if a lock is intended.

**Reproduction**

grep -rn Vesting src/ script/ shows no caller of Vesting.create. CoinFactory.launch with creatorBps = 500 transfers 50,000,000e18 coin to msg.sender in the launch transaction (line 150). Expected from the comment: a 6-month schedule. Actual: immediately liquid.

---

Judge's submission `0b5be0bf53e73ba57320b6f505ca872b8be5537cb32fd52bed2a9b66e8a0c1e4`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
