# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit (Foundry project: src/, test/, script/, README.md; OpenZeppelin 5.1 and Uniswap v4 core/periphery are the only dependencies, installed with forge). Read README.md first: it describes every contract, the fee split, the launch plan and the design decisions an auditor should know. Read the Solidity, not just the README. This is the second round: the first round (job fbe44d90) found a dust-order fee-evasion High in CreatorFeeHook._sellCoinForJig plus pull-pattern payouts, exact dev-buy refund, exact-tick boundary, PotVault.notifyDeposit and a HolderDrip underflow; all are fixed in this commit (see swarm-audit-report.md and README.md). Verify each fix holds and look for anything new the fixes introduced, then do the full scopes below. SCOPE A (whole base): SCOPE: the whole repository. Threat model: (a) nobody can remove or move the locked LP positions held by JIGLaunch, CoinFactory or LPDeepening; (b) nothing leaves PotVault or AirdropClaim except through declared/merkle distributions; (c) JIG and CreatorCoin supply cannot be increased; (d) Vesting cannot be claimed early or redirected; (e) JIGLaunchHook: nobody gets the 1% fee during the 10-minute window without being on the allowlist, and the hook cannot brick the pool; (f) any owner, keeper or factory privilege that could take user funds. Also check: single-sided seeding maths in JIGLaunch and CoinFactory for both currency orderings; CREATE2 hook address flag assumptions; reentrancy on every claim/pull/run path. SCOPE B (CreatorFeeHook in depth; this is where the money is): SCOPE: src/CreatorFeeHook.sol in depth (with CoinFactory.sol and CreatorCoin.sol for context). This hook handles every creator coin's fees. Threat model: (a) a swapper paying less than the current fee, including via exact-output swaps, hookData tricks, or the nested conversion swap; (b) the _converting guard: can a reentrant or nested call skip the fee or double-credit; (c) ERC-6909 claim accounting: can claimable balances ever exceed what the hook holds, can anyone claim another's balance, can totalClaimable drift; (d) the nested coin->JIG swap: price manipulation, sandwiching the conversion, pools that cannot absorb the amount, dust left as coin claims; (e) register/lowerFee/setFactory/setDeepening access control; (f) the anti-snipe decay arithmetic; (g) the fee-band and split arithmetic (sum must equal the fee, no overflow at 10% on large swaps); (h) hook permission flags vs. the address bits. Give exact exploit transactions where you find anything. SCOPE C (factory and modules): SCOPE: src/CoinFactory.sol, src/HolderDrip.sol, src/SweepAndBurn.sol, src/BuybackAndBurn.sol, src/LPDeepening.sol, src/AirdropClaim.sol, src/nft/LoomCollection.sol (v2 changes only: the mint(quantity, referral) path and REFERRAL_FEE_SHARE). Threat model: (a) CoinFactory: can a launch leave the pool, vesting or airdrop in an inconsistent state; can the 90/5/5 split be bypassed; ordering of coin vs JIG address handled correctly for price and range checks; LP locked; (b) HolderDrip: per-token accrual correctness when supply changes, double claims, non-owners; (c) SweepAndBurn: can the keeper extract value beyond overpaying for a real NFT; can a malicious marketplace call reenter; the JIG->ETH swap and ETH handling; (d) BuybackAndBurn and LPDeepening: unlock callbacks callable only by the PoolManager, settle/take correctness, leftover balances; (e) AirdropClaim: owner powers, expiry/sweep, per-coin isolation; (f) LoomCollection v2: fee conservation with the referral, reentrancy via referral receiver, referral == platform/zero cases. For every finding: contract, function, concrete exploit scenario with a Foundry reproduction where possible, and a concrete code fix. Answer every threat-model item above explicitly yes/no with reasoning, and note anything that would break on an L2 such as Robinhood Chain. Be specific; no generic advice; if something is fine say so and why.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `2b03ffed032ac684761ec4da129b9a48f8c2bb65` |
| Job | `489901b6-03f3-472d-ba18-a0195cbaf7a4` |
| Judged | 2026-10-16 06:23 UTC |
| Findings | 3 medium · 3 low · 4 info |

