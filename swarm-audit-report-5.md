# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. This is the fifth round. Rounds 1-4 (jobs fbe44d90, 489901b6, 0c246e1d, ae115cf4) and every fix are tabled in README.md and swarm-audit-report*.md. Round 4 fixes in this commit: (1) CreatorFeeHook.recycle folds only day-bucketed credits at least 7 days old (Earned{epoch, head, Chunk[] chunks}; recyclable() view), so nothing fresh is swept and recycle cannot chain creator->flywheel->pot in one block; (2) exact-input buys now pay exactly f of the JIG spent: _convertBuyFee does an exact-output nested swap for target = f * jigIn, charges the buyer only the coin that swap spent and burns the unused claims, falling back to the old full charge + pendingCoin at the range edge; (3) CoinFactory.launch takes LaunchParams.maxFeeWei, reads the fee once and uses it for the check, the payment and the refund; (4) HolderDrip.pull books only what the accumulator can pay. Verify each fix holds and hunt hardest for what the fixes introduced, in particular _convertBuyFee: ERC-6909 claim accounting (heldJig must equal totalClaimable after every swap shape, including partial fills at the range edge, pendingCoin retries and the spent > fee rounding branch), whether a buyer can make the exact-output nested swap spend more coin than the fee minted or less JIG than credited, sandwiching the nested swap, the 60% snipe window with the new conversion, and whether exact-output buys and exact-input sells are still consistent with it; the day-bucket recycle across claim epochs and the chunk array growth (gas griefing by many small credits); and the maxFeeWei/refund path. If, after a genuine attempt, nothing above Info remains, say so plainly. Then do the full scopes below. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, reference/LoomCollection.sol (reference copy, not compiled: check the 1-based sequential id, monotone totalSupply and transferFrom-to-dead assumptions HolderDrip and SweepAndBurn make). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection: do the id/supply/burn assumptions hold; anything in its owner powers or mint path that affects HolderDrip or SweepAndBurn. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `cfd5cb83ff00e4c2587d2e81e29db5c35414fdd9` |
| Job | `374e2a1a-d5e1-4348-90f8-f0b457785636` |
| Judged | 2026-10-16 10:30 UTC |
| Findings | 1 high · 1 medium · 2 low · 1 info |

Four agents audited the code as it is at `cfd5cb8`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. High: HolderDrip.pull() bricks permanently once per-token claims exceed the floored per-pull bookings (round-4 fix 4 introduced an underflow in undistributed())

`src/HolderDrip.sol:85`

```
        amount = (per * live) / ACC; // only what the accumulator can actually pay; the rounding dust stays undistributed for the next pull
```

Round-4 fix (4) books `accounted += floor(per * live / 1e18)` instead of the full amount pulled. But each token's owed() floors its OWN accumulated share `(accPerToken - baseline) / 1e18`, and the fractional parts that a per-pull floor discards are still carried inside accPerToken, so the sum of per-token floors is not bounded by the sum of per-pull floors. Every pull whose `amount * 1e18` is not divisible by `live` (any live count with a prime factor other than 2 or 5: 3, 6, 7, 9, 11, ...) under-books by up to 1 wei, while per-token flooring loses less than 1 wei per TOKEN in total. After more lossy pulls than there are live tokens, sum(owed) > accounted. Once holders claim (or markBurned sweeps to the pot, which also adds to paidOut), paidOut > accounted and undistributed() reverts with panic 0x11 on `accounted - paidOut`. pull() calls undistributed() unconditionally and accounted only grows inside pull(), so the drip is bricked forever: the hook still lets anyone move the coin's flywheel slice into the drip (claimFor(drip), or recycle after 7 days) but it can never be distributed again, and there is no rescue path. Nothing is stolen; the coin's whole NFT-holder flywheel stops and every later JIG credited to it is stuck. Confirmed: the proof fails with panic 0x11 on this commit and passes when line 85 is removed (accounted += the full `amount`). With full booking, sum(owed) <= sum(per*live)/1e18 <= accounted and balance >= accounted - paidOut always hold; the only unclaimable remainder is the sub-wei part of `amount*1e18 % live`, which is < 1 wei per pull, not the per-pull dust round 4 tried to carry. Fix: delete line 85 so `accounted += amount;` books the full spread (keep `amount` for the event). Do not re-spread the rounding remainder as a carry: it is already inside accPerToken and adding it again lets claims exceed the balance.

