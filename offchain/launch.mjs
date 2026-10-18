// Launch: create a collection through the audited factory on a chain that has one.
// Mainnet is refused unless ALLOW_MAINNET=1 is set on the server, on purpose.
import { createPublicClient, createWalletClient, http, parseAbi, parseEther, formatEther, decodeEventLog, encodeFunctionData } from 'viem';
import { send as sendTx } from './sender.mjs';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet, sepolia } from 'viem/chains';
import { ledger, load, save, list, update } from './store.mjs';
import { compose } from './builds.mjs';
import { pinFolder } from './pin.mjs';
import { planFromSettings, pinPlaceholder } from './reveal.mjs';
import { normalisePhases, onChainPhases, lifetimeCap, sellOutCheck } from './phases.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { buildDir } from './store.mjs';

export const CHAINS = {
  1: { chain: mainnet, rpc: process.env.RPC_URL ?? 'https://ethereum-rpc.publicnode.com', factory: process.env.MAINNET_FACTORY ?? null, launcher: process.env.MAINNET_LAUNCHER ?? null, phasedFactory: process.env.MAINNET_PHASED_FACTORY ?? null, name: 'Ethereum' },   // no default: 0x830c…e01a belongs to the retired burner
  11155111: { chain: sepolia, rpc: 'https://ethereum-sepolia-rpc.publicnode.com', factory: process.env.SEPOLIA_FACTORY ?? null, launcher: process.env.SEPOLIA_LAUNCHER ?? null, phasedFactory: process.env.SEPOLIA_PHASED_FACTORY ?? null, name: 'Sepolia' },
  4663: { chain: { id: 4663, name: 'Robinhood Chain', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [process.env.RH_RPC ?? 'https://rpc.mainnet.chain.robinhood.com'] } } }, rpc: process.env.RH_RPC ?? 'https://rpc.mainnet.chain.robinhood.com', factory: process.env.RH_FACTORY ?? null, launcher: process.env.RH_LAUNCHER ?? null, phasedFactory: process.env.RH_PHASED_FACTORY ?? null, name: 'Robinhood Chain' },
};
const abi = parseAbi([
  'function CREATE_FEE() view returns (uint256)',
  'function createCollection(string name, string symbol, uint256 maxSupply, uint256 mintPriceWei, uint256 maxPerWallet, address creator, uint96 royaltyBps) payable returns (address)',
  'event CollectionCreated(address indexed collection, address indexed owner, string name, uint256 maxSupply)',
]);

const launcherAbi = [{ type: 'function', name: 'create', stateMutability: 'payable', inputs: [{ name: 'c', type: 'tuple', components: [{ name: 'name', type: 'string' }, { name: 'symbol', type: 'string' }, { name: 'maxSupply', type: 'uint256' }, { name: 'mintPriceWei', type: 'uint256' }, { name: 'maxPerWallet', type: 'uint256' }, { name: 'creator', type: 'address' }, { name: 'royaltyBps', type: 'uint96' }] }, { name: 'provenance', type: 'bytes32' }, { name: 'uri', type: 'string' }, { name: 'revealLater', type: 'bool' }, { name: 'freeze', type: 'bool' }], outputs: [{ type: 'address' }] }];

// JigsawCollectionFactory (phased mints, 17 Oct): our own collection, created with its provenance, first URI and up to
// three mint phases in one transaction, owned by the operating wallet from the start.
const phasedAbi = [
  { type: 'function', name: 'create', stateMutability: 'nonpayable', inputs: [
    { name: 'c', type: 'tuple', components: [{ name: 'name', type: 'string' }, { name: 'symbol', type: 'string' }, { name: 'maxSupply', type: 'uint256' }, { name: 'maxPerWallet', type: 'uint256' }, { name: 'creator', type: 'address' }, { name: 'royaltyBps', type: 'uint96' }] },
    { name: 'phases', type: 'tuple[]', components: [{ name: 'start', type: 'uint64' }, { name: 'price', type: 'uint128' }, { name: 'maxPerWallet', type: 'uint32' }, { name: 'supply', type: 'uint32' }, { name: 'root', type: 'bytes32' }] },
    { name: 'provenance', type: 'bytes32' }, { name: 'uri', type: 'string' }, { name: 'revealLater', type: 'bool' }, { name: 'freeze', type: 'bool' }], outputs: [{ type: 'address' }] },
  ...parseAbi(['event CollectionCreated(address indexed collection, address indexed creator, bytes32 provenance, bool revealLater)']),
];