Four agents audited the code as it is at `2b03ffe`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Medium: CreatorFeeHook: an exact-output sell values the coin fee at the post-trade price, so a large seller pays about half the fee an exact-input sell pays

`src/CreatorFeeHook.sol:348`

```
        if (feeIsCoin) jigAmount = _sellCoinForJig(key, c, fee);
```

On a sell with exact JIG output (amountSpecified > 0, specified currency = JIG) the unspecified currency is the coin, so afterSwap takes fee = abs * f / (PIPS - f) in coin (line 338) and _sellCoinForJig sells it into the same pool at the price the seller's own trade just left (bounded to the launch range since the first-round fix, which stops the dust-order capture but not this). The coin fee is therefore valued at the marginal post-trade price instead of the trade's average price, and the shortfall grows with the seller's price impact. The equivalent exact-input sell takes f of the JIG output directly and has no such loss. Every router offers both shapes, so a seller unwinding a large position simply chooses exact-output. Threat-model B(a) ('a swapper paying less than the current fee, including via exact-output swaps') is therefore still YES; B(d) is YES in the sense that the swapper's own outer trade sets the conversion price. The symmetric case (exact-input buy, fee in coin sold at an elevated post-buy price) overcharges the buyer, so a trader who buys exact-output and sells exact-output always lands on the cheap side. Fix (design-preserving): when the fee is taken in coin on a sell (params.amountSpecified > 0 and the unspecified currency is the coin), require the converted JIG to be at least the exact-input equivalent, jigOut >= uint256(params.amountSpecified) * feePips / (PIPS - feePips), and revert otherwise so routers fall back to exact-input; or refuse exact-output sells on creator-coin pools outright; or price the coin fee at the pre-trade sqrt price (needs BEFORE_SWAP and a re-mined address). Merged from audit_economics; reproduced here on a Sepolia fork with the project's own factory and hook.

**Reproduction**

Fork harness test/scratch/Verify.fork.t.sol::test_exact_output_sell_pays_less_fee (forge test --match-path test/scratch/Verify.fork.t.sol --match-test exact_output -vv, rpc 'sepolia' from foundry.toml). State: coin launched through CoinFactory.launch at 1 coin = 1 JIG, feePips 10_000, 900M coin seeded single-sided over the launch range, snipe window over. Buyer spends 804M JIG exact-input and receives 426,452,632 coin. Path A: exact-input sell of all 426.45M coin via PoolSwapTest: seller nets 781,554,153 JIG, hook credits 7,894,486 JIG (1.0%), pendingCoin 0. Path B (same snapshot): amountSpecified = +781,554,153e18 (exact JIG out), zeroForOne = coinIs0, limit at the extreme, empty hookData: seller nets the identical 781,554,153 JIG, pays 423,007,052 coin in total, and the hook credits only 4,366,508 JIG, pendingCoin 0. Expected: both shapes pay about the same 1% (7.9M JIG). Actual: exact-output pays 55% of it; the assertion 'ratio B/A pct >= 95' fails with 55 < 95.

### 2. Medium: LPDeepening.run never collects the position's accrued LP fees first: INCREASE_LIQUIDITY compounds them into locked liquidity (team/pot never paid) or reverts with DeltaNotNegative when the fees exceed

`src/LPDeepening.sol:116`

```
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
```

