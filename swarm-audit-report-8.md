# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit: Solidity in src/ (Foundry; tests in test/, deploy scripts in script/, README.md describes every contract and every earlier round with its fixes) and the off-chain money paths in offchain/ (Node modules on one server with one hot "operating wallet"; offchain/README.md lists them). This is round 8, the review before a mainnet launch on Robinhood Chain (Arbitrum Orbit, chain 4663). WHAT CHANGED SINCE ROUND 7 (commit 63e94356); verify each and hunt for what it introduced:
> (1) Holder rewards fully on chain: src/CreatorCoin.sol streams JIG to holders (StakingRewards pattern over DURATION = 1 day, every transfer is a stake/unstake; protocol addresses excluded from the eligible supply; one notifier set once by the factory; reward streamed while nobody is eligible and dust carried to the next stream; the platform can pause adding and claiming for at most MAX_PAUSE = 14 days per decision, renewable). src/RewardsForwarder.sol pulls the coin's slice from CreatorFeeHook at most once a day (MIN_INTERVAL) and notifies the coin. HolderPayouts and SnapshotForwarder are removed. Hunt: accounting drift, reward theft or dilution via transfers to/from excluded addresses, flash or just-in-time holding around pull(), griefing pull() timing, carry/dust, the pause.
> (2) src/AirdropClaim.sol is per NFT: the factory parks each coin's 5% there; notify splits it as 5% / maxSupply (or totalSupply) per token id; the owner of NFT #id claims once within 30 days (claim), anyone may push to the current owner (claimFor, skips claimed, unminted and dead-owned ids), then sweep the rest to the pot. Owner renounced after setFactory. Hunt: double claims, claims for ids minted later, supply manipulation, sweep timing.
> (3) CreatorFeeHook: a flywheel module's slice never recycles (only the creator's own share can go stale after 7 days). BuybackAndBurn and LPDeepening keeper is settable by the platform (setKeeper).
> (4) src/CollectionLauncher.sol: create(c, provenance, uri, revealLater, freeze) in one transaction, admin-only reoffer.
> (5) NEW CONTRACTS src/JigsawCollection.sol + src/JigsawCollectionFactory.sol: our own ERC-721 (EIP-1167 clones) with up to 3 timed mint phases (start, price, per-wallet cap, optional phase supply, optional Merkle wallet list of OpenZeppelin double-hashed address leaves), a lifetime per-wallet cap, a list-only phase never after an open one, the same 0.0005 ETH fee split 40/40/20 pushed on every mint, provenance and first URI set in initialize, reveal seed once, freeze (needs a base URI), pause, ERC-2981 royalty, 1% owner reserve, no renounce. The factory is operator-only and keeps an isCollection registry the coin side trusts. An in-house round already fixed 5 Info findings (test/Audit_Phased_*.t.sol); the creator push payment (a creator that rejects ETH blocks minting) is accepted as on the Loom collection. Hunt: cap bypasses, Merkle issues, reentrancy via _safeMint, owner powers, setPhases/setPhaseRoot timing, the registry.
> (6) Deployment: script/go-day.sh runs the whole mainnet sequence (fork prediction, then live with every address compared to the prediction, roles read back); script/DeployPhased.s.sol; the team Safe receives every platform fee and a separate pot Safe owns PotVault. Check role wiring and anything a deploy-order mistake could break.
> (7) Off-chain: offchain/keeper.mjs (rewards pulls wait for nextPullAt; per-NFT airdrop push in batches gated on the coin's earned platform fees; a price check that refuses any keeper trade when the pool's spot is more than 10% from the median of the keeper's own 12 h readings, offchain/priceguard.mjs), offchain/rewards.mjs, offchain/phases.mjs (server-side phase lists, Merkle proofs served only for the root on chain, add-wallets with a per-build lock), offchain/flywheels.mjs (deploys a collection's flywheel module once: pending tx persisted before broadcast), offchain/go-day-env.mjs.
> Report every finding with severity, file and line, a concrete exploit path and a minimal fix; say what you checked and cleared.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `4e652a0d166d114d204e35065aed3b8c56330ac5` |
| Job | `70fa509e-5107-4b83-a3d9-31e985229b92` |
| Judged | 2026-10-18 09:52 UTC |
| Findings | 1 high · 1 medium · 3 low · 5 info |