// Shape matches the front end's LaunchOptions type: { chains: [{ chainId, name, factory }] }
// Chains where real money moves. Launching on any of them needs ALLOW_MAINNET=1 (founders' rule 2).
const MAINNETS = new Set([1, 4663]);
// The base URI a collection is frozen with: ipfs:// on mainnets (frozen at launch or at the reveal, so it must not
// depend on any gateway staying up: final audit, 17 Oct); the web gateway on test chains, where links still change.
export const finalBase = (chainId, pinned) => (MAINNETS.has(Number(chainId)) && pinned.baseURIIpfs ? pinned.baseURIIpfs : pinned.baseURI);
const mainnetBlocked = (chainId) => MAINNETS.has(Number(chainId)) && process.env.ALLOW_MAINNET !== '1';
// a mainnet also needs CollectionLauncher (provenance committed at creation); refused before any compose or pinning
const needsLauncher = (chainId) => MAINNETS.has(Number(chainId)) && !CHAINS[Number(chainId)]?.launcher;
export function launchOptions() {
  const chains = Object.entries(CHAINS).map(([id, c]) => { const available = !!c.factory && !mainnetBlocked(id) && !needsLauncher(id); return { chainId: Number(id), name: c.name, factory: available, available, phases: available && !!c.phasedFactory }; });
  return { chains };
}

/** Can `address` receive plain ETH on this chain? The collection pays the creator inside every mint, so a wallet that
 *  rejected ETH would make every mint of the collection revert (_sendETH reverts ETHTransferFailed). Defensive: not
 *  yet seen in practice. Simulated with a funded sender, nothing is sent. */
export async function canReceiveEth(chainId, address) {
  const c = CHAINS[Number(chainId)]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const from = '0x000000000000000000000000000000000000dEaD';
  try { await pub.call({ account: from, to: address, value: 1n, stateOverride: [{ address: from, balance: 10n ** 18n }] }); return true; } catch { return false; }
}

export async function createCollection({ chainId, name, symbol, maxSupply, mintPriceEth = '0', maxPerWallet, creator, royaltyBps = 500, provenance, uri, revealLater = false, freeze = false, phases = null }, { onSent } = {}) {
  chainId = Number(chainId);   // "1" must not slip past the mainnet guard (15 Oct audit)
  const lifetime = phases ? lifetimeCap(phases, maxPerWallet) : null; maxPerWallet = maxPerWallet ?? 5;   // phased: default = the largest phase allowance
  const c = CHAINS[chainId]; if (!c) throw new Error('unknown chain');
  if (!c.factory && !(phases && c.phasedFactory)) throw new Error(`no factory deployed on ${c.name} yet`);
  if (mainnetBlocked(chainId)) throw new Error('mainnet launches are disabled on this server');
  // the creator receives mint proceeds and royalties: never fall back silently to the operating wallet
  if (!/^0x[0-9a-fA-F]{40}$/.test(String(creator ?? ''))) throw new Error('a valid creator wallet address is required');
  if (!(await canReceiveEth(chainId, creator))) throw new Error('the creator wallet cannot receive ETH (a smart-account setup that rejects payments?): every mint pays it, so mints would fail. Connect a wallet that can receive ETH');
  const pk = process.env.LAUNCH_PK; if (!pk) throw new Error('LAUNCH_PK not set on the server');
  const account = privateKeyToAccount(pk);
  const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const fee = phases ? 0n : await pub.readContract({ address: c.factory, abi, functionName: 'CREATE_FEE' });
  const args = [name, symbol, BigInt(maxSupply), parseEther(String(mintPriceEth)), BigInt(maxPerWallet), creator, BigInt(royaltyBps)];
  // the hash is persisted before the broadcast (onSent), so a retry finds this contract instead of deploying a second one
  // Through CollectionLauncher when the chain has one: the clone is created, its provenance and first URI committed and
  // its ownership offered back to us in ONE transaction. Created directly, a clone is mintable at once and a single
  // outside mint before setProvenanceHash blocks the commitment for good (replica review, 17 Oct). Required on mainnets.
  let tx;
  if (phases) {
    // phased mints: our own factory, which commits everything in the creating transaction (no fee, no hand-over)
    if (!c.phasedFactory) throw new Error(`no phased-mint factory on ${c.name} yet`);
    if (!provenance || !uri) throw new Error('provenance and the first URI are needed before the collection is created');
    tx = { to: c.phasedFactory, data: encodeFunctionData({ abi: phasedAbi, functionName: 'create', args: [{ name, symbol, maxSupply: BigInt(maxSupply), maxPerWallet: BigInt(lifetime), creator, royaltyBps: BigInt(royaltyBps) }, onChainPhases(phases), provenance, uri, !!revealLater, !!freeze] }) };
  } else if (c.launcher) {
    if (!provenance || !uri) throw new Error('provenance and the first URI are needed before the collection is created');
    tx = { to: c.launcher, value: fee, data: encodeFunctionData({ abi: launcherAbi, functionName: 'create', args: [{ name, symbol, maxSupply: BigInt(maxSupply), mintPriceWei: parseEther(String(mintPriceEth)), maxPerWallet: BigInt(maxPerWallet), creator, royaltyBps: BigInt(royaltyBps) }, provenance, uri, !!revealLater, !!freeze] }) };
  } else {
    if (MAINNETS.has(chainId)) throw new Error(`no CollectionLauncher configured for ${c.name}: refusing to create a collection whose provenance could be blocked`);
    tx = { to: c.factory, data: encodeFunctionData({ abi, functionName: 'createCollection', args }), value: fee };
  }
  const { hash } = await sendTx(chainId, tx, { onHash: (h, nonce) => onSent?.(h, nonce) });
  const collection = await collectionFromTx(chainId, hash);
  if (!collection) throw new Error(`deploy transaction ${hash} did not report a new collection`);
  ledger(`launch,${c.name},${collection},${name},${symbol},${maxSupply},${hash}`);
  return { chainId, chainName: c.name, collection, owner: account.address, tx: hash, viaLauncher: !phases && !!c.launcher, phased: !!phases, createFeeEth: formatEther(fee), mintPage: `/mint?chain=${chainId}&address=${collection}` };
}

