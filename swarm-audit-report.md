# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, src/nft/LoomCollection.sol (v2 changes only: the mint(quantity, referral) path and REFERRAL_FEE_SHARE). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection v2: fee conservation with the referral, reentrancy via referral receiver, referral == platform/zero cases. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `a148086188efddbd3bbde1fcfb0612e727db61e4` |
| Job | `fbe44d90-e695-41cd-aa2a-ced0a28f2c8c` |
| Judged | 2026-10-15 20:13 UTC |
| Findings | 1 high · 5 low · 8 info |

Four agents audited the code as it is at `a148086`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. High: CreatorFeeHook: the nested coin->JIG conversion has no price bound, so a dust JIG order parked below the launch range captures the whole coin-side fee (fee evasion)

`src/CreatorFeeHook.sol:359`

```
                sqrtPriceLimitX96: coinIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
```

_sellCoinForJig sells the coin fee into the same pool with sqrtPriceLimitX96 at the extreme tick (MIN_SQRT_PRICE+1 for coinIs0, MAX_SQRT_PRICE-1 otherwise) and no reference to the price the outer swap traded at or to the seeded range. Creator-coin pools have no liquidity hooks, so anyone may add a position on the empty side of the single-sided launch range (below tickLower when the coin is currency0, above tickUpper otherwise) at a price where the coin is worth nothing; such a position costs about 0 JIG. A seller whose exact-output order (or exact-input order with a price limit at the range edge) drains the range's JIG leaves the pool price at the range edge; the fee the hook charges on top (abs*f/(PIPS-f) coin) then has no JIG left in the range to be sold into, and the conversion slides through the empty zone into the attacker's order and sells the entire fee for 0 JIG. jigOut is 0, so _split credits nothing to creator, flywheel, platform, pot or deepening; pendingCoin is also 0 because the sale 'filled'. The attacker removes the order and takes the fee coin back: an effective 0% fee on the sale that empties the pool, repeatable every time buyers refill the JIG side, and any pendingCoin left by other users' partial fills is sold the same way. Threat model B(a) 'a swapper paying less than the current fee' is therefore YES. Variant observed while reproducing: with the order at the very bottom ([-887200,-887000]) the price moves by less than one Q96 unit, the fee coin is swallowed by the PoolManager with no owner, and still nothing is credited. Fix (keeps the design): never sell below the launch range. Store the seeded range in Config at register() (the factory already knows tickLower/tickUpper) and use TickMath.getSqrtPriceAtTick(tickLower) (coinIs0) / getSqrtPriceAtTick(tickUpper) (else) as the nested swap's limit; read slot0 first (StateLibrary.getSlot0) and skip the swap, leaving the fee as pendingCoin[id], when the current price is already at or beyond that limit (this also removes the PriceLimitAlreadyExceeded revert reported separately). Alternatively bound the limit to a few percent of the post-trade sqrt price, or enable beforeAddLiquidity (re-mine the address) and restrict liquidity to the seeded range.

**Reproduction**