**Reproduction**

Collection with 3 live tokens (ids 1..3, one holder), HolderDrip bound to it (mock hook whose claim() returns 0, JIG delivered by plain transfer, which the contract documents as equivalent). Four times: mint 1e18 wei JIG to the drip and call pull(). Each pull: per = 333333333333333333333333333333333333, booked = 1e18 - 1, so accounted = 4e18 - 4, while owed(id) = floor(4 * per / 1e18) = 1333333333333333333 for each of the 3 tokens, total 4e18 - 1. Holder claims [1,2,3]: transfer succeeds (balance 4e18), paidOut = 4e18 - 1. Another 1e18 arrives. Expected: pull() spreads it. Actual: pull() reverts with panic 0x11 ((4e18-4) - (4e18-1) underflows in undistributed()) and keeps reverting forever. Run: forge test --match-path test/scratch/HolderDripUnderflow.t.sol (fails on this commit; passes with line 85 removed).

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderDrip} from "src/HolderDrip.sol";

/// Minimal ERC-20 standing in for JIG (SafeERC20-compatible: returns true).
contract MockJig {
    string public constant name = "JIG";
    string public constant symbol = "JIG";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Stands in for CreatorFeeHook: HolderDrip only reads jig(), pot() and calls claim().
/// claim() returns 0 here; the JIG is delivered by plain transfer, which the drip
/// documents as equivalent ("anything that lands here is distributed on the next pull").
contract MockHook {
    address public immutable jig;
    address public immutable pot;

    constructor(address jig_, address pot_) {
        jig = jig_;
        pot = pot_;
    }

    function claim() external pure returns (uint256) {
        return 0;
    }
}

/// A LoomCollection-shaped collection: ids 1..totalSupply, monotone supply.
contract MockCollection {
    uint256 public totalSupply;
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 quantity) external {
        for (uint256 i; i < quantity; i++) {
            totalSupply++;
            ownerOf[totalSupply] = to;
        }
    }
}

/// HolderDrip.pull() books floor(per * live / 1e18) per pull (round-4 fix), while each
/// token's owed() floors its own accumulated share. The per-token floors can sum to MORE
/// than the per-pull floors, so once every token has claimed, paidOut > accounted and
/// undistributed() reverts on `accounted - paidOut`. pull() calls undistributed()
/// unconditionally, so the drip is bricked forever: all later flywheel JIG for the coin
/// is stuck in it.
///
/// Concrete: 3 live tokens, four pulls of 1e18 wei each.
///   per pull: per = 333333333333333333333333333333333333, booked = 1e18 - 1
///   accounted after 4 pulls = 4e18 - 4
///   owed(token) = floor(4 * per / 1e18) = 1333333333333333333, times 3 = 4e18 - 1
/// The holder claims all three: paidOut = 4e18 - 1 > accounted = 4e18 - 4.
contract HolderDripUnderflowTest is Test {
    MockJig jig;
    MockHook hook;
    MockCollection coll;
    HolderDrip drip;
    address holder = makeAddr("holder");
    address pot = makeAddr("pot");

    function setUp() public {
        jig = new MockJig();
        hook = new MockHook(address(jig), pot);
        coll = new MockCollection();
        coll.mint(holder, 3);
        drip = new HolderDrip(address(hook), address(coll));
    }

    function test_pullSurvivesFullClaimAfterLossyPulls() public {
        for (uint256 i; i < 4; i++) {
            jig.mint(address(drip), 1e18);
            drip.pull();
        }
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        vm.prank(holder);
        uint256 paid = drip.claim(ids);
        // every claim is covered by the balance; the defect is in the bookkeeping, not the transfer
        assertEq(paid, 4e18 - 1, "claimed");
        assertEq(jig.balanceOf(address(drip)), 1, "one wei of dust left");

        // the module must keep working: new fees arrive and the next pull must spread them
        jig.mint(address(drip), 1e18);
        // on the current code this reverts with an arithmetic underflow inside undistributed()
        uint256 spread = drip.pull();
        assertGt(spread, 0, "pull must still distribute after everyone has claimed");
        assertGe(drip.accounted(), drip.paidOut(), "accounted must never fall below paidOut");
    }
}
```

### 2. Medium: Partially filled exact-input buys are charged f of the JIG requested (params.amountSpecified), not the JIG spent; on a young pool the swap reverts CurrencyNotSettled

`src/CreatorFeeHook.sol:390`

```
            uint256 target = (uint256(-params.amountSpecified) * feePips) / PIPS;
