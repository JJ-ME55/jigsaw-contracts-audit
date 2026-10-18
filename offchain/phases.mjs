// Mint phases (Jj, 17 Oct): e.g. VIP from 10:00, WL from 13:00, public from 17:00. Each phase has a start time, a price,
// a per-wallet allowance, an optional phase supply and an optional wallet list. JigsawCollection enforces all of it on
// chain; the server keeps the wallet lists (only their Merkle roots are on chain) and hands each wallet its proof.
import { createPublicClient, http, parseAbi, parseEther, formatEther, isAddress, getAddress, encodeFunctionData } from 'viem';
import { buildTree, leafOf } from './merkle.mjs';
import { list, load, update, ledger } from './store.mjs';
import { send as sendTx } from './sender.mjs';

export const MAX_PHASES = 3;
const MAX_WALLETS = 20_000;

const U32 = 2 ** 32 - 1;
const MAX_PRICE = 2n ** 128n - 1n - 5n * 10n ** 14n; // uint128 less the platform fee (JigsawCollection InvalidMintPrice)

const toUnix = (v, name) => {
  const bad = () => new Error(`${name}: start "${v}" is not a time (ISO with a timezone, e.g. 2026-10-21T10:00:00Z, or unix seconds)`);
  let t;
  if (typeof v === 'number' || /^\d+$/.test(String(v))) { t = Number(v); if (!Number.isSafeInteger(t) || t < 0) throw bad(); }
  else {
    // a time without Z or an offset would be read in the server's own timezone
    if (!/(Z|[+-]\d\d:?\d\d)$/i.test(String(v).trim())) throw new Error(`${name}: give the start with a timezone (e.g. 2026-10-21T10:00:00Z)`);
    const ms = Date.parse(String(v)); if (Number.isNaN(ms)) throw bad(); t = Math.floor(ms / 1000);
  }
  if (t > 1e11) throw new Error(`${name}: start ${v} looks like milliseconds; send unix seconds`);
  if (t > Date.now() / 1000 + 400 * 86400) throw new Error(`${name}: start is too far ahead (more than 400 days)`);
  return t;
};

const toPrice = (v, name) => {
  let w; try { w = parseEther(String(v ?? '0')); } catch { w = -1n; }
  if (!/^\d+(\.\d+)?$/.test(String(v ?? '0').trim()) || w < 0n || w > MAX_PRICE) throw new Error(`${name}: price "${v}" is not a valid ETH amount`);
  return w;
};

/** Validate and normalise LaunchInput.phases. Returns null when the launch has no phases (a single public mint). Every
 *  check the contract makes is made here too, so a bad phase is a 400 before anything is composed or pinned. */
export function normalisePhases(phases, { maxSupply, maxPerWallet }) {
  if (phases === undefined || phases === null) return null;
  if (!Array.isArray(phases) || phases.length < 1 || phases.length > MAX_PHASES) throw new Error(`a launch has 1 to ${MAX_PHASES} mint phases`);
  if (maxPerWallet && maxSupply && maxPerWallet > maxSupply) throw new Error(`the lifetime limit of ${maxPerWallet} per wallet is more than the whole collection (${maxSupply})`);
  const out = phases.map((p, i) => {
    const name = String(p.name ?? ['VIP', 'Allowlist', 'Public'][i] ?? `Phase ${i + 1}`).slice(0, 32);
    const start = toUnix(p.startsAt ?? p.start, name);
    const price = toPrice(p.priceEth, name);
    const per = Number(p.maxPerWallet);
    if (!Number.isInteger(per) || per < 1 || per > U32) throw new Error(`${name}: mints per wallet must be a whole number from 1`);
    if (maxPerWallet && per > maxPerWallet) throw new Error(`${name}: ${per} per wallet is above the collection's limit of ${maxPerWallet} per wallet`);
    if (maxSupply && per > maxSupply) throw new Error(`${name}: ${per} per wallet is more than the whole collection (${maxSupply})`);
    const supply = p.supply ? Number(p.supply) : 0;
    if (!Number.isInteger(supply) || supply < 0 || supply > U32 || (maxSupply && supply > maxSupply)) throw new Error(`${name}: the phase supply must be between 0 (no limit) and ${maxSupply ?? U32}`);
    let wallets = null;
    if (p.wallets !== undefined && p.wallets !== null) {
      // an empty list must not quietly open the phase to everyone (an empty CSV, say): leave wallets out for that
      if (!Array.isArray(p.wallets) || p.wallets.length === 0) throw new Error(`${name}: the wallet list is empty; leave it out for a phase open to everyone`);
      const bad = p.wallets.filter((w) => !isAddress(String(w).trim(), { strict: false }));
      if (bad.length) throw new Error(`${name}: ${bad.length} wallet(s) are not addresses, e.g. ${String(bad[0]).slice(0, 60)}`);
      wallets = [...new Set(p.wallets.map((w) => getAddress(String(w).trim().toLowerCase())))];
      if (wallets.length > MAX_WALLETS) throw new Error(`${name}: at most ${MAX_WALLETS} wallets`);
    }
    return { name, start, priceEth: formatEther(price), maxPerWallet: per, supply, wallets };
  });
  for (let i = 1; i < out.length; i++) if (out[i].start < out[i - 1].start) throw new Error(`${out[i].name} starts before ${out[i - 1].name}`);
  // as JigsawCollection._checkListOrder: phases stay open, so a list after an open phase would hide the open one
  const firstOpen = out.findIndex((p) => !p.wallets);
  if (firstOpen >= 0 && out.slice(firstOpen).some((p) => p.wallets)) throw new Error(`a list-only phase cannot come after ${out[firstOpen].name}, which is open to everyone`);
  for (const p of out) if (p.wallets) p.lists = { [buildTree(p.wallets).root]: p.wallets };
  return out;
}

