// One creator coin, everything the coin page needs, read from the chain (cached 15 s per coin).
// A coin counts only if the factory says so: CreatorCoin.collection() -> CoinFactory.coinOf(collection) == coin.
import { createPublicClient, http, parseAbi, getAddress, isAddress, formatUnits } from 'viem';
import { poolIdOf } from './v4state.mjs';
import { CHAINS } from './launch.mjs';
import { addresses, jigPrice } from './jig.mjs';
import { readPool } from './v4state.mjs';
import { list } from './store.mjs';

const EXPLORER = { 11155111: 'https://sepolia.etherscan.io', 1: 'https://etherscan.io', 4663: 'https://explorer.chain.robinhood.com' };

const keyType = { type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] };
const coinAbi = parseAbi(['function name() view returns (string)', 'function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function totalSupply() view returns (uint256)', 'function collection() view returns (address)']);
const factoryAbi = [
  ...parseAbi(['function coinOf(address) view returns (address)']),
  { type: 'function', name: 'keyOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [keyType] },
];
const hookAbi = [
  ...parseAbi([
    'function pools(bytes32) view returns (address coin, address creator, address flywheel, uint24 feePips, uint16 creatorBps, bytes32 id, int24 tickLower, int24 tickUpper, uint64 launchedAt, bool coinIs0, bool registered, bool seeded)',
    'function currentFee(bytes32) view returns (uint24)',
    'function platformBps(uint24) pure returns (uint16)',
    'function creatorBlockBps(uint24) pure returns (uint16)',
    'function claimable(address) view returns (uint256)',
    'function pendingCoin(bytes32) view returns (uint256)',
    'function POT_BPS() view returns (uint16)',
    'function DEEPEN_BPS() view returns (uint16)',
    'function SNIPE_WINDOW() view returns (uint64)',
  ]),
  { type: 'function', name: 'recyclable', stateMutability: 'view', inputs: [keyType, { type: 'address' }], outputs: [{ type: 'uint256' }, { type: 'uint256' }] },
];

export { decodeSlot0, poolIdOf } from './v4state.mjs';

/** JIG per coin from sqrtPriceX96 (both 18 decimals). currency1 per currency0 = (sqrtP / 2^96)^2. */
export function jigPerCoin(sqrtPriceX96, coinIs0) {
  const p = Number(sqrtPriceX96) / 2 ** 96; const price = p * p;
  return coinIs0 ? price : price === 0 ? 0 : 1 / price;
}

const cache = new Map();
export async function coin(addr) {
  if (!isAddress(addr)) throw Object.assign(new Error('not an address'), { status: 400 });
  const a = addresses(); if (!a.factory || !a.feeHook) throw new Error('COIN_FACTORY / CREATOR_FEE_HOOK not set');
  const coinAddr = getAddress(addr);
  const hit = cache.get(coinAddr); if (hit && Date.now() - hit.at < 15_000) return hit.value;
  const c = CHAINS[a.chainId]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const read = (address, abi, functionName, args) => pub.readContract({ address, abi, functionName, args });

  let collection;
  try { collection = await read(coinAddr, coinAbi, 'collection'); } catch { throw Object.assign(new Error('not a Jigsaw creator coin'), { status: 404 }); }
  const registered = await read(a.factory, factoryAbi, 'coinOf', [collection]);
  if (getAddress(registered) !== coinAddr) throw Object.assign(new Error('not a Jigsaw creator coin'), { status: 404 });

  const key = await read(a.factory, factoryAbi, 'keyOf', [collection]);
  const id = poolIdOf(key);
  const [name, symbol, decimals, supply, cfg, curFee, pending, potBps, deepBps, snipe] = await Promise.all([
    read(coinAddr, coinAbi, 'name'), read(coinAddr, coinAbi, 'symbol'), read(coinAddr, coinAbi, 'decimals'), read(coinAddr, coinAbi, 'totalSupply'),
    read(a.feeHook, hookAbi, 'pools', [id]), read(a.feeHook, hookAbi, 'currentFee', [id]), read(a.feeHook, hookAbi, 'pendingCoin', [id]),
    read(a.feeHook, hookAbi, 'POT_BPS'), read(a.feeHook, hookAbi, 'DEEPEN_BPS'), read(a.feeHook, hookAbi, 'SNIPE_WINDOW'),
  ]);
  const [, creator, flywheel, feePips, creatorBps, , tickLower, tickUpper, launchedAt, coinIs0] = cfg;
  const flyAddr = flywheel === '0x0000000000000000000000000000000000000000' ? creator : flywheel;
  const [platBps, blockBps, creatorClaim, flyClaim, creatorRec, flyRec] = await Promise.all([
    read(a.feeHook, hookAbi, 'platformBps', [feePips]), read(a.feeHook, hookAbi, 'creatorBlockBps', [feePips]),
    read(a.feeHook, hookAbi, 'claimable', [creator]), read(a.feeHook, hookAbi, 'claimable', [flyAddr]),
    read(a.feeHook, hookAbi, 'recyclable', [key, creator]).catch(() => [0n, 0n]), read(a.feeHook, hookAbi, 'recyclable', [key, flyAddr]).catch(() => [0n, 0n]),
  ]);

  let pool = null;
  const ps = await readPool(pub, a.chainId, id);
  if (ps) pool = { poolManager: ps.poolManager, poolId: id, sqrtPriceX96: ps.sqrtPriceX96.toString(), tick: ps.tick, liquidity: ps.liquidity.toString(), range: { tickLower, tickUpper }, inRange: ps.tick >= tickLower && ps.tick < tickUpper };

  const dec = Number(decimals); const sup = Number(formatUnits(supply, dec));
  const px = pool ? jigPerCoin(BigInt(pool.sqrtPriceX96), coinIs0) : null;
  const jp = await jigPrice().catch(() => null); const jigUsd = jp?.jigUsd ?? null;
  const now = Math.floor(Date.now() / 1000); const snipeEnds = Number(launchedAt) + Number(snipe);
  const fmt = (v) => formatUnits(v, 18);

  // our own build record, if this collection was launched here: name, mint page, a sample image
  let site = null;
  try {
    const b = list().find((x) => x.launch?.collection && getAddress(x.launch.collection) === getAddress(collection));
    if (b) site = { buildId: b.id, name: b.launch.settings?.name ?? b.input?.name, mintPage: `/mint/${b.launch.settings?.chainId}/${b.launch.collection}`, sampleImage: `/files/${b.id}/out_512/images/1.png`, revealed: b.launch.revealed ?? true };
  } catch {}

  const value = {
    chainId: a.chainId, coin: coinAddr, name, symbol, decimals: dec, totalSupply: supply.toString(), collection: getAddress(collection), site,
    creator, flywheel: flyAddr, flywheelIsCreator: flyAddr === creator, launchedAt: Number(launchedAt),
    key: { currency0: key.currency0, currency1: key.currency1, fee: key.fee, tickSpacing: key.tickSpacing, hooks: key.hooks }, coinIs0, pool,
    price: px === null ? null : { jigPerCoin: px, fdvJig: px * sup, fdvUsd: jigUsd === null ? null : px * sup * jigUsd, jigUsd, jigUsdSource: jp?.source ?? 'unknown' },
    fees: {
      feePips: Number(feePips), currentFeePips: Number(curFee), snipe: { endsAt: snipeEnds, secondsLeft: Math.max(0, snipeEnds - now) },
      splitBps: { pot: Number(potBps), deepening: Number(deepBps), platform: Number(platBps), creator: Number(creatorBps), flywheel: Number(blockBps) - Number(creatorBps) },
      sells: 'exact-input only',
    },
    balances: {
      creator: { claimableJig: fmt(creatorClaim), recyclable: { staleJig: fmt(creatorRec[0]), freshJig: fmt(creatorRec[1]) } },
      flywheel: flyAddr === creator ? null : { claimableJig: fmt(flyClaim), recyclable: { staleJig: fmt(flyRec[0]), freshJig: fmt(flyRec[1]) } },
      pendingCoin: fmt(pending),
    },
    links: EXPLORER[a.chainId] ? { coin: `${EXPLORER[a.chainId]}/token/${coinAddr}`, collection: `${EXPLORER[a.chainId]}/address/${getAddress(collection)}`, hook: `${EXPLORER[a.chainId]}/address/${a.feeHook}` } : null,
    readAt: new Date().toISOString(),
  };
  cache.set(coinAddr, { at: Date.now(), value });
  return value;
}