Four agents audited the code as it is at `4e652a0`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. High: PotVault is not excluded from CreatorCoin holder rewards: the swept airdrop remainder earns JIG that no code path can claim, permanently stranding a large share of every stream

`src/CoinFactory.sol:245`

```
        e[2] = airdropRecipient;
```

CreatorCoin streams JIG pro rata to every balance not held by an excluded address. CoinFactory._excluded() lists only the pool manager, the fee hook and the airdrop recipient (the constructor adds the factory, DEAD and the coin). AirdropClaim.sweep() (src/AirdropClaim.sol:131) sends every unclaimed share of the 5% airdrop (ids never minted inside the 30-day window, dead-owned ids, shares nobody claimed, rounding) to `pot`, which on mainnet is PotVault (script/go-day.sh: DeployRest POT=JIG_POT). PotVault then holds creator coin as an ordinary eligible holder, but it has no function that can call CreatorCoin.claim() (claim() pays only msg.sender; PotVault only declares merkle distributions of tokens it already holds; its owner Safe has no arbitrary-call path through it). Every stream after the sweep therefore credits the pot's share to rewards[pot], and that JIG sits in the coin contract forever: it is neither claimable nor added to carry, and real holders are diluted by exactly that fraction (pot balance / eligible supply). For a phased collection far from minted out most of the 5% ends up in the pot: 1,000 of 10,000 minted leaves 45M coin there against 55M held by every real holder, so 45% of every day's holder rewards are lost; with fewer real holders the share is higher (the economics specialist's variant: 49M swept vs 1M held loses 98%). No attacker and no precondition beyond the normal keeper-run sweep; the loss recurs daily for the life of the coin. Three specialists (math, flow, economics) reported this independently; merged here. Minimal fix: exclude the pot at launch, e.g. in CoinFactory read `AirdropClaim(airdropRecipient).pot()` once in the constructor into an immutable (the constructor already probes pot()) and append it as e[3] in _excluded(); coinInitCodeHash() uses _excluded() so the salt grinder stays in step. Alternatives that keep the pot earning: have AirdropClaim.sweep() burn to DEAD, or add a CreatorCoin.claimFor(address) that pays `account` so the keeper can move the pot's JIG into PotVault.

**Reproduction**

State: coin launched through the real CoinFactory.launch (test/scratch/PotStranded.t.sol stubs only the v4 position manager, permit2 and hook with a contract that answers every call with 32 zero bytes, so the real coin, real _excluded() list and real AirdropClaim.notify() run) for a collection with maxSupply 10,000 of which 1,000 ids are minted; AirdropClaim.claimFor pushes all 1,000 ids; warp 31 days; anyone calls AirdropClaim.sweep(coin). Actual: 45,000,000e18 coin moves to PotVault and coin.excluded(pot) == false. Then the notifier calls notifyReward(1,000e18) and one day passes. Expected: earned(pot) == 0 (the pot is a protocol address like the airdrop claim) and the whole 1,000 JIG is claimable by real holders. Actual: earned(pot) == 449999999999999997120 (45% of the stream) and no function can move that JIG out of the coin. Proof run: `forge test --match-path test/scratch/PotStranded.t.sol` fails on this code with "pot earns holder rewards it can never claim: 449999999999999997120 != 0"; the two other specialists' proofs (stub-factory variants) fail the same way with 2351.99e18 (98%) and 499.99e18 (5/6) stranded. Passes once the pot is in the coin's excluded list.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CreatorCoin} from "src/CreatorCoin.sol";
import {CoinFactory} from "src/CoinFactory.sol";
import {AirdropClaim} from "src/AirdropClaim.sol";
import {PotVault} from "src/PotVault.sol";

