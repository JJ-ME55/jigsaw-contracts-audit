// JIG and creator-coin side of the back end: launch-window status, the allowlist (Merkle tree the launch hook checks),
// and launch parameters for a creator coin. Reads the chain; the only write is setting the allowlist root, admin-only,
// never on a mainnet without ALLOW_MAINNET=1. Addresses come from the environment (see API.md "Coins").
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, encodeFunctionData, http, keccak256, encodeAbiParameters, concat, parseAbi, getAddress, isAddress, formatEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CHAINS, isOurCollection } from './launch.mjs';
import { send as sendTx } from './sender.mjs';
import { DATA } from './store.mjs';
import { leafOf, buildTree, proofFor, verify } from './merkle.mjs';
export { leafOf, buildTree, proofFor, verify };
import { ethPrice } from './builds.mjs';
import { poolIdOf, readPool, priceOf } from './v4state.mjs';
import * as vanity from './vanity.mjs';

const MAINNETS = new Set([1, 4663]);
const chainId = () => Number(process.env.JIG_CHAIN_ID ?? 11155111);
const addr = (name) => { const v = process.env[name]; return v && isAddress(v) ? getAddress(v) : null; };
export const addresses = () => ({
  chainId: chainId(),
  jig: addr('JIG_TOKEN'),
  launch: addr('JIG_LAUNCH'),
  launchHook: addr('JIG_LAUNCH_HOOK'),
  pot: addr('JIG_POT'),
  feeHook: addr('CREATOR_FEE_HOOK'),
  factory: addr('COIN_FACTORY'),
  airdrop: addr('AIRDROP_CLAIM'),
  deepening: addr('LP_DEEPENING'),
});

const pub = () => { const c = CHAINS[chainId()]; if (!c) throw new Error(`no chain config for ${chainId()}`); return createPublicClient({ chain: c.chain, transport: http(c.rpc) }); };

const launchHookAbi = parseAbi([
  'function initialized() view returns (bool)',
  'function windowEnd() view returns (uint64)',
  'function allowlistRoot() view returns (bytes32)',
  'function NORMAL_FEE() view returns (uint24)',
  'function OUTSIDER_FEE() view returns (uint24)',
  'function WINDOW() view returns (uint64)',
  'function setAllowlist(bytes32 root)',
]);
const factoryAbi = parseAbi([
  'function predictCoin(address collection, string name, string symbol, bytes32 salt) view returns (address)',
  'function launchFeeWei() view returns (uint256)',
  'function count() view returns (uint256)',
  'function coinOf(address) view returns (address)',
]);

// ---------------- allowlist ----------------
// Leaf and pairing exactly as JIGLaunchHook.isAllowlisted expects: leaf = keccak256(bytes.concat(keccak256(abi.encode(address))))
// (OpenZeppelin StandardMerkleTree shape), pairs hashed in sorted order (OpenZeppelin MerkleProof), odd node carried up.
const FILE = () => path.join(DATA, 'jig-allowlist.json');
const readList = () => { try { return JSON.parse(fs.readFileSync(FILE(), 'utf8')); } catch { return { addresses: [], frozen: false, root: null }; } };
const writeList = (l) => { fs.mkdirSync(DATA, { recursive: true }); fs.writeFileSync(FILE(), JSON.stringify(l, null, 1)); };

export function allowlist() { const l = readList(); const { root } = buildTree(l.addresses); return { count: l.addresses.length, frozen: !!l.frozen, root, addresses: l.addresses }; }
// The root on the hook, or null when none is set yet (or no hook is configured). On a mainnet DeployJIG sets the root,
// not the server, so the file's `frozen` flag is never set there: the chain is the authority (replica review, 17 Oct).
const ZERO32 = '0x' + '0'.repeat(64);
async function hookRoot() {
  const a = addresses(); if (!a.launchHook) return null;
  const r = await pub().readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'allowlistRoot' });
  return r === ZERO32 ? null : r;
}
export async function addToAllowlist(list, { rootOnChain = hookRoot } = {}) {
  const l = readList();
  if (l.frozen) throw new Error('allowlist is frozen: the root was set on the hook');
  if (await rootOnChain()) throw new Error('allowlist is closed: its root is already on the hook, so an addition would break every proof');
  const add = (Array.isArray(list) ? list : [list]).filter(isAddress).map(getAddress);
  l.addresses = [...new Set([...l.addresses.map(getAddress), ...add])];
  writeList(l);
  return allowlist();
}
/** A proof, served only if the list still builds the root on the hook (when one is set). */
export async function proof(address, { rootOnChain = hookRoot } = {}) {
  const l = readList(); const chain = await rootOnChain();
  if (chain && buildTree(l.addresses).root?.toLowerCase() !== chain.toLowerCase()) throw new Error('the allowlist file does not match the root on the hook; proofs are withheld until it is restored');
  return proofFor(l.addresses, address);
}