README line 155 and the contract header (line 27) promise that the deepening position's LP fees go half to the team and half to the pot via collectFees(). But run() (keeper-only, at times the back end chooses) adds liquidity to the existing position with INCREASE_LIQUIDITY + SETTLE_PAIR + SWEEP without collecting first. In the vendored PositionManager, _increase() calls poolManager.modifyLiquidity, whose callerDelta = principalDelta + feesAccrued (lib/v4-periphery/lib/v4-core/src/PoolManager.sol:171); the slippage check runs on the principal only (PositionManager.sol:302) and SETTLE_PAIR settles _getFullDebt, i.e. the principal net of the accrued fees. Two outcomes, same root cause: (1) fees smaller than the run's contribution are consumed as part of the new liquidity; the module keeps an equal amount of its own ETH/JIG as 'working balance' and reinvests it next run, so every fee that accrued between the last collectFees() and a run() is permanently locked instead of paid, and the Deepened event / totalEthAdded / totalJigAdded understate the deposit by the fee amounts; (2) fees larger than the run's contribution in either currency leave a positive delta, and SETTLE_PAIR's _getFullDebt reverts with DeltaNotNegative(currency) (DeltaResolver.sol:63), so run() is unusable until someone calls collectFees() (recoverable, but nothing in run() or the keeper docs orders it). Not an attacker path; it is the declared fee flow being diverted (threat-model A(f)). Fix: refactor collectFees() into an internal _collectFees() (both are nonReentrant, so run() must call the internal one) and call it at the top of run() when tokenId != 0, before `uint256 amount = jig.balanceOf(address(this))` on line 91, so the 50/50 split is paid first and the liquidity maths see only the module's own balance. After the fix a run following accrued fees (fe, fj) must leave platform and pot each fe/2 and fj/2 richer, and run() must not revert whatever the fee size. Merged from audit_math; the revert case is new from this review.

**Reproduction**

Fork harness test/scratch/Verify.fork.t.sol::test_deepening_run_compounds_accrued_fees. State: JIGLaunch pool live, LPDeepening run once (tokenId != 0, liquidity 33,220,618,325,414,395,812); five round-trip swaps on the JIG/ETH pool accrue 34,327,261,300,520 wei ETH and 12,215 JIG of fees to the deepening position (measured by collectFees() on a snapshot, then reverted). Nobody calls collectFees(). Step (i): keeper calls run(1) with 10,000 JIG in the module -> reverts with 0x3351b260 = DeltaNotNegative(JIG) because the accrued JIG fee exceeds the 5,000 JIG the run adds. Step (ii): with 3,010,000 JIG in the module, run(1) succeeds; expected pot +fe/2,+fj/2 and platform +fe/2,+fj/2 (or at least the fees still collectable afterwards); actual: pot gained 0 ETH / 0 JIG, platform gained 0 / 0, liquidity grew to 107,241,588,837,783,422,363, the module is left holding exactly the fee ETH (34,327,261,300,520 wei) as 'working balance', and a collectFees() straight after run() pays the pot 0 ETH and 0 JIG: the fees were folded into the locked position. The assertion 'fees accrued before run() never reach pot/platform: 0 <= 0' fails.

### 3. Medium: JIGLaunchHook: the 60% sniper tax is an LP fee, so a sniper who LPs a JIG band under the price earns a large part of their own tax back (measured: 40% of the tax rebated, effective tax about 36%)

`src/JIGLaunchHook.sol:142`

```
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
```

beforeSwap returns the 60% outsider fee as an LP fee override. v4 pays LP fees pro rata to every position in range, and the hook has no liquidity permissions (getHookPermissions: beforeAddLiquidity false, address flags 0x2080 = BEFORE_INITIALIZE | BEFORE_SWAP), so anyone may add a position during the window. JIGLaunch spreads its JIG over a very wide range below the start tick (tickLower -887_200 to the start tick in the fork tests), so its liquidity per tick is small; a 200-tick JIG-only band directly below the current price needs only about 1% of that JIG for equal in-range liquidity. An outsider who buys JIG once at 60% (or is given JIG by an allowlisted friend), mints such a band, then buys through it, splits their own 60% with JIGLaunch in proportion to liquidity, and withdraws the band after the window. With a band of about 9M JIG against 900M full-range the outsider's share is about half, so their second tranche costs about 30% and the pot/team receive half the sniper tax the README promises. The README's residual-trust note ('third parties can LP into the JIG pool and share its fees with the pot') does not cover this, which is threat-model A(e)'s subject. Severity medium: the sniper tax is the launch's main protection (threat-model A(e)), the band needs only a fraction of one 60% tranche's JIG (18% of it in the run below, less with a narrower band), it can be funded with JIG bought from an allowlisted friend at 1.5%, and each rebated tranche funds a larger band, so the effective tax falls further with repetition; the window being 5 minutes is the only limit. Fix options (scope decision): add BEFORE_ADD_LIQUIDITY (re-mine the address) and refuse liquidity from anyone but JIGLaunch until windowEnd; or take the outsider surcharge as a hook delta credited to the pot (BEFORE_SWAP_RETURNS_DELTA) and leave only 1.5% as LP fee. From audit_economics; reproduced here on a Sepolia fork with the project's JIGLaunch, JIGLaunchHook and the v4 test routers.