/** The lifetime per-wallet cap a phased collection is created with: the launch's own, else the largest phase allowance. */
export const lifetimeCap = (phases, maxPerWallet) => Math.max(Number(maxPerWallet ?? 0) || 0, ...phases.map((p) => p.maxPerWallet));

/** A reveal that waits only for the sell-out would never run if the phases cannot mint the whole collection. */
export function sellOutCheck(phases, maxSupply, reveal) {
  if (!phases || !reveal?.enabled || Number(reveal.timerHours) > 0) return;
  const room = phases.reduce((a, p) => a + Math.min(p.supply || Infinity, p.wallets ? p.wallets.length * p.maxPerWallet : Infinity), 0);
  if (room < maxSupply) throw new Error(`these phases can mint at most ${room} of ${maxSupply}, so the collection would never sell out and the reveal would never run: set a reveal timer, raise the phase supplies or open a phase to everyone`);
}

const rootOf = (p) => (p.wallets?.length ? buildTree(p.wallets).root : '0x' + '00'.repeat(32));

/** The JigsawCollection.Phase[] tuple for the creating transaction. */
export const onChainPhases = (phases) => phases.map((p) => ({ start: BigInt(p.start), price: parseEther(p.priceEth), maxPerWallet: p.maxPerWallet, supply: p.supply, root: rootOf(p) }));

/** The stored list whose root is the one on chain, or null (never serve proofs against another root). */
export const listFor = (lists, root) => lists?.[root] ?? (lists && Object.entries(lists).find(([r]) => r.toLowerCase() === String(root).toLowerCase())?.[1]) ?? null;

// Trees cached by root: a 20k list takes ~1.7 s to build, so the public route must never build one per request
// (internal round, 18 Oct).
const trees = new Map();
export function cachedProof(root, wallets, address) {
  let t = trees.get(root);
  if (!t) {
    const { layers } = buildTree(wallets); t = { layers, index: new Map(layers[0]?.map((l, i) => [l, i]) ?? []) };
    trees.set(root, t); if (trees.size > 50) trees.delete(trees.keys().next().value);
  }
  let idx = t.index.get(leafOf(address));
  if (idx === undefined) return { allowlisted: false, proof: [] };
  const proof = [];
  for (let l = 0; l < t.layers.length - 1; l++) { const sib = idx ^ 1; if (sib < t.layers[l].length) proof.push(t.layers[l][sib]); idx = Math.floor(idx / 2); }
  return { allowlisted: true, proof };
}

const collectionAbi = parseAbi([
  'function currentPhase() view returns (uint256)',
  'function mintableNow(uint256 phaseIndex, address wallet) view returns (uint256)',
  'function mintedInPhase(uint256 phase, address wallet) view returns (uint256)',
  'function phaseMinted(uint256 phase) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function maxSupply() view returns (uint256)',
  'function setPhaseRoot(uint256 i, bytes32 root)',
  'function phase(uint256 i) view returns ((uint64 start, uint128 price, uint32 maxPerWallet, uint32 supply, bytes32 root))',
]);

// collection -> build id, and short-lived chain reads: the public route must not parse every build or fan out uncached
// RPC calls per request (internal round, 18 Oct)
const buildIds = new Map();
function buildFor(chainId, collection) {
  const want = `${Number(chainId)}:${String(collection).toLowerCase()}`;
  const known = buildIds.get(want); if (known) return load(known);
  const b = list().find((x) => `${Number(x.launch?.settings?.chainId)}:${x.launch?.collection?.toLowerCase()}` === want) ?? null;
  if (b?.launch?.settings?.phases) buildIds.set(want, b.id);
  return b;
}
const reads = new Map();
const cached = (key, ms, fn) => {
  const hit = reads.get(key); if (hit && hit.until > Date.now()) return hit.p;
  const p = fn().catch((e) => { reads.delete(key); throw e; });
  reads.set(key, { until: Date.now() + ms, p }); if (reads.size > 5000) reads.delete(reads.keys().next().value);
  return p;
};
const listsOf = (p) => p.lists ?? (p.wallets ? { [buildTree(p.wallets).root]: p.wallets } : null);

/** Public: the phases of a collection, and for `address` whether it is on each list, its proof and what it can mint now.
 *  Proofs come only from the stored list whose root is the one on chain; if none matches, `listOutOfStep` is true and
 *  no proof is served. */