// The collection a deploy transaction created (waits for it to be mined).
export async function collectionFromTx(chainId, hash, { nonce } = {}) {
  const c = CHAINS[Number(chainId)]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  if (nonce !== undefined && nonce !== null) {
    const [rc, known] = await Promise.all([pub.getTransactionReceipt({ hash }).catch(() => null), pub.getTransaction({ hash }).catch(() => null)]);
    if (!rc && !known) {
      const who = privateKeyToAccount(process.env.LAUNCH_PK).address;
      const [mined, pending] = await Promise.all([pub.getTransactionCount({ address: who, blockTag: 'latest' }), pub.getTransactionCount({ address: who, blockTag: 'pending' })]);
      // unknown to the node: forgotten only if another transaction took its nonce, or nothing is pending at that
      // nonce (never broadcast); anything else may still be in flight and is waited for
      const again = await pub.getTransactionReceipt({ hash }).catch(() => null);
      if (!again && (mined > nonce || pending <= nonce)) throw Object.assign(new Error(`deploy transaction ${hash} was never mined (nonce ${nonce}, account at ${mined}, pending ${pending})`), { dropped: true });
    }
  }
  const r = await pub.waitForTransactionReceipt({ hash, timeout: 10 * 60_000 });
  if (r.status !== 'success') throw Object.assign(new Error(`deploy transaction ${hash} failed on chain`), { reverted: true });
  for (const l of r.logs) for (const a of [abi, phasedAbi]) { try { const e = decodeEventLog({ abi: a, data: l.data, topics: l.topics }); if (e.eventName === 'CollectionCreated') return e.args.collection; } catch {} }
  return null;
}

// Owner calls on a freshly created clone: the launch wallet owns it, the creator earns from it.
const cloneAbi = parseAbi(['function setProvenanceHash(bytes32)', 'function setBaseURI(string)', 'function setUnrevealedURI(string)', 'function setRevealSeed(bytes32)', 'function freezeMetadata()', 'function totalSupply() view returns (uint256)', 'function maxSupply() view returns (uint256)', 'function provenanceHash() view returns (bytes32)', 'function revealSeedSet() view returns (bool)', 'function metadataFrozen() view returns (bool)', 'function revealSeed() view returns (bytes32)', 'function baseURI() view returns (string)', 'function unrevealedURI() view returns (string)', 'function owner() view returns (address)', 'function pendingOwner() view returns (address)', 'function acceptOwnership()']);
/** Stop minting on a collection (owner call). Used before an early reveal: revealing while minting is open would let
 *  later minters see which art the next id gets and wait for a rare one (pre-audit review, 16 Oct). */
export async function endMint(chainId, collection) {
  const c = CHAINS[Number(chainId)]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const abiP = parseAbi(['function paused() view returns (bool)', 'function pause()']);
  if (await pub.readContract({ address: collection, abi: abiP, functionName: 'paused' })) return null;
  const { hash } = await sendTx(chainId, { to: collection, data: encodeFunctionData({ abi: abiP, functionName: 'pause' }) });
  return hash;
}