contract SJig is ERC20 {
    constructor() ERC20("J", "J") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// Answers every call with 32 zero bytes: stands in for the position manager, permit2 and the fee hook so that
/// CoinFactory.launch() runs its real coin creation, real _excluded() list and the real AirdropClaim.notify().
contract Yes {
    fallback() external payable { assembly { mstore(0, 0) return(0, 32) } }
}

contract SCollection {
    address public creator;
    uint256 public maxSupply = 10_000;
    uint256 public totalSupply = 1_000;
    constructor(address c) { creator = c; }
    function ownerOf(uint256 id) external view returns (address) { require(id != 0 && id <= totalSupply, "unminted"); return address(uint160(0xBEEF0000 + id)); }
}

/// The pot (PotVault) receives every swept airdrop remainder but is not in CoinFactory._excluded(): its coin balance
/// counts in the eligible supply and "earns" JIG that no code path can ever claim.
contract PotStrandedTest is Test {
    SJig jig; CoinFactory factory; CreatorCoin coin; AirdropClaim airdrop; PotVault pot; SCollection col;
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");
    address notifier = makeAddr("forwarder");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        jig = new SJig();
        pot = new PotVault(makeAddr("potSafe"));
        airdrop = new AirdropClaim(address(this), address(pot));
        Yes posm = new Yes(); Yes permit2 = new Yes(); Yes hook = new Yes();
        factory = new CoinFactory(address(posm), address(permit2), address(hook), address(jig), platform, address(airdrop), 0);
        airdrop.setFactory(address(factory));
        airdrop.renounceOwnership();
        col = new SCollection(creator);

        bytes32 salt = bytes32(bytes20(address(col)));
        address predicted = factory.predictCoin(address(col), "Coin", "C", salt);
        bool coinIs0 = predicted < address(jig);
        CoinFactory.LaunchParams memory p = CoinFactory.LaunchParams({
            collection: address(col), name: "Coin", symbol: "C", feePips: 10_000, flywheel: notifier, creatorShareBps: type(uint16).max,
            creatorBps: 500, devBuyJig: 0, devBuyMinCoin: 0, maxFeeWei: 0, salt: salt,
            sqrtPriceX96: TickMath.getSqrtPriceAtTick(0), tickLower: coinIs0 ? int24(0) : int24(-200), tickUpper: coinIs0 ? int24(200) : int24(0)
        });
        vm.prank(creator);
        (, address coinAddr) = factory.launch(p);
        coin = CreatorCoin(coinAddr);
        assertEq(coin.balanceOf(address(airdrop)), 50_000_000e18, "the 5% is parked");
        jig.mint(notifier, 1_000_000e18);
        vm.prank(notifier); jig.approve(address(coin), type(uint256).max);
    }

    function test_pot_balance_earns_rewards_nobody_can_claim() public {
        // 1,000 of 10,000 minted; the keeper pushes every minted id, the window closes, the rest is swept to the pot
        uint256[] memory ids = new uint256[](1_000);
        for (uint256 i; i < 1_000; i++) ids[i] = i + 1;
        airdrop.claimFor(address(coin), ids);
        vm.warp(block.timestamp + 31 days);
        uint256 swept = airdrop.sweep(address(coin));
        assertEq(coin.balanceOf(address(pot)), swept);
        assertEq(swept, 45_000_000e18, "90% of the airdrop went to the pot");

        vm.prank(creator); coin.transfer(alice, 5_000_000e18); // real holders: creator 45M + alice 5M + the 1,000 pushed owners 5M
        assertEq(coin.balanceOf(alice), 5_000_000e18);

        vm.prank(notifier); coin.notifyReward(1_000e18);
        vm.warp(block.timestamp + 1 days);

        // the pot is a protocol address with no way to call claim(): it must hold no share of holder rewards
        assertEq(coin.earned(address(pot)), 0, "pot earns holder rewards it can never claim");
        assertTrue(coin.excluded(address(pot)), "pot must be excluded from the eligible supply");
    }
}
```

### 2. Medium: AirdropClaim.claimFor pushes an NFT's share to whatever contract holds the NFT (escrow, vault, bridge) and marks the id claimed, so the beneficial owner loses the share for good; anyone can trigger it

`src/AirdropClaim.sol:111`

```
            IERC20(coin).safeTransfer(owner_, d.perNft);