```

Round-4 fix (2) sizes the nested exact-output conversion from params.amountSpecified, the amount the swapper ASKED to spend. v4 treats that as a maximum on exact-input swaps: when the swapper's sqrtPriceLimitX96 (or the top of the seeded range) stops the fill, the JIG actually spent is the specified-side delta, which is smaller. `fee` (line 371) already uses the real unspecified delta, so the two halves of afterSwap disagree about the trade size. Consequences, both borne by the buyer: (1) overcharge: the nested swap recovers f * requested JIG and the buyer is charged all the coin it spent (`charge = spent`, line 433), i.e. f * requested / spent times the nominal fee (5.05% instead of 1% in case 1 below). The hook's own accounting stays consistent (heldJig == totalClaimable), and the overcharge is credited through _split, so a creator can profit by front-running a victim's price-limited buy (push the price to just under the victim's limit) and collecting f * nominal of JIG the victim never spent. (2) Revert: when f * requested exceeds the JIG the pool can give before the range edge, jigOut < target so `charge = fee` while `spent > fee` was minted at line 424; the hook's coin delta inside the PoolManager ends at fee - spent < 0 and the whole swap reverts CurrencyNotSettled. Any buyer who sets a real price limit on a fresh creator pool cannot trade at all. The official V4Router / Universal Router pass no price limit, so standard buys are unaffected; any integrator or bot that uses sqrtPriceLimitX96 for slippage protection hits this. Exact-output buys and exact-input sells compute their fee from `delta` and are consistent. Fix (verified: both reproductions then pass, credited fee is exactly 1% of the JIG spent, heldJig == totalClaimable after the partial fill): replace line 390 with `int128 spec = specifiedIs0 ? delta.amount0() : delta.amount1(); uint256 target = (uint256(uint128(-spec)) * feePips) / PIPS;` (spec is negative on an exact-input buy). With the target bounded by the JIG actually paid in, the retrace always recovers it before the range edge, so the `spent > fee` branch at line 424 is reached only for the one-or-two-wei rounding case it was written for. Merged from three specialists (audit_math, audit_permissions, audit_economics) who reported the same root cause at this line.

**Reproduction**

Local PoolManager, hook at a 0x2844 address, coin/JIG pool at 1000 JIG per coin seeded single-sided with 900M coin over the factory-shaped range, fee 1%, sealed, 11 s after launch. Case 1: buyer A buys exact-input 100_000e18 JIG with no limit. Buyer B swaps exact-input amountSpecified = -50_000e18 JIG with sqrtPriceLimitX96 = the price a 10_000e18 buy reaches. B spends about 9_909.9e18 JIG. Expected fee: 1% of the JIG spent = about 99.1e18 JIG. Actual: hook.totalClaimable() rises by exactly 500000000000000000000 (1% of the 50_000e18 requested, 5.05% of the JIG spent), and the buyer is charged the coin that bought 500e18 JIG. Case 2: fresh pool, B swaps exact-input amountSpecified = -1_000_000e18 with the limit a 1_000e18 buy reaches. Expected: a partial fill of about 1_000e18 JIG paying 10e18 fee. Actual: the swap reverts CurrencyNotSettled() (target = 10_000e18 JIG > the 1_000e18 JIG in the pool). Both reproduced in test/scratch/ConvertBuyFeePartialFill.t.sol (fails on this commit, passes with the one-line fix). The harness imports v4-core's PoolManager, which does not compile under the project's optimizer_runs = 800 (Yul stack-too-deep inside PoolManager.swap, unrelated to this code); run it with FOUNDRY_OPTIMIZER_RUNS=44444, which is why it is not attached as a proof.

### 3. Low: recycle() folds day-bucketed credits after as little as 6 days + 1 second, not RECYCLE_AFTER (7 days)

`src/CreatorFeeHook.sol:273`

```
        uint64 cutoff = uint64(block.timestamp / 1 days) - uint64(RECYCLE_AFTER / 1 days); // days at or before this are stale