export async function readSupply(chainId, collection) {
  const c = CHAINS[Number(chainId)]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const [totalSupply, maxSupply] = await Promise.all([pub.readContract({ address: collection, abi: cloneAbi, functionName: 'totalSupply' }), pub.readContract({ address: collection, abi: cloneAbi, functionName: 'maxSupply' })]);
  return { totalSupply, maxSupply };
}
export async function configureClone(chainId, collection, { provenanceHash, baseURI, unrevealedURI, revealSeed, freeze = false }) {
  const c = CHAINS[chainId]; const account = privateKeyToAccount(process.env.LAUNCH_PK);
  const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) }); const wallet = createWalletClient({ account, chain: c.chain, transport: http(c.rpc) });
  const txs = {};
  // through the shared sender: one nonce at a time, and a reverted call throws instead of being recorded as done
  const send = async (fn, args) => { const { hash } = await sendTx(chainId, { to: collection, data: encodeFunctionData({ abi: cloneAbi, functionName: fn, args }) }); txs[fn] = hash; };
  // a collection made through CollectionLauncher offers us ownership (Ownable2Step): accept it first
  const [owner, pending] = await Promise.all([pub.readContract({ address: collection, abi: cloneAbi, functionName: 'owner' }), pub.readContract({ address: collection, abi: cloneAbi, functionName: 'pendingOwner' }).catch(() => null)]);
  if (owner.toLowerCase() !== account.address.toLowerCase()) {
    if (pending && pending.toLowerCase() === account.address.toLowerCase()) await send('acceptOwnership', []);
    else throw new Error(`the operating wallet does not own ${collection} (owner ${owner})`);
  }
  const onChain = provenanceHash ? await pub.readContract({ address: collection, abi: cloneAbi, functionName: 'provenanceHash' }).catch(() => null) : null;
  if (provenanceHash && (!onChain || /^0x0+$/.test(onChain))) await send('setProvenanceHash', [provenanceHash]);
  else if (provenanceHash && onChain.toLowerCase() !== provenanceHash.toLowerCase()) throw new Error(`the collection already has a different provenance (${onChain}); not changing it`);
  // every step is skipped when it is already on chain, so a retry after any interruption finishes instead of reverting
  // (a reveal stopped after freezeMetadata could never complete: replica review, 17 Oct)
  const read = (fn) => pub.readContract({ address: collection, abi: cloneAbi, functionName: fn });
  const frozen = await read('metadataFrozen');
  if (unrevealedURI && !frozen && (await read('unrevealedURI')) !== unrevealedURI) await send('setUnrevealedURI', [unrevealedURI]);
  if (revealSeed && !(await read('revealSeedSet'))) await send('setRevealSeed', [revealSeed]);
  else if (revealSeed && (await read('revealSeed')).toLowerCase() !== revealSeed.toLowerCase()) throw new Error('the collection already records a different reveal seed; not revealing with another (final audit)');
  if (baseURI && !frozen && (await read('baseURI')) !== baseURI) await send('setBaseURI', [baseURI]);
  if (baseURI && frozen && (await read('baseURI')) !== baseURI) throw new Error('metadata is frozen with a different base URI; not changing it');
  if (freeze && !frozen) await send('freezeMetadata', []);
  return txs;
}

