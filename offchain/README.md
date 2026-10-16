# Off-chain money paths (Jigsaw back end), for the audit

These Node modules move money or decide who gets it. They are copied from the private back end for review; they run on one server with one hot wallet (the "operating wallet"). Read with the contracts in `../src`.

| File | What it does |
|---|---|
| keeper.mjs | every 5 minutes: LPDeepening.run, BuybackAndBurn.run (quoted min-out), HolderDrip/SnapshotForwarder pulls, claimFor(pot), LP fee collects, payout rounds, airdrops, launch-fee check. Rule: a marker with the account nonce is written before every send; one pass at a time; per-job and daily caps; backoff |
| payouts.mjs, merkle.mjs | coin-holder snapshots (Transfer-log index) and NFT-holder airdrop snapshots, pro-rata splits, OpenZeppelin-compatible Merkle trees written to disk before HolderPayouts.declare / AirdropClaim.setDrop |
| coinSettings.mjs | creator-chosen payout cadence and airdrop timing, authorised by the collection creator's signature (nonce against replay) |
| swap.mjs | builds Universal Router calldata for exact-input swaps with a platform fee (TAKE_PORTION) |
| vanity.mjs | grinds the CREATE2 salt for creator coins (collection-bound, verified against CoinFactory.predictCoin) |
| jig.mjs, coins.mjs, v4state.mjs | JIG allowlist tree and proofs, launch parameters and start price, pool state reads |
| reveal.mjs, randomness.mjs | NFT reveal: drand quicknet seed (BLS-verified against the pinned key), keccak Fisher-Yates token-to-art map, setRevealSeed/setBaseURI/freeze |
| launch.mjs | NFT collection creation and configuration (owner calls) |
| deploy-nft-factory.mjs | deploys the NFT implementation and factory byte-identical to Sepolia's |
