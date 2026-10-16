// Provably random reveal for a launched collection.
//
// The contract (LoomCollection) has no on-chain shuffle: tokenURI is baseURI + id + ".json". So the randomness is
// applied to WHICH art each token id gets, in a way anyone can check:
//   1. At launch the art is composed and pinned in art order (index 1..N) and the provenance hash of that order is set
//      in the same transaction that creates the collection (CollectionLauncher), so no mint can come first (compose.py:
//      sha256 over the image hashes in id order). The base URI is NOT set: every token shows the unrevealed
//      placeholder (its cover is art #1; which token gets which art is unknown until the seed exists).
//   2. When minting sells out, or the creator's timer passes, the reveal is triggered; an early reveal pauses the mint
//      first. The seed is the drand randomness of the first round published after the later of the trigger and the
//      block that confirmed the pause (randomness.mjs), so anyone can check which round was due. It is recorded on the
//      contract with setRevealSeed.
//   3. perm = fisherYates(N, seed) (below, keccak-driven, documented in reveal.json next to the metadata). Token id t
//      gets art index perm[t]. The revealed metadata directory is pinned and becomes the base URI. If the launch asked
//      for it, metadata is then frozen.
// Anyone can recompute perm from the seed and compare each token's art hash against the provenance order.
import fs from 'node:fs';
import path from 'node:path';
import { keccak256, encodePacked, createPublicClient, http } from 'viem';
import { load, update, buildDir, list, ledger } from './store.mjs';
import { pinFolder } from './pin.mjs';
import { configureClone, readSupply, endMint, webBase, IPFS_GATEWAY, CHAINS } from './launch.mjs';
import { seedFor } from './randomness.mjs';

const MAX_ATTEMPTS = 5;

/** Fisher-Yates over 1..n driven by keccak256(seed, counter). perm[t] = art index for token t (1-based). */
export function permutation(n, seed) {
  const a = Array.from({ length: n }, (_, i) => i + 1);
  let counter = 0n; let pool = 0n; let bits = 0;
  const next = (bound) => { // exactly uniform integer in [0, bound) from a keccak stream, rejection-sampled per 64-bit chunk
    for (;;) {
      if (bits < 64) { pool = BigInt(keccak256(encodePacked(['bytes32', 'uint256'], [seed, counter++]))); bits = 256; }
      const chunk = pool & ((1n << 64n) - 1n); pool >>= 64n; bits -= 64;
      const b = BigInt(bound); const limit = (1n << 64n) - ((1n << 64n) % b);
      if (chunk < limit) return Number(chunk % b);
    }
  };
  for (let i = n - 1; i > 0; i--) { const j = next(i + 1); [a[i], a[j]] = [a[j], a[i]]; }
  const perm = new Array(n + 1); for (let t = 1; t <= n; t++) perm[t] = a[t - 1];
  return perm;
}

