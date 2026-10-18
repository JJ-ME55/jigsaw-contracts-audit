// Flywheel modules per collection (go-live item, 18 Oct): the coin launch form names a flywheel address, so the server
// deploys the chosen module for the collection first and hands back its address. One module per collection and kind,
// deployed once: the pending transaction is saved on the build before it is broadcast, a retry waits for that one
// instead of sending another, and calls for the same collection run one at a time (founders' rule 4). Refused once the
// collection has a coin (the flywheel is fixed at launch). Sweep & burn is not offered yet (it needs marketplace
// approvals from the creator).
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, http, encodeDeployData, getAddress, isAddress, parseAbi } from 'viem';
import { send as sendTx, clientsFor } from './sender.mjs';
import { list, load, update, ledger } from './store.mjs';
import { addresses } from './jig.mjs';
import { CHAINS } from './launch.mjs';

const ART = JSON.parse(fs.readFileSync(path.join(import.meta.dirname, 'artifacts', 'flywheels.json'), 'utf8'));
export const KINDS = {
  drip: { contract: 'HolderDrip', label: 'Holder drip (NFT holders paid per token)', args: (a, col) => [a.feeHook, col] },
  buyback: { contract: 'BuybackAndBurn', label: 'Buyback & burn', args: (a, col, keeper) => [a.feeHook, a.factory, col, keeper] },
  rewards: { contract: 'RewardsForwarder', label: 'Coin-holder rewards (JIG streamed over 24 hours)', args: (a, col) => [a.feeHook, a.factory, col] },
};

const locks = new Map();
const lock = (k, fn) => { const run = (locks.get(k) ?? Promise.resolve()).catch(() => {}).then(fn); locks.set(k, run); run.finally(() => { if (locks.get(k) === run) locks.delete(k); }).catch(() => {}); return run; };

/** The build that launched `collection` on the coin chain, or null. */
export function buildForCollection(collection) {
  const a = addresses(); const want = String(collection).toLowerCase();
  return list().find((b) => b.launch?.collection?.toLowerCase() === want && Number(b.launch?.settings?.chainId ?? b.launch?.chainId) === a.chainId) ?? null;
}

/** Deploy (or return) the `kind` module for the collection. `b` is the build, already owner-checked by the route. */
export function flywheelFor(b, kind) {
  if (!KINDS[kind]) throw Object.assign(new Error(`flywheel kind must be one of ${Object.keys(KINDS).join(', ')} (creator wallet = no module: pass 0x0)`), { status: 400 });
  const col = b.launch?.collection; if (!col || !isAddress(col)) throw new Error('the collection is not deployed yet');
  return lock(col.toLowerCase(), () => deploy(b.id, getAddress(col), kind));
}

async function deploy(buildId, col, kind) {
  const a = addresses(); if (!a.feeHook || !a.factory) throw new Error('CREATOR_FEE_HOOK / COIN_FACTORY not set on the server');
  const c = CHAINS[a.chainId]; const pub = createPublicClient({ chain: c.chain, transport: http(c.rpc) });
  const rec = load(buildId).launch?.flywheels?.[kind];
  if (rec?.address) return { kind, address: rec.address, tx: rec.tx, existing: true };
  const coin = await pub.readContract({ address: a.factory, abi: parseAbi(['function coinOf(address) view returns (address)']), functionName: 'coinOf', args: [col] });
  if (coin !== '0x0000000000000000000000000000000000000000') throw new Error(`this collection already has its coin (${coin}); its flywheel was fixed at launch`);
  const save = (patch) => update(buildId, (d) => { d.launch.flywheels = { ...(d.launch.flywheels ?? {}), [kind]: { ...(d.launch.flywheels?.[kind] ?? {}), ...patch } }; });
  let receipt;
  if (rec?.pendingTx) {
    // an earlier call broadcast (or tried to): wait for that transaction rather than deploying a second module
    receipt = await pub.waitForTransactionReceipt({ hash: rec.pendingTx, timeout: 120_000 }).catch(() => null);
    if (!receipt) { const known = await pub.getTransaction({ hash: rec.pendingTx }).catch(() => null); if (known) throw new Error(`the ${kind} module deploy ${rec.pendingTx} is still pending; try again shortly`); save({ pendingTx: null, droppedTx: rec.pendingTx }); }
    else if (receipt.status !== 'success') { save({ pendingTx: null, revertedTx: rec.pendingTx }); receipt = null; }
  }
  if (!receipt) {
    const k = KINDS[kind]; const keeper = clientsFor(a.chainId).account.address;
    const data = encodeDeployData({ abi: ART[k.contract].abi, bytecode: ART[k.contract].bytecode, args: k.args(a, col, keeper) });
    ({ receipt } = await sendTx(a.chainId, { data }, { onHash: (h) => save({ pendingTx: h, at: new Date().toISOString() }) }));
  }
  const address = getAddress(receipt.contractAddress);
  save({ address, tx: receipt.transactionHash, pendingTx: null });
  ledger(`${buildId},flywheel-${kind},${col},${address},${receipt.transactionHash},gas ${receipt.gasUsed}`);
  return { kind, address, tx: receipt.transactionHash, existing: false };
}
