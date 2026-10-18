// Coin-holder rewards and the per-NFT airdrop, read from the chain for the site. Both run entirely on chain (Jj, 17 Oct):
// CreatorCoin streams JIG to its holders (earned() / claim() on the coin), and AirdropClaim pays 5% / maxSupply per
// NFT to whoever owns it (claim(coin, ids)). Nothing here decides who is paid: it only reads, and returns the call the
// holder's wallet sends.
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress, isAddress, encodeFunctionData } from 'viem';
import { CHAINS } from './launch.mjs';
import { addresses } from './jig.mjs';

const coinAbi = parseAbi([
  'function earned(address) view returns (uint256)', 'function balanceOf(address) view returns (uint256)',
  'function rewardRate() view returns (uint256)', 'function periodFinish() view returns (uint256)',
  'function eligibleSupply() view returns (uint256)', 'function rewardsPaused() view returns (bool)',
  'function notifier() view returns (address)', 'function excluded(address) view returns (bool)', 'function claim() returns (uint256)',
]);
const airdropAbi = parseAbi([
  'function drops(address) view returns (address collection, uint64 opensAt, uint256 perNft, uint256 maxId)',
  'function claimed(address, uint256) view returns (bool)', 'function CLAIM_WINDOW() view returns (uint64)',
  'function claim(address coin, uint256[] ids) returns (uint256)', 'function claimFor(address coin, uint256[] ids) returns (uint256)',
]);
const nftAbi = parseAbi(['function ownerOf(uint256) view returns (address)', 'function totalSupply() view returns (uint256)']);
const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11';
const MAX_NFTS = Number(process.env.AIRDROP_MAX_NFTS ?? 50_000);
const pub = () => { const a = addresses(); const c = CHAINS[a.chainId]; return createPublicClient({ chain: c.chain, transport: http(c.rpc) }); };
const addr = (x, what) => { if (!isAddress(String(x ?? ''))) throw Object.assign(new Error(`${what} address required`), { status: 400 }); return getAddress(x); };

/** What `account` has earned from `coin`'s holder rewards, and the stream it is in. */
export async function rewardsOf(coin, account) {
  coin = addr(coin, 'coin'); account = addr(account, 'account');
  const p = pub(); const r = (fn, args = []) => p.readContract({ address: coin, abi: coinAbi, functionName: fn, args });
  const [earned, balance, rate, finish, eligible, paused, notifier, excluded] = await Promise.all([
    r('earned', [account]), r('balanceOf', [account]), r('rewardRate'), r('periodFinish'), r('eligibleSupply'), r('rewardsPaused'), r('notifier'), r('excluded', [account]),
  ]);
  const now = Math.floor(Date.now() / 1000); const live = Number(finish) > now;
  return {
    coin, account, earned: earned.toString(), balance: balance.toString(), excluded, paused,
    stream: { jigPerDay: live ? (rate * 86_400n).toString() : '0', endsAt: Number(finish) || null, eligibleSupply: eligible.toString(), notifier },
    // the share of today's stream this holder earns at their current balance
    yourJigPerDay: live && eligible > 0n && !excluded ? ((rate * 86_400n * balance) / eligible).toString() : '0',
    claim: { to: coin, data: encodeFunctionData({ abi: coinAbi, functionName: 'claim' }) },
  };
}

const _owners = new Map(); // collection -> { at, owners: string[] (index = id) }
async function ownersOf(p, collection, maxId) {
  const hit = _owners.get(collection); if (hit && Date.now() - hit.at < 60_000) return hit.owners;
  const n = Math.min(Number(maxId), Number(await p.readContract({ address: collection, abi: nftAbi, functionName: 'totalSupply' })), MAX_NFTS);
  const owners = [];
  for (let lo = 1; lo <= n; lo += 500) {
    const ids = []; for (let id = lo; id <= Math.min(n, lo + 499); id++) ids.push(id);
    const res = await p.multicall({ multicallAddress: MULTICALL3, allowFailure: true, contracts: ids.map((id) => ({ address: collection, abi: nftAbi, functionName: 'ownerOf', args: [BigInt(id)] })) });
    res.forEach((x, k) => { owners[ids[k]] = x.status === 'success' ? getAddress(x.result) : null; });
  }
  _owners.set(collection, { at: Date.now(), owners });
  return owners;
}