**Reproduction**

Fork harness test/scratch/SniperLP.fork.t.sol::test_sniper_lps_a_band_and_earns_own_tax_back (forge test --match-path test/scratch/SniperLP.fork.t.sol -vv). State: JIGLaunch.launch with the hook at flags 0x2080, allowlist root set, window open, pool at tick 202_400 with 900M JIG single-sided; the sniper is not allowlisted and passes empty hookData. Tranche 1: sniper buys with 1 ETH at 60% and receives 193,475,348 JIG; tick moves to 197,559; the pool's in-range liquidity (all JIGLaunch's) is 36,257,853,589,337,433,604,457. Tx: sniper mints through PoolModifyLiquidityTest a JIG-only band [196_400, 197_400] (five spacings directly below the price) with liquidityDelta equal to JIGLaunch's, costing 34,183,066 JIG (18% of tranche 1); nothing refuses it (no liquidity hook permissions). Tranche 2: sniper buys with 1 ETH again; beforeSwap returns 600_000 | OVERRIDE, 0.6 ETH is charged as LP fee; the price crosses the band down to 194,533. After windowEnd the sniper removes the band: net ETH spent on tranche 2 is 759,607,886,060,582,140 wei, i.e. 240,392,113,939,417,860 wei (40% of the 0.6 ETH tax) came back as the band's LP fees, and the sniper still received 99,176,800 JIG. Expected per README line 25: a non-allowlisted wallet pays 60% to the locked LP (pot/team). Actual: the sniper's effective tax on tranche 2 is about 36% and the pot/team position earned only 60% of the sniper tax. The assertion 'sniper should not get a material part of the 60% tax back: 240392113939417860 >= 50000000000000000' fails.

### 4. Low: LPDeepening.run spends ETH booked as platformOwedEth into the locked position, so withdrawPlatform reverts or is paid from later working capital

`src/LPDeepening.sol:123`

```
        posm.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);
```

collectFees() books the team's half as platformOwedEth when the push to platform fails (line 150) and leaves that ETH in the module. run() sizes the liquidity with address(this).balance (line 102), passes uint128(address(this).balance) as amount0Max (lines 113/117) and sends the whole balance as msg.value (line 123), with no deduction for platformOwedEth. In the normal regime (the 1.5% LP fee on the JIG sale makes ETH the scarce side of the add) the owed ETH is consumed by the permanent full-range position; the ledger still says the platform is owed it, so withdrawPlatform() reverts with PayoutFailed until a later run leaves ETH behind, and then pays the team out of that run's working capital. JIGLaunch._payout handles the same situation correctly with `eth = address(this).balance - platformOwedEth` (JIGLaunch.sol:146). Precondition: the immutable platform address rejects a plain ETH call at collect time. No third-party loss. Fix: in run(), compute `uint256 eth = address(this).balance - platformOwedEth;` and use it for getLiquidityForAmounts, amount0Max and the call value, keeping SWEEP for refunds. Merged from audit_flow and audit_economics (same defect, same fix).

**Reproduction**

