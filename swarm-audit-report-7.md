# Audit report

> The code is in the public repository https://github.com/JJ-ME55/jigsaw-contracts-audit: Solidity in src/ (Foundry; tests in test/, deploy scripts in script/, README.md describes every contract and rounds 1-6 with every fix), and NEW in this final round the off-chain money paths in offchain/ (Node modules that run on one server with one hot 'operating wallet'; offchain/README.md lists them). This is the final review before a mainnet launch on Robinhood Chain (Arbitrum Orbit, chain 4663) in days. WHAT CHANGED SINCE ROUND 6 (verify each, hunt for what it introduced): (1) CoinFactory deploys each coin with CREATE2; LaunchParams.salt must have the collection address as its first 20 bytes (BadSalt otherwise); predictCoin/coinInitCodeHash views; is the salt binding sufficient against front-running, can anyone grief a creator's launch or brick a collection's single coin slot; (2) JIG is deployed through CreateX (0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed) CREATE3 with a deployer-guarded salt (script/DeployJIG.s.sol _deployJig, test/JigVanity.fork.t.sol); (3) every deploy script refuses chain 1 and 4663 unless ALLOW_MAINNET_DEPLOY=1, and has Robinhood's Uniswap v4 addresses; (4) round-6 fixes: HolderDrip spreads each pull over the supply recorded at the previous pull and keeps uncovered tokens' baselines open on claim, dust exact-input buys are charged nothing, the recycle stale cutoff is safe on a young chain. (5) in-house pre-audit fixes since: HolderDrip folds burned tokens into burnedCount only once the supply being spread covers them (_foldBurns(supply)); deploy scripts require every role explicitly on chains 1 and 4663 (no silent deployer defaults), AirdropClaim is handed from the deployer to its operator with Ownable2Step after setFactory, no Vesting on mainnets, START_TICK; test/LowJig.fork.t.sol reruns the flywheel and regression suites with JIG at a very low address (the vanity JIG sorts below every coin). (6) NEW CONTRACT src/CollectionLauncher.sol (script/DeployLauncher.s.sol, test/CollectionLauncher.fork.t.sol against the live Sepolia Loom factory): creates a collection and commits setProvenanceHash and its first URI in the same transaction, then offers ownership to the operator (Ownable2Step), because a clone is mintable at once and one outside mint blocked the provenance commitment; HolderDrip records lastSupply in its constructor so the first pull does not reward tokens minted after the fees (test/HolderDripFirstPull.t.sol). Is the launcher safe (reentrancy through the factory or collection, a collection that is not a Loom clone, value handling, ownership left with the launcher)? OFF-CHAIN SCOPE (offchain/): (a) keeper.mjs + sender.mjs: can any job pay twice or overlap (rules: every operating-wallet transaction goes through sender.mjs, which takes a per-chain lock, signs, hands the hash to the caller to persist, then broadcasts; after a restart the keeper resolves an in-flight send from its receipt or the account nonce and never resends; one pass at a time; per-job and daily caps, airdrops on their own cap; backoff; nothing runs if the JIG window status is unknown; round/airdrop snapshots only when due; an on-chain record is never overwritten); are min-out quotes sound (quoted from the V4Quoter, slippage 3%) or sandwichable; does anything run inside the JIG launch window; can a malicious coin, flywheel module or collection (anyone can launch a coin for a collection they created) make the keeper waste gas, revert forever, or sign something harmful; (b) payouts.mjs + merkle.mjs: Merkle leaves and pairing must match HolderPayouts/AirdropClaim exactly; can the pro-rata split exceed the contract balance; can a holder be double-counted (Transfer-log index from launch block, incremental, persisted); excluded protocol addresses; is the tree always on disk before the root is declared; (c) coinSettings.mjs: signature authorisation (creator() else owner(), EIP-1271 via verifyMessage), nonce replay, message ambiguity, airdrop timing locked once the coin exists, minimum round capped at $1,000; (d) swap.mjs: Universal Router calldata, TAKE_PORTION fee to the platform, minOut after fee, two-hop path encoding, approvals; can a user be quoted something the transaction does not deliver; (e) vanity.mjs: salt verified against CoinFactory.predictCoin before use, cannot hand out a salt bound to another collection; (f) jig.mjs: allowlist tree vs JIGLaunchHook (leaf = keccak256(bytes.concat(keccak256(abi.encode(address)))), sorted pairs), launch parameters and start price; (g) reveal.mjs + randomness.mjs: drand quicknet BLS verification against a pinned key and DST, randomness = sha256(signature), round strictly after the trigger (an early reveal first pauses the mint, and the trigger time moves to after the pause), interrupted reveals marked failed at startup, Fisher-Yates bias, can the operator choose the seed; (h) launch.mjs: owner calls on collections (provenance committed at creation through CollectionLauncher, mainnets refuse without it; ownership accepted; every configure step skipped when already on chain; a reverted deploy is redeployed; no base URI change after freeze); isOurCollection (EIP-1167 clone of the factory implementation) gates the keeper and the vanity grinder against hostile collections; keeper gas cap, re-quoted minimums, per-coin transaction allowance; payouts index to the safe block, holder and NFT caps, O(n log n) proofs. Also: THREAT MODEL for the whole system with one hot wallet holding keeper and owner roles and a Safe holding every platform/payee role (docs are in the main repo; assume platform = a Safe). KNOWN AND PENDING A FOUNDERS' DECISION (do not spend effort re-proving it; do comment on the options): the operating wallet owns HolderPayouts and AirdropClaim in the mainnet plan, so a leaked hot key could declare a root paying itself (options in README 'Known risks'). Report anything else that lets the hot wallet, a creator, a holder or an outsider take funds, block payouts, or brick launches, with exact steps and a concrete fix; answer each scope item yes/no with reasoning; say plainly if nothing above Info remains.

| | |
|---|---|
| Repository | https://github.com/JJ-ME55/jigsaw-contracts-audit |
| Commit | `63e943565d430d7d3701036b39dbb8ee7e3243d4` |
| Job | `e587fdcb-14f0-45f8-bd8e-ebe576fed9da` |
| Judged | 2026-10-16 22:08 UTC |
| Findings | 3 medium · 11 low · 7 info |

Four agents audited the code as it is at `63e9435`, each in one area (math, permissions, economics, control flow),
and a judge reproduced, merged and ranked what they found, then read the code once more itself. Nothing in the repository was changed or deployed.

## Findings

### 1. Medium: Threat model gap: a leaked operating key drains LPDeepening and every BuybackAndBurn by sandwiching its own run(0); not covered by the README's 'Known risks'

`src/LPDeepening.sol:97`

```
        if (ethGot < minEthOut || ethGot == 0) revert TooLittleOut();
```

