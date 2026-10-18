# Off-chain money paths (Jigsaw back end), for the audit

These Node modules move money or decide who gets it. They are copied from the private back end for review; they run on one server with one hot wallet (the "operating wallet"). Read with the contracts in `../src`.

| File | What it does |
|---|---|
| keeper.mjs | every 5 minutes: LPDeepening.run and BuybackAndBurn.run (min-out re-quoted right before the send, after the price check), HolderDrip and RewardsForwarder pulls (a forwarder waits for nextPullAt), claimFor(pot), LP fee collects, the per-NFT airdrop push (AirdropClaim.claimFor in batches of 15, gated on the coin's earned platform fees covering the gas), launch-fee check. Serves only coins on collections our NFT factories made (launch.mjs isOurCollection). A marker before every send and the hash before broadcast; an in-flight send is resolved from its receipt or nonce after a restart, never resent; one pass at a time; per-job and daily caps; gas capped; backoff; nothing runs while the JIG window status is unknown |
| priceguard.mjs | the keeper's price check (18 Oct): spot price readings per pool, one per pass, 12 h window; a trade waits when the spot is more than 10% off their median or the history is too short |
| sender.mjs | the one way the operating wallet sends: per-chain lock (one nonce queue for keeper, launches, reveals, phase roots, flywheel deploys), sign, hand the hash to the caller to persist, broadcast, wait, throw on revert |
| rewards.mjs | read side of holder rewards and the per-NFT airdrop: what a holder earned, which ids are still owed, the airdrop push status (fees earned vs push gas) |
| phases.mjs, merkle.mjs | mint phases for JigsawCollection: validation before any spend, the on-chain Phase tuple, wallet lists kept per root (proofs served only for the root on chain), add-wallets (setPhaseRoot) one call at a time per build; OpenZeppelin-compatible Merkle trees (also JIG's allowlist) |
| flywheels.mjs | deploys a collection's flywheel module (HolderDrip, BuybackAndBurn, RewardsForwarder) once, before its coin: pending tx persisted before broadcast, one call at a time per collection, refused once the coin exists (bytecode from the Foundry build, lib/artifacts/flywheels.json in the back end) |
| swap.mjs | Universal Router calldata for exact-input swaps with a 0.25% platform fee (TAKE_PORTION) |
| vanity.mjs | grinds the CREATE2 salt for creator coins (collection-bound, verified against CoinFactory.predictCoin) |
| jig.mjs, coins.mjs, v4state.mjs | JIG allowlist tree and proofs, launch parameters and start price, pool state reads |
| reveal.mjs, randomness.mjs | NFT reveal: drand quicknet seed (BLS-verified against the pinned key) from the round after the block where minting ended, keccak Fisher-Yates token-to-art map, setRevealSeed/setBaseURI/freeze |
| launch.mjs | collection creation through CollectionLauncher (Loom) or JigsawCollectionFactory (phases), provenance and first URI in the creating transaction, idempotent configuration, isOurCollection over both factories |
| deploy-nft-factory.mjs, go-day-env.mjs, jig-start-tick.mjs | go day: the Loom NFT factory deploy (byte-identical to Sepolia), the server env from script/go-day.sh's result (dry run by default), the JIG start tick from the day's ETH price. In the back end they live in scripts/, so relative paths assume that layout |
