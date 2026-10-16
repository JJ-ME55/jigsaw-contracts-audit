// One way to send a transaction from the operating wallet (LAUNCH_PK) on the launch chains: a lock per chain so the
// keeper, launches, reveals and the allowlist root never pick the same nonce. The lock is in-process: run ONE server
// process per wallet (no cluster mode). The IMD payments (imd.mjs, float.mjs) send on Ethereum outside this lock: safe
// while no launch chain is Ethereum, as nonces are per chain. For every send here the hash is known (and handed to the
// caller to persist) BEFORE the transaction is broadcast. After a crash the caller looks the hash up instead of
// guessing from the nonce
// (pre-audit review, 16 Oct: concurrent auto-nonce sends collided, and "nonce moved" was not proof a job's tx went out).
import { createPublicClient, createWalletClient, http, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CHAINS } from './launch.mjs';

const locks = new Map(); // chainId -> tail of the promise chain
function withLock(chainId, fn) {
  const prev = locks.get(chainId) ?? Promise.resolve();
  const run = prev.then(fn, fn);
  locks.set(chainId, run.catch(() => {}));
  return run;
}

export function clientsFor(chainId) {
  const c = CHAINS[Number(chainId)]; if (!c) throw new Error(`unknown chain ${chainId}`);
  const pk = process.env.LAUNCH_PK; if (!pk) throw new Error('LAUNCH_PK not set on the server');
  const account = privateKeyToAccount(pk);
  return { account, pub: createPublicClient({ chain: c.chain, transport: http(c.rpc) }), wallet: createWalletClient({ account, chain: c.chain, transport: http(c.rpc) }) };
}

/**
 * Sign, report the hash through onHash (persist it there), broadcast, wait, and throw unless the receipt says success.
 * tx: { to?, data?, value? }. Returns { hash, receipt }.
 */
export function send(chainId, tx, { onHash, timeoutMs = 10 * 60_000, allowRevert = false } = {}) {
  return withLock(Number(chainId), async () => {
    const { account, pub, wallet } = clientsFor(chainId);
    const nonce = await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
    const request = await wallet.prepareTransactionRequest({ ...tx, account, nonce });
    const signed = await wallet.signTransaction(request);
    const hash = keccak256(signed);
    await onHash?.(hash, nonce);
    await pub.sendRawTransaction({ serializedTransaction: signed });
    const receipt = await pub.waitForTransactionReceipt({ hash, timeout: timeoutMs });
    if (receipt.status !== 'success' && !allowRevert) throw Object.assign(new Error(`transaction ${hash} reverted on chain`), { hash, receipt });
    return { hash, receipt };
  });
}