Merged from audit_permissions #2, audit_economics #1 and item (3) of audit_flow's threat model. Reproduced by reading: LPDeepening.run(minEthOut) and BuybackAndBurn.run(minCoinOut) (src/BuybackAndBurn.sol:88) take their only price floor from the caller; `keeper` is immutable in both (LPDeepening.sol:46, BuybackAndBurn.sol:34) and there is no pause or rotation. Each run spends the module's whole balance (deepening: half of all accrued JIG is sold; buyback: the coin's entire slice). README line 139 accepted 'the keeper can sandwich its own runs' as Low because 'the keeper is the platform'. On the mainnet plan the keeper is the hot operating wallet and the platform is a Safe, so that premise no longer holds: whoever holds LAUNCH_PK is not the platform, and keeper.mjs's 3% slippage rule is irrelevant because an attacker calls run(0) from their own script. Robinhood's first-come sequencer lets one sender order three transactions back to back, so no public mempool is needed. The README 'Known risks' section lists only the HolderPayouts/AirdropClaim root path for this key; this path is of the same shape (a leaked hot key takes protocol JIG) and is not listed, so the founders are deciding on an incomplete picture. Fix, smallest first: (a) list it in 'Known risks' next to the root item and state that the keeper role and the claim-owner role should at least live in different processes/keys; (b) a contract floor the module can check itself, e.g. CreatorFeeHook already runs afterSwap on every swap and can keep a short time-weighted coin/JIG observation per pool, and run() requires out >= quoteAtObservedPrice(amount) * (10_000 - MAX_IMPACT_BPS) / 10_000 (MAX_IMPACT_BPS around 500 keeps the keeper's 3% inside it), with the JIG/ETH side using an observation stored by LPDeepening itself; or (c) make `keeper` rotatable by the platform Safe so a leaked key can be cut off. (b) and (c) are contract changes and need re-test; (a) is a doc change for launch day.

**Reproduction**

State: BuybackAndBurn for coin C holds 10,000 JIG (claimable + balance); attacker A holds LAUNCH_PK and a second wallet. On Robinhood Chain: tx1 (second wallet) buys C with JIG on C's pool, moving the price up several-fold inside the seeded range; tx2 (hot wallet) BuybackAndBurn.run(0): hook.claim(), swaps all 10,000 JIG for C at the inflated price, `coinBurned < 0` is false so the check at line 88 passes and the tiny coinBurned is burned; tx3 (second wallet) sells C back for JIG. Same shape on the JIG/ETH pool around LPDeepening.run(0): sell JIG first, run(0) sells half the module's JIG at the depressed price (`ethGot < 0` is false at line 97) and mints the position at that spot, buy back. Expected (README 'Known risks'): a leaked key can at most declare Merkle roots for itself. Actual: it also converts every module's accrued JIG into the attacker's profit, bounded only by pool depth and the 1.5-10% hook fees.

### 2. Medium: A creator can pick the moment of a holder-payout snapshot by switching cadence minutes before a launch-aligned window edge

`offchain/coinSettings.mjs:124`

```
  const from = Math.max(w.start, now); // first seen mid-window: a random moment in what is left of it
```

Reproduced by reading (audit_permissions #1). keeper.mjs:265 sets `prev = j.round?.cadence === s.cadence ? j.round : null`, so a cadence change discards the stored random pick, and roundSchedule() then draws a new moment inside what is left of the CURRENT window: `at = from + rand * (w.end - from)` with `from = now`. Windows are aligned to launchedAt (windowOf), which is public (CreatorFeeHook.pools(id).launchedAt), and every daily boundary is also a weekly boundary. A creator who signs {cadence:'daily'} (nonce+1, allowed after launch by coinSettings.set) a few minutes before a daily boundary gets `at` within those few minutes, and the keeper (5-minute passes) declares the round on its next pass. The only brake, keeper.mjs:270 (`nowS - lastAt >= CADENCES[new]/2`, 12 h for daily), is observable from RoundDeclared events. The file header's goal ('nobody can buy just before a known payout snapshot') is defeated for the creator: they buy coin before the moment they chose, are counted pro rata in the snapshot (payouts.holders() at the safe block), and sell after RoundDeclared. Holders lose the share the creator's temporary float takes. Fix: after a cadence change (prev null while a round has already happened) do not schedule inside the remainder of the launch-aligned window; schedule at = max(now, lastAt + P_new/2) + rand * P_new/2, or compute windows from the last round time instead of launchedAt, keeping the half-period brake.

**Reproduction**

State: coin launched at L, flywheel SnapshotForwarder, cadence weekly, last round declared > 12 h ago, HolderPayouts.balance[coin] = R > 0. Steps: (1) at t = L + 7d - 240 s the creator POSTs settings {cadence:'daily'} with a valid signature (coinSettings.set accepts: cadence may change after launch). (2) The creator buys a large amount of coin. (3) Next keeper pass (<= 5 min): prev = null (cadence differs), windowOf(L,'daily',t) gives end = L + 7d, from = t, at in [t, L + 7d]; the brake passes (lastAt older than 12 h); within one or two passes nowS >= at, prepareRound snapshots balances with the creator holding most of the float, declare() goes on chain. (4) The creator sells after RoundDeclared and claims their share. Expected: the snapshot moment is unpredictable to every holder including the creator. Actual: the creator knows it to within one keeper pass.

### 3. Medium: launch.mjs: a collection deploy whose hash was persisted but never mined pins the build in 'failed' forever (no redeploy path)

`offchain/launch.mjs:190`

```
      catch (e) { if (!e.reverted) throw e; b = setStage(id, 'deploying', { deployTx: null, revertedDeployTx: b.launch.deployTx }); }
```

Reproduced by reading (audit_flow #1). createCollection() persists the hash through onSent before sender.mjs broadcasts it (launch.mjs:73, sender.mjs:38-39). If sendRawTransaction throws after signing (HTTP 429/timeout from the RPC, a sequencer rejection, a nonce collision with a send made outside the lock) or the transaction is later dropped, the hash is on disk and no transaction will ever exist. On every retry runLaunch() calls collectionFromTx(deployTx), which waits 10 minutes for a receipt and throws viem's WaitForTransactionReceiptTimeoutError, which has no `reverted` flag, so line 190 rethrows without clearing deployTx; startLaunch() then keeps prev.deployTx (`deployed = true`, line 157) on the next retry. Only an on-chain revert clears the hash. The keeper (keeper.mjs:231-245) already resolves the same situation from the account nonce and getTransaction and declares a signed-but-never-broadcast send dead after 30 minutes; the launch path does not. The build can never be redeployed from the UI; the way out is editing the build JSON by hand on a mainnet launch day. Fix: persist the nonce with the hash in onSent; in the timeout branch read getTransaction(hash) and getTransactionCount(account,'latest'), and when the node does not know the transaction and the nonce is unused (or used by another hash with no receipt for this one after a few checks) clear deployTx exactly like the reverted case; also clear deployTx when sendRawTransaction itself throws, since the node never accepted it.

**Reproduction**

State: the RPC rejects or drops the raw transaction (rate limit, network error, sequencer rejection) when a build is launched. Steps: 1) startLaunch(build) -> runLaunch -> createCollection; sender.send signs, calls onHash -> setStage(id,'deploying',{deployTx: h}); sendRawTransaction throws. 2) runLaunch catch -> stage 'failed', deployTx = h kept. 3) Retry startLaunch(build): keep = {deployTx: h}, deployed = true. 4) runLaunch -> collectionFromTx(h) waits 10 min -> throws a timeout error without .reverted -> line 190 rethrows -> stage 'failed' again with deployTx still h. Expected: the retry notices the hash never landed (nonce unused, tx unknown) and redeploys. Actual: every retry fails after a 10-minute wait, forever; the build is stuck until someone edits the JSON.

