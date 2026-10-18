// Swaps on our own pools (ETH <-> JIG, JIG <-> creator coin, and ETH <-> creator coin through JIG), through Uniswap's
// Universal Router, with a platform fee taken inside the swap: TAKE_PORTION sends SWAP_FEE_BPS of the output to the
// platform wallet, TAKE_ALL sends the rest to the user and enforces their minimum. The same interface-fee pattern
// Uniswap's own site uses. Aggregators cannot route through our hooked pools, so this is the swap for JIG and coins.
//
// Exact-input only: creator-coin sells must be exact-input (the hook refuses exact-output sells), and one shape keeps
// the fee maths obvious. The user signs the transaction; the server only quotes and builds calldata.
//
// Router param layout is the deployed Universal Router's (original v4 release, as float.mjs uses on mainnet), not
// the pinned periphery's newer one with minHopPriceX36.
import { createPublicClient, http, parseAbi, getAddress, isAddress, encodeAbiParameters, encodeFunctionData, decodeFunctionResult, formatUnits } from 'viem';
import { CHAINS } from './launch.mjs';
import { addresses } from './jig.mjs';

export const ETH = '0x0000000000000000000000000000000000000000';
const V4 = {
  11155111: { router: '0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b', quoter: '0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227', permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3' },
  4663: { router: '0x8876789976dEcBfCbBbe364623C63652db8C0904', quoter: '0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94', permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3' }, // Robinhood Chain (Uniswap docs, checked on chain 16 Oct)
};
const DYNAMIC_FEE = 0x800000; const JIG_SPACING = 200;
const ACT = { SWAP_EXACT_IN_SINGLE: 0x06, SWAP_EXACT_IN: 0x07, SETTLE_ALL: 0x0c, TAKE_ALL: 0x0f, TAKE_PORTION: 0x10 };
const CMD_V4_SWAP = '0x10';
export const MAX_FEE_BPS = 100;
export const feeBps = () => Math.min(MAX_FEE_BPS, Math.max(0, Number(process.env.SWAP_FEE_BPS ?? 25)));

const keyTuple = { type: 'tuple', components: [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }] };
const pathKeyTuple = { type: 'tuple', components: [{ name: 'intermediateCurrency', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }, { name: 'hookData', type: 'bytes' }] };
const quoterAbi = [
  { type: 'function', name: 'quoteExactInputSingle', stateMutability: 'nonpayable', inputs: [{ type: 'tuple', components: [{ name: 'poolKey', ...keyTuple }, { name: 'zeroForOne', type: 'bool' }, { name: 'exactAmount', type: 'uint128' }, { name: 'hookData', type: 'bytes' }] }], outputs: [{ type: 'uint256' }, { type: 'uint256' }] },
  { type: 'function', name: 'quoteExactInput', stateMutability: 'nonpayable', inputs: [{ type: 'tuple', components: [{ name: 'exactCurrency', type: 'address' }, { name: 'path', type: 'tuple[]', components: pathKeyTuple.components }, { name: 'exactAmount', type: 'uint128' }] }], outputs: [{ type: 'uint256' }, { type: 'uint256' }] },
];
const coinAbi = parseAbi(['function collection() view returns (address)', 'function symbol() view returns (string)']);
const factoryAbi = [...parseAbi(['function coinOf(address) view returns (address)']), { type: 'function', name: 'keyOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [keyTuple] }];
const erc20Abi = parseAbi(['function allowance(address,address) view returns (uint256)', 'function balanceOf(address) view returns (uint256)']);
const permit2Abi = parseAbi(['function allowance(address,address,address) view returns (uint160 amount, uint48 expiration, uint48 nonce)']);

const ctx = () => {
  const a = addresses(); const v = V4[a.chainId]; if (!v) throw new Error(`swaps not configured for chain ${a.chainId}`);
  // COIN_FACTORY is only needed for coin routes: ETH <-> JIG must quote from the first block of the JIG window, before
  // the coin side is deployed (pre-audit review, 16 Oct)
  if (!a.jig || !a.launchHook) throw new Error('JIG_TOKEN / JIG_LAUNCH_HOOK not set');
  const c = CHAINS[a.chainId];
  return { a, v, pub: createPublicClient({ chain: c.chain, transport: http(c.rpc) }) };
};

export const jigPoolKey = (a) => ({ currency0: ETH, currency1: a.jig, fee: DYNAMIC_FEE, tickSpacing: JIG_SPACING, hooks: a.launchHook });

/** The pool linking `token` to JIG: the JIG/ETH pool for ETH, the creator coin's own pool for a registered coin. */
async function poolWithJig(pub, a, token) {
  if (token === ETH) return { key: jigPoolKey(a), kind: 'jig' };
  const collection = await pub.readContract({ address: token, abi: coinAbi, functionName: 'collection' }).catch(() => null);
  if (!collection) throw new Error(`${token} is not ETH, JIG or a Jigsaw creator coin`);
  if (!a.factory) throw new Error('COIN_FACTORY not set: only ETH <-> JIG can be quoted yet');
  const coin = await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'coinOf', args: [collection] });
  if (getAddress(coin) !== getAddress(token)) throw new Error(`${token} is not a Jigsaw creator coin`);
  return { key: await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'keyOf', args: [collection] }), kind: 'coin' };
}