/// Set the root on the hook. Works only where the server's LAUNCH_PK owns the hook (Sepolia); on a mainnet the JIG
/// deployer owns it and DeployJIG sets ALLOWLIST_ROOT. Freezes the file.
export async function setRoot() {
  const a = addresses(); if (!a.launchHook) throw new Error('JIG_LAUNCH_HOOK not set');
  if (MAINNETS.has(a.chainId) && process.env.ALLOW_MAINNET !== '1') throw new Error('mainnet is disabled on this server');
  const l = readList(); const { root } = buildTree(l.addresses); if (!root) throw new Error('allowlist is empty');
  // through the shared sender (one nonce queue with the keeper, launches and reveals; throws on a revert)
  const { hash } = await sendTx(a.chainId, { to: a.launchHook, data: encodeFunctionData({ abi: launchHookAbi, functionName: 'setAllowlist', args: [root] }) });
  l.frozen = true; l.root = root; l.setTx = hash; writeList(l);
  return { root, tx: hash, count: l.addresses.length };
}

// ---------------- status ----------------
export async function status() {
  const a = addresses(); const out = { ...a, launched: false, windowEnd: null, secondsLeft: null, fees: { normalPips: 15_000, outsiderPips: 600_000 }, allowlist: { count: allowlist().count, rootOnChain: null, rootHere: allowlist().root } };
  if (!a.launchHook) return out;
  const p = pub();
  const [initialized, windowEnd, root, normal, outsider] = await Promise.all([
    p.readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'initialized' }),
    p.readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'windowEnd' }),
    p.readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'allowlistRoot' }),
    p.readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'NORMAL_FEE' }),
    p.readContract({ address: a.launchHook, abi: launchHookAbi, functionName: 'OUTSIDER_FEE' }),
  ]);
  const now = Math.floor(Date.now() / 1000);
  out.launched = initialized; out.windowEnd = Number(windowEnd) || null; out.secondsLeft = initialized ? Math.max(0, Number(windowEnd) - now) : null;
  out.fees = { normalPips: Number(normal), outsiderPips: Number(outsider), windowOpen: initialized && now < Number(windowEnd) };
  out.allowlist.rootOnChain = root;
  out.allowlist.frozen = root !== '0x' + '0'.repeat(64);
  return out;
}

// ---------------- JIG price ----------------
// JIG per ETH from the JIG/ETH pool (ETH is currency0, so the pool price is JIG per ETH), times ETH/USD.
// JIG_USD in the environment overrides it (testing only). null when either side is unknown.
let _jp = { at: 0, value: null };
export async function jigPrice() {
  if (process.env.JIG_USD) return { jigUsd: Number(process.env.JIG_USD), jigPerEth: null, ethUsd: null, source: 'env JIG_USD' };
  if (Date.now() - _jp.at < 60_000 && _jp.value) return _jp.value;
  const a = addresses(); if (!a.jig || !a.launchHook) return null;
  const key = { currency0: '0x0000000000000000000000000000000000000000', currency1: a.jig, fee: 0x800000, tickSpacing: 200, hooks: a.launchHook };
  const pool = await readPool(pub(), a.chainId, poolIdOf(key)).catch(() => null);
  const ethUsd = await ethPrice().catch(() => 0);
  if (!pool || !pool.sqrtPriceX96 || !ethUsd) return null;
  const jigPerEth = priceOf(pool.sqrtPriceX96);
  _jp = { at: Date.now(), value: { jigUsd: ethUsd / jigPerEth, jigPerEth, ethUsd, source: 'JIG/ETH pool x ETH/USD' } };
  return _jp.value;
}