Fork harness test/scratch/Verify.fork.t.sol::test_deepening_run_spends_platform_owed_eth. State: platform is a contract whose receive() reverts; LPDeepening has run once; five round-trip swaps accrue fees. (1) collectFees(): pot receives its half, the platform push fails, platformOwedEth = 17,163,630,650,260 wei and address(deep).balance = 17,163,630,650,260 wei (the module's whole ETH). (2) keeper calls run(1) with 3,000,000 JIG in the module. Expected: the owed ETH stays reserved, module balance >= platformOwedEth afterwards. Actual: module balance after run is 0 while platformOwedEth is still 17,163,630,650,260: the owed ETH went into the position. The platform (now accepting ETH) calling withdrawPlatform() reverts with PayoutFailed; the test's final assertion 'owed ETH was put into the locked position' fails.

### 5. Low: SweepAndBurn.sweep: the JigMoved guard uses != and so also fires on a JIG inflow, letting anyone paid during the marketplace call veto the sweep with hook.claimFor(module)

`src/SweepAndBurn.sol:126`

```
        if (jig.balanceOf(address(this)) != jigAfterSwap) revert JigMoved();
```

The guard is meant to stop JIG from leaving the module during the marketplace call (header comment: 'JIG may only leave through the swap') but tests strict inequality. CreatorFeeHook.claimFor(address) is permissionless (CreatorFeeHook.sol:284) and pushes the module's pending flywheel slice into its balance, and sweep() does not pull first (it budgets from jig.balanceOf(this)). Real marketplaces execute counterparty code inside a fulfil call (the seller's payable fallback, royalty receivers, Seaport zones), so a seller can include hook.claimFor(sweepModule) and the sweep reverts after the ETH was sent and the NFT received (all rolled back, no funds lost). The module can be kept unsweepable as long as it has a non-zero claimable balance in the hook, which is the normal state between pulls; a one-wei swap on the coin pool re-credits it before each attempt. Impact: griefing of specific sweeps and wasted keeper gas. Fix: `if (jig.balanceOf(address(this)) < jigAfterSwap) revert JigMoved();` (an inflow is harmless), and optionally call hook.claim() at the top of sweep() so nothing is left to push. Merged from audit_flow and audit_permissions; the attached proof is audit_permissions', run here and failing for the stated reason.

**Reproduction**

test/scratch/SweepJigMoved.t.sol (no fork). State: SweepAndBurn with an approved marketplace, maxPriceWei = 1 ether, 1 ether of ETH already held (jigToSell = 0 path, no pool involved), a real listing of tokenId 7 at 0.5 ether. Keeper calls sweep(market, buy(7), 7, 0.5 ether, 0, 0); during market.buy the module's JIG balance rises by 1 wei. Expected: NFT 7 is bought and sent to 0xdEaD, burned() == 1. Actual: `forge test --match-path test/scratch/SweepJigMoved.t.sol` fails with [FAIL: JigMoved()]; the test passes once line 126 compares with <.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SweepAndBurn} from "src/SweepAndBurn.sol";

contract TokenMock is ERC20 {
    constructor() ERC20("JIG", "JIG") { _mint(msg.sender, 1e27); }
}

contract NftMock is ERC721 {
    constructor() ERC721("N", "N") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// Stands in for CreatorFeeHook: SweepAndBurn only reads jig() and poolManager() from it in the constructor.
contract HookStub {
    IERC20 public jig;
    address public poolManager = address(0xBEEF);
    constructor(IERC20 j) { jig = j; }
}

/// An approved marketplace. While the module is paying for a real listing, the module's JIG balance goes UP by
/// 1 wei (here a plain transfer; on the live system the seller's receive() calls hook.claimFor(module), which
/// anyone may do and which needs no JIG of their own).
contract Market {
    NftMock nft; TokenMock jig; address seller;
    constructor(NftMock n, TokenMock j, address s) { nft = n; jig = j; seller = s; }
    function buy(uint256 id) external payable {
        nft.transferFrom(seller, msg.sender, id);
        jig.transfer(msg.sender, 1);
        (bool ok,) = seller.call{value: msg.value}("");
        require(ok);
    }
}

contract SweepJigMovedTest is Test {
    /// Fails on the current code with SweepAndBurn.JigMoved: the "JIG may only leave through the swap" check
    /// is `!=`, so an inflow of 1 wei blocks a legitimate sweep. Passes once the check is `<`.
    function test_sweep_survives_a_jig_inflow_during_the_marketplace_call() public {
        TokenMock jig = new TokenMock();
        NftMock nft = new NftMock();
        HookStub hook = new HookStub(jig);
        address owner = makeAddr("owner");
        address keeper = makeAddr("keeper");
        address seller = makeAddr("seller");
        PoolKey memory k = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(jig)), 0x800000, 200, IHooks(address(0)));
        SweepAndBurn s = new SweepAndBurn(address(hook), address(nft), owner, keeper, k, 1 ether);
        Market m = new Market(nft, jig, seller);
        jig.transfer(address(m), 1);
        nft.mint(seller, 7);
        vm.prank(seller); nft.setApprovalForAll(address(m), true);
        vm.prank(owner); s.setMarket(address(m), true);
        vm.deal(address(s), 1 ether); // ETH already held: jigToSell = 0 path, no pool involved

        vm.prank(keeper);
        s.sweep(address(m), abi.encodeCall(Market.buy, (7)), 7, 0.5 ether, 0, 0);

        assertEq(nft.ownerOf(7), s.DEAD(), "a real listing at half the cap must be bought and burned");
        assertEq(s.burned(), 1);
        assertEq(jig.balanceOf(address(s)), 1, "the inflow stays in the module; nothing left it");
    }
}
```

### 6. Low: DeployCoins defaults the factory's airdrop recipient to PotVault, which cannot accept notify(), so every launch reverts and the hook's one-shot setFactory is consumed by a dead factory

`script/DeployCoins.s.sol:30`

```
        address airdrop = vm.envOr("AIRDROP", pot);
