# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. This is the sixth round. Rounds 1-5 (jobs fbe44d90, 489901b6, 0c246e1d, ae115cf4, 374e2a1a) and every fix are tabled in README.md and swarm-audit-report*.md. Round 5 fixes in this commit: HolderDrip.pull books the full amount again (the round-4 floor change was reverted); CreatorFeeHook._convertBuyFee sizes its target from the specified-side delta (JIG actually spent) and on a partial fill charges max(fee, spent); recycle uses _staleCutoff (day <= today - 8, grace 7 to 8 days) and folds at most MAX_FOLD = 64 buckets per call; _creditEarned moves head instead of deleting chunks on an epoch change. Verify each holds, with the same rigour as round 5, on exactly these: HolderDrip solvency (sum of owed vs accounted vs balance across pulls, claims, markBurned and late mints); every swap shape through _convertBuyFee including price-limited partial fills, limit exactly at the range edge, spent > fee rounding, and pendingCoin retries, asserting heldJig == totalClaimable and that no swap reverts; recycle head/chunks across epochs, MAX_FOLD partial folds and recyclable() agreement. If, after a genuine attempt, nothing above Info remains, say so plainly. Then do the full scopes below. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, reference/LoomCollection.sol (reference copy, not compiled: check the 1-based sequential id, monotone totalSupply and transferFrom-to-dead assumptions HolderDrip and SweepAndBurn make). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection: do the id/supply/burn assumptions hold; anything in its owner powers or mint path that affects HolderDrip or SweepAndBurn. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `3a9f3d2825a6062e50055ca137c4af0081be6d78` |
| Job | `b47cb5dc-2046-4e16-91f7-0f07194b2c50` |
| Judged | 2026-10-16 11:09 UTC |
| Findings | 1 low · 3 info |

Four agents audited the code as it is at `3a9f3d2`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Low: HolderDrip.pull() spreads JIG that accrued before a mint over tokens minted just before the pull

`src/HolderDrip.sol:79`

```
        uint256 supply = collection.totalSupply();
```

pull() reads the collection's totalSupply at pull time and spreads everything undistributed (the hook's claimable[drip], which accrues continuously and is only moved by a permissionless pull) over every live token at that moment. A token minted after the slice accrued but before anyone pulled is counted in the checkpoint and takes a full per-token share of JIG earned while it did not exist. The module stays solvent (sum owed <= accounted <= balance); existing holders are diluted. Whoever times a mint right before a pull captures most of a large unpulled slice; on LoomCollection the owner's reserveMint costs nothing, and an onERC721Received receiver can call pull() mid-batch because _mintBatch increments totalSupply before minting. Fix (keeps the design): in pull() spread `amount` over the live supply recorded at the previous pull (store lastSupply; tokens minted since then start earning from the next pull), or have the collection's mint path call drip.pull() before it increments totalSupply.

**Reproduction**

test/scratch/DripTiming.t.sol (mock hook and LoomCollection-shaped collection, no fork): 4 tokens held; hook.claimable(drip) = 1000e18; a minter mints 96 tokens (ids 5..100), calls drip.pull(), claims ids 5..100. Expected under 'a token only earns while it existed': 0. Actual: 960e18 to the late minter, 40e18 to the 4 original holders. `forge test --match-path test/scratch/DripTiming.t.sol` fails: 960000000000000000000 != 0.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HolderDrip} from "src/HolderDrip.sol";

contract MockJig is ERC20 {
    constructor() ERC20("JIG", "JIG") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// Stands in for CreatorFeeHook: holds the drip's accrued flywheel slice and pays it on claim().
contract MockHook {
    MockJig public jig;
    address public pot = address(0xB0B);
    mapping(address => uint256) public claimable;
    constructor(MockJig j) { jig = j; }
    function accrue(address to, uint256 a) external { jig.mint(address(this), a); claimable[to] += a; }
    function claim() external returns (uint256 a) { a = claimable[msg.sender]; claimable[msg.sender] = 0; jig.transfer(msg.sender, a); }
}

/// LoomCollection's id/supply rule: ids 1..totalSupply, monotone counter.
contract MockCollection {
    uint256 public totalSupply;
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 q) external { for (uint256 i; i < q; i++) ownerOf[++totalSupply] = to; }
}

