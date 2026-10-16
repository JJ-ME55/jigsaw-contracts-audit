// Creator-chosen timing for a coin's holder payouts and its airdrop. Off chain: HolderPayouts.declare and
// AirdropClaim.setDrop take no timing, so the keeper simply reads these settings.
//
// Payout cadence: daily | weekly (default) | fortnightly | monthly. Time since launch is cut into windows of that
// length and one round is declared at a random moment inside each window, so nobody can buy just before a known
// payout snapshot. minRoundUsd skips a window whose round would be smaller (the JIG waits for the next one).
// Airdrop: auto (default: a random moment 1 to 3 days after launch) | launch (as soon as the keeper sees the coin) |
// days (N days after launch, 1 to 6) | soldout (when the collection sells out, at most 6 days). Only auto is random:
// launch, days and soldout give a time the creator (and anyone reading the settings) knows in advance, by their choice. AirdropClaim sends
// the 5% to the pot if no drop is set within 7 days, so nothing can be later than 6 days. The airdrop choice is fixed
// once the coin is launched; minRoundUsd is at most $1,000. The nonce makes every signature single-use (no expiry).
//
// Who may set them: the collection's creator, exactly as CoinFactory decides who may launch (creator(), or owner()
// only when the collection has no creator()). Proven by signing the canonical message below with that wallet.
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, http, parseAbi, getAddress, isAddress } from 'viem';
import { CHAINS } from './launch.mjs';
import { DATA } from './store.mjs';
import { addresses } from './jig.mjs';

export const CADENCES = { daily: 86_400, weekly: 7 * 86_400, fortnightly: 14 * 86_400, monthly: 30 * 86_400 };
export const AIRDROP_MODES = ['auto', 'launch', 'days', 'soldout'];
export const MAX_MIN_ROUND_USD = 1000;
export const DEFAULTS = { cadence: 'weekly', minRoundUsd: 0, airdrop: { mode: 'auto', days: null } };
const FILE = () => path.join(DATA, 'coin-settings.json');
const read = () => { try { return JSON.parse(fs.readFileSync(FILE(), 'utf8')); } catch { return {}; } };
const write = (v) => { fs.mkdirSync(DATA, { recursive: true }); const t = FILE() + '.tmp'; fs.writeFileSync(t, JSON.stringify(v, null, 1)); fs.renameSync(t, FILE()); };

/** Validate and normalise; throws with a message the site can show. */
export function normalise(input) {
  const cadence = String(input?.cadence ?? DEFAULTS.cadence);
  if (!CADENCES[cadence]) throw new Error(`cadence must be one of ${Object.keys(CADENCES).join(', ')}`);
  const minRoundUsd = Number(input?.minRoundUsd ?? 0);
  // capped so a creator cannot hold the holders' JIG back indefinitely with an unreachable minimum (pre-audit review, 16 Oct)
  if (!Number.isFinite(minRoundUsd) || minRoundUsd < 0 || minRoundUsd > MAX_MIN_ROUND_USD) throw new Error(`minRoundUsd must be between 0 and ${MAX_MIN_ROUND_USD}`);
  const mode = String(input?.airdrop?.mode ?? 'auto');
  if (!AIRDROP_MODES.includes(mode)) throw new Error(`airdrop.mode must be one of ${AIRDROP_MODES.join(', ')}`);
  let days = null;
  if (mode === 'days') { days = Number(input.airdrop.days); if (!Number.isInteger(days) || days < 1 || days > 6) throw new Error('airdrop.days must be a whole number from 1 to 6 (the drop must be set within 7 days of launch)'); }
  return { cadence, minRoundUsd, airdrop: { mode, days } };
}

/** The exact text the creator signs. Field order and wording are fixed; the site builds the same string. */
export function message(chainId, collection, s, nonce) {
  return [
    'Jigsaw coin settings',
    `chain: ${chainId}`,
    `collection: ${getAddress(collection)}`,
    `payout cadence: ${s.cadence}`,
    `minimum round (USD): ${s.minRoundUsd}`,
    `airdrop: ${s.airdrop.mode}${s.airdrop.mode === 'days' ? ` ${s.airdrop.days}` : ''}`,
    `nonce: ${nonce}`,
  ].join('\n');
}

export function get(collection) {
  const all = read(); const rec = all[getAddress(collection)];
  return rec ? { ...DEFAULTS, ...rec.settings, setBy: rec.by, nonce: rec.nonce, updatedAt: rec.updatedAt, isDefault: false } : { ...DEFAULTS, nonce: 0, isDefault: true };
}