// The whole launch, async: compose at 1024 -> pin -> create the clone -> provenance + base URI -> live.
// Progress lives on the build as build.launch; poll GET /builds/:id.
export function startLaunch(buildId, settings) {
  settings = { ...settings, chainId: Number(settings.chainId) };
  const build = load(buildId); if (!build) throw new Error('no such build');
  if (!['ready', 'composed'].includes(build.status) && build.status !== 'launched') throw new Error(`build is ${build.status}`);
  if (build.launch && !['failed'].includes(build.launch.stage)) throw new Error(`launch already ${build.launch.stage}`);
  const c = CHAINS[settings.chainId]; if (!c) throw new Error('unknown chain');
  const phased = settings.phases !== undefined && settings.phases !== null;
  if (!c.factory && !(phased && c.phasedFactory)) throw new Error(`no factory deployed on ${c.name} yet`);
  if (mainnetBlocked(settings.chainId)) throw new Error('mainnet launches are disabled on this server');
  if (!phased && needsLauncher(settings.chainId)) throw new Error('no CollectionLauncher configured for this chain: set it before launching');
  if (!/^0x[0-9a-fA-F]{40}$/.test(String(settings.creator ?? ''))) throw new Error('connect the wallet that should receive the mint proceeds');
  if (!process.env.LAUNCH_PK) throw new Error('LAUNCH_PK not set on the server');
  // mint phases (VIP / allowlist / public): validated now, before anything is composed or pinned
  // (skipped on a retry once a contract exists: its settings are the ones on chain)
  const alreadyDeployed = build.launch?.stage === 'failed' && !!(build.launch.collection || build.launch.deployTx);
  if (phased && !alreadyDeployed) {
    if (!c.phasedFactory) throw new Error(`mint phases are not available on ${c.name} yet`);
    const supply = settings.maxSupply ?? build.input.size;
    settings.phases = normalisePhases(settings.phases, { maxSupply: supply, maxPerWallet: settings.maxPerWallet ? Number(settings.maxPerWallet) : null });
    sellOutCheck(settings.phases, supply, settings.reveal);
  }
  // Pinning plan guard: the free Pinata tier allows 500 files, two per token. PIN_MAX_TOKENS lifts this once a plan is paid.
  const maxTokens = Number(process.env.PIN_MAX_TOKENS ?? 240); const wanted = settings.maxSupply ?? build.input.size;
  if (wanted > maxTokens) throw new Error(`this collection has ${wanted} tokens but the current pinning plan allows ${maxTokens}; upgrade the pinning plan or launch a smaller collection`);
  // Disk guard: 1024 renders measured 1.1 to 2.3 MB a piece on 15 Oct (2.4 is the safe side). Launches hold one batch on disk at a time, plus metadata. Fail now, not 15 minutes in.
  sweepLaunched();
  // the launch wipes this build's own out_1024 before composing, so that space counts as free
  const needGb = (Math.min(wanted, Math.max(50, Number(process.env.LAUNCH_BATCH ?? 500))) * 2.4 + 50) / 1024; const freeNow = freeDiskGb(); const free = freeNow === null ? null : freeNow + dirGb(path.join(buildDir(buildId), 'out_1024'));
  if (free !== null && free < needGb) throw new Error(`not enough disk on the server for this launch: needs about ${needGb.toFixed(1)} GB, ${free.toFixed(1)} GB free`);
  // A retry after a failure resumes from the furthest point reached: never a second contract, never re-pinning art
  // that is already pinned for the same name. Once a contract exists its settings are fixed (they are on chain).
  const prev = build.launch?.stage === 'failed' ? build.launch : null;
  const deployed = !!(prev?.collection || prev?.deployTx);
  const effective = deployed ? prev.settings : settings;
  const keep = prev ? { collection: prev.collection, deployTx: prev.deployTx, chainName: prev.chainName, tx: prev.tx,
    ...(prev.pinned && (deployed || prev.pinnedFor === pinKey(effective)) ? { pinned: prev.pinned, pinnedFor: prev.pinnedFor, provenance: prev.provenance } : {}) } : {};
  build.launch = { stage: 'composing', settings: effective, startedAt: new Date().toISOString(), ...keep, ...(prev ? { resumedAfter: prev.error } : {}) };
  save(build);
  runLaunch(buildId).catch(() => {});
  return build.launch;
}
// Wallets and explorers read `image`. The free public gateways (ipfs.io, dweb.link) stopped serving files in Oct 2026,
// so an ipfs:// image shows blank in any wallet still using them. `image` is a web link through our gateway;
// `image_ipfs` keeps the permanent ipfs:// link (the CID is in both, so any gateway can serve it).
export const IPFS_GATEWAY = (process.env.IPFS_GATEWAY ?? 'https://gateway.pinata.cloud/ipfs/').replace(/\/?$/, '/');
// The contract's base URI is a web link for the same reason: a wallet fetches tokenURI before it ever sees `image`.
export const webBase = (cid) => `${IPFS_GATEWAY}${cid}/`;
export const imageLinks = (cid, t) => ({ image: `${IPFS_GATEWAY}${cid}/${t}.png`, image_ipfs: `ipfs://${cid}/${t}.png` });