export async function phasesFor(chainId, collection, address, { CHAINS }) {
  if (!isAddress(String(collection))) throw Object.assign(new Error('not a collection address'), { status: 400 });
  const b = buildFor(chainId, collection);
  const phases = b?.launch?.settings?.phases;
  if (!phases) return { collection, phased: false, phases: [] };
  const c = CHAINS[Number(chainId)]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const who = address && isAddress(address) ? getAddress(address) : null;
  const key = `${chainId}:${collection.toLowerCase()}`;
  const read = (functionName, args = []) => pub.readContract({ address: collection, abi: collectionAbi, functionName, args });
  const state = await cached(`s:${key}`, 10_000, async () => {
    const [cur, total, max, ...rest] = await Promise.all([read('currentPhase'), read('totalSupply'), read('maxSupply'), ...phases.flatMap((_, i) => [read('phase', [BigInt(i)]), read('phaseMinted', [BigInt(i)])])]);
    return { cur, total, max, roots: phases.map((_, i) => rest[2 * i].root), minted: phases.map((_, i) => rest[2 * i + 1]) };
  });
  const mintable = who ? await cached(`w:${key}:${who}`, 10_000, () => Promise.all(phases.map((_, i) => read('mintableNow', [BigInt(i), who])))) : null;
  const now = Math.floor(Date.now() / 1000);
  const rows = phases.map((p, i) => {
    const listed = !!p.wallets?.length;
    const wallets = listed ? listFor(listsOf(p), state.roots[i]) : null;
    const pr = wallets && who ? cachedProof(state.roots[i], wallets, who) : null;
    return {
      index: i, name: p.name, startsAt: new Date(p.start * 1000).toISOString(), start: p.start, open: now >= p.start,
      priceEth: p.priceEth, maxPerWallet: p.maxPerWallet, supply: p.supply || null, minted: Number(state.minted[i]),
      listed, walletCount: listed ? (wallets ?? p.wallets).length : null, ...(listed && !wallets ? { listOutOfStep: true } : {}),
      ...(who ? { eligible: !listed || !!pr?.allowlisted, proof: pr?.proof ?? [], mintableNow: Number(mintable[i]) } : {}),
    };
  });
  return { collection, phased: true, currentPhase: state.cur === 2n ** 256n - 1n ? null : Number(state.cur), totalSupply: Number(state.total), maxSupply: Number(state.max), phases: rows };
}

/** Owner: add wallets to one phase's list before that phase starts (sets the new root on chain). One call at a time per
 *  build. Every list is stored under its root before the transaction and never deleted, so whatever happens to the
 *  transaction (mined late, dropped, reverted) the route serves the list whose root is on chain. */
const locks = new Map();
export function addWallets(buildId, index, add) {
  const run = (locks.get(buildId) ?? Promise.resolve()).catch(() => {}).then(() => addWalletsNow(buildId, index, add));
  locks.set(buildId, run); run.finally(() => { if (locks.get(buildId) === run) locks.delete(buildId); }).catch(() => {});
  return run;
}
async function addWalletsNow(buildId, index, add) {
  const b = load(buildId); const s = b?.launch?.settings; const p = s?.phases?.[index];
  if (!p) throw new Error('no such phase');
  if (!b.launch.collection) throw new Error('the collection is not deployed yet');
  if (!p.wallets?.length) throw new Error(`${p.name} is open to everyone; a list cannot be added after launch`);
  if (Math.floor(Date.now() / 1000) >= p.start) throw new Error(`${p.name} has started: its list is fixed`);
  const bad = add.filter((w) => !isAddress(String(w).trim(), { strict: false })); if (bad.length) throw new Error(`${bad.length} wallet(s) are not addresses`);
  const wallets = [...new Set([...p.wallets, ...add.map((w) => getAddress(String(w).trim().toLowerCase()))])];
  if (wallets.length === p.wallets.length) throw new Error('every one of those wallets is already on the list');   // no transaction for nothing
  if (wallets.length > MAX_WALLETS) throw new Error(`at most ${MAX_WALLETS} wallets`);
  const root = buildTree(wallets).root;
  update(buildId, (d) => { const q = d.launch.settings.phases[index]; q.lists = { ...listsOf(q), [root]: wallets }; q.wallets = wallets; q.pendingRoot = root; });
  try {
    const { hash } = await sendTx(Number(s.chainId), { to: b.launch.collection, data: encodeFunctionData({ abi: collectionAbi, functionName: 'setPhaseRoot', args: [BigInt(index), root] }) },
      { onHash: (h) => update(buildId, (d) => { d.launch.settings.phases[index].pendingTx = h; }) });
    update(buildId, (d) => { const q = d.launch.settings.phases[index]; delete q.pendingRoot; delete q.pendingTx; });
    ledger(`${buildId},phase-root,${b.launch.collection},${index},${wallets.length},${hash}`);
    reads.clear();
    return { index, walletCount: wallets.length, root, tx: hash };
  } catch (e) {
    ledger(`${buildId},phase-root-failed,${b.launch.collection},${index},${wallets.length},${e.hash ?? ''}`);
    throw e;
  }
}