```

CoinFactory.launch (src/CoinFactory.sol:146) calls IAirdropNotify(airdropRecipient).notify(coin) for any recipient with code; that is the first-round fix for a mis-bound AirdropClaim. The deploy script falls back to the PotVault address when AIRDROP is unset (the script header lists AIRDROP as optional, 'default POT'). PotVault has code but exposes only receive() (src/PotVault.sol:49) and no fallback or notify, so the call reverts and launch() reverts for every creator after the pool was registered and seeded in the same transaction (all rolled back). airdropRecipient is immutable in the factory and hook.setFactory is one-shot (script line 39 calls it unconditionally), so the CreatorFeeHook deployed in that run is permanently bound to a factory that cannot launch anything; both must be redeployed with a new CREATE2 salt. Even if notify were accepted, the 5% airdrop share would have no distribution path out of PotVault (it only pays declared merkle trees of JIG the owner chooses). Fix: use vm.envAddress('AIRDROP') with no default, and have the CoinFactory constructor probe the recipient once (e.g. a staticcall to AirdropClaim.pot() or drops(address)) so a wrong recipient fails at deploy time rather than at every launch. Verified by reading; merged from audit_permissions.

**Reproduction**

Run `forge script script/DeployCoins.s.sol` with JIG and POT set and AIRDROP unset: airdrop = pot (line 30), CoinFactory(... airdropRecipient = pot ...) at line 38, hook.setFactory(factory) at line 39. Then any creator calls factory.launch(params) with the exact launch fee. Expected: a coin, pool and airdrop share. Actual: revert at CoinFactory.sol:146, because `IAirdropNotify(pot).notify(coinAddr)` hits PotVault, which has only receive() and no notify/fallback; hook.factory() is already set and cannot be changed (CreatorFeeHook.sol:161 reverts FactorySet).

### 7. Info: README contract table and the audit brief say a 10-minute window at 1%; the code and the launch-plan table say 5 minutes at 1.5%

`src/JIGLaunchHook.sol:37`

```
    uint64 public constant WINDOW = 5 minutes;
```

README line 15 ('for 10 minutes after the pool opened, allowlisted tx.origin pays 1%') and the residual-trust note at line 115 ('10-minute windows') disagree with README line 25 and the code (WINDOW = 5 minutes, NORMAL_FEE = 15_000). The code is internally consistent and matches the launch plan, so this is a documentation defect, but an allowlisted friend relying on the table would expect protection in minutes 5-10 they do not have. Fix: correct README lines 15 and 115 (or change the constants if 10 minutes is the agreed value). Merged from audit_flow and audit_permissions.

**Reproduction**

Read src/JIGLaunchHook.sol:35-37 (NORMAL_FEE 15_000, WINDOW 5 minutes) against README.md:15. quoteFee(account, proof) returns NORMAL_FEE for everyone from windowEnd = initialise time + 300 s, never 10_000.

### 8. Info: src/nft/LoomCollection.sol is not in the tree: scope C(f) could not be audited, and HolderDrip's over-claim fix rests on the collection minting sequential ids from 1

`src/HolderDrip.sol:95`

```
            if (checkpoints[mid].supply >= tokenId) hi = mid;