Reproduced in test/scratch/FeeEvasionDustOrder.t.sol (self-contained: the vendored v4 PoolManager runtime is etched because PoolManager.sol does not compile under the repo's via-ir/runs=800 profile). Setup: coinIs0 pool registered at 10% (feePips 100_000), 900M coin single-sided in [200, 887200] at tick 0, exactly as CoinFactory seeds it. (1) buyer swaps 100_000e18 JIG exact-input: hook credits 10_000.98 JIG (honest path works). (2) attacker adds liquidity {tickLower:-600000, tickUpper:-599800, liquidityDelta:1e15}: cost 1 wei JIG. (3) attacker swaps zeroForOne=true, amountSpecified=+1_000_000e18 (exact JIG out), sqrtPriceLimitX96=getSqrtPriceAtTick(200): receives 89_999.02 JIG for 98_009.29 coin (88_208.36 swapped + 9_800.93 fee); the hook's nested swap emits Swap(amount0=-9_800.93 coin, amount1=0) and FeeTaken(jigAmount=0); totalClaimable unchanged; pendingCoin(id)=0. (4) attacker removes the dust position and receives 9_800.929103 coin of the 9_800.929104 coin fee. Expected: the ~10_000 JIG of fee value credited to the five recipients, or kept as pendingCoin for a conversion inside the range. Actual: nothing credited, attacker has the fee back. Run: forge test --match-path test/scratch/FeeEvasionDustOrder.t.sol -vv (fails now with 'attacker took the coin fee back through the dust order: 9800929103296688660334 >= 98009291047044555472'; passes once the nested sale cannot leave the launch range).

### 2. Low: CreatorFeeHook: an exact-output sell that exhausts the pool's JIG reverts with PriceLimitAlreadyExceeded instead of partially filling

`src/CreatorFeeHook.sol:354`

```
        BalanceDelta d = poolManager.swap(
```

When a swapper sells coin for an exact JIG output (unspecified = coin, so the fee is taken in coin) and asks for more JIG than the range holds, using the limit every router defaults to (MIN_SQRT_PRICE+1 for coinIs0, MAX_SQRT_PRICE-1 otherwise), v4 fills partially and slides the pool price through the empty side of the range to exactly that limit. afterSwap then runs the nested conversion with the same limit and Pool.swap reverts PriceLimitAlreadyExceeded because limit >= current (v4-core Pool.sol lines 323-334), so the whole transaction reverts where plain v4 would have partially filled. Only the caller's transaction is affected and the next buy repairs the price, so the pool is not bricked, but the documented partial-fill/pendingCoin path (line 373-374) is unreachable in this direction and front ends must special-case it. Fix: in _sellCoinForJig read slot0 (StateLibrary.getSlot0) and skip the conversion, leaving the fee as pendingCoin[id], when the current price already sits at or beyond the limit; the range-bounded limit proposed for the high finding needs the same check.

**Reproduction**

Reproduced in test/scratch/HookChecks.t.sol (same harness): coinIs0 pool with ~90_000 JIG in the range after a 100_000 JIG buy. Attacker swaps zeroForOne=true, amountSpecified=+1_000_000e18, sqrtPriceLimitX96=TickMath.MIN_SQRT_PRICE+1, hookData ''. Expected (plain v4): partial fill of ~90_000 JIG. Actual: the swap reverts with Hooks.WrappedError(hook, afterSwap.selector, PriceLimitAlreadyExceeded(4295128740, 4295128740), HookCallFailed) i.e. 0x7c9c6e8f with both arguments MIN_SQRT_PRICE+1, raised by the nested poolManager.swap in _sellCoinForJig.

### 3. Low: CreatorFeeHook.recycle: when the flywheel is the creator wallet, a stale creator balance is forfeited in full to the pot instead of being folded back through the split

`src/CreatorFeeHook.sol:265`

```
        else _credit(pot, rest);
```

recycle() computes fly = c.flywheel == address(0) ? c.creator : c.flywheel. For the 'fees to the team wallet' flywheel option (flywheel = address(0) or == creator) the branch 'from == c.creator && fly != c.creator' can never be taken, so the entire creator+flywheel block (70% at a 1% fee, 55% at 10%) of a creator's stale balance goes to the pot, with platform/pot/deepening bands on top: the creator receives nothing. The README ('folded back through the same split') and the contract header ('a stale creator balance feeds the flywheel') describe a redistribution, not a 100% forfeiture, and nothing tells creators who choose this option that an idle week (no claim, no new fee credit on that pool) costs them everything they earned on it. Anyone can trigger it; whether the creator keeps the money depends on who is first after day 7 (see the claimFor note). Reported as a design/trust mismatch, not a bypass. Fix options (scope decision): for fly == c.creator pay the creator via _claim(from) instead of folding, or send only the platform/pot/deepening bands and leave the block with the creator, or document the forfeiture for this flywheel option.

**Reproduction**

Reproduced in test/scratch/HookChecks.t.sol test_recycleForfeitsCreatorBlockToPotWhenFlywheelIsCreator: pool registered with flywheel=address(0) at 10%; one 100_000 JIG buy credits the creator 5_500.54 JIG; vm.warp(+7 days); anyone calls hook.recycle(key, creator). Expected per README: the creator keeps a share. Actual: recycle returns 5_500.54, claimable[creator] == 0, pot (also the deepening address in the harness) is credited 3_300.32 JIG = 3% + 2% + the whole 55% block, platform 2_200.22 JIG.

### 4. Low: LPDeepening.collectFees sends half of the deepening position's LP fees to the platform while the README and the contract header say they go to the pot

`src/LPDeepening.sol:42`

```
    uint16 public constant TEAM_BPS = 5000;
```

The deepening slice is 2% of every creator-coin fee, i.e. money whose declared destination is the pot: README line 155 ('LP fees it earns go to the pot') and LPDeepening.sol line 27 ('LP fees it earns are collected to the pot'). collectFees() splits both the ETH and the JIG legs TEAM_BPS = 5000 to platform first (lines 144-152). The 50/50 team/pot split is a signed-off decision for the JIG launch pool (JIGLaunch); nothing in the README or DRIFT notes extends it to the deepening position, so this is a threat-model (f) item: the hard-coded fee recipient takes half of a pot-declared flow. Either send 100% to the pot (pot.call{value: eth}; jig.safeTransfer(pot, j)) or state the 50/50 split in README and the contract header so the audit trail and the founders' agreement match.

**Reproduction**

Code trace: LPDeepening.sol:42 TEAM_BPS = 5000; collectFees() lines 143-153: team = eth*5000/10_000 to platform, eth-team to pot; same for JIG. State: a position (tokenId != 0) that accrued 1 ETH and 100 JIG of fees; anyone calls collectFees(). Expected per README/NatSpec: pot receives 1 ETH and 100 JIG. Actual: platform receives 0.5 ETH and 50 JIG, pot 0.5 ETH and 50 JIG.

### 5. Low: JIGLaunch.collectFees and LPDeepening.collectFees are all-or-nothing: if the immutable platform wallet cannot accept ETH, the pot's half can never be collected and the fees stay in the locked position

`src/JIGLaunch.sol:149`

```
            if (!a || !b) revert PayoutFailed();
```

The pot's share of the LP fees is coupled to the platform's share in a single call that reverts if either plain ETH transfer fails. platform is immutable in both contracts (LPDeepening reads it from the hook, also immutable). If it is ever a contract that rejects plain ETH (a Safe module or fallback handler that reverts, a contract without receive, a self-destructed contract), every collectFees() call reverts with PayoutFailed forever; the position cannot be moved, so the accrued fees of the locked JIG/ETH position and of the deepening position are unreachable by anyone. The same pattern is at src/LPDeepening.sol:145-147. Fix: pull-pattern for the team half (credit an owedToPlatform balance the platform withdraws) or pay the pot first and record a failed platform push as owed instead of reverting.

**Reproduction**

Code trace: JIGLaunch._payout lines 147-149: (a,) = platform.call{value: team}(''); (b,) = potVault.call{value: eth-team}(''); if (!a || !b) revert PayoutFailed(). State: JIGLaunch deployed with platform_ = a contract whose receive()/fallback reverts; pool launched; swaps accrued ETH fees. Anyone calls collectFees(). Expected: the pot receives its 50%. Actual: PayoutFailed on every call, indefinitely; identical for LPDeepening.collectFees after the first run().

### 6. Low: CoinFactory._devBuy refunds the factory's entire JIG balance to the current launcher, not just this dev buy's unspent JIG

`src/CoinFactory.sol:178`

```
        uint256 left = jig.balanceOf(address(this));
```

The refund is computed from the factory's absolute JIG balance instead of jigIn - spent. Any JIG that reaches the factory by another route (a mistaken transfer, JIG sent by error from the pot or airdrop owners, a future credit path) is handed to whichever creator next launches with devBuyJig > 0. Not exploitable for other users' funds today because nothing credits the factory with JIG in normal operation, but it is a silent value path from the factory to an arbitrary creator. Fix: have unlockCallback return (got, spent) and refund jigIn - spent only.

**Reproduction**

Code trace: CoinFactory.sol:178-179 left = jig.balanceOf(address(this)); if (left > 0) jig.safeTransfer(msg.sender, left). State: anyone transfers 1_000e18 JIG directly to the factory; a creator launches with p.devBuyJig = 1e18 and the pool fills it fully (spent = 1e18). Expected: refund 0. Actual: the launcher receives 1_000e18 JIG.

### 7. Info: CreatorFeeHook: claimFor(address) pre-empts recycle(), so the 7-day recycling of stale creator/flywheel balances is best-effort only

`src/CreatorFeeHook.sol:286`

```
        claimEpoch[to]++; // per-pool recycle entries from before this claim no longer count
```

recycle(key, from) requires earned[id][from].epoch == claimEpoch[from]; _claim(to) bumps claimEpoch[to] and anyone can reach it through claimFor(to). The moment a balance becomes recyclable, anyone (including the creator's own bot) can call claimFor(creator) and the JIG is paid to the creator; a later recycle reverts NotStale. The documented economics ('a stale creator balance feeds the flywheel, a stale flywheel balance feeds the pot') therefore only happen when nobody pushes, and a recycle in the mempool can be front-run by a single claimFor. No funds are at risk and the recycler never gains; the finding is that the mechanism is not a reliable revenue path and the Earned ledger costs three storage writes per credit for it. Fix: document recycling as best-effort, or restrict claimFor to recipients that cannot call claim() themselves (to == pot || to == deepening, or to.code.length > 0).

**Reproduction**

Reproduced in test/scratch/HookChecks.t.sol test_claimForPreemptsRecycle: creator credited by one buy; vm.warp(+7 days); anyone calls hook.claimFor(creator) -> creator receives the JIG; hook.recycle(key, creator) then reverts NotStale.

### 8. Info: JIGLaunchHook.WINDOW is 5 minutes while README line 15 and the residual-trust note describe a 10-minute launch window

`src/JIGLaunchHook.sol:37`

```
    uint64 public constant WINDOW = 5 minutes;
```

The hook enforces a 5-minute allowlist window and the launch-plan table (README lines 25-26) says 5 minutes, but the Phase 1 contract table (README line 15: 'for 10 minutes after the pool opened') and the residual-trust paragraph ('The 10-minute windows rely on the sequencer's clock') say 10 minutes, and this task's threat model (e) was written with 10 minutes. Whichever is intended, the deploy checklist and the friends-and-family communication will disagree with the chain. Fix: align the README (or make WINDOW a constructor argument the deploy script validates).

**Reproduction**

Read JIGLaunchHook.WINDOW(): 300 seconds. A non-allowlisted tx.origin swapping at windowOpen + 6 minutes pays NORMAL_FEE (1.5%), not OUTSIDER_FEE (60%), contrary to README line 15.

### 9. Info: SweepAndBurn has no 'one sweep per 10 minutes' throttle although the README's first-pass fix table still claims it; the keeper's self-dealing residual is bounded only by the cap and the module's balan

`src/SweepAndBurn.sol:103`

```
    function sweep(address marketplace, bytes calldata data, uint256 tokenId, uint256 priceWei, uint256 jigToSell, uint256 minEthOut)
```

README line 74 records the fix for the first-pass High ('the keeper could drain the module') as including 'one sweep per 10 minutes'; the code has no timestamp, cooldown or per-block counter (the second-pass table says cooldowns were removed, and the operational note says no caps and no cooldowns by decision). The NatSpec claim 'may not be any contract this module holds a balance in' is implemented as a fixed blocklist in setMarket (jig, collection, hook, poolManager, self), not a balance check. The practical consequence equals the documented residual trust (the keeper may buy its own listings at up to maxPriceWei), but a reader of the first-pass table believes the drain rate is bounded per 10 minutes when it is bounded only by the cap times the number of listings and the module's ETH/JIG balance, and the owner has no window to lower the cap or revoke the market. Fix: correct README line 74 and the NatSpec, or reinstate a cooldown if that bound is wanted (uint64 lastSweep; revert if block.timestamp < lastSweep + 10 minutes).

**Reproduction**

Code read: no block.timestamp reference anywhere in src/SweepAndBurn.sol; sweep() checks only sweeper, allowedMarket, priceWei <= maxPriceWei, balances and NFT arrival. Keeper calls sweep(market, buy(1), 1, cap, 0, 0) and sweep(market, buy(2), 2, cap, 0, 0) in the same block. Expected per README line 74: the second call reverts. Actual: both succeed.

### 10. Info: PotVault.notifyDeposit lets anyone emit a Received event for any token and amount without a transfer

`src/PotVault.sol:54`

```
    function notifyDeposit(address token, uint256 amount) external {
```

The function emits Received(msg.sender, token, amount) with no transfer or balance check, so an indexer that sums Received events to display pot inflows can be spoofed. No on-chain funds are affected. Fix: remove it (ERC-20 Transfer events already cover deposits) or pull the tokens inside it with safeTransferFrom so the event is backed by a real deposit.

**Reproduction**

Any EOA calls potVault.notifyDeposit(jig, 1_000_000_000e18). Expected: no effect or revert. Actual: Received(attacker, jig, 1e27) is emitted while jig.balanceOf(potVault) is unchanged.

### 11. Info: CoinFactory.launch rejects tickLower == startTick when the coin is currency0 even at the exact tick price, an asymmetry with the coin-is-currency1 case; a start price one unit below the range bottom i

`src/CoinFactory.sol:134`

```
        if (coinIs0 ? p.tickLower <= startTick : p.tickUpper > startTick) revert RangeWrongSide();
```

When the coin is currency1 the factory accepts tickUpper == startTick, so the first buy fills exactly at the stated start price (the JIGLaunch fix 'start price set exactly at the range top'). When the coin is currency0 the check rejects tickLower == startTick even when sqrtPriceX96 == TickMath.getSqrtPriceAtTick(tickLower), the one case where v4's in-range branch yields amount1 = 0 and the position would still be single-sided coin. A specialist reported a forced 2.02% gap (one tick spacing); that overstates it: a creator can pass sqrtPriceX96 = getSqrtPriceAtTick(tickLower) - 1, whose tick is tickLower - 1, which passes the check and starts the first fill a negligible fraction below the range bottom. So the only effect is that the exact boundary price is refused for one ordering and the front end must know the trick. Fix, if wanted: accept the boundary only at the exact tick price: coinIs0 ? (p.tickLower < startTick || (p.tickLower == startTick && p.sqrtPriceX96 != TickMath.getSqrtPriceAtTick(startTick))) ...; any other price inside that tick would need amount1 > 0 and already reverts on amount1Max = 0.

**Reproduction**

Input: coinIs0 launch with p.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1000), p.tickLower = 1000, p.tickUpper = 887200. Actual: RangeWrongSide at line 134 (startTick 1000, 1000 <= 1000). With p.sqrtPriceX96 = getSqrtPriceAtTick(1000) - 1 the same range is accepted and the position holds coin only. Mirror case: coinIs0 == false with p.tickUpper = startTick is accepted.

### 12. Info: HolderDrip relies on LoomCollection semantics (sequential ids from 1, totalSupply never decreasing) that are not enforced and could not be verified: src/nft/LoomCollection.sol is not in this repositor

`src/HolderDrip.sol:79`

```
        uint256 live = supply - burnedCount;
```

The task's scope C names src/nft/LoomCollection.sol (mint(quantity, referral), REFERRAL_FEE_SHARE), but the pinned tree has no src/nft directory (README: the collection and factory stay as the swarm wrote them; the v2 referral was dropped), so scope C(f) and the collection properties HolderDrip and CoinFactory depend on were not re-derived from code. Two failure modes if the assumption is ever violated: (1) if the collection's totalSupply() can decrease (an ERC721Enumerable-style burn) after tokens were marked burned here, 'supply - burnedCount' underflows and every pull() reverts forever, stranding the drip's JIG (claims of already-accrued amounts still work) while the flywheel slice accumulates in the hook as claimable[HolderDrip] and becomes recyclable after 7 quiet days; a collection whose burn makes ownerOf revert also makes markBurned revert, so a burned token keeps its share. (2) _baseline treats a token as existing at a checkpoint when checkpoint.supply >= tokenId (line 95), which is correct only for 1-based sequential ids; a 0-based collection would over-credit each token minted right after a pull by one pull, making the sum of owed() exceed accounted and the last claimants revert. Also, CoinFactory._controlsCollection trusts creator() to be the artist. Fix: pin the collection's behaviour in a test that imports LoomCollection, and make pull() robust (live = supply > burnedCount ? supply - burnedCount : 0).

**Reproduction**

Not a defect in this tree on its own. Failing state for (1): collection totalSupply 2, tokens 1 and 2 at 0xdEaD and markBurned for both (burnedCount 2), then the collection burns token 2 so totalSupply() returns 1: pull() reverts with arithmetic underflow at line 79 on every call. Failing state for (2): 0-based ids; mint token 0; 100 JIG arrives; pull() -> checkpoint {supply 1, accBefore 0}; mint token 1; owed(1) = 100 (checkpoints[0].supply 1 >= 1) although it did not exist at the pull; the second claimant's transfer fails.

### 13. Info: CoinFactory does not bound the seeded range width or the dev buy, so a creator can take the whole pool share at the chosen fee in the launch transaction (anti-snipe does not apply to the dev buy)

`src/CoinFactory.sol:148`

```
        if (p.devBuyJig > 0) devBuyCoin = _devBuy(key, coinIs0, coinAddr, p.devBuyJig, p.devBuyMinCoin);
```

Only the side of the range relative to the start price is checked (line 134). A creator may seed the 90% pool share into a single 200-tick band adjacent to the start price and, in the same transaction, dev-buy through all of it: afterSwap uses c.feePips rather than the 60% decay when sender == factory (CreatorFeeHook.sol:329), which only the factory's own unlock can produce. The creator then holds creatorBps (up to 5%) plus the pool share, the pool holds only JIG, and the anti-snipe fee advertised to buyers protects nothing on that coin. This matches 'no caps' in the decisions log and the dev buy is intended, so it is a transparency note, not a bypass: the front end should display the seeded range width and the dev-buy size, or the factory should enforce a minimum range width / a maximum devBuy as a fraction of the pool share.

**Reproduction**

coinIs0 launch with sqrtPriceX96 just below tick T (T a multiple of 200), tickLower = T, tickUpper = T + 200, creatorBps = 500, devBuyJig large enough to buy the whole band, devBuyMinCoin = 0. Actual: the launch transaction ends with the creator holding ~95% of supply bought at feePips, the position holding JIG only, and later buyers paying the 60% decay on a pool with no coin left to buy.

### 14. Info: Threat-model answers for scopes A, B and C, with L2 notes (verified against the source; each YES has its own finding above)

`src/CreatorFeeHook.sol:320`

```
        if (_converting) return (IHooks.afterSwap.selector, 0);
```

SCOPE A. (a) LP removal: NO. JIGLaunch, CoinFactory and LPDeepening hold the PositionManager NFT with no transfer/approve/decrease function; collectFees encodes DECREASE_LIQUIDITY with liquidity 0 then TAKE_PAIR (fee collection only on the vendored v4-periphery). (b) PotVault/AirdropClaim exits: NO other exit. PotVault.claim is the only transfer, gated by a declared root and reserved accounting; settle() only releases accounting; AirdropClaim transfers only to proven leaves or to the pot. Owner-authored roots are the accepted trust. (c) Supply: NO. JIG and CreatorCoin mint only in their constructors; ERC20Burnable only reduces. (d) Vesting: NO early/redirected claim; release pays only the beneficiary and is monotone; no revoke path. (e) JIGLaunchHook: NO 1.5% fee without a valid proof for tx.origin against a root frozen before init (relay-for-friends is documented); beforeSwap is view and reverts only on malformed caller-supplied hookData; beforeInitialize accepts one pool once from JIGLaunch at the agreed spacing and price, so the hook cannot brick the pool. (f) Privileges: setFactory/setDeepening (one-shot, owner), the three merkle owners, the factory's launch fee, SweepAndBurn's owner/keeper and the keeper-only runs are the trust surface; no function moves user funds to a privileged address (LPDeepening's 50/50 platform split is the one undocumented platform flow, reported above). Single-sided seeding: for both orderings the range check guarantees a one-token position and the amounts use getLiquidityForAmount0/1 with the matching max (boundary asymmetry reported above). CREATE2 flags: both constructors call Hooks.validateHookPermissions; 0x2044 = BEFORE_INITIALIZE|AFTER_SWAP|AFTER_SWAP_RETURNS_DELTA and 0x2080 = BEFORE_INITIALIZE|BEFORE_SWAP match the permission structs. Reentrancy: every claim/pull/run/sweep/recycle is nonReentrant; the hook's claim cannot run inside an unlock (AlreadyUnlocked). SCOPE B. (a) Paying less than the fee: YES (high finding: dust order below the launch range). The exact-output scaling abs*f/(PIPS-f) is otherwise correct for all four swap shapes; hookData is unused. (b) _converting: no skip or double credit; the nested swap calls only the PoolManager, which skips hook calls when msg.sender == hook, and the flag is reset before any other code runs. (c) ERC-6909: every credited JIG is minted as a claim inside the same unlock; _split sums exactly to the amount; recycle is balance-neutral; claimFor pays only the credited address; totalClaimable cannot exceed held claims. (d) Nested swap: pool-cannot-absorb and dust are handled by pendingCoin in the buy direction, but the missing price bound is the exploit above and the sell direction reverts (low finding). (e) Access control correct (owner one-shots, factory-only register, creator-only slider/lowerFee, flywheel blacklist). (f) Decay: linear 600_000 -> feePips over 10 s, uint24 cast safe; dev buy exempt only when sender == factory. (g) Bands sum exactly; abs*600_000 fits uint256; int128 cast safe for 1e27-supply tokens. (h) Flags match. SCOPE C. (a) Factory: atomic launch; 90/5/5 enforced by constants and MAX_CREATOR_BPS; ordering handled; LP locked; dev-buy refund over-pays stray balances (low). (b) HolderDrip: per-token checkpoints correct for a non-decreasing supply; no double claim; non-owners revert; unverified collection assumptions (info). (c) SweepAndBurn: keeper bounded to approved markets, price cap, JigMoved check, NFT arrival; reentrancy blocked by nonReentrant; ETH leaves only as priceWei; residual: keeper buys its own listing at the cap with no throttle (info). (d) Buyback/Deepening: unlockCallback requires msg.sender == poolManager and is only reachable from the module's own unlock; sync/transfer/settle then take is correct; leftovers stay in the module. (e) AirdropClaim: one root per coin, no withdraw, per-coin isolation by token address; sweep races documented. (f) LoomCollection v2 is not in the tree. L2 (Robinhood Chain / Arbitrum O

**Reproduction**

Summary entry: each NO was traced in the source as described; each YES has its own finding with inputs above.

---

Judge's submission `28c14952cac9d86e99fb2a7a1f82ff6871e84ac51a45051ab66158ca6db38bdf`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
