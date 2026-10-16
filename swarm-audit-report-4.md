# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. This is the fourth round. Rounds 1-3 (jobs fbe44d90, 489901b6, 0c246e1d) and every fix are tabled in README.md and swarm-audit-report*.md. Round 3 fixes in this commit: CreatorFeeHook has BEFORE_ADD_LIQUIDITY (flags 0x2844) and after the factory calls seal(key) a creator pool refuses all liquidity forever; LPDeepening.run collects fees after its own sale; CoinFactory constructor also requires the AirdropClaim to be unbound (factory() == 0) and launch accepts msg.value >= fee with a refund; recycle staleness runs from Earned.firstCredit. Verify each fix holds and hunt for anything the fixes introduced (especially: can seal() be called before seeding or skipped so a pool stays open; can the factory's own seed be blocked or front-run by the liquidity lock; does the launch refund open reentrancy or a griefing path via a reverting msg.sender; does firstCredit misbehave across claim epochs; is anything in the hook now callable in a wrong order). If, after a genuine attempt, nothing above Info remains, say so plainly: this round decides whether the swarm phase is complete. Then do the full scopes below. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, reference/LoomCollection.sol (reference copy, not compiled: check the 1-based sequential id, monotone totalSupply and transferFrom-to-dead assumptions HolderDrip and SweepAndBurn make). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection: do the id/supply/burn assumptions hold; anything in its owner powers or mint path that affects HolderDrip or SweepAndBurn. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `ec8476c81506731e3945d5b714a2c4a5d89800fe` |
| Job | `ae115cf4-22d5-4e44-949a-2136ee66fb7e` |
| Judged | 2026-10-16 08:46 UTC |
| Findings | 3 low · 5 info |

Four agents audited the code as it is at `ec8476c`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Low: recycle() staleness runs from firstCredit, which never refreshes while a balance is outstanding: fresh credits are swept with the stale one, and recycle(creator) chains into recycle(flywheel) in the s

`src/CreatorFeeHook.sol:270`

```
        if (block.timestamp < e.firstCredit + RECYCLE_AFTER) revert NotStale(); // from the first unclaimed credit, so a dust buy cannot reset the clock
```

Round 3 moved the recycle clock from Earned.lastCredit to Earned.firstCredit. _creditEarned (line 427) only sets firstCredit when e.amount == 0, so once ANY unclaimed credit on a pool is RECYCLE_AFTER old, recycle() takes e.amount in full (line 271), which includes every credit since, down to one made in the same block. Two consequences, both introduced by the round-3 change (merged from two specialists, same root cause, one fix): (1) for an actively traded coin whose flywheel (HolderDrip, SnapshotForwarder, BuybackAndBurn, SweepAndBurn) or creator has not pulled for 7 days, anyone can fold the WHOLE 7 days of earnings through the split, not just the stale part; the README (line 188) says a balance 'untouched for 7 days' is recyclable, which readers take to mean the stale money, not fresh fees. (2) recycle(creator) credits the creator's block to the flywheel via _creditEarned (line 283); since the flywheel's e.amount is already > 0 its firstCredit stays old, so recycle(flywheel) succeeds in the same transaction and the block that was meant to 'feed the flywheel' (README line 106) goes to the pot instead, with the platform/pot/deepening cut taken twice. Under the round-2 lastCredit rule the second call reverted NotStale. Nobody profits except the platform/pot; the losers are the flywheel's beneficiaries (NFT holders, buyback) and the creator. Severity Low: no attacker gain, needs a week of nobody calling the permissionless pull(), but it contradicts the documented recycle semantics and is the only behaviour the round-3 fix set made worse. Fix (keeps the design): track two buckets per Earned entry, e.g. {uint128 stale; uint128 recent; uint64 recentSince}: in _creditEarned, if block.timestamp >= recentSince + RECYCLE_AFTER then stale += recent, recent = 0, recentSince = now; then recent += amount. recycle() rolls the same way, requires stale > 0 and recycles only `stale`. And in recycle() credit the flywheel with _credit(fly, rest) instead of _creditEarned so recycled money is never re-recyclable (or set e.firstCredit = block.timestamp on that inflow). Operational mitigation until then: the keeper pulls every module at least weekly.

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F1, same setUp as test/Regressions.fork.t.sol: PoolManager 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543, hook at a 0x2844-flag address, factory fee 0.01 ETH). Launch a coin at 1 JIG = 1000 coin with flywheel = a HolderDrip, feePips 10_000, default split. warp +11s. Buyer exact-input buys 1,000 JIG: claimable(creator) = 5005066100453389722 (5.0 JIG), claimable(drip) = 2002026440181355890 (2.0 JIG). warp +7 days + 1 s. Buyer exact-input buys 1,000,000 JIG in the same block as the recycles: claimable(creator) = 10014807753850665337308 (10,014 JIG), claimable(drip) = 4005923101540266134926 (4,005 JIG). Anyone calls hook.recycle(key, creator): EXPECTED (README 'untouched for 7 days'): ~5.0 JIG recycled, the 10,009 JIG credited this block stays with the creator. ACTUAL: returns 10014807753850665337308, the whole balance including the same-block credit. Then, same block, hook.recycle(key, drip): EXPECTED (README line 106 'a stale creator balance feeds the flywheel', and pre-round-3 behaviour): revert NotStale, drip keeps its 4,005 JIG plus the ~7,010 JIG block just moved to it. ACTUAL: succeeds, returns 11016288529235731871042 (11,016 JIG), claimable(drip) == 0; pot gains 8762956784619332170147 JIG and platform 5257774070771599302087 JIG across the two calls. heldJig() == totalClaimable() holds throughout (accounting is consistent; the defect is who gets the money).