```

claimFor(coin, ids) is permissionless and transfers id's share to whatever ownerOf(id) returns, then sets claimed[coin][id]. It skips only address(0) and DEAD. When the NFT sits in a contract that cannot move ERC-20s (an escrow-style marketplace listing, a lending or staking vault, a bridge lock) the coin lands in that contract and is irrecoverable, and because the id is now claimed the real owner's later claim() reverts AlreadyClaimed even after they take the NFT back. Under the pull path alone the holder would have waited to claim with the NFT in a wallet of their choice; the push path removes that choice, and it is not limited to the keeper (which pushes every minted, unclaimed id within hours, offchain/keeper.mjs line 183): a griefer can target exactly the ids held by such contracts. The stranded coin also stays in the eligible supply and keeps earning holder rewards nobody can claim (same mechanism as the pot finding). Two specialists (permissions, economics) reported this; merged. Minimal fix that keeps the push design: in claimFor skip owners with code (`if (owner_.code.length > 0) continue;` next to the DEAD check on line 109), leaving contract holders (Safes, escrows) to call claim() themselves or to claim once the NFT is back in a wallet; or restrict pushes to contract-owned ids to the keeper.

**Reproduction**

State: AirdropClaim bound to a factory stand-in, collection C (maxSupply 10), Alice owns #7 and has listed it on an escrow marketplace contract E (implements onERC721Received, has no ERC-20 withdraw); a coin for C parks 50,000,000e18 in AirdropClaim and notify() fixes perNft = 5,000,000e18. Input: griefer calls claimFor(coin, [7]). Expected: #7's share stays claimable by Alice (or reaches Alice). Actual: 5,000,000e18 coin is transferred to E and claimed[coin][7] = true; after Alice cancels the listing (ownerOf(7) == Alice) her claim(coin, [7]) reverts AlreadyClaimed; the share is stranded in E (sweep() cannot reach it either). Proof run: `forge test --match-path test/scratch/AirdropPushToEscrow.t.sol` fails on this code with "share pushed into a contract that cannot move it: 5000000000000000000000000 != 0" and passes once claimFor skips code-bearing owners.

**Proof**: a Foundry test that fails on this code and passes once it is fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {AirdropClaim} from "src/AirdropClaim.sol";

contract MockCollection is ERC721 {
    uint256 public constant maxSupply = 10;
    constructor() ERC721("C", "C") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

/// A creator coin stand-in: only collection() and plain ERC20 are needed by AirdropClaim.
contract MockCoin is ERC20 {
    address public collection;
    constructor(address col, address to) ERC20("K", "K") { collection = col; _mint(to, 50_000_000e18); }
}

/// A marketplace escrow: holds listed NFTs, can receive ERC-721s, has no way to move ERC-20s.
contract Escrow is IERC721Receiver {
    mapping(uint256 => address) public lister;
    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        lister[id] = from;
        return this.onERC721Received.selector;
    }
    function cancel(address col, uint256 id) external {
        require(lister[id] == msg.sender);
        delete lister[id];
        ERC721(col).transferFrom(address(this), msg.sender, id);
    }
}

contract AirdropPushToEscrowTest is Test {
    AirdropClaim drop;
    MockCollection col;
    MockCoin coin;
    Escrow escrow;
    address pot = makeAddr("pot");
    address alice = makeAddr("alice");
    address griefer = makeAddr("griefer");

    function setUp() public {
        drop = new AirdropClaim(address(this), pot);
        drop.setFactory(address(this)); // this test plays the CoinFactory
        col = new MockCollection();
        escrow = new Escrow();
        col.mint(alice, 7);
        // Alice lists #7 on the escrow marketplace before the coin launches
        vm.prank(alice);
        col.safeTransferFrom(alice, address(escrow), 7);
        coin = new MockCoin(address(col), address(drop)); // the 5% lands in AirdropClaim ...
        drop.notify(address(coin)); // ... and the factory fixes the per-NFT share
    }

    /// Anyone can push #7's share to the escrow contract; the escrow cannot move ERC-20s, and once the id is
    /// marked claimed Alice can never take her share even after she takes the NFT back.
    function test_pushToContractOwnerStrandsTheShare() public {
        (,, uint256 perNft,) = drop.drops(address(coin));
        assertGt(perNft, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 7;
        vm.prank(griefer);
        drop.claimFor(address(coin), ids);

        // Alice delists and tries to claim herself
        vm.prank(alice);
        escrow.cancel(address(col), 7);
        assertEq(col.ownerOf(7), alice);

        vm.prank(alice);
        try drop.claim(address(coin), ids) {} catch {}

        // Expected: Alice (the NFT's beneficial owner) ends up with #7's share, or the share is still claimable by her.
        // Actual: the coin sits in the escrow contract forever and #7 is marked claimed.
        assertEq(coin.balanceOf(address(escrow)), 0, "share pushed into a contract that cannot move it");
        assertEq(coin.balanceOf(alice), perNft, "Alice never receives her share");
    }
}
```

### 3. Low: JigsawCollection.initialize accepts freeze=true with an empty base URI, freezing a collection on no metadata for good (freezeMetadata() refuses the same state)

