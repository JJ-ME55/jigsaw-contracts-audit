# Off-chain money paths (Jigsaw back end), for the audit

These Node modules move money or decide who gets it. They are copied from the private back end for review; they run on one server with one hot wallet (the "operating wallet"). Read with the contracts in `../src`.

| File | What it does |
|---|---|
| keeper.mjs | every 5 minutes: LPDeepening.run, BuybackAndBurn.run (min-out re-quoted right before the send), HolderDrip/SnapshotForwarder pulls, claimFor(pot), LP fee collects, payout rounds, airdrops, launch-fee check. Serves only coins on collections our NFT factory made (launch.mjs isOurCollection). Rules: a marker is written before every send and the hash before broadcast; after a restart an in-flight send is resolved from its receipt or the nonce, never resent; one pass at a time; airdrops first with their own cap; per-job caps and a daily cap that grows per serviced coin; every send's gas capped; backoff; snapshots only when due; nothing runs when the JIG window status is unknown |
| sender.mjs | the one way the operating wallet sends on the launch chains: per-chain in-process lock (one nonce queue for keeper, launches, reveals, allowlist root), sign, hand the hash to the caller to persist, broadcast, wait, throw on revert |
| payouts.mjs, merkle.mjs | coin-holder snapshots (Transfer-log index) and NFT-holder airdrop snapshots, pro-rata splits, OpenZeppelin-compatible Merkle trees written to disk before HolderPayouts.declare / AirdropClaim.setDrop |
| coinSettings.mjs | creator-chosen payout cadence and airdrop timing, authorised by the collection creator's signature (nonce against replay) |
| swap.mjs | builds Universal Router calldata for exact-input swaps with a platform fee (TAKE_PORTION) |
| vanity.mjs | grinds the CREATE2 salt for creator coins (collection-bound, verified against CoinFactory.predictCoin) |
| jig.mjs, coins.mjs, v4state.mjs | JIG allowlist tree and proofs, launch parameters and start price, pool state reads |
| reveal.mjs, randomness.mjs | NFT reveal: drand quicknet seed (BLS-verified against the pinned key), keccak Fisher-Yates token-to-art map, setRevealSeed/setBaseURI/freeze |
| launch.mjs | NFT collection creation through CollectionLauncher (../src: provenance and first URI committed in the creating transaction; mainnets refuse without it), ownership acceptance, idempotent configuration (owner calls), isOurCollection |
| deploy-nft-factory.mjs | deploys the NFT implementation and factory byte-identical to Sepolia's (in the back end it lives in scripts/, so its relative paths assume that layout) |
