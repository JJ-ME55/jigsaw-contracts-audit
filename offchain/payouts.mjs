// Holder snapshots for the two Merkle claim contracts, and the proofs the site serves.
//
// Coin-holder rounds (HolderPayouts, fed by a coin's SnapshotForwarder): at a random moment, snapshot who holds the
// coin (from its Transfer logs, indexed incrementally) and split the coin's JIG balance in HolderPayouts pro rata.
// Protocol addresses are excluded (pool manager, factory, hook, claim contracts, the coin, burn addresses).
// Airdrop (AirdropClaim, the 5% of every coin): at a random moment 24 to 72 h after launch, snapshot the collection's
// NFT holders (ownerOf over ids 1..totalSupply) and give every NFT an equal share. Both windows are 7 days; unclaimed
// payout JIG returns to the coin's balance on settle(), unclaimed airdrop goes to the pot.
//
// Every tree is written to disk BEFORE its root goes on chain, so a proof can always be served for a live root.
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, http, parseAbi, getAddress, parseAbiItem } from 'viem';
import { CHAINS } from './launch.mjs';
import { DATA } from './store.mjs';
import { addresses } from './jig.mjs';
import { amountTree } from './merkle.mjs';
import { POOL_MANAGER } from './v4state.mjs';

const DIR = () => path.join(DATA, 'payouts');
const ZERO = '0x0000000000000000000000000000000000000000';
const DEAD = '0x000000000000000000000000000000000000dEaD';
export const WINDOW_S = 7 * 86400;
const transferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');
const payoutsAbi = parseAbi(['function balance(address) view returns (uint256)', 'function roundCount(address) view returns (uint256)', 'function rounds(address,uint256) view returns (bytes32 root, uint128 total, uint128 claimed, uint64 expiry, bool settled)', 'function declare(address coin, bytes32 root, uint256 total, uint64 expiry) returns (uint256)', 'function settle(address coin, uint256 round) returns (uint256)']);
const airdropAbi = parseAbi(['function drops(address) view returns (bytes32 root, uint128 total, uint128 claimed, uint64 expiry)', 'function receivedAt(address) view returns (uint64)', 'function setDrop(address coin, bytes32 root, uint256 total, uint64 expiry)']);
const nftAbi = parseAbi(['function totalSupply() view returns (uint256)', 'function ownerOf(uint256) view returns (address)']);
const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)']);

const pub = () => { const a = addresses(); const c = CHAINS[a.chainId]; return createPublicClient({ chain: c.chain, transport: http(c.rpc) }); };
const file = (...p) => path.join(DIR(), ...p);
const readJson = (p, d) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return d; } };
const writeJson = (p, v) => { fs.mkdirSync(path.dirname(p), { recursive: true }); const t = p + '.tmp'; fs.writeFileSync(t, JSON.stringify(v, null, 1)); fs.renameSync(t, p); };

/** First block at or after unix time `ts` (binary search on headers; cached per coin). */
async function blockAt(p, ts) {
  let hi = await p.getBlockNumber(); let lo = hi > 2_000_000n ? hi - 2_000_000n : 0n;
  while (lo < hi) { const mid = (lo + hi) / 2n; const b = await p.getBlock({ blockNumber: mid }); if (Number(b.timestamp) < ts) lo = mid + 1n; else hi = mid; }
  return lo;
}

/** Balances of `coin` holders, from Transfer logs since `launchedAt`, indexed incrementally on disk. */
export async function holders(coin, launchedAt) {
  const p = pub(); coin = getAddress(coin);
  const idx = readJson(file('index', `${coin}.json`), null) ?? { fromBlock: (await blockAt(p, Number(launchedAt) - 60)).toString(), balances: {} };
  const head = await p.getBlockNumber();
  let from = BigInt(idx.fromBlock); let step = 10_000n;
  while (from <= head) {
    const to = from + step - 1n > head ? head : from + step - 1n;
    let logs;
    try { logs = await p.getLogs({ address: coin, event: transferEvent, fromBlock: from, toBlock: to }); }
    catch (e) { if (step > 500n) { step /= 2n; continue; } throw e; }
    for (const l of logs) {
      const { from: f, to: t, value: v } = l.args;
      if (f !== ZERO) idx.balances[f] = (BigInt(idx.balances[f] ?? 0) - v).toString();
      idx.balances[t] = (BigInt(idx.balances[t] ?? 0) + v).toString();
    }
    from = to + 1n; idx.fromBlock = from.toString();
  }
  writeJson(file('index', `${coin}.json`), idx);
  return { block: head, balances: idx.balances };
}

const excluded = (a, coin) => new Set([ZERO, DEAD, coin, a.factory, a.feeHook, a.airdrop, a.payouts, a.deepening, a.pot, POOL_MANAGER[a.chainId]].filter(Boolean).map((x) => getAddress(x)));

/** Pro-rata split of `total` over eligible balances (floored; the sum never exceeds total). */
export function split(balances, total, skip) {
  const elig = Object.entries(balances).map(([k, v]) => [getAddress(k), BigInt(v)]).filter(([k, v]) => v > 0n && !skip.has(k));
  const sum = elig.reduce((s, [, v]) => s + v, 0n); if (sum === 0n) return {};
  const out = {}; for (const [k, v] of elig) { const amt = (BigInt(total) * v) / sum; if (amt > 0n) out[k] = amt.toString(); }
  return out;
}