`src/JigsawCollection.sol:139`

```
        if (freeze && revealLater) revert NothingToFreeze(); // the reveal freezes a reveal-later collection
```

freezeMetadata() guards `bytes(baseURI).length == 0` with NothingToFreeze (line 328) because a frozen collection without a base URI leaves every token on the placeholder forever. The same freeze done in initialize() (the JigsawCollectionFactory.create path with freeze=true, revealLater=false) only checks `freeze && revealLater`; an empty `uri` passes. The clone is then metadataFrozen with baseURI == "" and unrevealedURI == "": setBaseURI, setUnrevealedURI and setRevealSeed all revert MetadataIsFrozen and tokenURI(id) returns "" for every token forever, while minting stays open. Operator-only input, but one the contract's own later guard treats as invalid and that cannot be undone (no renounce, clones are not upgradeable). Reported by three specialists; merged. Fix: in initialize, `if (freeze && (revealLater || bytes(uri).length == 0)) revert NothingToFreeze();`.

**Reproduction**

Input: operator calls JigsawCollectionFactory.create(Config{name:"N",symbol:"S",maxSupply:100,maxPerWallet:10,creator,royaltyBps:500}, [Phase{start:now,price:0,maxPerWallet:10,supply:0,root:0}], provenance=bytes32(1), uri="", revealLater=false, freeze=true). Expected: revert NothingToFreeze, as freezeMetadata() does for an empty base URI. Actual (test/scratch/JudgeLows.t.sol::test_initialize_freeze_with_empty_uri_is_accepted_and_irreversible, passes on this code showing the stuck state): create succeeds, metadataFrozen() == true, baseURI() == "", after mint(1) with 0.0005 ether tokenURI(1) == "", and the owner's setBaseURI("ipfs://x/") reverts MetadataIsFrozen; the same collection created without freeze then has freezeMetadata() revert NothingToFreeze.

### 4. Low: AirdropClaim assumes ids 1..maxSupply: on a 0-based collection token 0 can never claim and its share is swept to the pot

`src/AirdropClaim.sol:84`

```
            if (id == 0 || id > d.maxId) revert BadId(id);
```

notify() fixes the claimable range as ids 1..maxId with maxId = maxSupply() (or totalSupply()). CoinFactory.launch() accepts any contract whose creator() (or owner()) is the caller, not only JigsawCollection or Loom clones (both 1-based), and nothing in AirdropClaim reads the id base. For a 0-based collection (ERC721A style, ids 0..maxSupply-1) the owner of token 0 is refused with BadId while id == maxSupply does not exist (ownerOf reverts: claim() reverts NotOwnerOf, claimFor() skips it). One holder loses their share, which sweep() later sends to the pot. HolderDrip documents the same 1-based assumption; AirdropClaim does not and has no guard. Fix: either require the collection to be registered in the JigsawCollectionFactory / Loom factory (isCollection) in launch(), or record a first-id base in the Drop (accept id 0 when ownerOf(0) succeeds) and check `id < base || id >= base + maxId`.

**Reproduction**

State: a coin launched for a collection with maxSupply() == 100 whose ids run 0..99 (every id minted). notify(): maxId = 100, perNft = 50,000,000e18 / 100. Input: the owner of token 0 calls claim(coin, [0]). Expected: receives perNft. Actual (test/scratch/JudgeLows.t.sol::test_airdrop_refuses_token_id_zero_of_a_zero_based_collection, passes on this code showing the state): revert BadId(0); claimFor(coin, [0]) returns 0; claimFor(coin, [100]) returns 0 (unminted); after 31 days sweep() moves the whole balance, token 0's share included, to the pot.

### 5. Low: Every JigsawCollection clone is owned by the operator hot key from birth with no platform recovery path; rotating the factory operator does not reach existing clones (asymmetry with CollectionLauncher

`src/JigsawCollectionFactory.sol:50`

```
        JigsawCollection(collection).initialize(c, operator, phases, provenance, uri, revealLater, freeze);
```