### 2. Low: Exact-input buys pay the fee at the marginal post-trade price: 2x nominal at half the pool, 10x at 90%, while exact-output buys of the same coin pay exactly f

`src/CreatorFeeHook.sol:365`

```
        if (feeIsCoin) jigAmount = _sellCoinForJig(key, c, fee);
```

For an exact-input buy (JIG in, coin out) afterSwap takes f of the coin output and _sellCoinForJig sells that coin back into the same pool, exact-input with the range edge as the only limit, starting from the price the buyer's own trade just left. The JIG recovered is the cost of the LAST f*G coin the buyer bought (the marginal segment of their own price impact), not f of what they paid. On the single-sided launch position every launch-sized buy has real price impact, so the JIG the buyer effectively loses to the fee grows without bound with trade size, while exact-output buys (fee charged on the JIG input, line 351) pay the nominal rate at every size. The buyer receives exactly the quoted (1-f)*G coin, so a router quote shows nothing wrong; the loss shows up as the pool keeping far less JIG than the buyer paid, which is all their coin can ever be sold back for, and as the creator (70%) and platform (25%) being credited many multiples of the stated fee. Round 3 (#4) recorded the direction ('above nominal, by construction') as Info without the magnitude; measured here it makes the stated 1-10% band untrue for any trade above about 10% of the pool. Severity Low: no third party can trigger it, the buyer is not an attacker, and it was accepted as a design property in round 3; reported because the magnitude at realistic launch-sniper sizes (50% of pool -> 2x, 90% -> 10x) was not on the table when it was accepted. Fix (keeps the 'fee in the unspecified currency, held as JIG' design): bound the conversion to the nominal JIG value: target = (|specified JIG input| * feePips) / PIPS; run the nested sale as EXACT-OUTPUT for `target` JIG (amountSpecified = +int256(target), same price limit); read coinUsed from the delta; mint JIG claims for the JIG received; return int128(coinUsed) as the hook delta so the coin not needed stays with the swapper; fall back to pendingCoin only when the price sits at the range edge. Alternative: take the buy fee on the JIG input with BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA and drop the nested conversion (new hook flags, redeploy).

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F4, standard launch: 1 JIG = 1000 coin, 950M coin seeded single-sided from the start tick to the range end, feePips 10_000, flywheel 0, warp +11s past the snipe window). For each size S the buyer does an exact-input buy of S JIG on a state snapshot, reading spent = buyer JIG delta, feeJig = hook.heldJig() delta; then on the same snapshot an exact-output buy of the same coin amount. EXPECTED (README: the creator's 1% fee): ~100 bps both ways at every size. ACTUAL, exact-input bps / exact-output bps: 1k JIG 100/99; 10k 101/99; 100k 110/99; 1M (about half the pool) 200/99; 10M 1019/99; 50M 3451/99; 100M 5107/99. At 10M JIG exact-input the hook credits 1,019,157 JIG of the 10,000,000 paid (10.19%); buying the same coin exact-output costs 9,071,557 JIG with a 90,715 JIG fee (0.99%). hook.heldJig() == hook.totalClaimable() after every swap.

### 3. Low: launch() has no caller-stated maximum fee since the round-3 refund change, so a setLaunchFee mined first takes the creator's whole msg.value

`src/CoinFactory.sol:122`

```
        if (msg.value < launchFeeWei) revert WrongFee(); // a fee update landing before a quoted launch must not revert it; excess is refunded
```

Round 3 changed launch() from an exact-fee check to msg.value >= launchFeeWei with the excess refunded. The stated reason is that a creator pads msg.value to survive a fee update; the effect is that the creator no longer bounds what they agree to pay: the fee charged is whatever launchFeeWei is when the transaction executes, up to msg.value. The platform (the only caller of setLaunchFee) can raise the fee to msg.value in the same block, or an honest fee update that lands first silently consumes the padding. Before round 3 the same transaction reverted WrongFee. The platform is a trusted role, so this is a trust-assumption note under threat-model item (f) rather than a theft, but it is a new privilege the round-3 fix introduced: the platform can now take an arbitrary amount of a creator's ETH, bounded only by what the creator attached. Fix: add uint256 maxFeeWei to LaunchParams and revert WrongFee when launchFeeWei > p.maxFeeWei (keep msg.value >= launchFeeWei and the refund). The front end passes the quoted fee plus its tolerance. While there, cache `uint256 fee = launchFeeWei;` at the top and use it for the check, the payment and the refund (see the Info finding on line 166).

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F3, same setUp as test/Regressions.fork.t.sol::test_launch_overpayment_is_refunded, launchFeeWei = 0.01 ether). vm.prank(platform); factory.setLaunchFee(0.5 ether); then vm.prank(creator); factory.launch{value: 0.5 ether}(params). EXPECTED (the creator's intent and pre-round-3 behaviour): revert WrongFee, or pay 0.01 ETH and refund 0.49 ETH. ACTUAL: launch succeeds, creator.balance drops by exactly 500000000000000000 wei, platform.balance rises by 500000000000000000 wei, refund 0.

### 4. Info: launch() re-reads launchFeeWei from storage after paying the platform, so a fee change inside the platform's receive() strands the creator's refund in the factory

`src/CoinFactory.sol:166`

```
        if (msg.value > launchFeeWei) {
```

The refund path compares msg.value with the storage variable launchFeeWei (lines 164, 166, 167) after an external call to the platform. nonReentrant guards launch() but not setLaunchFee(). If the platform is a contract (a Safe with a module or fallback handler, for example) whose receive() calls setLaunchFee(), the second read differs from the first: with msg.value 0.015 ETH and the fee raised from 0.01 to 0.015 (or anything >= msg.value) during receive, the platform is paid 0.01, `msg.value > launchFeeWei` is false, and 0.005 ETH stays in CoinFactory forever (no withdraw, no receive, nothing can ever move it). Lowering it instead makes the refund larger than the factory holds and the launch reverts. The platform is trusted and gains nothing, so Info (merged from two specialists), but it is the only path by which ETH can be stuck in the factory and the fix is one line: cache `uint256 fee = launchFeeWei;` at the top of launch() and use `fee` for the check, the platform payment and the refund.

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F2). Deploy a second hook/factory pair whose platform is a contract with receive() { factory.setLaunchFee(0.015 ether); }, launchFeeWei = 0.01 ether. Creator calls launch{value: 0.015 ether}(params). EXPECTED: platform receives 0.01 ETH, creator refunded 0.005 ETH. ACTUAL: platform receives 10000000000000000 wei, creator paid 15000000000000000 wei, refund 0, address(factory).balance == 5000000000000000 wei permanently.