const setStage = (id, stage, extra = {}) => { const b = load(id); b.launch = { ...b.launch, stage, ...extra }; save(b); return b; };
const pinKey = (st) => `${st.name}|${st.symbol}|${st.maxSupply ?? ''}`;
// Pinata hiccups should not kill a 45-minute launch: three tries with a pause between
async function withRetry(label, fn, tries = 3) {
  for (let i = 1; ; i++) { try { return await fn(); } catch (e) { if (i >= tries) throw new Error(`${label}: ${e.message}`); await new Promise((r) => setTimeout(r, 15_000 * i)); } }
}
async function runLaunch(id) {
  try {
    let b = load(id); const s = b.launch.settings; const size = 1024;
    const out = path.join(buildDir(id), `out_${size}`); const sym = (s.symbol || 'collection').toLowerCase();
    let { pinned, provenance, collection } = b.launch;
    if (!collection && b.launch.deployTx) {
      // the deploy was sent before the failure: find the contract it made instead of deploying again; a deploy that
      // reverted on chain made nothing, so it is forgotten and sent again (replica review, 17 Oct)
      setStage(id, 'deploying');
      // a deploy that was signed but never mined (the RPC refused it, or it was dropped) is forgotten too, once the
      // node does not know it and its nonce is unused or taken by another transaction (final audit, 17 Oct)
      try { collection = await collectionFromTx(s.chainId, b.launch.deployTx, { nonce: b.launch.deployNonce }); }
      catch (e) { if (!e.reverted && !e.dropped) throw e; b = setStage(id, 'deploying', { deployTx: null, [e.reverted ? 'revertedDeployTx' : 'droppedDeployTx']: b.launch.deployTx }); }
      if (collection) b = setStage(id, 'configuring', { collection });
    }
    if (!pinned) {
      // Compose at 1024 under the LAUNCH name, so token metadata reads "Cool Skeletons #7", not the build's working name.
      // Batched: build LAUNCH_BATCH pieces, pin them, delete them, repeat. Disk holds one batch, not the whole collection.
      const BATCH = Math.max(50, Number(process.env.LAUNCH_BATCH ?? 500)); const batches = [];
      await compose(id, { size, count: s.maxSupply ?? b.input.size, name: s.name, batch: { size: BATCH, onBatch: async ({ lo, hi, total, out: bOut }) => {   // bOut: compose renders into a folder it swaps in at the end
        setStage(id, 'composing', { progress: { done: lo - 1, total, step: 'uploading' } });
        const tids = []; for (let t = lo; t <= hi; t++) tids.push(t);
        const pinnedBatch = await withRetry(`pinning images ${lo}-${hi}`, () => pinFolder(path.join(bOut, 'images'), `${sym}-images-${lo}`, { only: new Set(tids.map((t) => `${t}.png`)) }));
        batches.push({ from: lo, to: hi, cid: pinnedBatch.cid, files: pinnedBatch.files });
        for (const t of tids) {   // point each token at its batch, then free the disk
          const mp = path.join(bOut, 'metadata', `${t}.json`); const m = JSON.parse(fs.readFileSync(mp, 'utf8'));
          Object.assign(m, imageLinks(pinnedBatch.cid, t)); fs.writeFileSync(mp, JSON.stringify(m, null, 1));
        }
        const keep = keepSet(bOut);
        for (const t of tids) if (!keep.has(`${t}.png`)) fs.rmSync(path.join(bOut, 'images', `${t}.png`), { force: true });
        setStage(id, 'composing', { progress: { done: hi, total, step: 'building' } });
      } } });
      b = setStage(id, 'pinning metadata', { progress: undefined });
      const meta = await withRetry('pinning metadata', () => pinFolder(path.join(out, 'metadata'), `${sym}-metadata`));
      pinned = { imagesCid: batches[0]?.cid, imageBatches: batches, metadataCid: meta.cid, baseURI: webBase(meta.cid), baseURIIpfs: `ipfs://${meta.cid}/`, files: batches.reduce((a, x) => a + x.files, 0) + meta.files, pinnedAt: new Date().toISOString() };
      provenance = '0x' + fs.readFileSync(path.join(out, 'provenance.txt'), 'utf8').trim();
      fs.writeFileSync(path.join(out, 'pinned.json'), JSON.stringify(pinned, null, 1));
      b = setStage(id, collection ? 'configuring' : 'deploying', { pinned, pinnedFor: pinKey(s), provenance });
    }
    provenance = provenance ?? ('0x' + fs.readFileSync(path.join(out, 'provenance.txt'), 'utf8').trim());
    const plan = planFromSettings(s);
    // the placeholder is pinned BEFORE the collection exists: it is committed in the creating transaction
    let placeholder = load(id).launch.placeholder;
    if (plan && !placeholder) { placeholder = await withRetry('pinning placeholder', () => pinPlaceholder(id, { name: s.name })); setStage(id, collection ? 'configuring' : 'deploying', { placeholder }); }
    if (!collection) {
      b = setStage(id, 'deploying');
      const count = load(id).composed.count;
      const created = await createCollection({ chainId: s.chainId, name: s.name, symbol: s.symbol, maxSupply: count, mintPriceEth: s.mintPriceEth ?? '0', maxPerWallet: s.phases ? s.maxPerWallet : (s.maxPerWallet ?? 5), creator: s.creator, royaltyBps: s.royaltyBps ?? 500,   // phased: the lifetime cap defaults to the largest phase allowance (lifetimeCap)
        provenance, uri: plan ? placeholder.uri : finalBase(s.chainId, pinned), revealLater: !!plan, freeze: !plan && MAINNETS.has(Number(s.chainId)), phases: s.phases ?? null },
        { onSent: (hash, nonce) => { setStage(id, 'deploying', { deployTx: hash, deployNonce: nonce }); } });
      collection = created.collection;
      b = setStage(id, 'configuring', { ...created });
    }
    if (plan) {
      // Reveal later: the provenance and the placeholder are committed; the base URI stays unset. reveal.mjs does the rest.
      const txs = await configureClone(s.chainId, collection, { provenanceHash: provenance, unrevealedURI: placeholder.uri });
      update(id, (d) => { d.status = 'launched'; d.launch = { ...d.launch, stage: 'live', provenance, baseURI: null, unrevealedURI: placeholder.uri, revealed: false, reveal: { ...plan, ...(d.launch.reveal?.state && d.launch.reveal.state !== 'waiting' ? d.launch.reveal : {}) }, configureTxs: txs, finishedAt: new Date().toISOString() }; });
      ledger(`${id},launch-live-unrevealed,${collection},${s.chainId},${placeholder.uri}`);
    } else {
      const base = finalBase(s.chainId, pinned);
      const txs = await configureClone(s.chainId, collection, { provenanceHash: provenance, baseURI: base, freeze: MAINNETS.has(Number(s.chainId)) });
      update(id, (d) => { d.status = 'launched'; d.launch = { ...d.launch, stage: 'live', provenance, baseURI: base, frozen: MAINNETS.has(Number(s.chainId)), revealed: true, configureTxs: txs, finishedAt: new Date().toISOString() }; });
      ledger(`${id},launch-live,${collection},${s.chainId},${base}`);
    }
    try { pruneLaunched(id); } catch (e) { console.error('prune', id, e.message); }
  } catch (e) { setStage(id, 'failed', { error: e.message }); }
}