create() initialises each clone with owner_ = operator, the server's hot operating wallet (script/DeployPhased.s.sol: "OPERATOR: the operating wallet (creates and owns every collection)"). The owner can pause/unpause minting, setPhases before the first phase starts, setPhaseRoot for a phase not yet started, setRevealSeed, setBaseURI/setUnrevealedURI until frozen, reserveMint 1% and transferOwnership; renounceOwnership is disabled. The Safe's only powers (setOperator, setImplementation) affect future clones only. The Loom path got an admin escape hatch for the lost-key case (CollectionLauncher.reoffer, Safe-only); the phased path has none: if the operator key is lost, every reveal-later collection it owns can never be revealed or frozen and a paused one stays paused; if the key leaks, the holder can point every unfrozen collection's baseURI anywhere, pick reveal seeds, pause mints and transfer ownership of all of them, and the Safe cannot intervene. This is the intended ownership model (README: operator owns), so it is recorded as a trust assumption with its material risk, merging the permissions (low) and economics (info) specialists' entries. Mitigation without changing who operates: give JigsawCollection an immutable GUARDIAN (the factory owner / Safe) set in the constructor like PLATFORM, with one guardian-only `_transferOwnership(newOwner)` (or pause) function; or transfer each collection to the Safe after its mint window and freeze at reveal, which the code already supports.

**Reproduction**

State: factory.create(...) with revealLater = true; the operator key is lost (or leaked). Input: Safe calls factory.setOperator(newOps); newOps calls collection.setRevealSeed / setBaseURI / unpause / transferOwnership. Expected: the platform can recover administration of the collection. Actual (by code: onlyOwner on every setter, Ownable2StepUpgradeable owner fixed at initialize, renounceOwnership reverts CannotRenounce at line 292, factory has no call path into a clone): every call reverts OwnableUnauthorizedAccount(newOps); the clone stays administered by the lost or hostile key. Compare CollectionLauncher.reoffer (admin-only) which exists for the same situation on the Loom path.

### 6. Info: The isCollection registry is not read on chain: CoinFactory.launch accepts any contract whose creator()/owner() is the caller, so a self-made collection's launcher takes the whole 5% airdrop

`src/CoinFactory.sol:130`

```
        if (!_controlsCollection(msg.sender, p.collection)) revert NotCollectionOwner();
```

The brief says the JigsawCollectionFactory keeps an isCollection registry "the coin side trusts", but only the off-chain launch page and keeper read it (offchain/launch.mjs isOurCollection; offchain/keeper.mjs refuses to service unregistered collections and states "CoinFactory is open to any collection creator"). On chain, launch() requires only code at p.collection and creator()/owner() == msg.sender, and AirdropClaim reads maxSupply()/ownerOf() from that same contract. A launcher can deploy a contract whose creator() is themselves, maxSupply() returns 1 and ownerOf(1) returns themselves, launch a coin for it (launch fee 0 on launch day) and claim the entire 50,000,000 coin airdrop in the same block, on top of the 5% creatorBps and the dev buy. The coin carries the same hook, pool and vanity suffix as a genuine one; the keeper will not service it, but trading on it is open. This matches the documented design (open launch), so it is recorded as a trust/design note rather than a defect; if the registry is meant to be binding, require isCollection(p.collection) on one of the registries in launch(), or have AirdropClaim treat a collection below a supply floor as "no drop".

**Reproduction**

Input: deploy Fake { creator() returns attacker; maxSupply() returns 1; ownerOf(uint256) returns attacker }. attacker calls CoinFactory.launch({collection: Fake, salt: bytes32(bytes20(Fake)), creatorBps: 500, ...}), then AirdropClaim.claim(coin, [1]). Expected per the stated trust: launch refuses an unregistered collection. Actual by code: _controlsCollection returns true (line 234), launch succeeds, notify() fixes perNft = 50_000_000e18 / 1, claim() transfers the whole 5% to attacker (claim path verified by the scratch tests above with a hand-made collection).

### 7. Info: CollectionLauncher.create silently ignores freeze when revealLater is set, while JigsawCollection.initialize reverts NothingToFreeze for the same input

`src/CollectionLauncher.sol:77`

```
        if (freeze && !revealLater) ILoomCollectionOwner(collection).freezeMetadata();
```

The two launch paths take the same (uri, revealLater, freeze) triple from the same operator back end. The phased path treats freeze && revealLater as a caller error and reverts (src/JigsawCollection.sol:139); the Loom path returns success and launches an unfrozen collection, emitting Launched with no indication that nothing was frozen. Fix: revert in create() when freeze && revealLater, matching JigsawCollection.initialize (or make both lenient; they should agree).

**Reproduction**