### 4. Low: Keeper drip job counts JIG already distributed and waiting for holder claims as pullable, so it sends a no-op HolderDrip.pull() every 4-8 h per coin with unclaimed JIG

`offchain/keeper.mjs:180`

```
        const amount = kind === 'drip' ? owed + held : owed;
```

Merged from audit_flow #2 and audit_economics #3; reproduced by reading. `held = jig.balanceOf(module)`; a HolderDrip keeps every distributed JIG in its own balance until holders claim (HolderDrip.sol claim() pays from balance; undistributed() = balance - (accounted - paidOut)). So `held` is dominated by JIG an earlier pull already spread, and worth(amount) stays true once a coin's drip holds >= KEEPER_MIN_USD ($5) of unclaimed JIG, whatever arrived since. tick() simulates (pull() returns 0 cleanly after hook.claim()), estimates gas and sends; each such send burns gas, counts against maxPerJobPerDay (3) and the shared daily cap, and is ledgered as success. The comment distrusts the module's undistributed(); a trusted equivalent exists from reads the keeper already does: HolderDrip.accounted() and paidOut() are plain storage views. Fix: for kind 'drip', amount = owed + max(0, held - (accounted - paidOut)); or require owed > 0 and persist `held` after each successful pull, counting only its growth.

**Reproduction**

State: coin C with HolderDrip D; D has pulled once and holds 100 JIG (> $5) that no holder has claimed; hook.claimable(D) = 0; no new fees. plan(): owed = 0, held = 100e18, amount = 100e18, ready = true. tick(): pub.call passes, estimateGas ~60k, D.pull() is sent: hook.claim() returns 0, undistributed() = 0, pull returns 0; onSuccess sets nextAt 4-8 h ahead. Repeats at every nextAt (up to 3 per day per coin) until holders claim. Expected: a drip job is ready only when undistributed JIG is worth >= $5. Actual: a pointless transaction every 4-8 hours per such coin, consuming the per-coin and daily allowances.

### 5. Low: reveal.mjs: when the mint is already closed the drand trigger time is the server clock, so the operator can choose among published rounds and nobody can check the round from chain data

`offchain/reveal.mjs:98`

```
      let pausedUnix = Math.floor(Date.now() / 1000);
```

Merged from audit_flow #3, audit_permissions #6 and audit_economics #4; reproduced by reading. The seed is quicknet round roundAfter(trigger.unix) (randomness.mjs:63) and seedFor() fetches that round whether or not it was already published at trigger time. When run() has to pause the mint, trigger.unix is anchored to the pause transaction's block timestamp (checkable on chain). When the mint is already closed (sold out, or paused earlier by the owner), endMint() returns null, pausedUnix is Date.now() on the server, and trigger.unix = max(r.trigger.unix, pausedUnix) where r.trigger.unix is also the server clock at trigger(). Nothing on chain anchors that number (setRevealSeed records only the seed), so the operator, or anyone on the server (the box that already holds the hot key), can edit build.launch.reveal.trigger.unix or the clock to any past second and thereby choose any already-published round, i.e. choose the permutation; the stored reveal.json stays self-consistent. Even a few seconds of clock lag lets the person pressing the owner button see the candidate seed before committing. The brief asks 'can the operator choose the seed': for sold-out and already-paused reveals, yes. Fix: never use the server clock as the anchor. For a sold-out collection use the timestamp of the block that minted token id == maxSupply (public Transfer log); for an earlier manual pause use the pause transaction's block; store the anchoring block number in reveal.json so anyone can recompute the round; and refuse to proceed if fetchRound(roundAfter(anchor)) is already published at the moment the anchor is first recorded whenever the anchor is 'now'.

**Reproduction**

State: collection with maxSupply 100 sold out at block B (timestamp T). tick() would trigger about T+60 (round roundAfter(T+60)). Instead the operator stops the server for an hour, computes permutation(n, randomness(r)) for every published round r since T, picks r* that gives token 7 (which they hold) the one-of-one, edits the build JSON so launch.reveal = { state:'failed', attempts:0, trigger:{ reason:'sold out', unix: genesis + (r*-2)*3 + 1 }, mintEnded:{ soldOut:true, pausedUnix: same } } and restarts. tick() -> trigger(id,'retry') keeps r.trigger; run() skips endMint (mintEnded set); seedFor(trigger.unix) returns round r* with a valid BLS signature; the permutation is pinned and setRevealSeed(randomness(r*)) is sent. Expected: the round is fixed by chain state so the operator has no choice. Actual: any published round since sell-out can be presented as 'the first round after the trigger' and reveal.json verifies for all of them.

### 6. Low: swap.mjs quotes with tx.origin = 0x0, so an allowlisted wallet is quoted the 60% outsider fee during the JIG window even with a valid proof, and its minOut is set 60% too low

`offchain/swap.mjs:89`

```
  const res = await pub.call({ to: v.quoter, data });
```

