# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit: Solidity in src/ (Foundry; tests in test/, deploy scripts in script/, README.md describes every contract and every earlier round, including round 8's table), off-chain money paths in offchain/ (offchain/README.md). Round 9 is the check on round 8's fixes before a mainnet launch on Robinhood Chain (chain 4663). Round 8 (swarm-audit-report-8.md) found 1 high, 1 medium, 3 low, 5 info. VERIFY EACH FIX HOLDS AND HUNT FOR WHAT IT INTRODUCED (in earlier rounds the fixes themselves caused new issues):
> (1) High 1 fix: CoinFactory._excluded() now adds IAirdropPot(airdropRecipient).pot() as a fourth excluded address. Check the constructor's pot() probe and every launch path; any way the pot, or another protocol address that can never call CreatorCoin.claim() (AirdropClaim, the hook, flywheel modules such as HolderDrip, BuybackAndBurn, LPDeepening, RewardsForwarder, SweepAndBurn, PotVault), still earns rewards nobody can claim; what happens to rewards credited before an address is excluded.
> (2) Medium 2 fix: AirdropClaim.claimFor skips owners with code (owner.code.length != 0). Check constructor-time (code.length == 0 during construction) and EIP-7702 delegated EOAs, counterfactual smart wallets, griefing via a contract that later self-destructs or changes code, interaction with claim() and sweep(), and the off-chain side (offchain/rewards.mjs pushableIds now returns contractHeld; the keeper must never loop on them).
> (3) Low 3 fix: JigsawCollection.initialize reverts NothingToFreeze when freeze is set with an empty uri. (4) Low 5 fix: JigsawCollection.recoverOwnership(newOwner), callable only by Ownable(factory).owner() where factory is the msg.sender of initialize: check the factory address can never be spoofed (initialize is called only by JigsawCollectionFactory.create in the clone's creating transaction), what a compromised factory owner can now do to every clone, and Ownable2Step pending state.
> (5) Info 7 fix: CollectionLauncher.create reverts NothingToFreeze for freeze with revealLater. (6) Info 10 fix: RewardsForwarder.pull() with no new JIG calls coin.notifyReward(0) when the coin's carry > 0 and rewards are not paused: check it cannot restart or stretch a running stream (MIN_INTERVAL == DURATION), revert paths that would block pull(), and paused state.
> (7) Accepted (round 8 Low 4, Info 6, Info 9; reasons in README): say if you disagree.
> Report every finding with severity, file and line, a concrete exploit path and a minimal fix, and what you checked and cleared.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `840d2a198dd06e3ce901d656c42c5989a8a19765` |
| Job | `c68a3cd2-9cbd-48d9-998e-757eff7d6aa7` |
| Judged | 2026-10-18 11:03 UTC |
| Findings | 4 low · 2 info |

Four agents audited the code as it is at `840d2a1`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Low: Round 8 High 1 fix: _excluded() calls pot() on the airdrop recipient unconditionally, so an EOA recipient the constructor accepts makes every launch(), coinInitCodeHash() and predictCoin() revert

`src/CoinFactory.sol:251`

```
        e[3] = IAirdropPot(airdropRecipient).pot();
```

The round 8 fix appends IAirdropPot(airdropRecipient).pot() to _excluded(). The constructor probes pot()/factory() only when airdropRecipient_.code.length > 0 (lines 110-116), and launch() line 168 calls notify() only for a recipient with code, so a plain wallet recipient is an accepted configuration by the contract's own text (DeployCoins.s.sol also has a non-AirdropClaim branch). With such a recipient the high-level pot() call in _excluded() gets no return data and reverts while decoding the address. _excluded() runs inside launch() (line 139, the CreatorCoin constructor arguments) and inside coinInitCodeHash()/predictCoin() (lines 264, 269), so the factory can neither launch a coin nor predict an address; airdropRecipient is immutable and CreatorFeeHook.setFactory is once-only, so the hook bound to it is wasted too. The round 2 constructor guard exists precisely so that 'a wrong recipient would brick every launch' cannot happen; the round 8 fix reintroduces that class for the EOA case. No attacker: a deployment misconfiguration the constructor now silently accepts. The mainnet plan (script/go-day.sh) passes an AirdropClaim, so the live launch is not affected, hence Low. Checked and cleared on the same fix: coinInitCodeHash() shares _excluded() with launch() so the vanity grinder stays in step; AirdropClaim.pot is immutable so the excluded set cannot drift between prediction and launch; the pot, AirdropClaim, hook, pool manager, factory, DEAD and the coin are the only protocol addresses holding coin across transactions (BuybackAndBurn buys and burns in one call; LPDeepening, SweepAndBurn, HolderDrip and RewardsForwarder hold only JIG/ETH/NFTs; the position manager settles coin straight into the pool manager); exclusion is fixed in the coin constructor so no reward can be credited to an address before it is excluded, and earned()/_updateAccount() return 0/skip for excluded accounts. Minimal fix: either refuse an EOA recipient in the constructor (require airdropRecipient_.code.length > 0, so the pot() probe always runs) and store the probed pot in an immutable read by _excluded(); or, to keep wallet recipients, in _excluded() add pot() only when airdropRecipient.code.length > 0 and return a 3-entry list otherwise. Merged from four specialists (economics, permissions, math, flow).

**Reproduction**

State: new CoinFactory(posm, permit2, hook, jig, platform, airdropRecipient = makeAddr('airdropWallet'), 0) succeeds (code.length == 0 skips lines 110-116). Input: factory.predictCoin(collection, 'Coin', 'C', bytes32(bytes20(collection))), then factory.launch(p) from collection.creator() with a valid LaunchParams. Expected: both succeed and the wallet receives 50,000,000e18 coin without notify() (line 167-168 is written for exactly this recipient), or the constructor reverts BadAirdropRecipient. Actual: predictCoin, coinInitCodeHash and launch all revert with empty data from the pot() call in _excluded(). Reproduced: forge test --match-path test/scratch/EoaAirdropRecipient.t.sol (the flow specialist's proof) fails on this code with 'predictCoin() reverts for an EOA airdrop recipient: _excluded() calls pot() on an account without code' (run in a mirror of the repo with lib/ installed; lib/ is not in the audit repo). It passes once the constructor refuses an EOA recipient or _excluded() guards the call.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CoinFactory} from "src/CoinFactory.sol";

/// Answers every call with 32 zero bytes: stands in for the position manager, permit2, the fee hook and JIG so that
/// CoinFactory.launch() runs its real coin creation and its real _excluded() list.
contract Yes {
    fallback() external payable { assembly { mstore(0, 0) return(0, 32) } }
}

contract SCollection {
    address public creator;
    uint256 public maxSupply = 100;
    constructor(address c) { creator = c; }
}

/// Round 8 High 1 fix: _excluded() calls IAirdropPot(airdropRecipient).pot() on every launch and in every
/// coinInitCodeHash()/predictCoin(). The constructor only probes pot() when the recipient has code, so an EOA
/// recipient (a plain wallet, which launch() line 168 explicitly supports) is accepted and then every launch and
/// every prediction reverts: the factory is dead on arrival and the hook, bound once by setFactory, with it.
contract EoaAirdropRecipientTest is Test {
    address creator = makeAddr("creator");

    function test_eoa_airdrop_recipient_is_refused_or_launches_work() public {
        Yes posm = new Yes(); Yes permit2 = new Yes(); Yes hook = new Yes(); Yes jig = new Yes();
        address wallet = makeAddr("airdropWallet"); // an EOA airdrop recipient
        CoinFactory f;
        try new CoinFactory(address(posm), address(permit2), address(hook), address(jig), makeAddr("platform"), wallet, 0) returns (CoinFactory f_) {
            f = f_;
        } catch {
            return; // the constructor refused the EOA recipient: consistent, nothing more to check
        }
        // the constructor accepted it, so the factory must be usable with it
        SCollection col = new SCollection(creator);
        bytes32 salt = bytes32(bytes20(address(col)));
        (bool ok,) = address(f).staticcall(abi.encodeCall(f.predictCoin, (address(col), "Coin", "C", salt)));
        assertTrue(ok, "predictCoin() reverts for an EOA airdrop recipient: _excluded() calls pot() on an account without code");
        address predicted = f.predictCoin(address(col), "Coin", "C", salt);
        bool coinIs0 = predicted < address(jig);
        CoinFactory.LaunchParams memory p = CoinFactory.LaunchParams({
            collection: address(col), name: "Coin", symbol: "C", feePips: 10_000, flywheel: address(0), creatorShareBps: type(uint16).max,
            creatorBps: 0, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0, salt: salt,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0), tickLower: coinIs0 ? int24(0) : int24(-200), tickUpper: coinIs0 ? int24(200) : int24(0)
        });
        vm.prank(creator);
        (, address coinAddr) = f.launch(p);
        assertEq(coinAddr, predicted);
    }
}
```

### 2. Low: Round 8 Low 3 was fixed on the phased path only: CollectionLauncher.create(freeze = true, revealLater = false, uri = '') still freezes a Loom collection with no metadata, for good

`src/CollectionLauncher.sol:79`

```
        if (freeze && !revealLater) ILoomCollectionOwner(collection).freezeMetadata();
```

Round 8 Low 3 made JigsawCollection.initialize revert NothingToFreeze for freeze with an empty uri (src/JigsawCollection.sol:146), and Info 7 made CollectionLauncher.create revert for freeze with revealLater 'as JigsawCollection' (line 72). The empty-URI half was not mirrored: with freeze = true, revealLater = false and uri = '', create() calls setBaseURI('') and then freezeMetadata() on the Loom clone. reference/LoomCollection.sol:177-181 (the implementation behind every clone) freezes unconditionally ('An owner may intentionally freeze an empty URI'). The clone is then metadataFrozen with baseURI == '' and unrevealedURI == '': tokenURI(id) is '' for every token forever, setBaseURI/setUnrevealedURI/setRevealSeed revert MetadataIsFrozen, minting stays open, and neither the operator nor the Safe (reoffer only moves ownership) can undo it. Same operator-only input and same irreversible outcome as round 8 Low 3, on the other launch path; the two paths take the same (uri, revealLater, freeze) triple from the same back end (offchain/launch.mjs line 270 sends freeze = true on mainnet with uri = finalBase(pinned), so an empty pinned base URI reaches this line). Minimal fix: in create(), `if (freeze && (revealLater || bytes(uri).length == 0)) revert NothingToFreeze();`. Merged from three specialists.

**Reproduction**

State: a CollectionLauncher bound to a factory that clones reference/LoomCollection.sol and makes the caller its owner (MockLoomFactory in the proof). Input: operator calls create({name:'N',symbol:'S',maxSupply:10,mintPriceWei:0,maxPerWallet:1,creator,royaltyBps:0}, bytes32(uint256(1)), '', false, true). Expected: revert NothingToFreeze, as JigsawCollectionFactory.create does for the same arguments (test/Audit8_Rest.t.sol::test_low3_freeze_at_creation_needs_a_base_uri). Actual: create succeeds and emits Launched; after acceptOwnership, metadataFrozen() == true, baseURI() == '', setBaseURI('ipfs://x/') reverts MetadataIsFrozen, and after mint{value: 0.0005 ether}(1) tokenURI(1) == ''. Reproduced: forge test --match-path test/scratch/LoomFreezeEmptyUri.t.sol fails on this code with 'next call did not revert as expected'; a second scratch test asserting the stuck state (frozen, empty baseURI, MetadataIsFrozen on setBaseURI, empty tokenURI after a mint) passes on this code.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CollectionLauncher} from "src/CollectionLauncher.sol";
import {LoomCollection} from "reference/LoomCollection.sol";

/// Stands in for the Loom NFT factory: clones the live LoomCollection implementation and makes the caller its owner,
/// which is what the launcher relies on (it then sets provenance and URI as owner).
contract MockLoomFactory {
    address public immutable impl;
    constructor(address impl_) { impl = impl_; }
    function createCollection(string calldata name, string calldata symbol, uint256 maxSupply, uint256 mintPriceWei, uint256 maxPerWallet, address creator, uint96 royaltyBps) external payable returns (address c) {
        c = Clones.clone(impl);
        LoomCollection(c).initialize(name, symbol, maxSupply, mintPriceWei, maxPerWallet, creator, royaltyBps, msg.sender);
    }
}

/// Round 8 Low 3 was fixed on the phased path only: CollectionLauncher.create(freeze = true, revealLater = false,
/// uri = "") still freezes a Loom clone on an empty base URI, for good (LoomCollection.freezeMetadata has no guard).
/// Fails on this code ("next call did not revert as expected"); passes once create() reverts NothingToFreeze for
/// freeze with an empty uri, as JigsawCollection.initialize does.
contract LoomFreezeEmptyUriTest is Test {
    address operator = makeAddr("operator");
    address safe = makeAddr("safe");
    address creator = makeAddr("creator");
    address minter = makeAddr("minter");

    function test_launcher_refuses_freeze_with_empty_uri_as_the_phased_path_does() public {
        MockLoomFactory f = new MockLoomFactory(address(new LoomCollection(safe, safe)));
        CollectionLauncher l = new CollectionLauncher(address(f), operator, safe);
        CollectionLauncher.Collection memory c = CollectionLauncher.Collection({name: "N", symbol: "S", maxSupply: 10, mintPriceWei: 0, maxPerWallet: 1, creator: creator, royaltyBps: 0});
        vm.prank(operator);
        // on this code the call succeeds and the clone is metadataFrozen with baseURI == "" and tokenURI(id) == ""
        // for every token, with setBaseURI reverting MetadataIsFrozen: nothing can ever give the tokens metadata
        vm.expectRevert(CollectionLauncher.NothingToFreeze.selector);
        l.create(c, bytes32(uint256(1)), "", false, true);
    }
}
```

### 3. Low: Keeper marks a coin's push airdrop done for good while contract-held ids remain, so an NFT that leaves an escrow or vault later in the 30-day window is never pushed

`offchain/keeper.mjs:166`

```
        if (!pa.open || (pa.complete && pa.ids.length === 0)) { (st.airdropDone ??= {})[coin] = true; return; }
```

Since the round 8 Medium 2 fix, rewards.pushableIds() (offchain/rewards.mjs:100) splits unclaimed ids into `ids` (EOA owners) and `contractHeld`. The keeper correctly never queues contractHeld (it is not read anywhere, so there is no resend loop on contract-held ids while getCode works). But the completion rule still looks only at `ids`: when the collection is complete and `ids` is empty, airdropDone[coin] is set permanently (line 164 skips the whole block from then on) even when contractHeld is non-empty. Before round 8 those ids stayed in `ids`, so the keeper kept serving the coin. An id sitting in a marketplace escrow, vault or bridge at that moment becomes pushable the moment it returns to an EOA (claimFor would then pay it), but the keeper never looks at the coin again, and pushStatus() (rewards.mjs:138) reports 'done' to the site. Nothing is stolen: the holder keeps claim() for the rest of the window (the site shows the claim button for an EOA with unclaimed ids), and after day 30 the share is swept to the pot. It breaks the 'airdrop lands without holders doing anything' promise the push exists for, introduced by the fix. Fix: mark done only when `!pa.open || (pa.complete && pa.ids.length === 0 && pa.contractHeld.length === 0)`, re-checking coins with pending contract-held ids (cheaply, e.g. every hour) until the window closes, and report them in pushStatus instead of 'done'. Merged from two specialists.

**Reproduction**

State: collection maxSupply 3, all minted; ids 1 and 2 held by EOAs, id 3 by an escrow contract (code.length != 0); none claimed. Pass 1: pushableIds returns {open: true, ids: [1, 2], contractHeld: [3], complete: true}; the keeper pushes ids 1 and 2. Pass 2: pushableIds returns {open: true, ids: [], contractHeld: [3], complete: true}; line 166's condition `pa.complete && pa.ids.length === 0` is true, so airdropDone[coin] = true. Day 5: the escrow returns id 3 to EOA 0xB0B. Expected: a later pass pushes id 3 (claimFor(coin, [3]) would now transfer perNft to 0xB0B). Actual: line 164's `!st.airdropDone?.[coin]` is false for the rest of the window; the keeper never calls pushableIds for the coin again; pushStatus reports 'done'; on day 31 sweep() sends id 3's share to the pot unless 0xB0B calls claim(). Traced by code: keeper.mjs lines 164-168 and rewards.mjs lines 95-100 (contractHeld is returned but never consulted).

### 4. Low: Public airdrop status reads call pushableIds() on every request, which flushes the owners cache and does one serial eth_getCode per holder: thousands of RPC calls per anonymous request on a large coll

`offchain/rewards.mjs:72`

```
  try { const pa = await pushableIds(coin); delivery = open ? await pushStatus(coin, collection, pa.ids.length) : { status: 'closed' }; } catch (e) { delivery = { status: 'unknown', reason: e.shortMessage ?? e.message }; }
```

The round 8 Medium 2 keeper change made pushableIds() classify every unclaimed id's owner with p.getCode(), one sequential `await` per distinct owner (line 99; no batching, no cache; pub() uses a plain http transport). pushableIds() also deletes the owners cache first (line 91) and re-reads every ownerOf and every claimed flag. airdropFor() (the per-account view behind the site's airdrop page) calls pushableIds() on every request at line 72 just to fill the `delivery` field, so one request on a 10,000-id collection with 5,000 distinct holders of unclaimed ids costs ~20 ownerOf multicalls + ~20 claimed multicalls + 5,000 serialized eth_getCode round trips, and leaves the owners cache (meant to make the per-account read cheap for 60 s) invalidated for the next request. The keeper pays the same cost per coin per 5-minute pass while any unclaimed id remains in the 30-day window. No funds at risk: latency, RPC quota and a one-request-to-thousands load amplification on the server that also runs the keeper and its price checks. Fix: cache the code check per address (an address's code only changes on deployment or an EIP-7702 delegation; a 60 s TTL like _owners is fine), fetch it in parallel chunks or via a Multicall3 getCodeSize-style aggregation, and do not call pushableIds() from airdropFor() (serve `delivery` from a short-TTL cache); keep `_owners.delete` to the keeper path. From the math specialist; verified by code trace.

**Reproduction**

State: a coin on a JigsawCollection with maxSupply 10,000, all minted to 5,000 distinct wallets, none pushed (push gate waiting for fees). Input: airdropFor(coin, anyAccount) twice in a row (the site's /coins/:coin/airdrop read). Expected: the account's ids from the 60 s owners cache plus one claimed multicall. Actual, by code: line 66 fills the owners cache; line 72 calls pushableIds(), which at line 91 deletes _owners[collection], at line 92 re-fetches 10,000 ownerOf results (20 multicalls of 500), at line 94 10,000 claimed flags (20 multicalls), and at line 99 issues 5,000 eth_getCode calls one after another; the second request repeats all of it because nothing from the first is cached. viem is not installed in this tree, so the trace is from the source; no on-chain state is involved.

### 5. Info: pushableIds treats a failed eth_getCode as 'no code', so during an RPC error contract-held ids re-enter the push batch and the keeper sends claimFor transactions that push nothing until the read works

`offchain/rewards.mjs:99`

```
  for (const o of new Set(open.map((id) => owners[id]))) code.set(o, ((await p.getCode({ address: o }).catch(() => '0x')) ?? '0x') !== '0x');
```

The code check that keeps the keeper from looping on contract-held ids fails open: `.catch(() => '0x')` classifies an owner whose getCode call threw (rate limit, timeout) as an EOA, so its ids land in `ids` instead of `contractHeld`. keeper.mjs line 168 takes the first KEEPER_AIRDROP_BATCH (15) of `ids` in id order; on chain AirdropClaim.claimFor (src/AirdropClaim.sol:112) skips the code-bearing owner without marking it, so the batch is a paid transaction that pushes nothing (Pushed(coin, 0, 0)); the keeper's simulation passes (no revert), the receipt is a success, airdropSpentEth grows (which delays the pay-as-earned gate for real pushes) and the same ids come back next pass while getCode keeps failing. Bounded by KEEPER_AIRDROP_TX_PER_DAY (300 per coin), the fee gate and the error lasting; cost is gas per pass. The brief's requirement that the keeper never loop on contract-held ids holds only while getCode succeeds. Fix: fail closed, as kindOf() already does for module probes: on a getCode failure leave the owner's ids out of both lists for this pass (`.catch(() => null)` and skip null), or abort pushableIds for the pass. Merged from two specialists.

**Reproduction**

State: a coin's drop with ids 1..15 owned by one staking contract and ids 16..30 by EOAs, none claimed; the RPC's eth_getCode throws for the staking contract's address while eth_call (ownerOf/claimed multicalls) succeeds. Input: keeper pass. Expected: ids 1..15 in contractHeld and the batch is ids 16..30 (or the pass is skipped). Actual, by code: line 99 maps the thrown getCode to '0x', so code.get(stakingContract) === false; line 100 returns ids = [1..30]; keeper.mjs line 168 takes batch = [1..15]; claimFor(coin, [1..15]) hits `owner_.code.length != 0` for every id and emits Pushed(coin, 0, 0); the receipt is a success, onSuccess schedules the next batch and the same ids are sent again while the read keeps failing.

### 6. Info: Round 8 Info 10 fix: after any stream the carry is division dust under 86,400 wei, so every zero-fee pull calls notifyReward(0), sets rewardRate to 0 and moves periodFinish for nothing

`src/RewardsForwarder.sol:68`

```
            if (a != address(0) && CreatorCoin(a).carry() > 0 && !CreatorCoin(a).rewardsPaused()) CreatorCoin(a).notifyReward(0);
```

CreatorCoin.notifyReward leaves carry = total - rewardRate * DURATION, i.e. total mod 86,400 wei (src/CreatorCoin.sol:136), which is non-zero after practically every stream. pull() therefore sees carry > 0 on every quiet day and calls notifyReward(0): total = carry < 86,400, rewardRate = 0, carry unchanged, lastUpdate and periodFinish reset, RewardAdded(0, 0, now + 1 day) emitted, and offchain/rewards.mjs rewardsOf() reports a live stream with jigPerDay 0. The intended case (a real carry from a stream with no eligible holders) is served; the condition just fires almost always, costing the keeper ~30k gas per idle day per coin. Checked and cleared: the branch cannot restart or stretch a running stream (MIN_INTERVAL == DURATION, so at the earliest allowed pull block.timestamp == periodFinish and `block.timestamp < periodFinish` is false: nothing is folded; holders' earned() is unchanged); it cannot block pull() (JIG is a plain OpenZeppelin ERC20, transferFrom of 0 with zero allowance succeeds; the branch is skipped while paused and when no coin exists; hook.claim() does not revert on a zero balance); and the amount > 0 branch reverts Paused while paused, which is the intended brake (fees wait in the hook; accepted Info 9). Fix if wanted: condition on `carry() >= CreatorCoin.DURATION` (the smallest carry that gives a non-zero rate), or on eligibleSupply() > 0 together with it. Merged from two specialists.

**Reproduction**

State (test/scratch/DustRestream.t.sol, passes on this code): coin with 100e18 eligible (alice) and the rest held by the excluded factory stand-in; the forwarder holds 1_000e18 + 12345 JIG and pull() runs at T: rewardRate = 11574074074074074, carry = 18745 wei. Input: pull() at T + 1 day with no new JIG. Expected per the fix's intent: a re-stream of carried reward, or no call when nothing can stream. Actual: notifyReward(0) runs; rewardRate == 0, carry still 18745, periodFinish == T + 2 days; alice's earned() == 999999999999999993600 before and after, and unchanged at T + 2 days (the whole first stream, confirming no stretch and nothing streamed); the dust is never paid.

---

Judge's submission `47a492775689ecc52062cc35cf39f860bb9920f9c1cdc72aee72043fb8b339b5`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