/** Prepare the next coin-holder round: snapshot, tree on disk, and the declare() call to send. Null if nothing to pay. */
export async function prepareRound(coin, launchedAt) {
  const a = addresses(); const p = pub(); coin = getAddress(coin);
  const bal = await p.readContract({ address: a.payouts, abi: payoutsAbi, functionName: 'balance', args: [coin] });
  if (bal === 0n) return null;
  const snap = await holders(coin, launchedAt);
  const alloc = split(snap.balances, bal, excluded(a, coin));
  const t = amountTree(alloc); if (!t.root) return null;
  const round = Number(await p.readContract({ address: a.payouts, abi: payoutsAbi, functionName: 'roundCount', args: [coin] }));
  const expiry = Math.floor(Date.now() / 1000) + WINDOW_S;
  const rec = { kind: 'payout', coin, round, snapshotBlock: snap.block.toString(), expiry, ...t, declaredTx: null, preparedAt: new Date().toISOString() };
  return { rec, path: file('rounds', coin, `${round}.json`), call: { address: a.payouts, abi: payoutsAbi, functionName: 'declare', args: [coin, t.root, BigInt(t.total), BigInt(expiry)] } };
}

/** Expired, unsettled rounds of `coin` (settle returns the unclaimed JIG to the coin's balance; anyone may call). */
export async function expiredRounds(coin) {
  const a = addresses(); const p = pub(); const n = Number(await p.readContract({ address: a.payouts, abi: payoutsAbi, functionName: 'roundCount', args: [coin] }));
  const out = []; const now = Math.floor(Date.now() / 1000);
  for (let r = 0; r < n; r++) { const R = await p.readContract({ address: a.payouts, abi: payoutsAbi, functionName: 'rounds', args: [coin, BigInt(r)] }); if (!R[4] && Number(R[3]) < now) out.push(r); }
  return out.map((r) => ({ round: r, call: { address: a.payouts, abi: payoutsAbi, functionName: 'settle', args: [coin, BigInt(r)] } }));
}

/** Prepare the airdrop for `coin`: NFT holders of its collection, equal share per NFT. Null if not due or already set. */
export async function prepareAirdrop(coin, collection) {
  const a = addresses(); const p = pub(); coin = getAddress(coin);
  const d = await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'drops', args: [coin] });
  if (d[0] !== '0x' + '0'.repeat(64)) return null; // set already
  const received = Number(await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'receivedAt', args: [coin] }));
  if (!received || Date.now() / 1000 > received + WINDOW_S - 3600) return null; // nothing delivered, or the unset window is closing (it then sweeps to the pot)
  const total = await p.readContract({ address: coin, abi: erc20, functionName: 'balanceOf', args: [a.airdrop] });
  const n = Number(await p.readContract({ address: collection, abi: nftAbi, functionName: 'totalSupply' }));
  if (n === 0 || total === 0n) return null;
  const owners = {};
  for (let id = 1; id <= n; id++) { const o = await p.readContract({ address: collection, abi: nftAbi, functionName: 'ownerOf', args: [BigInt(id)] }).catch(() => null); if (o && getAddress(o) !== getAddress(DEAD)) owners[getAddress(o)] = (owners[getAddress(o)] ?? 0n) + 1n; }
  const nfts = Object.values(owners).reduce((s, v) => s + v, 0n); if (nfts === 0n) return null;
  const per = total / nfts; const alloc = {}; for (const [k, v] of Object.entries(owners)) alloc[k] = (per * v).toString();
  const t = amountTree(alloc);
  const expiry = Math.floor(Date.now() / 1000) + WINDOW_S;
  const rec = { kind: 'airdrop', coin, collection, nfts: nfts.toString(), perNft: per.toString(), expiry, ...t, setTx: null, preparedAt: new Date().toISOString() };
  return { rec, path: file('airdrops', `${coin}.json`), call: { address: a.airdrop, abi: airdropAbi, functionName: 'setDrop', args: [coin, t.root, BigInt(t.total), BigInt(expiry)] } };
}

// ---------------- serving ----------------
export function roundsOf(coin) {
  const dir = file('rounds', getAddress(coin)); if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((f) => /^\d+\.json$/.test(f)).map((f) => readJson(path.join(dir, f), null)).filter(Boolean)
    .map(({ claims, ...r }) => r).sort((x, y) => x.round - y.round);
}
export function payoutProof(coin, round, account) {
  const r = readJson(file('rounds', getAddress(coin), `${Number(round)}.json`), null); if (!r) return { found: false };
  const c = r.claims[getAddress(account)]; return c ? { found: true, coin: r.coin, round: r.round, root: r.root, expiry: r.expiry, account: getAddress(account), amount: c.amount, proof: c.proof } : { found: false, round: r.round };
}
export function airdropProof(coin, account) {
  const r = readJson(file('airdrops', `${getAddress(coin)}.json`), null); if (!r) return { found: false };
  const c = r.claims[getAddress(account)]; return c ? { found: true, coin: r.coin, root: r.root, expiry: r.expiry, account: getAddress(account), amount: c.amount, proof: c.proof } : { found: false };
}
export const saveRecord = (p, rec) => writeJson(p, rec);