/** The airdrop `account` can claim from `coin` now: its unclaimed NFT ids, the amount, and the call to send. */
export async function airdropFor(coin, account) {
  coin = addr(coin, 'coin'); account = addr(account, 'account');
  const a = addresses(); if (!a.airdrop) throw new Error('AIRDROP_CLAIM not set');
  const p = pub();
  const [collection, opensAt, perNft, maxId] = await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'drops', args: [coin] });
  if (!Number(opensAt)) return { coin, open: false, reason: 'no airdrop for this coin' };
  const window = Number(await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'CLAIM_WINDOW' }));
  const closesAt = Number(opensAt) + window; const open = Math.floor(Date.now() / 1000) <= closesAt;
  const owners = await ownersOf(p, collection, maxId);
  const mine = []; for (let id = 1; id < owners.length; id++) if (owners[id] === account) mine.push(id);
  const claimed = mine.length ? await p.multicall({ multicallAddress: MULTICALL3, allowFailure: false, contracts: mine.map((id) => ({ address: a.airdrop, abi: airdropAbi, functionName: 'claimed', args: [coin, BigInt(id)] })) }) : [];
  const ids = mine.filter((_, k) => !claimed[k]);
  // delivery status for the whole collection's pending shares (what the keeper still has to push)
  let delivery = null;
  try { const pa = await pushableCached(coin); delivery = open ? await pushStatus(coin, collection, pa.ids.length) : { status: 'closed' }; } catch (e) { delivery = { status: 'unknown', reason: e.shortMessage ?? e.message }; }
  // a contract wallet (Safe, smart account) is never pushed to (round 8, Medium 2): it claims with the button
  const selfClaim = ((await p.getCode({ address: account }).catch(() => '0x')) ?? '0x') !== '0x';
  return {
    coin, collection, open, delivery, selfClaim, opensAt: Number(opensAt), closesAt, perNft: perNft.toString(), maxId: Number(maxId),
    ids, alreadyClaimed: mine.filter((_, k) => claimed[k]), amount: (perNft * BigInt(ids.length)).toString(),
    claim: open && ids.length ? { to: a.airdrop, data: encodeFunctionData({ abi: airdropAbi, functionName: 'claim', args: [coin, ids.map(BigInt)] }) } : null,
  };
}

/** For the keeper's push airdrop: ids of `coin`'s drop that are minted, unclaimed and not burned, plus whether the
 *  collection is complete (every id minted), so the keeper knows when nothing more can ever become pushable. */
// Whether an owner is a contract (claimFor skips those), cached an hour; a failed read is not cached and counts as
// unknown, never as a wallet (round 9, Info 5). Reads run 25 at a time, not one after another (round 9, Low 4).
const _code = new Map();
export async function codeOf(p, owners) {   // exported for tests
  const out = new Map(); const todo = [];
  for (const o of owners) { const c = _code.get(o); if (c && Date.now() - c.at < 3600_000) out.set(o, c.has); else todo.push(o); }
  for (let i = 0; i < todo.length; i += 25) {
    await Promise.all(todo.slice(i, i + 25).map(async (o) => {
      try { const has = ((await p.getCode({ address: o })) ?? '0x') !== '0x'; _code.set(o, { has, at: Date.now() }); out.set(o, has); }
      catch { out.set(o, null); }
    }));
  }
  return out;
}
// The site's airdrop view reads the delivery status from a copy at most a minute old (round 9, Low 4); the keeper
// always reads fresh.
const _push = new Map();
async function pushableCached(coin) {
  const k = String(coin).toLowerCase(); const hit = _push.get(k);
  if (hit && Date.now() - hit.at < 60_000) return hit.p;
  const p = pushableIds(coin, { fresh: false }).catch((e) => { _push.delete(k); throw e; });
  _push.set(k, { at: Date.now(), p }); return p;
}

export async function pushableIds(coin, { fresh = true } = {}) {
  coin = addr(coin, 'coin'); const a = addresses(); if (!a.airdrop) return { open: false, ids: [] };
  const p = pub();
  const [collection, opensAt, perNft, maxId] = await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'drops', args: [coin] });
  if (!Number(opensAt) || perNft === 0n) return { open: false, ids: [] };
  const window = Number(await p.readContract({ address: a.airdrop, abi: airdropAbi, functionName: 'CLAIM_WINDOW' }));
  if (Math.floor(Date.now() / 1000) > Number(opensAt) + window) return { open: false, ids: [] };
  if (fresh) _owners.delete(collection); // the keeper's push goes to whoever holds the NFT now
  const owners = await ownersOf(p, collection, maxId);
  const minted = []; for (let id = 1; id < owners.length; id++) if (owners[id] && owners[id] !== getAddress('0x000000000000000000000000000000000000dEaD')) minted.push(id);
  const claimed = minted.length ? await p.multicall({ multicallAddress: MULTICALL3, allowFailure: false, contracts: minted.map((id) => ({ address: a.airdrop, abi: airdropAbi, functionName: 'claimed', args: [coin, BigInt(id)] })) }) : [];
  const open = minted.filter((_, k) => !claimed[k]);
  // claimFor skips NFTs held by a contract (escrow, vault, smart wallet: swarm round 8, Medium 2); their owners claim
  // themselves, so the keeper never queues them (it would send the same batch again and again)
  const code = await codeOf(p, new Set(open.map((id) => owners[id])));
  return { open: true, collection, ids: open.filter((id) => code.get(owners[id]) === false), contractHeld: open.filter((id) => code.get(owners[id]) === true), unknown: open.filter((id) => code.get(owners[id]) === null), complete: owners.length - 1 >= Number(maxId), airdrop: a.airdrop };
}

