// Reading Uniswap v4 pool state straight from the PoolManager (extsload), as v4-core's StateLibrary does:
// pools mapping at slot 6, state struct at keccak256(poolId, 6), slot0 packed, liquidity at offset 3.
import { keccak256, encodeAbiParameters, hexToBigInt, pad, toHex, parseAbi } from 'viem';

export const POOL_MANAGER = { 11155111: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543', 4663: '0x8366a39CC670B4001A1121B8F6A443A643e40951' };
export const keyType = { type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] };
const extsloadAbi = parseAbi(['function extsload(bytes32) view returns (bytes32)']);

export const poolIdOf = (key) => keccak256(encodeAbiParameters([keyType], [key]));
export const stateSlot = (id) => keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'bytes32' }], [id, pad(toHex(6), { size: 32 })]));

export function decodeSlot0(word) {
  const v = hexToBigInt(word);
  const sqrtPriceX96 = v & ((1n << 160n) - 1n);
  let tick = Number((v >> 160n) & 0xffffffn); if (tick >= 0x800000) tick -= 0x1000000;
  return { sqrtPriceX96, tick, lpFee: Number((v >> 208n) & 0xffffffn) };
}

/** currency1 per currency0 (both 18 decimals). */
export const priceOf = (sqrtPriceX96) => { const p = Number(sqrtPriceX96) / 2 ** 96; return p * p; };

export async function readPool(pub, chainId, id) {
  const pm = POOL_MANAGER[chainId]; if (!pm) return null;
  const base = stateSlot(id);
  const [w0, wl] = await Promise.all([
    pub.readContract({ address: pm, abi: extsloadAbi, functionName: 'extsload', args: [base] }),
    pub.readContract({ address: pm, abi: extsloadAbi, functionName: 'extsload', args: [toHex(hexToBigInt(base) + 3n, { size: 32 })] }),
  ]);
  return { poolManager: pm, poolId: id, ...decodeSlot0(w0), liquidity: hexToBigInt(wl) };
}