Reproduced by reading (audit_flow #4). quoteGross() runs the V4Quoter through eth_call without `account`, so the node executes with from = tx.origin = address(0). JIGLaunchHook.beforeSwap checks the allowlist leaf of tx.origin (src/JIGLaunchHook.sol:147: `keccak256(bytes.concat(keccak256(abi.encode(tx.origin))))`), so during the 5-minute window the proof in hookData never matches and the quote assumes OUTSIDER_FEE (60%). quote() then derives netOut and minOut from that gross, so the site shows ~40% of what the user's real transaction (tx.origin = the allowlisted EOA) delivers, and the minOut it signs is ~60% below the real output, which is the whole protection the swap has (amountOutMinimum in the swap action is 0; only TAKE_ALL enforces minOut). This happens exactly in the minutes the allowlist exists for, when the site is the only swap path. Fix: pass `account` (the user's address, or the operating wallet for keeper quotes) to pub.call so eth_call sets tx.origin to it.

**Reproduction**

State: JIG window open (block.timestamp < windowEnd), wallet W on the allowlist with proof P. Call quote({from: ETH, to: JIG, amountIn: 1e18, account: W, hookData: P}). quoteGross encodes quoteExactInputSingle with hookData P and calls pub.call({to: quoter, data}) with no account; in the simulated swap tx.origin == address(0); leaf(0x0) is not in the tree -> fee = 600000 -> grossOut ~0.4x the normal-fee output; minOut = net * 0.99 of that. The user then sends tx.data from the quote; on chain tx.origin == W, fee = NORMAL_FEE (15000), output ~2.46x the quoted grossOut. Expected: the quote equals what the transaction delivers up to slippage. Actual: the quote understates by ~60% and the signed minimum protects only ~40% of the real output.

### 7. Low: CollectionLauncher offers ownership to an immutable operator with no re-offer path, so a key rotation or lost build record between create() and acceptOwnership() strands the collection's owner functio

`src/CollectionLauncher.sol:69`

```
        ILoomCollectionOwner(collection).transferOwnership(operator);
```

Merged from audit_flow #7 and audit_permissions #4; reproduced by reading. LoomCollection is Ownable2StepUpgradeable (reference/LoomCollection.sol:105), so after create() the clone's owner is the launcher and pendingOwner is `operator` until acceptOwnership() is sent from the operator key (launch.mjs configureClone, line 115, on the next step). The launcher has no function to call anything on a collection it still owns, no way to re-target the pending owner, and `operator` is immutable. If the operating key is rotated or lost between the two steps (the documented response to a hot-key leak, or a crash on launch day followed by a new LAUNCH_PK), or the server loses the build record so configureClone never runs, pause/unpause, setRevealSeed, setBaseURI, freezeMetadata and reserveMint on that collection are unreachable forever: a reveal-later collection stays on its placeholder for good while mints keep paying the creator. Rotating the operating wallet at any time also requires deploying a new CollectionLauncher and updating RH_LAUNCHER, which the runbook should say. Otherwise the launcher is safe: create() is operator-only and stateless, it only calls the immutable Loom factory and the clone that factory returns (never a caller-supplied collection), msg.value is forwarded unchanged and it holds nothing. Fix: add `reoffer(address collection, address to)` callable by the operator (or by a platform admin, the Safe) that calls transferOwnership on a clone the launcher still owns, and/or make the operator settable by the Safe; keep create() operator-only.

**Reproduction**

State: launcher deployed with operator = hot wallet H. Steps: (1) H calls create(c, provenance, uri, true): owner = launcher, pendingOwner = H. (2) Before configureClone runs, LAUNCH_PK is rotated to H2 (a new launcher is deployed for H2). (3) H2 calls acceptOwnership() on the clone: reverts OwnableUnauthorizedAccount(H2); the launcher exposes no transferOwnership passthrough. Expected: the platform can always reach the clone's owner functions. Actual: the collection can never be paused, revealed or frozen by anyone; mint() keeps working.

### 8. Low: HolderDrip's first pull excludes every token minted between the module's deployment and the first fee, although those tokens predate all fees

`src/HolderDrip.sol:72`

```
        lastSupply = collection.totalSupply();
```

Reproduced by reading (audit_permissions #3). The pre-audit fix records lastSupply in the constructor so the first pull does not pay tokens minted after fees accrued. But the module is deployed by the back end BEFORE CoinFactory.launch (README: 'deployed by the back end before launch and passed as flywheel') and the collection keeps minting between deployment and launch (coinSettings' airdrop mode 'soldout' exists because coins launch before sell-out). Fees only start with the pool. So tokens minted after the drip's deployment but before the first fee are excluded from the first pull even though they existed before any JIG arrived, and the keeper never makes a zero pull (keeper.mjs:100 'never a zero pull'), so nothing records the supply at launch. The error is bounded to the first pull's amount (one 4-8 h interval at launch, the highest-volume moment). pull() with amount 0 still sets lastSupply = current before returning, so the fix is operational: have the launch flow call pull() once right after CoinFactory.launch (or let the keeper make one zero pull when it first discovers a drip), which records the launch supply at no accounting cost.

**Reproduction**

State: collection has 100 tokens; the back end deploys HolderDrip (lastSupply = 100). Over the next hours the collection mints to 1,000; then CoinFactory.launch(collection, flywheel = drip); traders pay fees; the hook credits the drip 40 JIG; the keeper pulls. Expected: 40 JIG spread over the 1,000 tokens that all existed before the first fee (0.04 each). Actual: pull() spreads over supply = lastSupply = 100: owed(1..100) = 0.4 JIG each, owed(101..1000) = 0. test/HolderDripFirstPull.t.sol covers only mints after the fee.

### 9. Low: configureClone skips setRevealSeed silently when a different seed is already on chain, so a frozen collection can carry metadata ordered by a seed the contract does not record

`offchain/launch.mjs:126`

```
  if (revealSeed && !(await read('revealSeedSet'))) await send('setRevealSeed', [revealSeed]);
```

Reproduced by reading (audit_permissions #5). The provenance step (lines 119-120) reads the on-chain value and throws on a mismatch, but the reveal-seed step only checks the revealSeedSet flag and never compares revealSeed(); cloneAbi does not even include the revealSeed() view. LoomCollection.setRevealSeed is once-only. If any seed is already set (an owner call made by hand, or an earlier reveal attempt whose build record was lost or edited), the reveal continues: the permutation and metadata are pinned for the drand seed, the base URI is set and frozen, while the contract commits to another seed. Anyone checking perm = fisherYates(N, revealSeed) against the pinned metadata then finds a mismatch and the provable-fairness claim fails, irreversibly once frozen. Fix: read revealSeed() and, when revealSeedSet is true and it differs from the requested seed, throw, mirroring the provenance branch.

**Reproduction**

State: reveal-later collection owned by the operating wallet, reveal state 'waiting'. Steps: (1) the owner key calls setRevealSeed(0xAAAA...) directly (no record on the server). (2) The timer fires, reveal.mjs computes seedInfo.seed = drand randomness S, pins metadata for perm(N, S), calls configureClone({revealSeed: S, baseURI, freeze: true}). (3) revealSeedSet is true so the seed send is skipped; setBaseURI and freezeMetadata go through. Expected: the reveal refuses, as it does for a differing provenance. Actual: the collection is frozen with on-chain revealSeed = 0xAAAA... and metadata ordered by S.

### 10. Low: HolderDrip._foldBurns is unbounded: a batch of tokens burned after a pull is folded in one later pull, which can push pull() past the keeper's gas cap (about 320 burns) or a block limit (thousands)

`src/HolderDrip.sol:162`

```
    function _foldBurns(uint256 supply) internal {
```

Reproduced by reading (audit_math #1; the specialist's gas numbers were recomputed from opcode costs here, the project's lib/ is not vendored so no test was run). markBurned() of a token with id > lastSupply appends to _burnedAbove; the first pull() whose spread supply covers those ids folds every one of them in a single loop (cold SLOAD, burnedCount SSTORE, swap-and-pop SSTOREs: roughly 7,000 gas net per entry after refunds) with no per-call bound, unlike CreatorFeeHook.recycle which caps folding per call. The keeper refuses any send whose estimate x1.3 exceeds KEEPER_GAS_CAP (3,000,000), i.e. estimates above about 2.3M, so from roughly 320 burned-after-pull tokens the drip job backs off every pass ('needs N gas, over the cap') until someone calls pull() by hand with a higher limit (pull is permissionless, so this is recoverable); from several thousand such tokens pull() exceeds the block gas limit and is bricked permanently, because every later pull uses supply = lastSupply >= those ids and must fold them all first. While pull() cannot run the drip's share stays as claimable in the hook and after RECYCLE_AFTER anyone can recycle() it to the pot, so the collection's NFT holders lose their flywheel JIG. The cost to an attacker is owning that many NFTs of the collection and destroying them (markBurned requires ownerOf == dEaD; LoomCollection has no burn), so this is expensive griefing, hence Low. Fix: bound the fold like recycle does (fold at most MAX_FOLD entries per pull, leaving the rest for the next pull), or key burns by the supply bucket they become eligible at so pull() does O(1) work.

**Reproduction**

State: HolderDrip deployed on a collection with totalSupply 10 (lastSupply = 10). Steps: (1) mint tokens 11..310, send each to 0xdEaD and call markBurned(id) for each (all > lastSupply, so each is pushed to _burnedAbove); (2) send 1e18 JIG to the drip and pull() (spreads over 10, lastSupply becomes 310, nothing folded); (3) send 1e18 JIG and pull() again: _foldBurns(310) iterates all 300 entries. Expected: a routine keeper transaction well under KEEPER_GAS_CAP. Actual: about 2.2M gas (x1.3 margin = 2.86M; a few more burns put the estimate over the 3M cap and the keeper refuses the job every pass). With thousands of burned tokens the pull no longer fits a block and no pull() can ever succeed for that drip.

### 11. Low: Keeper marks a creator's whole round window as done from one spot JIG/ETH price read, so a transient dip under minRoundUsd skips the holders' payout for the entire window

`offchain/keeper.mjs:274`

```
        if (s.minRoundUsd > 0 && job.usd < s.minRoundUsd) { j.round.doneIndex = sch.index; j.lastResult = `window ${sch.index} skipped: round worth $${(job.usd ?? 0).toFixed(2)}, under the creator's $${s.minRoundUsd}`; writeState(st); continue; }
```

Reproduced by reading (audit_math #2). job.usd = Number(balance)/1e18 x jigPrice().jigUsd, where jigUsd comes from the JIG/ETH pool's spot sqrtPrice divided into ETH/USD (jig.mjs jigPrice) with no averaging or sanity band. When the creator set minRoundUsd (up to $1,000) and the single read comes in below it, the keeper writes j.round.doneIndex = sch.index, which roundSchedule() treats as 'this window's round is done' (at: null) for the rest of the window, so the round is not retried even if the price recovers a minute later; the JIG waits a full cadence period (weekly by default). JIG launches at about $4k FDV on a pool whose depth is the launch seed, so the spot price is cheap to move for a few blocks around a keeper pass, and the pass cadence is published. Nothing is lost, only delayed, hence Low. Fix: do not finalise doneIndex on a price-based skip; back off and re-evaluate on later passes until the window ends, and compare against a smoothed price (median of recent reads) with the same 'unknown price waits' rule already applied to a null price.

**Reproduction**

State: a coin whose SnapshotForwarder has moved 300 JIG into HolderPayouts.balance[coin]; creator settings minRoundUsd = 1000, cadence weekly; true JIG price $3.60 (round worth $1,080); sch.at has passed. Steps: an outsider sells JIG into the JIG/ETH pool so the spot reads $3.20 (round now $960) during the keeper's next tick(), then buys back. Expected: the round is declared once the price is back above the minimum, or at least retried later in the window. Actual: line 274 sets j.round.doneIndex = sch.index; every later pass in that window gets at: null from roundSchedule() and the holders' 300 JIG waits for the next weekly window at the earliest.

### 12. Low: isOurCollection accepts any EIP-1167 clone of the Loom implementation, not only collections the factory made, so a self-deployed clone passes the keeper and vanity gates

`offchain/launch.mjs:345`

```
  const ours = (code ?? '').toLowerCase() === `0x363d3d373d3d3d363d73${impl.slice(2).toLowerCase()}5af43d82803e903d91602b57fd5bf3`;
```

Reproduced by reading (audit_economics #2). The gate compares runtime bytecode with the minimal-proxy template for factory.implementation(). LoomCollection.initialize() is a public `initializer` on a fresh clone (reference/LoomCollection.sol:85-94, with its own @dev warning), so anyone can deploy a minimal proxy to the same implementation in their own transaction and initialise it with themselves as creator and owner, any maxSupply, any mintPriceWei and no CREATE_FEE. Such a clone is byte-identical to a factory clone and passes isOurCollection, so (a) jig.mjs:186 hands it to vanity.request, and ten such clones with ten requests fill MAX_QUEUE (10) so real creators get 'busy' until each 15-minute grind completes (the queue dedupes per collection, which is why ten clones are needed); (b) keeper.plan() services the coin the attacker launches on it (launch fee only), spending up to maxPerJobPerDay sends per job on it. Damage is bounded by the existing caps (MAX_NFTS, MAX_HOLDERS, gas cap, per-job cap), so this is a gate that does not do what its comment and the README say rather than a fund loss. Fix: decide 'ours' from the factory, not from bytecode: look up the factory's CollectionCreated log for the address (topic 1 = collection; launch.mjs already has the event ABI) once and cache it, keeping the bytecode check as a second condition.

**Reproduction**

On Sepolia: impl = factory.implementation(). Attacker deploys the standard EIP-1167 creation code 0x3d602d80600a3d3981f3363d3d373d3d3d363d73<impl>5af43d82803e903d91602b57fd5bf3 and calls initialize('X','X',1000000,0,1000000,attacker,0,attacker) on it in the same transaction. Expected: isOurCollection(chainId, clone) === false (README: only collections our NFT factory made are served). Actual: getCode(clone) equals the template exactly, isOurCollection returns true and caches it; vanity.request(clone,'A','A') is queued; ten clones return { state: 'busy' } to the next genuine creator; CoinFactory.launch for the clone succeeds (attacker is creator()) and keeper.plan() lists buyback/drip/airdrop/round jobs for it.

### 13. Low: Airdrop snapshot failures back off exponentially even as the 7-day unset window closes, so five consecutive failures on a late ('soldout' or 'days 6') airdrop sweep the coin's 5% to the pot

`offchain/keeper.mjs:191`

```
const backoff = (j) => { j.failures = (j.failures ?? 0) + 1; j.nextAt = Date.now() + 30 * 60_000 * 2 ** Math.min(j.failures, 5); };
```

Reproduced by reading (audit_economics #5). prepareAirdrop() throws on any multicall failure by design (payouts.mjs:119: a partial snapshot must never be used) and tick() answers every prepare failure with backoff(j): nextAt = +1 h, +2 h, +4 h, +8 h, +16 h, then 16 h each. The backoff check (line 260) runs before the 'due' logic, so the forced path at receivedAt + 7 d - 12 h (line 280) does not bypass it. The airdrop's hard deadline is AirdropClaim's UNSET_WINDOW: prepareAirdrop returns null once now > receivedAt + 7 d - 1 h and anyone may sweepUnset() after 7 d. For airdrop mode 'soldout' or 'days: 6' the job is first due at launchedAt + 6 d (coinSettings.airdropAt), so the whole budget is about 23 hours; attempts then fall at +0, +1 h, +3 h, +7 h, +15 h and the sixth at +31 h, past the deadline. Five failed snapshots over 15 hours (a rate-limited multicall batch on a large collection, a provider incident) and the 5% that CoinFactory parked for the NFT holders goes to the pot, irreversibly. The creator's choice narrows the window, but the loss is the holders'. Fix: cap the backoff for kind 'airdrop' at about 10 minutes once now > receivedAt + 5 d, retry a failed multicall batch a few times inside nftOwners before throwing, and consider capping 'soldout'/'days' at 5 days so a day of slack always remains; alert when an airdrop is within 24 h of its deadline and still unset.

**Reproduction**

State: coin C launched at T (receivedAt = T), creator setting airdrop { mode: 'soldout' }, a 10,000-NFT collection not sold out. j.airdrop.at = T + 6 d. At T + 6 d tick() runs prepareAirdrop: nftOwners issues 20 multicall batches; the RPC rate-limits one, viem reports every call in that batch as failed, nftOwners throws, backoff -> failures 1, nextAt +1 h. Same at +1 h (2, +2 h), +3 h (3, +4 h), +7 h (4, +8 h), +15 h (5, +16 h). Next attempt at T + 6 d 31 h > T + 7 d - 1 h: prepareAirdrop returns null ('nothing to set'); at T + 7 d anyone calls AirdropClaim.sweepUnset(C): 50,000,000e18 C to the pot. Expected: the keeper retries quickly while the unset window is closing. Actual: the retry spacing exceeds the remaining window after five failures and the holders' airdrop is lost.

### 14. Low: A prepared round record can be overwritten with a new snapshot while its first declare transaction can still be mined, leaving round N on chain with a root the server has no tree for

`offchain/keeper.mjs:309`

```
      if (record) payouts.saveRecord(record.path, record.rec); // the tree is on disk before its root goes on chain
```

Reproduced by reading (audit_economics #6); the precondition is narrow, hence Low. The record path is rounds/<coin>/<roundCount>.json and recordIsFinal() only protects a record whose declaredTx/setTx was written by onSuccess. The recovery loop concludes 'never broadcast' when, 30 minutes after signing, the RPC returns neither a receipt nor the pending transaction (lines 243-245), and 'replaced' when the nonce moved and three passes saw no receipt (238-239); both clear inflight without onSuccess. A load-balanced RPC whose nodes do not all hold the pending transaction, or a transaction evicted and re-gossiped later (Sepolia/Ethereum; unlikely behind Robinhood's sequencer), produces exactly that. The job then re-prepares round N (roundCount still N on chain), takes a new snapshot with root R2 and overwrites N.json. If the first transaction (root R1) is mined after that re-prepare, round N on chain has R1, the file has R2, payoutProof() serves proofs that fail against R1 for the whole 7-day window, and the rootCheck in onSuccess never runs for R1 because the second declare reverts BadRound. The JIG is not lost (settle() returns it to balance[coin]) but the round's holders are paid a week late from a different snapshot with no alert. Fix: store the signed hash in the record from onHash (sentTx) and treat a record with sentTx but no declaredTx as final until roundCount on chain proves it was not mined; or key records by root and resolve the served tree by reading rounds(coin, N).root; and have recovery call roundRoot()/roundCount() before declaring a round transaction dead.

**Reproduction**

State: coin C has 500 JIG in HolderPayouts.balance, roundCount 0. Pass 1: prepareRound -> 0.json {root R1, declaredTx null}, send h1 at nonce k, waitForTransactionReceipt times out at 5 min, inflight {tx h1, nonce k} kept. Passes over 30 min: getTransactionReceipt(h1) null; getTransactionCount(latest) == k; getTransaction(h1) null on the answering node -> 'never broadcast', inflight null, backoff. Later: prepareRound -> roundCount still 0, new snapshot R2, recordIsFinal(0.json) false -> 0.json overwritten with R2, send h2 at nonce k+1. h1 is then mined: declare(C, R1, 500) succeeds, round 0 = R1. h2: declare(C, R2, 500) reverts BadRound (balance 0). Expected (payouts.mjs header): the tree for the root on chain is always on disk. Actual: rounds/C/0.json holds R2, every claim for round 0 fails BadProof until expiry, then settle() returns the 500 JIG to the balance.

### 15. Info: sender.mjs has no replacement or gas-bump path; one transaction stuck in a mempool blocks every later send on that chain indefinitely

`offchain/sender.mjs:40`

```
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: timeoutMs });
```

Reproduced by reading (audit_flow #5). send() takes the 'pending' nonce, broadcasts and waits up to timeoutMs. If the transaction is accepted into a mempool but not mined (underpriced on Ethereum/Sepolia; a sequencer queue that accepted but is not sequencing), later sends take nonce+1, nonce+2 and queue behind it. The keeper's recovery loop (keeper.mjs:243-244) sees getTransaction(hash) non-null and waits forever ('still in the mempool'); nothing resends or replaces, by design. Nothing double-pays, but every keeper job, launch, reveal and allowlist send on that chain stalls until a human replaces the nonce from outside the server. On Robinhood a sequencer includes or rejects quickly, so this mostly matters on Sepolia/Ethereum, but it is the one liveness failure the design has no answer for. Fix: when an in-flight hash has been visible but unmined for longer than N minutes, rebroadcast the same nonce with a higher fee (same calldata, same to) through the lock and record the new hash on the same marker; or expose an admin 'replace nonce' action that sends a self-transfer at that nonce.

**Reproduction**

State: send A broadcast with nonce n at a fee the network no longer includes. Keeper pass: inflight.tx = A, receipt null, mined == n, getTransaction(A) returns the pending tx -> `continue` forever. Next keeper send B uses nonce n+1 (pending count), waits 5 min, times out; B's job also goes inflight. Expected: a stuck nonce is replaced after a bounded time. Actual: all jobs on the chain accumulate unresolved inflight markers and no send ever lands until manual intervention.

### 16. Info: payouts.expiredRounds reads every round of every forward coin on every keeper pass (unbounded growth in RPC calls)

`offchain/payouts.mjs:101`

```
  for (let r = 0; r < n; r++) { const R = await p.readContract({ address: a.payouts, abi: payoutsAbi, functionName: 'rounds', args: [coin, BigInt(r)] }); if (!R[4] && Number(R[3]) < now) out.push(r); }
```

Reproduced by reading (audit_flow #6). plan() runs every 5 minutes and, for each coin whose flywheel is a SnapshotForwarder, loops over all roundCount(coin) rounds with one eth_call each. Rounds are append-only and settled rounds never need re-reading, so the per-pass cost grows linearly with lifetime rounds per coin (daily cadence: 365 reads per coin per year, every pass), and plan() is also what GET /admin/keeper calls. Fix: persist the lowest unsettled round index per coin in keeper.json and start the loop there; rounds settle in order of expiry so the index only moves forward.

**Reproduction**

State: coin C on daily cadence live for 400 days -> roundCount(C) = 400, 399 settled. Every keeper pass (288 per day) makes 400 readContract('rounds') calls for C before any job runs. Expected: constant work per pass. Actual: linear in the coin's age, multiplied by the number of forward coins, on every pass and every admin page load.

### 17. Info: Collections that reveal immediately are never frozen, so the hot wallet keeps the power to rewrite every token's metadata

`offchain/launch.mjs:237`

```
      const txs = await configureClone(s.chainId, collection, { provenanceHash: provenance, baseURI: pinned.baseURI });
```

Reproduced by reading (audit_flow #8). `freeze` is only ever passed for the reveal-later plan (reveal.mjs:124, r.freeze). An immediate-reveal launch sets provenance and baseURI and stops; metadataFrozen stays false and the owner (the operating wallet) can call setBaseURI at any time (upgradeImageLinks/upgradeWebBaseURI do exactly that on Sepolia). Under the stated threat model a leaked key can point every live collection's tokenURI at arbitrary content; the provenance hash is a commitment, not an enforcement. This is a design choice (fixing links later) but belongs in the threat model and the collection's public facts. Fix: offer `freeze` for immediate reveals too (default on for mainnets once the base URI is content-addressed), or freeze after a grace period from the keeper.

**Reproduction**

State: a collection launched with reveal disabled on Robinhood. After launch metadataFrozen() == false. Any holder of LAUNCH_PK sends setBaseURI('https://attacker/') -> every tokenURI changes; freezeMetadata() afterwards makes that permanent. Expected per the brief ('no base URI change after freeze'): a freeze exists for every live collection. Actual: immediate-reveal collections never reach a frozen state unless someone does it by hand.

### 18. Info: holders() falls back to the latest block when the 'safe' tag is unavailable, silently re-enabling the phantom-balance case the comment guards against

`offchain/payouts.mjs:51`

```
  const head = await p.getBlock({ blockTag: 'safe' }).then((b) => b.number).catch(() => p.getBlockNumber());
```

Reproduced by reading (audit_economics #7). holders() persists the index incrementally and never re-reads a block, so a block indexed at latest and then reorged leaves a wrong balance in <coin>.json for good, which is why the code reads 'safe'. The catch() turns an RPC that does not support the tag (or a transient error) into exactly that unsafe behaviour without a log line. On an Arbitrum Orbit chain the sequencer feed can be reorganised until the batch is posted. Fix: on failure use latest minus a fixed depth (e.g. 1,000 blocks on Robinhood) or skip the round this pass with a logged reason.

**Reproduction**

State: RPC_URL points at a node that answers eth_getBlockByNumber('safe') with an error. prepareRound -> holders(): head = latest. A sequencer-level reorg replaces the last blocks, including a 100,000 C transfer from A to B that was indexed. Expected: the index only ever contains finalised transfers. Actual: idx.balances[B] keeps the 100,000 and idx.fromBlock has moved past the block, so every future round pays B for coin it does not hold, with no recovery path short of deleting the index file.

### 19. Info: CollectionLauncher commits whatever provenance it is given, including bytes32(0), which LoomCollection then treats as committed forever

`src/CollectionLauncher.sol:66`

```
        ILoomCollectionOwner(collection).setProvenanceHash(provenance);
```

Reproduced by reading (audit_economics #8, narrowed). LoomCollection.setProvenanceHash sets provenanceSet = true for any value, zero included (reference/LoomCollection.sol:144-151), and refuses a second call; create() passes the value through with no check. launch.mjs:67 only checks `!provenance`, so the JS side relies on viem's fixed-size encoder to reject a short value (current viem throws on a bytes32 whose length is not 32 bytes, so an empty provenance.txt fails before anything is sent; a provenance.txt holding 64 zero characters, or a direct call to create(), still reaches the contract). The clone is then created with a meaningless commitment; a later configureClone sees onChain == 0 (line 119), calls setProvenanceHash again and reverts ProvenanceAlreadySet, so the launch fails after the collection exists and the fee is spent, and no real provenance can ever be recorded for it. Fix: `if (provenance == bytes32(0)) revert BadProvenance();` in create(), and have launch.mjs assert /^0x[0-9a-f]{64}$/ and non-zero before building the call.

**Reproduction**

Call CollectionLauncher.create(c, bytes32(0), 'ipfs://placeholder', true) from the operator with the creation fee. Expected: revert, a zero hash commits nothing. Actual: the collection is created, provenanceSet is true with provenanceHash 0; a later configureClone(provenanceHash: real) throws after one reverted transaction.

### 20. Info: Threat model for the one hot wallet: every power it holds on the mainnet plan, and comments on the three options for the pending HolderPayouts/AirdropClaim decision

`src/HolderPayouts.sol:61`

```
    function declare(address coin, bytes32 root, uint256 total, uint64 expiry) external onlyOwner returns (uint256 round) {
```

Trust assumptions, not new defects (merged from audit_flow #9 and the threat-model parts of the other specialists). Roles the operating key holds on the mainnet plan and what a leaked key can do with each, assuming platform/pot/payees = the Safe: (1) HolderPayouts owner: declare(coin, root, balance[coin], now+1) with a one-leaf tree paying itself for every coin with a non-zero balance, claimed in the same block with an empty proof (known, pending). (2) AirdropClaim owner: setDrop(coin, oneLeafRoot, balance) for every coin whose drop is unset; up to 5% of every recently launched coin's supply (known, pending; the 7-day sweepUnset only protects coins already past 7 days). (3) LPDeepening.keeper and every BuybackAndBurn.keeper: run(0) sandwiched by its own trades (separate Medium finding). (4) Owner of every collection: pause, setBaseURI until freeze (separate Info), setRevealSeed once, reserveMint up to the reserve cap, freezeMetadata (permanent), acceptOwnership on new ones. (5) CollectionLauncher.operator: create collections, spending the create fee. (6) Keeper gas: wasted by hostile modules only within KEEPER_GAS_CAP x maxPerJobPerDay per coin. Not held by the hot key: CreatorFeeHook/JIGLaunchHook owner (JIG deployer, nothing left to set after binding), CoinFactory.platform/setLaunchFee, PotVault owner, LPDeepening.platform (the Safe). On the three README options: option 2 (Safe declares everything) removes automation for rounds that must happen at random moments and for airdrops that must land within 7 days, so it will be missed in practice. Option 3 leaves (1)+(2)+(3) as the largest loss path in the system. Option 1 is the right shape; a cheaper variant that needs no new timing logic: keep the hot wallet as proposer but let a declared root become claimable only after a delay (12-24 h) during which the Safe can cancel it, so the Safe acts only to stop a theft, not to allow every round. Either way the claim contracts need a pending-root state, a cancel, and the keeper must compute the round's expiry from the activation time. At minimum, put the keeper key and the claim-owner key in different processes so a keeper compromise does not also get (1)+(2).

**Reproduction**

State: LAUNCH_PK leaked. Steps for (1): for each coin with balance[coin] > 0 call declare(coin, keccak256(bytes.concat(keccak256(abi.encode(attacker, balance)))), balance, block.timestamp+1), then claim(coin, round, attacker, balance, []) in the same block (an empty proof verifies a single-leaf tree). Steps for (2): setDrop(coin, sameShapeRoot, balanceOf(airdrop)) then claim. Expected: a bounded, delayed or two-party path for each. Actual: immediate and unilateral; the README lists (1) and (2) and omits (3).

### 21. Info: Scope answers (yes/no with reasons) for every item in the brief; nothing above Medium remains, and the Mediums are a trust-model gap, a creator timing manipulation and an operational brick

`src/CoinFactory.sol:133`

```
        if (bytes20(p.salt) != bytes20(p.collection)) revert BadSalt();
```

Verified by reading every file in src/, script/, offchain/ and reference/LoomCollection.sol; the repository does not vendor lib/, so forge build and the fork suites were not run here and no proof file accompanies any finding (none is Critical or High). (1) CoinFactory CREATE2: salt binding sufficient against front-running: YES. The deployer is the factory, bytes20(salt) must equal the collection, only _controlsCollection(msg.sender) may launch, coinOf is written only inside a successful launch, and predictCoin/coinInitCodeHash use the same abi.encode(name, symbol, SUPPLY, collection, factory) as launch(). A mempool salt is useless to anyone else; outsiders cannot grief or brick a collection's slot (a reverted launch consumes no CREATE2 address); a creator can only brick their own slot. (2) JIG via CreateX CREATE3 with a deployer-guarded salt: consistent with CreateX's guard and asserted in _deployJig; not re-executed here. (3) Mainnet refusal: every script and the keeper/launch paths check 1 and 4663 against ALLOW_MAINNET_DEPLOY / ALLOW_MAINNET; Robinhood v4 addresses (Universal Router, Quoter, Multicall3 in swap.mjs/payouts.mjs) could not be verified from here and should be checked with cast code on the day. (4)/(5) HolderDrip: spreading over lastSupply, open baselines on claim, constructor lastSupply and _foldBurns(supply) are consistent and live cannot underflow; two Lows kept (first-pull anchor at deployment, unbounded fold). (6) CollectionLauncher: safe against reentrancy (operator-only, stateless, calls only the immutable factory and the clone it returns), non-Loom collections (never takes a collection as input), value (forwarded unchanged); ownership exposure and the zero-provenance edge are the kept Low/Info. (a) keeper/sender: pay twice or overlap: NO (marker before signing, hash before broadcast, inflight blocks a second send, restart resolution from receipt then nonce then mempool with a 3-pass lag tolerance; the one narrow race is the kept Low on record overwrite). Min-out: quoted from V4Quoter right before each send at 3%; sandwichable by outsiders only within 3% minus the hook fees on both legs, not profitable, and Robinhood has no public mempool; by the keeper key holder, YES (Medium). Inside the JIG window: NO (status fails closed; windowOpen skips the pass). Malicious coin/module/collection: bounded to gas <= KEEPER_GAS_CAP x maxPerJobPerDay per coin behind isOurCollection (whose bytecode check is bypassable, kept Low); the keeper signs only run(min)/pull()/collectFees/claimFor/declare/setDrop with no value and holds no approvals. (b) payouts/merkle: leaves keccak256(keccak256(abi.encode(account, amount))), sorted pairs, odd node carried: MATCH HolderPayouts/AirdropClaim/OpenZeppelin; split floors so total <= balance and declare() rechecks; the Transfer index persists fromBlock only after each chunk so a crash cannot double count; protocol addresses excluded (PLATFORM_ADDRESS must be set on mainnet); the tree is written before the send (keeper.mjs:309). (c) coinSettings: creator()-else-owner() mirrors _controlsCollection, verifyMessage covers EIP-1271, nonce = current+1 single-use, the message carries chain and collection so it cannot be replayed across either, airdrop timing locked once coinOf is set, minRoundUsd capped at 1,000: SOUND; the cadence-edge manipulation is the kept Medium. (d) swap.mjs: actions SWAP/SETTLE_ALL/TAKE_PORTION/TAKE_ALL with amountOutMinimum 0 in the swap and the user's minOut after the fee in TAKE_ALL, two-hop path with the proof only on the JIG hop, Permit2 approvals listed: CORRECT; the tx.origin quoting gap during the window is the kept Low. (e) vanity.mjs: the salt is re-derived through predictCoin and its first 20 bytes checked against the collection before being stored: YES, it cannot hand out a salt bound to another collection. (f) jig.mjs allowlist: leaf keccak256(keccak256(abi.encode(address))), sorted pairs, odd node carried: MATCHES JIGLaunchHook.isAllowlisted. (g) reveal/

**Reproduction**

Not a defect; this entry records the per-item verdicts and the verification performed (static reading of every file in src/, script/, offchain/ and the Loom reference; forge was not run because lib/ is not vendored in the repository).

---

Judge's submission `d948d94cb9f5b086d0f67a68ecdb629ccf50459ff63a1df472785218cb9fdabe`, accepted on the IdentityMD network. Acceptance means the report met the job's checks;
it is not a guarantee that the code has no other defects.