contract DripTimingTest is Test {
    MockJig jig;
    MockHook hook;
    MockCollection nft;
    HolderDrip drip;
    address holder = address(0xA11CE);
    address late = address(0x1A7E);

    function setUp() public {
        jig = new MockJig();
        hook = new MockHook(jig);
        nft = new MockCollection();
        drip = new HolderDrip(address(hook), address(nft));
        nft.mint(holder, 4);
    }

    function test_mint_before_pull_takes_earlier_accrual() public {
        // 1000 JIG of flywheel slice accrues on the hook while exactly 4 tokens exist
        hook.accrue(address(drip), 1000e18);
        // a minter mints 96 tokens, then calls the permissionless pull()
        vm.startPrank(late);
        nft.mint(late, 96);
        drip.pull();
        uint256[] memory ids = new uint256[](96);
        for (uint256 i; i < 96; i++) ids[i] = i + 5;
        uint256 got = drip.claim(ids);
        vm.stopPrank();
        uint256[] memory old = new uint256[](4);
        for (uint256 i; i < 4; i++) old[i] = i + 1;
        vm.prank(holder);
        uint256 kept = drip.claim(old);
        emit log_named_uint("late minter got", got);
        emit log_named_uint("original holders got", kept);
        // a token should only earn what accrued while it existed: the 96 late tokens existed for none of it
        assertEq(got, 0, "late tokens took JIG accrued before they were minted");
    }
}
```

### 2. Info: _staleCutoff() underflows when block.timestamp < 8 days, so recycle()/recyclable() panic instead of returning nothing stale

`src/CreatorFeeHook.sol:303`

```
        return uint64(block.timestamp / 1 days) - uint64(RECYCLE_AFTER / 1 days) - 1;
```

Checked subtraction of 8 from today's day number. On any chain with timestamp < 691200 (fresh anvil/forge chain) recyclable() reverts with panic 0x11 instead of (0,0) and recycle() panics instead of NotStale. No effect on Sepolia, mainnet or any live L2 (Robinhood Chain included) whose clock is ~1.7e9; only local harnesses are affected. Fix: in recycle()/recyclable(), treat `block.timestamp / 1 days <= 8` as 'nothing stale' (recycle reverts NotStale, recyclable returns (0, fresh-sum)) before computing the cutoff; a plain saturate-to-0 would make day-0 chunks immediately stale on such a chain.

**Reproduction**

test/scratch/StaleCutoff.t.sol: CreatorFeeHook deployed with deployCodeTo at 0xAA..2844, vm.warp(7 days), staticcall recyclable(key, any). Expected: (0,0). Actual: revert (panic 0x11).

### 3. Info: Exact-input buys too small to owe any JIG (target == 0) are still charged the coin fee, which credits nobody until a later buy sells it

`src/CreatorFeeHook.sol:423`

```
        if (target == 0 || (coinIs0 ? spot <= limit : spot >= limit)) {
```

When jigSpent * feePips / PIPS rounds to 0 but fee = coinOut * f is >= 1 (coin cheaper than JIG), _convertBuyFee takes the park branch: the buyer is charged `fee` coin, nothing is split, and the coin waits in pendingCoin. The next exact-input buy sells it first, under that later swap's split, and that buyer's `charge = spent` is measured after the parked sale moved the price. Accounting stays exact (heldJig == totalClaimable, coin claims == pendingCoin); amounts are dust. Fix: before the park check, `if (target == 0) { poolManager.burn(address(this), coin.toId(), fee); return (jigAmount, 0); }` so a buy that owes no JIG is charged no coin; keep parking only for the range-edge case.

**Reproduction**

Local PoolManager (FOUNDRY_OPTIMIZER_RUNS=44444444, test/scratch/HookShapes.t.sol::test_shapes_coin0 and _coin1), hook at 0x..2844, 1% pool, range [-46000, 46000] seeded single-sided at the coin edge, sealed, 11 s after launch. Five exact-input buys of 50 wei JIG: expected no charge; actual pendingCoin = 49 coin wei taken from buyers, totalClaimable stays 0. The next 1000e18 JIG buy sells it (pendingCoin back to 0). Both orderings.

### 4. Info: donate() is allowed on sealed creator pools; donated tokens accrue to CoinFactory's locked position, which has no collect path, and are lost

`src/CreatorFeeHook.sol:146`

```
            beforeDonate: false,
```

The hook does not gate donate, so once the price is in range anyone can PoolManager.donate to a creator pool. The donation becomes fee growth on the only position (CoinFactory's seed NFT); CoinFactory has no collect/decrease function, so nobody can ever withdraw it. Only the donor loses (e.g. a mistaken integration); hook accounting is unaffected. Fix if wanted: set beforeDonate (address bits 0x2844 -> 0x2864, redeploy hook via CREATE2 mining) and revert in beforeDonate, or add a CoinFactory fee-collect that pays out like LPDeepening._collectFees.

**Reproduction**

test/scratch/HookShapes.t.sol::test_donate_stuck (local PoolManager): after one 1000e18 JIG buy, PoolDonateTest.donate(key, 0, 1e18) succeeds and 1e18 JIG leaves the donor; CoinFactory exposes no function to recover it. Expected for a 'factory-only liquidity' pool: revert.

---

Judge's submission `68f4627d68dc635e83f0bd6f7d2e42c82ec551c03b6cb9abffb2ecd98a3afac3`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