```

Round-4 fix (1) buckets creator/flywheel credits by UTC day and recycle() treats every bucket with day <= today - 7 as stale (recyclable() at line 302-304 uses the same test). A bucket records only the day, not the time within it, so a credit made at 23:59:59 of day D sits in bucket D and satisfies the test at 00:00:00 of day D+7, i.e. 6 days and 1 second later, up to 86_399 s short of RECYCLE_AFTER. The README ('untouched for 7 days') and the round-4 commit ('at least 7 days old') promise a 7-day grace; the actual grace is anywhere in [6d 0h 0m 1s, 7d] depending on the time of day the fee was earned. Anyone can fold a creator's or flywheel module's balance up to a day early; the fold still goes through the split to pot/platform/deepening and the other side, so the caller gains nothing, but a creator or keeper that pulls on a weekly schedule anchored to the credit time can be recycled before its pull. Fix: make the comparison strict so a whole bucket must be older than RECYCLE_AFTER: keep `cutoff = block.timestamp / 1 days - 7` and use `e.chunks[i].day < cutoff` in both recycle() (line 276) and recyclable() (line 304). Every folded wei is then at least 7 days old (and at most 8 days less 1 s, the right side to err on for a 'nothing fresh is swept' rule). Merged from four specialists reporting the same cutoff.

**Reproduction**

Local PoolManager, hook at a 0x2844 address, coin/JIG pool (factory shape, 1% fee, sealed), past the snipe window. Warp to t = last second of a UTC day (t % 86400 == 86399). Buyer swaps exact-input 1000e18 JIG: creator credited 5e18 JIG; recyclable(key, creator) returns (stale 0, fresh 5e18). Warp to t + 6 days + 1 s (first second of day D+7). Expected: recyclable still reports it fresh and recycle(key, creator) reverts NotStale until t + 7 days. Actual: recyclable returns (stale 5000000000000000000, fresh 0) and recycle(key, creator) succeeds, returning 5e18 and folding it through the split 518_401 s after the credit. Reproduced in test/scratch/HookExtra.t.sol::test_recycle_before_7_days (log: 'recycled 5000000000000000000 elapsed 518401'); the harness needs FOUNDRY_OPTIMIZER_RUNS=44444 to compile v4-core's PoolManager locally.

### 4. Low: _creditEarned deletes the whole stale chunk array inside an unrelated swapper's transaction: ~5.2k gas per unclaimed trading day, 4.4M gas on one swap after 400 days

`src/CreatorFeeHook.sol:491`

```
        if (e.epoch != claimEpoch[to]) { e.epoch = claimEpoch[to]; delete e.chunks; e.head = 0; }