const collAbi = parseAbi(['function creator() view returns (address)', 'function owner() view returns (address)']);
const factoryAbi = parseAbi(['function coinOf(address) view returns (address)']);
/** The coin launched on `collection`, or null. */
export async function coinOf(pub, collection) {
  const a = addresses(); if (!a.factory) return null;
  const c = await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'coinOf', args: [collection] });
  return c && c !== '0x0000000000000000000000000000000000000000' ? getAddress(c) : null;
}
/** CoinFactory's rule: creator() if the collection has one, else owner(). */
// Exactly as CoinFactory._controlsCollection: if creator() answers, that is the answer (zero means nobody); owner() only
// when the collection has no creator(). An RPC error is an error, never "no creator()" (replica review, 17 Oct).
const reverted = (e) => /Revert|ZeroData|returned no data|execution reverted/i.test(`${e?.name} ${e?.cause?.name} ${e?.shortMessage} ${e?.message}`);
export async function creatorOf(pub, collection) {
  let c;
  try { c = await pub.readContract({ address: collection, abi: collAbi, functionName: 'creator' }); }
  catch (e) { if (!reverted(e)) throw e; return getAddress(await pub.readContract({ address: collection, abi: collAbi, functionName: 'owner' })); }
  if (!c || c === '0x0000000000000000000000000000000000000000') throw Object.assign(new Error('this collection has no creator, so nobody can launch its coin or set its settings'), { status: 403 });
  return getAddress(c);
}

/**
 * Save new settings if `signature` is the collection creator's signature over message(...) with nonce = current + 1.
 * `deps` lets tests inject the chain reads.
 */
export async function set(collection, input, signature, nonce, deps = {}) {
  if (!isAddress(collection)) throw new Error('collection address required');
  collection = getAddress(collection);
  const s = normalise(input);
  const cur = get(collection).nonce ?? 0;
  if (Number(nonce) !== cur + 1) throw Object.assign(new Error(`nonce must be ${cur + 1}`), { status: 409 });
  const a = addresses();
  const pub = deps.pub ?? createPublicClient({ chain: CHAINS[a.chainId].chain, transport: http(CHAINS[a.chainId].rpc) });
  const creator = await (deps.creatorOf ?? creatorOf)(pub, collection);
  const msg = message(a.chainId, collection, s, Number(nonce));
  // verifyMessage on the public client handles plain wallets and smart-contract wallets (EIP-1271)
  const ok = await pub.verifyMessage({ address: creator, message: msg, signature }).catch(() => false);
  if (!ok) throw Object.assign(new Error('signature is not from the collection creator'), { status: 403 });
  // the airdrop timing is fixed once the coin exists: changing it then would let the creator time the NFT snapshot
  // around their own buys (pre-audit review, 16 Oct). Cadence and the minimum may still change.
  const prev = get(collection).airdrop;
  if ((prev.mode !== s.airdrop.mode || (prev.days ?? null) !== (s.airdrop.days ?? null)) && (await (deps.coinOf ?? coinOf)(pub, collection)))
    throw Object.assign(new Error('the airdrop timing cannot change after the coin has launched'), { status: 409 });
  const all = read(); all[collection] = { settings: s, by: creator, nonce: Number(nonce), updatedAt: new Date().toISOString() }; write(all);
  return get(collection);
}

// ---------------- schedule (pure, for the keeper and the tests) ----------------

/** Window of `cadence` that `now` falls in, counted from launch. All in unix seconds. */
export function windowOf(launchedAt, cadence, now) {
  const P = CADENCES[cadence]; const k = Math.floor((now - launchedAt) / P);
  return { index: k, start: launchedAt + k * P, end: launchedAt + (k + 1) * P, period: P };
}

/**
 * The moment the round for the current window should run. Stable for a window: `prev` carries the earlier pick.
 * Returns { index, at } (at = null when this window's round is already done).
 */
export function roundSchedule(launchedAt, cadence, now, prev, rand = Math.random) {
  const w = windowOf(launchedAt, cadence, now);
  if (prev?.cadence === cadence && prev.doneIndex === w.index) return { index: w.index, at: null, end: w.end };
  if (prev?.cadence === cadence && prev.index === w.index && prev.at) return { index: w.index, at: prev.at, end: w.end };
  const from = Math.max(w.start, now); // first seen mid-window: a random moment in what is left of it
  return { index: w.index, at: Math.floor(from + rand() * (w.end - from)), end: w.end };
}

/** When the airdrop should be set (unix seconds), or 'when sold out' guarded by the 6-day cap. */
export function airdropAt(launchedAt, airdrop, rand = Math.random) {
  const D = 86_400;
  switch (airdrop.mode) {
    case 'launch': return { at: launchedAt, soldOutTrigger: false };
    case 'days': return { at: launchedAt + airdrop.days * D, soldOutTrigger: false };
    case 'soldout': return { at: launchedAt + 6 * D, soldOutTrigger: true };
    default: return { at: launchedAt + Math.floor(D + rand() * 2 * D), soldOutTrigger: false };
  }
}