Input: operator calls CollectionLauncher.create(c, provenance, "ipfs://placeholder", revealLater = true, freeze = true). Expected (per the phased path): revert. Actual by code (line 75 sets the unrevealed URI, line 77 skips freezeMetadata because !revealLater is false, line 79 emits Launched): the collection is created with unrevealedURI set and metadataFrozen false; the same arguments to JigsawCollectionFactory.create revert NothingToFreeze.

### 8. Info: RewardsForwarder comments describe a 7-day stream; CreatorCoin.DURATION is 1 day

`src/RewardsForwarder.sol:24`

```
    uint64 public constant MIN_INTERVAL = 1 days; // each pull restarts the coin's 7-day stream for what is left
```

Lines 15, 24 and 53 of RewardsForwarder still say the coin streams over seven days and that each pull restarts a 7-day stream. CreatorCoin.DURATION was changed to 1 day in this round (src/CreatorCoin.sol:34) and MIN_INTERVAL equals it, which is exactly what makes the "nothing is ever re-spread" argument hold: when the next pull is allowed, periodFinish has already been reached. A reader checking the timing argument from the forwarder alone is misled. Documentation only. Fix: state the 1-day stream and that MIN_INTERVAL == DURATION is the invariant.

**Reproduction**

Read src/RewardsForwarder.sol lines 15, 24, 53 against src/CreatorCoin.sol line 34 (`uint256 public constant DURATION = 1 days;`). Expected: consistent numbers. Actual: "seven days" / "7-day" in the forwarder vs 1 day in the coin. No state effect.

### 9. Info: A rewards pause batches up to 14 days of fees into a single one-day stream that anyone can time with pull()

`src/CreatorCoin.sol:130`

```
        if (rewardsPaused()) revert Paused();
```

While rewards are paused notifyReward reverts Paused, so RewardsForwarder.pull() reverts as a whole (lastPull is not advanced since the transaction reverts) and the coin's slice keeps accruing in the hook as claimable[forwarder]. The moment the pause lapses (or is lifted) anyone can call pull(): up to 14 days of fees are then streamed over DURATION = 1 day. Because every transfer is a stake/unstake with no lock, a large buyer who enters just before that pull and exits a day later captures balance/eligibleSupply of the whole batch for two swap fees; under normal daily pulls this is uneconomic, after a pause the batch is public knowledge and the pull is permissionless. Inherent to the chosen StakingRewards design and the pause is a requested power; recorded as a design/trust note for the Safe (prefer lifting a pause with a known-small backlog, or let the forwarder spread a backlog larger than N days over N streams).

**Reproduction**

State: platform calls setRewardsPaused(true); 13 days of swaps accrue 13x the daily flywheel slice in the hook. At pausedUntil a buyer acquires B coin, calls pull(), holds one day, claims B/(B+H) of 13 days of fees, sells. Expected from the daily-stream design: one day of intake per stream. Actual by code (notifyReward line 130 reverts while paused; pull line 56 only checks lastPull; notifyReward lines 133-138 stream amount + carry over DURATION): 13 days in one stream.

### 10. Info: Reward carry (streamed while nobody was eligible) is only re-streamed by a later notifyReward, which pull() skips when the hook has nothing

`src/RewardsForwarder.sol:60`

```
        if (amount > 0) {
```

carry is folded into a stream only inside CreatorCoin.notifyReward() (line 133). RewardsForwarder.pull() calls notifyReward only when amount > 0, and notifyReward is notifier-only, so for a coin whose trading stops a non-zero carry stays in the contract indefinitely even after holders appear. Low impact: carry is only large if a stream ran with zero eligible supply, which happens at launch with creatorBps = 0, no dev buy and no buyers for a day. Fix: let pull() notify when the coin's carry > 0 even if amount == 0, or allow anyone to trigger a zero-amount restream.

**Reproduction**

State: launch with creatorBps = 0 and no dev buy; the notifier streams 70e18 while eligibleSupply() == 0 (CreatorCoin._updateGlobal line 159 adds it to carry); a day later alice buys; trading then stops so hook.claimable[forwarder] stays 0. Expected: alice eventually receives the 70e18. Actual by code: pull() reads amount == 0 and skips notifyReward (line 60), carry == 70e18 forever, earned(alice) stays 0 until some future pull with amount > 0.

---

Judge's submission `fec69dfa3033ec0959bf90baaf51dbb61ea8a2d56131db9ba547b91c9d7e2c76`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