### 5. Info: _converting is dead code: v4 never calls afterSwap for the hook's own nested swap, so the fee-skip protection comes from the PoolManager, not the flag

`src/CreatorFeeHook.sol:339`

```
        if (_converting) return (IHooks.afterSwap.selector, 0);
```

Hooks.afterSwap in v4-core (lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol line 293: `if (msg.sender == address(self)) return (swapDelta, BalanceDeltaLibrary.ZERO_DELTA);`) returns before calling the hook whenever the swap's msg.sender is the hook itself, and the nested conversion in _sellCoinForJig is a poolManager.swap() made by the hook. So afterSwap is never re-entered during the conversion, the branch at line 339 is unreachable, and the double-charge / double-credit protection the README ('guarded by _converting so the nested swap is not charged again', line 193) and the threat model attribute to _converting is actually the PoolManager's self-call rule. Not a vulnerability (the outcome is correct either way); the two storage writes cost about 5k gas per coin-fee swap and the README's reasoning should cite the v4 rule. The same noSelfCall rule means a seal would not bind a modifyLiquidity call made by the hook itself; the hook has no such code path and must not gain one. Fix: delete _converting and its three uses, or keep it as belt-and-braces and correct the comments.

**Reproduction**

Static: lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol line 293 returns before the hook call when msg.sender == address(self); _sellCoinForJig (line 388) calls poolManager.swap from the hook, so msg.sender in Hooks.afterSwap is the hook. Dynamic: any exact-input buy on a creator pool after launch (test/scratch/Judge.fork.t.sol::test_F4, 1,000 JIG in) enters afterSwap exactly once per outer swap; a `require(!_converting)` placed at line 339 never fires.