// The pieces the site shows from the server: the first 25 (samples) and every one-of-one (legends).
function keepSet(out) {
  const keep = new Set(); for (let i = 0; i <= 25; i++) keep.add(`${i}.png`);
  try { for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(path.join(out, 'dna.json'), 'utf8')).tokens)) if (typeof v === 'string') keep.add(`${k}.png`); } catch {}
  return keep;
}

// Once a collection is live its images and metadata are on IPFS, so the 1024 renders on disk are only a copy.
// Keep the ones the site shows (first 25, samples, legends) and delete the rest.
// Layers (re-rolls), the 512 previews, metadata, rarity, provenance and dna all stay.
export function pruneLaunched(id) {
  const b = load(id); if (!b || b.launch?.stage !== 'live' || !b.launch?.pinned?.imagesCid) return 0;
  const dir = path.join(buildDir(id), 'out_1024', 'images'); if (!fs.existsSync(dir)) return 0;
  const keep = new Set([...(b.composed?.sampleUrls ?? []), ...(b.composed?.legendUrls ?? [])].map((u) => path.basename(u)));
  for (let i = 0; i <= 24; i++) keep.add(`${i}.png`);
  let n = 0;
  for (const f of fs.readdirSync(dir)) if (!keep.has(f)) { fs.rmSync(path.join(dir, f), { force: true }); n++; }
  if (n) console.log(`prune ${id}: removed ${n} pinned 1024 renders`);
  return n;
}
export function sweepLaunched() { let n = 0; for (const b of list()) { try { n += pruneLaunched(b.id); } catch (e) { console.error('prune', b.id, e.message); } } return n; }
const dataRoot = () => path.dirname(buildDir('x'));
function dirGb(dir) { let t = 0; const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else t += fs.statSync(p).size; } }; try { walk(dir); } catch { return 0; } return t / 1024 ** 3; }
export function freeDiskGb() { try { const s = fs.statfsSync(dataRoot()); return (s.bavail * s.bsize) / 1024 ** 3; } catch { return null; } }
export function diskGb() {
  try { const s = fs.statfsSync(dataRoot()); return { freeGb: +((s.bavail * s.bsize) / 1024 ** 3).toFixed(2), totalGb: +((s.blocks * s.bsize) / 1024 ** 3).toFixed(2) }; } catch (e) { return { error: e.message }; }
}