```

The brief lists src/nft/LoomCollection.sol (mint(quantity, referral), REFERRAL_FEE_SHARE) under scope C, but the repository has no src/nft directory; README line 138 says the collection stays as written at an earlier launch and the v2 referral was dropped. HolderDrip._baseline binds a token to the first checkpoint whose recorded totalSupply is >= tokenId, which is only the checkpoint taken after the token existed if ids are 1..totalSupply (README line 115 records this requirement). With 0-based ids the token minted when supply goes n -> n+1 has id n and inherits the accBefore of a pull taken at supply n, reopening the first-round over-claim. HolderDrip also depends on totalSupply never decreasing and on ownerOf() returning 0xdEaD for burned tokens (markBurned only recognises that), and SweepAndBurn on transferFrom to 0xdEaD being allowed. None of this could be verified here. Recommended: commit LoomCollection so the next round can audit it, and enforce the id assumption in code (e.g. store the collection's first id and compare `supply >= tokenId - firstId + 1`). Merged from audit_flow and audit_permissions.

**Reproduction**

`ls src/nft` on the pinned commit: no such directory. Arithmetic case: ids 0..3, pull() of 400 JIG writes checkpoint {supply 4, accBefore 0}; mint id 4; owed(4): binary search finds checkpoints[0].supply (4) >= 4, baseline 0, owed 100 JIG for a token that did not exist at the pull. With ids 1..4 the same search returns lo == n and owed(5) == 0.

### 9. Info: L2 (Robinhood Chain / Arbitrum Orbit) deployment notes: CREATE2 proxy presence, tx.origin allowlist with smart wallets, sequencer timestamps, missing v4 addresses

`script/DeployCoins.s.sol:18`

```
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
```

Nothing in the Solidity breaks on an Arbitrum-style L2, but: (1) both hooks are CREATE2-mined through the deterministic deployment proxy; if an Orbit chain lacks it, the deployment either reverts in Hooks.validateHookPermissions or fails the `address(hook) == predicted` require (fail-closed, but the script should pre-check `CREATE2_DEPLOYER.code.length > 0`). (2) JIGLaunchHook keys the allowlist to tx.origin; friends using ERC-4337 or Safe wallets pay 60% (README line 29 documents this). (3) CreatorFeeHook.SNIPE_WINDOW (10 s) and JIGLaunchHook.WINDOW (5 min) use the sequencer's block.timestamp, which can lag wall-clock and is coarse; the 10-second decay may span 0 to tens of blocks. (4) _v4() in the scripts has only Sepolia addresses; the target chain's PoolManager, PositionManager and Permit2 must be added and the PositionManager version checked for the zero-liquidity DECREASE_LIQUIDITY fee-collection path used by JIGLaunch.collectFees and LPDeepening.collectFees (works on the pinned v4-periphery). Merged from audit_flow and audit_economics.

**Reproduction**

On a chain without code at 0x4e59b44847b379578588920cA78FbF26c0B4956C, `forge script script/DeployCoins.s.sol --broadcast` computes `predicted` from that proxy (line 58) but the mined salt yields a different address without the flag bits, so the constructor reverts with HookAddressNotValid or line 37 reverts 'hook address mismatch'. Any other chain id reverts at _v4() with 'v4 addresses not set for this chain'.

### 10. Info: Threat-model answers for scopes A, B and C; first-round fixes verified to hold

`src/CreatorFeeHook.sol:44`

```
contract CreatorFeeHook is IHooks, IUnlockCallback, ReentrancyGuard {
```

FIRST-ROUND FIXES: all present in the source and confirmed by the specialists' local harnesses and the repository's Regressions tests: _sellCoinForJig bounds the nested sale at the launch-range edge and parks the fee as pendingCoin when the spot is at or beyond it (lines 364-369); JIGLaunch._payout and LPDeepening.collectFees pay the pot first and book a failed platform push as platformOwedEth; CoinFactory._devBuy refunds exactly jigIn - spent (CoinFactory.sol:180); CoinFactory.sol:135 accepts tickLower == startTick only at the exact tick price; PotVault.notifyDeposit is gone; HolderDrip guards live = supply > burnedCount ? supply - burnedCount : 0. NEW FROM THE FIXES: the range bound converts the coin fee at the post-trade price inside the range, which is the exact-output-sell medium above; pendingCoin left by one swapper is converted inside a later swapper's transaction and credited through the pool's split at that time, which is benign. SCOPE A: (a) NO: JIGLaunch, CoinFactory and LPDeepening expose no transfer/approve/decrease path; collectFees decreases 0 liquidity then TAKE_PAIR. (b) NO: PotVault moves tokens only in claim() against a declared root inside reserved[]; AirdropClaim only to proven leaves or the pot. (c) NO: JIG and CreatorCoin mint once in their constructors; only ERC20Burnable. (d) NO: Vesting.release pays only s.beneficiary, vested() is monotone in time, nothing revocable. (e) Fee: NO for the 1.5% (a proof for tx.origin against a root frozen before initialisation is required), with the LP-rebate low above halving the tax for a sniper who LPs; bricking: NO, beforeSwap only reverts on malformed caller-supplied hookData and beforeInitialize accepts exactly one pool from JIGLaunch. (f) Privileges: hook owner binds factory/deepening once; the three merkle owners author trees but cannot withdraw; the platform sets the launch fee; SweepAndBurn owner (markets, cap) and keeper (listing, minimum out) together could buy their own listing at the cap; keepers choose minimum-out. None moves user balances to a privileged address; all are documented trust. Single-sided seeding: correct for both orderings (CoinFactory.sol:135 and _seed's amount0Max/amount1Max; JIGLaunch's range must sit below the start tick). CREATE2 flags: 0x2044 and 0x2080 match the permission structs and are enforced by validateHookPermissions in both constructors; register() refuses keys whose hooks field is not the hook. Reentrancy: every claim/pull/run/sweep path is nonReentrant; the hook's claim cannot run inside a swap (PoolManager.unlock reverts AlreadyUnlocked); JIG and CreatorCoin have no transfer hooks. SCOPE B: (a) YES, the exact-output-sell medium; exact-input swaps and exact-output buys pay f exactly (fee = f*output, or f/(1-f)*input), hookData is ignored. (b) NO: _converting is set only around poolManager.swap, whose only external call is this hook's own afterSwap. (c) NO: every credit is matched by a JIG claim mint, recycle is net-zero on totalClaimable, _claim pays only the credited address, and heldJig == totalClaimable held after every swap shape in the specialists' probes. (d) Bounded to the range; sandwiching changes the sale price but never below the range bottom; a pool that cannot absorb keeps pendingCoin; the swapper's own trade setting the conversion price is the medium above. (e) register factory-only, lowerFee/setCreatorShare creator-only, setFactory/setDeepening owner-only one-shot: correct. (f) currentFee decays monotonically from 600_000 to feePips with no overflow in uint24. (g) potA + deep + plat + creator + fly == amount by construction; at 10% on a 2^100 swap the fee fits int128. (h) exact match. SCOPE C: (a) CoinFactory.launch is atomic; 90/5/5 enforced by SUPPLY - AIRDROP_SHARE - creatorTokens with creatorBps <= 500; LP locked in the factory; ordering handled at lines 123-135. (b) HolderDrip correct for 1-based sequential ids (info above). (c) SweepAndBurn keeper bounded to an approved market, the cap, no JIG outflow a

**Reproduction**

Summary entry, not a defect. Each NO was traced in the source at the lines cited; each YES has its own finding above with a reproduction. Local fork runs in this review: test/scratch/Verify.fork.t.sol (three tests) and test/scratch/SweepJigMoved.t.sol.

---

Judge's submission `37b6815daeec67a50887fcdf3c0919bdabb634f937d100cad5855698f8cc13ee`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