// ---------------- creator-coin launch parameters ----------------
// Start price and single-sided range for a coin on the collection, in the shape CoinFactory.launch wants. The coin's
// address (CREATE2, below) decides the currency ordering against JIG.
const TICK_SPACING = 200; const MAX_TICK = 887_200;
// The coin's address comes from CREATE2 with a salt bound to the collection, ground so it ends in COLLECT (vanity.mjs).
// It depends on name and symbol, so the site asks with them; while the grind runs the answer is { ready: false,
// vanity: { state: 'grinding' } } and the site asks again. vanity: false (scripts) skips the ending.
export async function launchParams(collection, { name, symbol, vanity: wantVanity = true } = {}) {
  const a = addresses(); if (!a.factory || !a.jig) throw new Error('COIN_FACTORY / JIG_TOKEN not set');
  if (!isAddress(collection)) throw new Error('collection address required');
  if (!name || !symbol) throw new Error('name and symbol are needed: they decide the coin address');
  const p = pub();
  const [feeWei, existing] = await Promise.all([
    p.readContract({ address: a.factory, abi: factoryAbi, functionName: 'launchFeeWei' }),
    p.readContract({ address: a.factory, abi: factoryAbi, functionName: 'coinOf', args: [getAddress(collection)] }),
  ]);
  if (existing !== '0x0000000000000000000000000000000000000000') throw new Error(`collection already has a coin: ${existing}`);
  // the grinder serves only collections our NFT factory made: anyone could otherwise fill its queue with random
  // addresses and push real creators to 'busy' (replica review, 17 Oct)
  let ours = false; try { ours = await isOurCollection(a.chainId, collection); } catch {}
  let v = !wantVanity ? { state: 'off' } : ours ? vanity.request(collection, name, symbol) : { state: 'unavailable', reason: 'the COLLECT ending is ground only for collections made here' };
  if (v.state === 'grinding' || v.state === 'queued') return { ready: false, vanity: v, retryAfterSeconds: 3 };
  const salt = v.state === 'ready' ? v.salt : vanity.plainSalt(collection);
  const predicted = await p.readContract({ address: a.factory, abi: factoryAbi, functionName: 'predictCoin', args: [getAddress(collection), name, symbol, salt] });
  if (v.state === 'ready' && predicted.toLowerCase() !== v.coin.toLowerCase()) v = { state: 'failed', error: 'stored salt no longer matches the factory' };
  const coinIs0 = predicted.toLowerCase() < a.jig.toLowerCase();
  // start FDV in USD over the fixed 1B supply, in JIG at JIG_USD (set from the pool later; env for now)
  const fdvUsd = Number(process.env.COIN_START_FDV_USD ?? 4000);
  const jp = await jigPrice(); if (!jp?.jigUsd) throw new Error('JIG price unknown (JIG pool or ETH/USD unavailable); not quoting a start price on a guess');
  const jigUsd = jp.jigUsd;
  const jigPerCoin = fdvUsd / 1e9 / jigUsd; // JIG per coin
  const price = coinIs0 ? jigPerCoin : 1 / jigPerCoin; // currency1 per currency0
  const tick = Math.floor(Math.log(price) / Math.log(1.0001));
  const sqrtPriceX96 = BigInt(Math.floor(Math.sqrt(price) * 2 ** 48)) * (2n ** 48n); // sqrt(price) * 2^96 in two steps to keep precision
  let tickLower, tickUpper;
  if (coinIs0) { tickLower = (Math.floor(tick / TICK_SPACING) + 1) * TICK_SPACING; tickUpper = MAX_TICK; }
  else { tickLower = -MAX_TICK; tickUpper = (Math.floor(tick / TICK_SPACING) - 1) * TICK_SPACING; }
  return {
    ready: true, factory: a.factory, feeHook: a.feeHook, jig: a.jig, name, symbol, salt, predictedCoin: predicted, coinIs0, vanity: { ...v, ending: vanity.ENDING },
    launchFeeWei: feeWei.toString(), launchFeeEth: formatEther(feeWei), maxFeeWei: (feeWei + feeWei / 10n).toString(), // 10% tolerance
    startFdvUsd: fdvUsd, jigUsd, jigPriceSource: jp.source, jigPerCoin, startTick: tick, sqrtPriceX96: sqrtPriceX96.toString(), tickLower, tickUpper, tickSpacing: TICK_SPACING,
    feeBands: [{ feePips: '10000', label: '1%', platformBps: 2500 }, { feePips: '20000..30000', label: '2-3%', platformBps: 3000 }, { feePips: '40000..60000', label: '4-6%', platformBps: 3500 }, { feePips: '70000..100000', label: '7-10%', platformBps: 4000 }],
    fixedBps: { pot: 300, deepening: 200 }, supply: '1000000000', airdropBps: 500, maxCreatorBps: 500,
    sells: 'exact-input only (exact-output sells revert ExactOutputSell)',
  };
}