/** Write `metadata_revealed/<t>.json` for every token from the art-order metadata, renumbered. Returns the count. */
export function writeRevealed(out, perm, { name, seedInfo, provenance }) {
  const src = path.join(out, 'metadata'); const dst = path.join(out, 'metadata_revealed');
  fs.rmSync(dst, { recursive: true, force: true }); fs.mkdirSync(dst, { recursive: true });
  const n = perm.length - 1;
  for (let t = 1; t <= n; t++) {
    const art = perm[t];
    const m = JSON.parse(fs.readFileSync(path.join(src, `${art}.json`), 'utf8'));
    m.name = String(m.name ?? '').replace(/#\d+\s*$/, '').trim(); m.name = `${m.name || name} #${t}`;
    m.art_index = art; // the position in the provenance order
    fs.writeFileSync(path.join(dst, `${t}.json`), JSON.stringify(m, null, 1));
  }
  fs.writeFileSync(path.join(dst, 'reveal.json'), JSON.stringify({
    algorithm: 'token t gets art index perm[t]; perm = Fisher-Yates over 1..N, swaps drawn from keccak256(abi.encodePacked(bytes32 seed, uint256 counter)) in 64-bit chunks with rejection sampling (backend/lib/reveal.mjs permutation())',
    n, provenance, ...seedInfo,
  }, null, 1));
  return n;
}

export function revealState(b) { return b?.launch?.reveal ?? null; }

/** Launch settings -> the reveal plan stored on the build, or null when the launch reveals immediately. */
export function planFromSettings(s) {
  if (!s?.reveal?.enabled) return null;
  const hours = Number(s.reveal.timerHours ?? 0);
  return { state: 'waiting', freeze: s.reveal.freeze !== false, revealAt: hours > 0 ? new Date(Date.now() + hours * 3600_000).toISOString() : null, attempts: 0 };
}

/** Trigger now (owner button or the scheduler). Persists the marker before anything runs; refuses to overlap. */
export function trigger(id, reason) {
  const b = update(id, (d) => {
    const r = d.launch?.reveal; if (!r) throw new Error('this collection reveals immediately; nothing to do');
    if (d.launch.stage !== 'live') throw new Error(`launch is ${d.launch.stage}`);
    if (r.state !== 'waiting' && r.state !== 'failed') throw new Error(`reveal is ${r.state}`);
    if (r.state === 'failed' && (r.attempts ?? 0) >= MAX_ATTEMPTS) throw new Error('reveal has failed too many times; a founder must look');
    d.launch.reveal = { ...r, state: 'seeding', trigger: r.trigger ?? { reason, at: new Date().toISOString(), unix: Math.floor(Date.now() / 1000) }, attempts: (r.attempts ?? 0) + 1, error: undefined };
  });
  run(id).catch(() => {});
  return b.launch.reveal;
}

async function run(id) {
  const setR = (patch) => update(id, (d) => { d.launch.reveal = { ...d.launch.reveal, ...patch }; });
  try {
    let b = load(id); const L = b.launch; const r = L.reveal; const s = L.settings;
    const out = path.join(buildDir(id), 'out_1024');
    // 0. an early reveal (timer or owner) ends the mint first: once art is mapped to ids, a still-open mint could be
    //    sniped id by id. Done before the seed is fixed, so no mint lands after the randomness is known.
    if (!r.mintEnded) {
      const { totalSupply, maxSupply } = await readSupply(s.chainId, L.collection);
      const tx = totalSupply < maxSupply ? await endMint(s.chainId, L.collection) : null;
      // the seed must be a round published after minting stopped: the trigger time moves to the block that confirmed
      // the pause (checkable on chain; the server clock if the pause was already in place), so nobody can know the
      // token-to-art map while a mint is still possible. Persisted, so a retry keeps it.
      let pausedUnix = Math.floor(Date.now() / 1000);
      if (tx) { const c = CHAINS[Number(s.chainId)]; const p = createPublicClient({ chain: c.chain, transport: http(c.rpc) }); const rc = await p.getTransactionReceipt({ hash: tx }); pausedUnix = Number((await p.getBlock({ blockNumber: rc.blockNumber })).timestamp); }
      setR({ mintEnded: { at: new Date().toISOString(), soldOut: totalSupply >= maxSupply, minted: totalSupply.toString(), pauseTx: tx, pausedUnix }, trigger: { ...r.trigger, unix: Math.max(r.trigger.unix, pausedUnix), seededAfterMintEnded: true } });
      b = load(id);
    }
    // 1. seed: drand round after the trigger (moved to the end of minting above); fixed, so a retry gets the same one
    let seedInfo = b.launch.reveal.seedInfo;
    if (!seedInfo) {
      const triggerUnix = b.launch.reveal.trigger.unix;
      for (let i = 0; i < 20 && !seedInfo; i++) { seedInfo = await seedFor(triggerUnix); if (!seedInfo) await new Promise((res) => setTimeout(res, 3000)); }
      if (!seedInfo) throw new Error('randomness round not published yet; retry');
      setR({ seedInfo });
    }
    // 2. permutation + metadata
    const n = Number(load(id).composed?.count ?? s.maxSupply);
    let pinned = load(id).launch.reveal.pinned;
    if (!pinned) {
      setR({ state: 'pinning' });
      const perm = permutation(n, seedInfo.seed);
      writeRevealed(out, perm, { name: s.name, seedInfo, provenance: L.provenance });
      const meta = await pinFolder(path.join(out, 'metadata_revealed'), `${(s.symbol || 'collection').toLowerCase()}-revealed`);
      pinned = { metadataCid: meta.cid, baseURI: webBase(meta.cid), baseURIIpfs: `ipfs://${meta.cid}/`, files: meta.files, pinnedAt: new Date().toISOString() };
      setR({ pinned });
    }
    // 3. on chain: seed, base URI, freeze
    setR({ state: 'configuring' });
    const txs = await configureClone(s.chainId, L.collection, { revealSeed: seedInfo.seed, baseURI: pinned.baseURI, freeze: r.freeze });
    update(id, (d) => { d.launch.reveal = { ...d.launch.reveal, state: 'done', txs, finishedAt: new Date().toISOString() }; d.launch.baseURI = pinned.baseURI; d.launch.revealed = true; });
    ledger(`${id},reveal,${L.collection},${s.chainId},${pinned.baseURI},${seedInfo.source}:${seedInfo.round}`);
  } catch (e) {
    setR({ state: 'failed', error: e.message });
  }
}

/** At startup: a reveal a restart cut off mid-step is marked failed (same trigger, so the same seed) and the tick
 *  retries it; without this it would sit in seeding/pinning/configuring for good (pre-audit review, 16 Oct). */
export function recoverInterrupted() {
  let n = 0;
  for (const b of list()) {
    const r = b.launch?.reveal;
    if (r && ['seeding', 'pinning', 'configuring'].includes(r.state)) {
      update(b.id, (d) => { d.launch.reveal = { ...d.launch.reveal, state: 'failed', error: `interrupted in ${r.state} by a restart; retried automatically` }; });
      n++;
    }
  }
  return n;
}

let _ticking = false;
/** Every minute: trigger reveals whose condition is met. One pass at a time; a failed reveal is retried with backoff. */
export async function tick() {
  if (_ticking) return; _ticking = true;
  try {
    for (const b of list()) {
      const r = b.launch?.reveal; if (!r || b.launch.stage !== 'live') continue;
      if (r.state === 'failed') {
        if ((r.attempts ?? 0) >= MAX_ATTEMPTS) continue;
        const since = Date.now() - new Date(b.updatedAt ?? 0).getTime();
        if (since > 5 * 60_000 * (r.attempts ?? 1)) { try { trigger(b.id, 'retry'); } catch {} }
        continue;
      }
      if (r.state !== 'waiting') continue;
      const timer = r.revealAt && Date.now() >= new Date(r.revealAt).getTime();
      let soldOut = false;
      if (!timer) { try { const { totalSupply, maxSupply } = await readSupply(b.launch.settings.chainId, b.launch.collection); soldOut = totalSupply >= maxSupply && maxSupply > 0n; } catch {} }
      if (timer || soldOut) { try { trigger(b.id, timer ? 'timer' : 'sold out'); } catch (e) { console.error('reveal', b.id, e.message); } }
    }
  } finally { _ticking = false; }
}

/** Placeholder metadata every token shows before the reveal. Pinned once per launch. */
export async function pinPlaceholder(id, { name, description }) {
  const dir = path.join(buildDir(id), 'out_1024', 'unrevealed'); fs.mkdirSync(dir, { recursive: true });
  const sample = path.join(buildDir(id), 'out_1024', 'images', '1.png');
  let image;
  if (fs.existsSync(sample)) { fs.copyFileSync(sample, path.join(dir, 'preview.png')); const img = await pinFolder(dir, `${name}-unrevealed-image`, { only: new Set(['preview.png']) }); image = { image: `${IPFS_GATEWAY}${img.cid}/preview.png`, image_ipfs: `ipfs://${img.cid}/preview.png` }; }
  fs.writeFileSync(path.join(dir, 'placeholder.json'), JSON.stringify({ name: `${name} (unrevealed)`, description: description ?? 'Revealed after the mint, with public drand randomness. The art and its order were committed on chain when the collection was created, before any mint.', ...image, attributes: [{ trait_type: 'Status', value: 'Unrevealed' }] }, null, 1));
  const meta = await pinFolder(dir, `${name}-unrevealed`, { only: new Set(['placeholder.json']) });
  return { cid: meta.cid, uri: `${IPFS_GATEWAY}${meta.cid}/placeholder.json` };
}