### 6. Info: register() checks the flywheel against the deepening address bound at registration time, so a coin launched before setDeepening can name the future LPDeepening as its flywheel

`src/CreatorFeeHook.sol:173`

```
            flywheel == platform || flywheel == pot || flywheel == deepening || flywheel == address(this)
```

Until setDeepening() runs, deepening == pot, so the BadFlywheel list excludes only the pot. The deploy order is hook, factory, then LPDeepening (DeployDeepening.s.sol binds it afterwards), and the LPDeepening address is a plain CREATE address predictable from the deployer nonce. A launch in that gap with flywheel == the future LPDeepening passes register(), and setDeepening() to that address later succeeds. Consequence: that pool's flywheel slice is credited to LPDeepening and its stale balance is recyclable by anyone to pot/deepening/platform (the flywheel side's remainder goes to the pot), never to the recycler, and LPDeepening.pull() is permissionless, so no value is extractable; it only defeats the stated intent of the exclusion list. Fix if wanted: have CoinFactory.launch refuse launches while hook.deepening() == hook.pot() (one line), or have setDeepening refuse an address already registered as a flywheel.

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F6). Deploy hook and factory, do not call setDeepening. launch({... flywheel: X ...}) with X = the address LPDeepening will get. EXPECTED: BadFlywheel. ACTUAL: PoolRegistered with pools[id].flywheel == X; then vm.prank(owner); hook.setDeepening(X) succeeds and hook.deepening() == X, so every swap on that pool credits X both the 2% deepening slice and the flywheel block.

### 7. Info: recycle() re-splits with the platform band of the current feePips, not the band in force when the balance was earned

`src/CreatorFeeHook.sol:278`

```
        uint256 plat = (amount * platformBps(c.feePips)) / 10_000;
```

_split() credits the platform by the band of the fee at swap time; recycle() re-splits the stale creator or flywheel balance by the band of the fee at recycle time. After lowerFee() from the 7-10% band (platform 4000) to the 1% band (platform 2500), a stale balance earned under the old band pays the platform 25% instead of 40% on recycling, with the difference going to the flywheel (creator's stale money) or the pot (flywheel's stale money). The recycler never gains and the creator cannot raise the fee, so the only direction is less to the platform. Accept and document, or store the band with the Earned entry.

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F7). Pool registered at feePips 100_000 (platform band 4000). After the snipe window a 1,000 JIG exact-input buy credits the creator 55050656338532086231 (55.05 JIG). Creator calls lowerFee(key, 10_000). warp +7 days + 1 s; anyone calls recycle(key, creator). EXPECTED under the earning band: platform credited 40% = 22.02 JIG. ACTUAL: platform credited 13762664084633021557 = exactly 25% (55.05 * 2500 / 10_000).

### 8. Info: HolderDrip.pull() books the full amount as distributed but the accumulator floors, so up to live-1 wei per pull is owed to nobody and never re-spread

`src/HolderDrip.sol:83`

```
        accPerToken += (amount * ACC) / live;
```

accPerToken grows by floor(amount*1e18/live) but accounted grows by the full amount (line 84). The remainder, less than `live` wei per pull, is counted as distributed yet is claimable by no token. undistributed() = balance - (accounted - paidOut) excludes it, so it is never re-spread and sits in the contract forever. Magnitude is below the live supply in wei per pull (a 10,000-token collection strands at most 1e4 wei per pull), so no fix is required; if wanted, grow `accounted` by (accDelta * live) / ACC instead of `amount` so the remainder stays undistributed and is picked up by the next pull.

**Reproduction**

Sepolia fork (test/scratch/Judge.fork.t.sol::test_F5). HolderDrip on a collection with 3 live tokens; transfer 10 wei of JIG to it; pull(): accPerToken += 3333333333333333333, accounted += 10. The holder claims ids 1..3: EXPECTED all 10 wei eventually distributable. ACTUAL: claim returns 9, jig.balanceOf(drip) == 1, undistributed() == 0, so no later pull can ever re-spread the 1 wei.

---

Judge's submission `9f4d241c6db936c4a03d96ac78b6d98bb504e48265536af5dba79aced23751e6`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