// ---------------- what the platform has earned from one coin (for the airdrop push gate) ----------------
const feeTaken = parseAbiItem('event FeeTaken(bytes32 indexed id, uint256 jigAmount, uint24 feePips)');
const platformBps = (fee) => (fee <= 10_000 ? 2500n : fee <= 30_000 ? 3000n : fee <= 60_000 ? 3500n : 4000n); // CreatorFeeHook.platformBps
async function blockAt(p, ts) {
  let lo = 0n, hi = await p.getBlockNumber();
  while (lo < hi) { const mid = (lo + hi) / 2n; const b = await p.getBlock({ blockNumber: mid }); if (Number(b.timestamp) < ts) lo = mid + 1n; else hi = mid; }
  return lo;
}
/** The platform's share of every fee taken on pool `poolId`, in JIG wei, indexed incrementally from `prev`
 *  ({ fromBlock, jig } as strings; the caller persists the result). Starts at the pool's launch. */
export async function platformEarned(poolId, launchedAt, prev) {
  const a = addresses(); const p = pub();
  let from = prev?.fromBlock ? BigInt(prev.fromBlock) : await blockAt(p, Number(launchedAt) - 60);
  let jig = BigInt(prev?.jig ?? 0);
  const head = await p.getBlockNumber(); let step = 10_000n;
  while (from <= head) {
    const to = from + step - 1n > head ? head : from + step - 1n;
    let logs;
    try { logs = await p.getLogs({ address: a.feeHook, event: feeTaken, args: { id: poolId }, fromBlock: from, toBlock: to }); }
    catch (e) { if (step > 500n) { step /= 2n; continue; } throw e; }
    for (const l of logs) jig += (l.args.jigAmount * platformBps(Number(l.args.feePips))) / 10_000n;
    from = to + 1n;
  }
  return { fromBlock: from.toString(), jig: jig.toString() };
}

// ---------------- airdrop delivery status for the site (17 Oct) ----------------
// The keeper pushes a coin's airdrop only once the platform's share of that coin's trading fees covers the gas
// (AIRDROP_PUSH_GATE). This says where a coin stands, so the site can show "sending", "done" or roughly how much more
// trading is needed, next to a "claim now" button.
const hookPoolsAbi = parseAbi(['function pools(bytes32) view returns (address coin, address creator, address flywheel, uint24 feePips, uint16 creatorBps, bytes32 id, int24 tickLower, int24 tickUpper, uint64 launchedAt, bool coinIs0, bool registered, bool seeded)']);
const keyAbi = [{ type: 'function', name: 'keyOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] }] }];
const GAS_PER_NFT = 150_000; const BATCH = Number(process.env.KEEPER_AIRDROP_BATCH ?? 15);

export async function pushStatus(coin, collection, pending) {
  if (pending === 0) return { status: 'done' };
  if (process.env.AIRDROP_PUSH_GATE === '0') return { status: 'sending' };
  const a = addresses(); const p = pub();
  const { DATA } = await import('./store.mjs'); const { jigPrice } = await import('./jig.mjs'); const { ethPrice } = await import('./builds.mjs'); const { poolIdOf } = await import('./v4state.mjs');
  const fs = await import('node:fs'); const path = await import('node:path');
  let st = {}; try { st = JSON.parse(fs.readFileSync(path.join(DATA, 'keeper.json'), 'utf8')); } catch {}
  const key = await p.readContract({ address: a.factory, abi: keyAbi, functionName: 'keyOf', args: [collection] });
  const cfg = await p.readContract({ address: a.feeHook, abi: hookPoolsAbi, functionName: 'pools', args: [poolIdOf(key)] });
  const feePips = Number(cfg[3]);
  const earnedJig = st.fees?.[coin]?.jig ? BigInt(st.fees[coin].jig) : BigInt((await platformEarned(poolIdOf(key), Number(cfg[8]), null)).jig);
  const [jp, eth, gasPrice] = await Promise.all([jigPrice().catch(() => null), ethPrice().catch(() => 0), p.getGasPrice()]);
  if (!jp?.jigUsd || !eth) return { status: 'waiting', reason: 'prices unavailable right now' };
  const earnedUsd = (Number(earnedJig) / 1e18) * jp.jigUsd;
  const spentUsd = Number(st.airdropSpentEth?.[coin] ?? 0) * eth;
  const nextUsd = (Math.min(BATCH, pending) * GAS_PER_NFT * Number(gasPrice)) / 1e18 * eth;
  const allUsd = (pending * GAS_PER_NFT * Number(gasPrice)) / 1e18 * eth;
  const shortfall = Math.max(0, spentUsd + nextUsd - earnedUsd);
  const platformShare = (feePips / 1e6) * (Number(platformBps(feePips)) / 10_000); // platform's cut of each traded dollar
  return {
    status: shortfall === 0 ? 'sending' : 'waiting',
    platformEarnedUsd: Number(earnedUsd.toFixed(2)), pushCostSoFarUsd: Number(spentUsd.toFixed(2)), pushCostRemainingUsd: Number(allUsd.toFixed(2)),
    // trading volume still needed before the next batch goes out (rough: prices move)
    volumeNeededUsd: shortfall === 0 ? 0 : Math.ceil(shortfall / platformShare),
  };
}