/** Route from `from` to `to`: one hop when one side is JIG, two hops through JIG otherwise. */
export async function route(from, to) {
  const { a, pub } = ctx();
  const norm = (t) => (t === 'ETH' || t === ETH ? ETH : getAddress(t));
  from = norm(from); to = norm(to);
  if (from === to) throw new Error('from and to are the same');
  const isJig = (t) => t === a.jig;
  if (isJig(from) || isJig(to)) {
    const other = isJig(from) ? to : from;
    const { key, kind } = await poolWithJig(pub, a, other);
    return { from, to, hops: [{ key, kind, zeroForOne: getAddress(from) === getAddress(key.currency0) }] };
  }
  const h1 = await poolWithJig(pub, a, from); const h2 = await poolWithJig(pub, a, to);
  return { from, to, hops: [{ key: h1.key, kind: h1.kind, zeroForOne: getAddress(from) === getAddress(h1.key.currency0) }, { key: h2.key, kind: h2.kind, zeroForOne: getAddress(a.jig) === getAddress(h2.key.currency0) }], via: a.jig };
}

// the allowlist proof (hookData) goes to the JIG pool hop: a two-hop ETH -> coin swap crosses it too, and without the
// proof an allowlisted wallet paid the 60% window fee there (pre-audit review, 16 Oct)
const pathOf = (r, hookData = '0x') => r.hops.map((h, i) => {
  const out = i === r.hops.length - 1 ? r.to : r.via;
  return { intermediateCurrency: out, fee: h.key.fee, tickSpacing: h.key.tickSpacing, hooks: h.key.hooks, hookData: h.kind === 'jig' ? hookData : '0x' };
});

/** Output for `amountIn` from the V4 Quoter (eth_call; the quoter reverts internally by design). Net of every pool and
 *  hook fee on the route (the quoter runs the hooks); "gross" only of the platform's TAKE_PORTION, applied after. */
// `account` is the sender: eth_call then runs with tx.origin = that wallet, which is what JIGLaunchHook's allowlist
// checks (without it an allowlisted wallet was quoted the 60% window fee, final audit 17 Oct)
export async function quoteGross(r, amountIn, hookData = '0x', account) {
  const { v, pub } = ctx();
  const data = r.hops.length === 1
    ? encodeFunctionData({ abi: quoterAbi, functionName: 'quoteExactInputSingle', args: [{ poolKey: r.hops[0].key, zeroForOne: r.hops[0].zeroForOne, exactAmount: amountIn, hookData }] })
    : encodeFunctionData({ abi: quoterAbi, functionName: 'quoteExactInput', args: [{ exactCurrency: r.from, path: pathOf(r, hookData), exactAmount: amountIn }] });
  const res = await pub.call({ to: v.quoter, data, ...(account && isAddress(account) ? { account: getAddress(account) } : {}) });
  const [out] = decodeFunctionResult({ abi: quoterAbi, functionName: r.hops.length === 1 ? 'quoteExactInputSingle' : 'quoteExactInput', data: res.data });
  return out;
}