```

The round-4 ledger grows one Chunk (one storage slot) per calendar day per recipient per pool while the recipient does not claim; recycle() only advances `head` and never frees anything. When the recipient finally claims, or anyone calls the permissionless claimFor(recipient) (claimEpoch bump at line 325), the next fee credit for that recipient finds e.epoch != claimEpoch and runs `delete e.chunks`, zeroing every slot. That credit happens inside afterSwap, so the cost lands on whichever buyer or seller makes the first swap after the claim, not on the recipient who let the ledger grow. Measured: 400 daily buckets each on the creator and the flywheel, both claim, the next 1e18 JIG buy costs 4,426,898 gas versus 302,565 for the same buy one block later (EIP-3529 refunds are capped at 20% of the transaction, so most of it is real). A creator and flywheel that go two years without claiming make the next trade cost about 8M gas; a router that estimated gas before the claim landed runs out of gas, and the creator can repeat this on their own pool (claim, let the ledger grow, claim again) to make swaps intermittently fail. It is not profitable (buckets are per day, so dust credits cannot inflate the count faster than one per day) and it is bounded, so low. Fix: never delete on the hot path. Either key the ledger by epoch, `mapping(PoolId => mapping(address => mapping(uint64 => Earned)))` read at `claimEpoch[to]`, so a stale epoch is abandoned in O(1); or on epoch mismatch set `e.head = e.chunks.length` instead of deleting and keep pushing after the old chunks (recycle and recyclable already start at head). Merged from three specialists.

**Reproduction**

Same local harness (1% pool, flywheel = a wallet). One exact-input buy of 1e18 JIG per day for 400 days with neither creator nor flywheel claiming: storage read of earned[id][creator] and earned[id][flywheel] shows chunks.length == 400, head == 0 for both. Creator calls claim(), flywheel calls claim(). An unrelated buyer does an exact-input buy of 1e18 JIG. Expected: roughly the same gas as any other buy. Actual: 4,426,898 gas (vs 302,565 for the identical buy immediately after), because _split -> _creditEarned executes `delete e.chunks` over 800 slots; afterwards chunks.length == 1 and epoch == 1. Reproduced in test/scratch/HookExtra2.t.sol::test_chunk_count_and_delete_gas (needs FOUNDRY_OPTIMIZER_RUNS=44444 to compile PoolManager; note vm.warp in a loop must use vm.getBlockTimestamp() under via-IR, which caches block.timestamp).

### 5. Info: claimFor(address) lets anyone reset a creator's or module's recycle ledger by paying them out, so recycle() is best-effort, never guaranteed

`src/CreatorFeeHook.sol:325`

```
        claimEpoch[to]++; // per-pool recycle entries from before this claim no longer count
```

claimFor is permissionless by design (PotVault and the deepening module cannot call claim() themselves). A side effect is that anyone can call claimFor(creator) in the block before a recycle() would fold the creator's stale balance: the balance is paid to the creator and the epoch bump makes recycle() revert NotStale. Funds can only ever reach the credited address, so nothing is lost or misdirected; but the README's economics ('a stale creator balance feeds the flywheel, a stale flywheel balance feeds the pot') is a liveness backstop against balances nobody pushes, not an enforceable redistribution. No change required; if the team wants recycling to be unavoidable, claimFor must be restricted to recipients that cannot call claim() themselves (pot, deepening) and the creator/flywheel left to claim() only.

**Reproduction**

Same local harness. Creator credited 5e18 JIG by a 1000e18 buy; warp 8 days; recyclable(key, creator) returns stale > 0. A stranger calls hook.claimFor(creator): creator's JIG balance rises by 5e18. Then hook.recycle(key, creator). Expected per README: stale balance folded through the split. Actual: reverts NotStale (earned[id][creator].epoch != claimEpoch[creator]). Reproduced in test/scratch/HookExtra2.t.sol::test_claimFor_blocks_recycle.

---

Judge's submission `e97597ddc83e86c2f75ba3b5e8ba5f659bf8d2ef2d01ac0ee9bbda0b141c6ee8`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