// One-off upgrade for collections launched before web image links: rewrite each token's metadata, re-pin the
// metadata folder, and point the contract at it (one setBaseURI). Sepolia only, and only for builds named here.
// Marked in-flight before it pins or sends anything; never repeats once done; at most 2 attempts.
export const IMAGE_LINK_UPGRADES = ['2b1796912b39'];   // Steam-Punk Skeletons, approved by Fish 15 Oct
export async function upgradeImageLinks(id) {
  const b = load(id); const L = b?.launch;
  if (!L || L.stage !== 'live' || !L.collection) return 'not live';
  if (L.settings?.chainId !== 11155111) return 'not sepolia';
  const u = L.imageLinks ?? {};
  if (u.state === 'done') return 'already done';
  if (u.state === 'running' && Date.now() - Date.parse(u.startedAt) < 60 * 60 * 1000) return 'already running';
  if ((u.attempts ?? 0) >= 2) return 'gave up after 2 attempts';
  b.launch.imageLinks = { state: 'running', startedAt: new Date().toISOString(), attempts: (u.attempts ?? 0) + 1 }; save(b);
  try {
    const metaDir = path.join(buildDir(id), 'out_1024', 'metadata');
    let n = 0;
    for (const f of fs.readdirSync(metaDir)) {
      const p = path.join(metaDir, f); const m = JSON.parse(fs.readFileSync(p, 'utf8'));
      const src = m.image_ipfs ?? m.image; const hit = /^ipfs:\/\/([^/]+)\/(\d+)\.png$/.exec(src ?? '');
      if (!hit) throw new Error(`${f}: unexpected image ${src}`);
      Object.assign(m, imageLinks(hit[1], hit[2])); fs.writeFileSync(p, JSON.stringify(m, null, 1)); n++;
    }
    const sym = (L.settings.symbol || 'collection').toLowerCase();
    const meta = await pinFolder(metaDir, `${sym}-metadata-weblinks`);
    const baseURI = `ipfs://${meta.cid}/`;
    const txs = await configureClone(L.settings.chainId, L.collection, { baseURI });
    const d = load(id);
    d.launch = { ...d.launch, previousBaseURI: d.launch.baseURI, baseURI, imageLinks: { state: 'done', files: n, metadataCid: meta.cid, tx: txs.setBaseURI, finishedAt: new Date().toISOString(), attempts: b.launch.imageLinks.attempts } };
    save(d); ledger(`${id},image-links,${L.collection},${L.settings.chainId},${baseURI},${txs.setBaseURI}`);
    return `done: ${n} files, ${baseURI}`;
  } catch (e) {
    const d = load(id); d.launch.imageLinks = { ...d.launch.imageLinks, state: 'failed', error: e.message }; save(d);
    return 'failed: ' + e.message;
  }
}

// Second step for the same named collections: point the contract's base URI at a web link for the metadata
// (one setBaseURI). Same guards: Sepolia only, in-flight marker, runs once, at most 2 attempts.
export async function upgradeWebBaseURI(id) {
  const b = load(id); const L = b?.launch;
  if (!L || L.stage !== 'live' || !L.collection) return 'not live';
  if (L.settings?.chainId !== 11155111) return 'not sepolia';
  const cid = /^ipfs:\/\/([^/]+)\/$/.exec(L.baseURI ?? '')?.[1];
  if (!cid) return L.baseURI?.startsWith('http') ? 'already a web link' : `unexpected baseURI ${L.baseURI}`;
  if (L.imageLinks?.state !== 'done') return 'image links not upgraded yet';
  const u = L.webBaseURI ?? {};
  if (u.state === 'done') return 'already done';
  if (u.state === 'running' && Date.now() - Date.parse(u.startedAt) < 60 * 60 * 1000) return 'already running';
  if ((u.attempts ?? 0) >= 2) return 'gave up after 2 attempts';
  b.launch.webBaseURI = { state: 'running', startedAt: new Date().toISOString(), attempts: (u.attempts ?? 0) + 1 }; save(b);
  try {
    const baseURI = webBase(cid);
    const txs = await configureClone(L.settings.chainId, L.collection, { baseURI });
    const d = load(id);
    d.launch = { ...d.launch, baseURIIpfs: d.launch.baseURI, baseURI, webBaseURI: { state: 'done', tx: txs.setBaseURI, finishedAt: new Date().toISOString(), attempts: b.launch.webBaseURI.attempts } };
    save(d); ledger(`${id},web-base-uri,${L.collection},${L.settings.chainId},${baseURI},${txs.setBaseURI}`);
    return `done: ${baseURI}`;
  } catch (e) {
    const d = load(id); d.launch.webBaseURI = { ...d.launch.webBaseURI, state: 'failed', error: e.message }; save(d);
    return 'failed: ' + e.message;
  }
}

// Collections made by our NFT factory are registered in it (isCollection). CoinFactory is open to any contract
// that names a creator, so the keeper and the vanity grinder serve only these (replica review, 17 Oct).
const _ours = new Map();
export async function isOurCollection(chainId, collection) {
  const c = CHAINS[Number(chainId)]; if (!c?.factory && !c?.phasedFactory) throw new Error('no NFT factory configured for this chain');
  const k = `${chainId}:${String(collection).toLowerCase()}`; if (_ours.has(k)) return _ours.get(k);
  const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  // the factory's own registry: a self-deployed clone of the same implementation is byte-identical but not registered
  // (final audit, 17 Oct). Either factory: the Loom one or our phased one.
  const reg = parseAbi(['function isCollection(address) view returns (bool)']);
  let ours = false;
  for (const f of [c.factory, c.phasedFactory].filter(Boolean)) { if (await pub.readContract({ address: f, abi: reg, functionName: 'isCollection', args: [collection] })) { ours = true; break; } }
  _ours.set(k, ours); return ours;
}