/** Universal Router calldata: swap, settle input, TAKE_PORTION fee to the platform, TAKE_ALL the rest to the user (>= minOut). */
export { pathOf };
export function calldata(r, amountIn, minOut, { bps, platform, deadline, hookData = '0x' }) {
  const swapAct = r.hops.length === 1 ? ACT.SWAP_EXACT_IN_SINGLE : ACT.SWAP_EXACT_IN;
  const acts = [swapAct, ACT.SETTLE_ALL, ...(bps > 0 ? [ACT.TAKE_PORTION] : []), ACT.TAKE_ALL];
  const actions = `0x${acts.map((x) => x.toString(16).padStart(2, '0')).join('')}`;
  const swapParams = r.hops.length === 1
    ? encodeAbiParameters([{ type: 'tuple', components: [{ name: 'poolKey', ...keyTuple }, { name: 'zeroForOne', type: 'bool' }, { name: 'amountIn', type: 'uint128' }, { name: 'amountOutMinimum', type: 'uint128' }, { name: 'hookData', type: 'bytes' }] }],
        [{ poolKey: r.hops[0].key, zeroForOne: r.hops[0].zeroForOne, amountIn, amountOutMinimum: 0n, hookData }])
    : encodeAbiParameters([{ type: 'tuple', components: [{ name: 'currencyIn', type: 'address' }, { name: 'path', type: 'tuple[]', components: pathKeyTuple.components }, { name: 'amountIn', type: 'uint128' }, { name: 'amountOutMinimum', type: 'uint128' }] }],
        [{ currencyIn: r.from, path: pathOf(r, hookData), amountIn, amountOutMinimum: 0n }]);
  const settle = encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [r.from, amountIn]);
  const params = [swapParams, settle];
  if (bps > 0) params.push(encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint256' }], [r.to, platform, BigInt(bps)]));
  params.push(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [r.to, minOut])); // the user's minimum, after the fee
  const v4Input = encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], [actions, params]);
  return encodeFunctionData({ abi: parseAbi(['function execute(bytes commands, bytes[] inputs, uint256 deadline) payable']), functionName: 'execute', args: [CMD_V4_SWAP, [v4Input], deadline] });
}

/** Everything the site needs to show a swap and send it. `account` is optional; with it, the approvals still missing are listed. */
export async function quote({ from, to, amountIn, slippageBps = 100, account, hookData = '0x' }) {
  const { a, v, pub } = ctx();
  const amt = BigInt(amountIn); if (amt <= 0n) throw new Error('amountIn must be positive');
  const slip = Math.min(5000, Math.max(0, Number(slippageBps)));
  const r = await route(from, to);
  const gross = await quoteGross(r, amt, hookData, account);
  const bps = feeBps(); const platform = process.env.PLATFORM_ADDRESS && isAddress(process.env.PLATFORM_ADDRESS) ? getAddress(process.env.PLATFORM_ADDRESS) : null;
  const effBps = platform ? bps : 0;
  const fee = (gross * BigInt(effBps)) / 10_000n; const net = gross - fee;
  const minOut = (net * BigInt(10_000 - slip)) / 10_000n;
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 20 * 60);
  const data = calldata(r, amt, minOut, { bps: effBps, platform, deadline, hookData });
  const approvals = [];
  if (r.from !== ETH && account && isAddress(account)) {
    const [toPermit2, p2] = await Promise.all([
      pub.readContract({ address: r.from, abi: erc20Abi, functionName: 'allowance', args: [getAddress(account), v.permit2] }),
      pub.readContract({ address: v.permit2, abi: permit2Abi, functionName: 'allowance', args: [getAddress(account), r.from, v.router] }),
    ]);
    if (toPermit2 < amt) approvals.push({ step: 'token -> Permit2', to: r.from, call: 'approve(permit2, max)', spender: v.permit2 });
    const [p2amt, p2exp] = p2;
    if (p2amt < amt || Number(p2exp) < Math.floor(Date.now() / 1000) + 60) approvals.push({ step: 'Permit2 -> router', to: v.permit2, call: 'approve(token, router, amount, expiration)', token: r.from, spender: v.router });
  }
  return {
    chainId: a.chainId, from: r.from, to: r.to, via: r.via ?? null, hops: r.hops.length,
    amountIn: amt.toString(), grossOut: gross.toString(), feeBps: effBps, feeOut: fee.toString(), feeRecipient: platform, netOut: net.toString(), minOut: minOut.toString(), slippageBps: slip,
    tx: { to: v.router, data, value: r.from === ETH ? amt.toString() : '0', deadline: deadline.toString() },
    approvals, permit2: v.permit2, router: v.router,
    note: r.hops.some((h) => h.kind === 'jig') ? 'the JIG pool charges 60% to wallets not on the allowlist for 5 minutes after launch; pass the allowlist proof as hookData then' : undefined,
  };
}

export const fmt = (x) => formatUnits(BigInt(x), 18);
