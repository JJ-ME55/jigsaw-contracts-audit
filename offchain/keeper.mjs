// The keeper: the on-chain housekeeping nobody else will do, at random times, with a minimum out on every trade.
//
// Jobs (discovered from the chain each pass):
//   deepening        LPDeepening.run(minEthOut): sells half its JIG for ETH, adds both as locked JIG/ETH liquidity
//   buyback:<coin>   BuybackAndBurn.run(minCoinOut): buys the coin with the module's whole JIG, burns it
//   drip:<coin>      HolderDrip.pull(): moves the NFT holders' slice in and spreads it (frequent pulls keep the
//                    mint-timing lag short, swarm audit 6)
//   forward:<coin>   SnapshotForwarder.pull(): moves the coin holders' slice to HolderPayouts for the next round
//   pot              CreatorFeeHook.claimFor(pot): pushes the pot's JIG into PotVault (it cannot claim itself)
//   jigfees          JIGLaunch.collectFees(): the JIG pool's LP fees, half team, half pot
// Trades (deepening, buyback) run at a random time 2 to 10 hours after the last run, the whole balance at once
// (Jj, 15 Oct). Pulls and collects run every 4 to 8 hours. Nothing runs inside the JIG launch window (the hook
// charges the modules 60% and refuses the deepening's liquidity).
//
// Rule 4: a marker (with the account nonce) is written before every send; a pass never overlaps another; each job
// has a daily cap and backs off on failure; the whole keeper has a daily transaction cap. Every send is ledgered.
// Off unless KEEPER_ENABLED=1. Mainnets refused unless ALLOW_MAINNET=1.
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, createWalletClient, http, parseAbi, getAddress, formatEther, encodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CHAINS } from './launch.mjs';
import { DATA, ledger } from './store.mjs';
import { addresses, status as jigStatus, jigPrice } from './jig.mjs';
import { poolIdOf } from './v4state.mjs';
import { jigPoolKey, quoteGross } from './swap.mjs';
import * as payouts from './payouts.mjs';
import { ethPrice } from './builds.mjs';
import * as coinSettings from './coinSettings.mjs';
import { readSupply } from './launch.mjs';

const MAINNETS = new Set([1, 4663]);
const FILE = () => path.join(DATA, 'keeper.json');
const ZERO = '0x0000000000000000000000000000000000000000';
const env = (k, d) => (process.env[k] === undefined ? d : Number(process.env[k]));
const cfg = () => ({
  slippageBps: env('KEEPER_SLIPPAGE_BPS', 300),
  minUsd: env('KEEPER_MIN_USD', 5),                 // skip a job whose JIG is worth less than this (gas would eat it)
  maxTxPerDay: env('KEEPER_MAX_TX_PER_DAY', 24),
  maxPerJobPerDay: env('KEEPER_MAX_PER_JOB_PER_DAY', 3),
  tradeHours: [env('KEEPER_TRADE_MIN_H', 2), env('KEEPER_TRADE_MAX_H', 10)],
  pullHours: [env('KEEPER_PULL_MIN_H', 4), env('KEEPER_PULL_MAX_H', 8)],
  roundHours: [env('KEEPER_ROUND_MIN_H', 24), env('KEEPER_ROUND_MAX_H', 168)],   // coin-holder snapshot rounds: a random moment 1 to 7 days apart
  airdropHours: [env('KEEPER_AIRDROP_MIN_H', 24), env('KEEPER_AIRDROP_MAX_H', 72)], // the 5% airdrop snapshot, 1 to 3 days after the keeper first sees a coin
});

const hookAbi = parseAbi(['function claimable(address) view returns (uint256)', 'function claimFor(address) returns (uint256)', 'function pools(bytes32) view returns (address coin, address creator, address flywheel, uint24 feePips, uint16 creatorBps, bytes32 id, int24 tickLower, int24 tickUpper, uint64 launchedAt, bool coinIs0, bool registered, bool seeded)']);
const keyComponents = [{ name: 'currency0', type: 'address' }, { name: 'currency1', type: 'address' }, { name: 'fee', type: 'uint24' }, { name: 'tickSpacing', type: 'int24' }, { name: 'hooks', type: 'address' }];
const factoryAbi = [...parseAbi(['function count() view returns (uint256)', 'function launchFeeWei() view returns (uint256)', 'function setLaunchFee(uint256)', 'function platform() view returns (address)']), { type: 'function', name: 'launches', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ name: 'coin', type: 'address' }, { name: 'collection', type: 'address' }, { name: 'creator', type: 'address' }, { name: 'tokenId', type: 'uint256' }, { name: 'key', type: 'tuple', components: keyComponents }] }];
const probeAbi = parseAbi(['function keeper() view returns (address)', 'function burned() view returns (uint256)', 'function undistributed() view returns (uint256)', 'function payouts() view returns (address)', 'function sweeper() view returns (address)']);
const moduleAbi = parseAbi(['function run(uint256)', 'function pull() returns (uint256)', 'function collectFees()', 'function tokenId() view returns (uint256)']);
const erc20 = parseAbi(['function balanceOf(address) view returns (uint256)']);

function readState() { try { return JSON.parse(fs.readFileSync(FILE(), 'utf8')); } catch { return { jobs: {}, day: null, txToday: 0, kinds: {} }; } }
function writeState(s) { fs.mkdirSync(DATA, { recursive: true }); const tmp = FILE() + '.tmp'; fs.writeFileSync(tmp, JSON.stringify(s, null, 1)); fs.renameSync(tmp, FILE()); }
const today = () => new Date().toISOString().slice(0, 10);
const randHours = ([lo, hi]) => (lo + Math.random() * (hi - lo)) * 3600_000;

function clients() {
  const a = addresses(); const c = CHAINS[a.chainId];
  const account = privateKeyToAccount(process.env.LAUNCH_PK);
  return { a, account, pub: createPublicClient({ chain: c.chain, transport: http(c.rpc) }), wallet: createWalletClient({ account, chain: c.chain, transport: http(c.rpc) }) };
}

/** What kind of module sits at `addr` (cached: modules are immutable). */
async function kindOf(pub, addr, st) {
  if (addr === ZERO) return 'wallet';
  if (st.kinds[addr]) return st.kinds[addr];
  const code = await pub.getCode({ address: addr }); if (!code || code === '0x') return (st.kinds[addr] = 'wallet');
  const has = async (fn) => { try { await pub.readContract({ address: addr, abi: probeAbi, functionName: fn }); return true; } catch { return false; } };
  const kind = (await has('sweeper')) ? 'sweep' : (await has('payouts')) ? 'forward' : (await has('undistributed')) ? 'drip' : (await has('burned')) && (await has('keeper')) ? 'buyback' : 'unknown';
  return (st.kinds[addr] = kind);
}

/** Every job the chain currently implies, with what it would send. Reads only. */
export async function plan() {
  const { a, account, pub } = clients(); const st = readState(); const c = cfg();
  const jobs = [];
  const jp = await jigPrice().catch(() => null); const usd = (jig) => (jp?.jigUsd ? (Number(jig) / 1e18) * jp.jigUsd : null);
  const worth = (jig) => { if (jig <= 0n) return false; const u = usd(jig); return u === null || u >= c.minUsd; }; // never a zero pull, whatever the threshold
  const claim = (who) => pub.readContract({ address: a.feeHook, abi: hookAbi, functionName: 'claimable', args: [who] });
  const bal = (who) => pub.readContract({ address: a.jig, abi: erc20, functionName: 'balanceOf', args: [who] });

  if (a.deepening) {
    const amount = (await bal(a.deepening)) + (await claim(a.deepening));
    const keeper = await pub.readContract({ address: a.deepening, abi: probeAbi, functionName: 'keeper' }).catch(() => null);
    const job = { id: 'deepening', kind: 'trade', to: a.deepening, amountJig: amount.toString(), usd: usd(amount), ready: worth(amount) && keeper && getAddress(keeper) === account.address, why: !keeper || getAddress(keeper) !== account.address ? `keeper is ${keeper}, not this wallet` : worth(amount) ? '' : `JIG worth under $${c.minUsd}` };
    if (job.ready) {
      const half = amount / 2n;
      const ethOut = await quoteGross({ from: a.jig, to: ZERO, hops: [{ key: jigPoolKey(a), zeroForOne: false }] }, half);
      job.min = ((ethOut * BigInt(10_000 - c.slippageBps)) / 10_000n).toString(); job.quote = `${formatEther(half)} JIG -> ${formatEther(ethOut)} ETH`;
      job.data = encodeFunctionData({ abi: moduleAbi, functionName: 'run', args: [BigInt(job.min)] });
    }
    jobs.push(job);
    const tokenId = await pub.readContract({ address: a.deepening, abi: moduleAbi, functionName: 'tokenId' }).catch(() => 0n);
    if (tokenId > 0n) jobs.push({ id: 'deepfees', kind: 'pull', to: a.deepening, ready: true, data: encodeFunctionData({ abi: moduleAbi, functionName: 'collectFees' }) });
  }
  // the creator-coin launch fee follows LAUNCH_FEE_USD (default $149) in ETH; re-priced only on a drift above LAUNCH_FEE_DRIFT_BPS
  if (a.factory) {
    const [cur, plat, eth] = await Promise.all([
      pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'launchFeeWei' }),
      pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'platform' }).catch(() => null),
      ethPrice().catch(() => 0),
    ]);
    const usdTarget = env('LAUNCH_FEE_USD', 149); const drift = env('LAUNCH_FEE_DRIFT_BPS', 500);
    if (eth > 0 && usdTarget > 0) {
      const target = BigInt(Math.round((usdTarget / eth) * 1e9)) * 10n ** 9n; // gwei precision
      const off = cur === 0n ? 10_000n : ((cur > target ? cur - target : target - cur) * 10_000n) / target;
      const mine = plat && getAddress(plat) === account.address;
      jobs.push({ id: 'launchfee', kind: 'pull', to: a.factory, ready: !!mine && off > BigInt(drift), why: !mine ? `platform is ${plat}` : off > BigInt(drift) ? '' : `within ${drift} bps`, quote: `${formatEther(cur)} -> ${formatEther(target)} ETH ($${usdTarget} at $${eth})`, data: encodeFunctionData({ abi: factoryAbi, functionName: 'setLaunchFee', args: [target] }) });
    }
  }
  if (a.launch) jobs.push({ id: 'jigfees', kind: 'pull', to: a.launch, ready: true, data: encodeFunctionData({ abi: moduleAbi, functionName: 'collectFees' }) });
  if (a.pot) { const owed = await claim(a.pot); jobs.push({ id: 'pot', kind: 'pull', to: a.feeHook, amountJig: owed.toString(), usd: usd(owed), ready: worth(owed), why: worth(owed) ? '' : `JIG worth under $${c.minUsd}`, data: encodeFunctionData({ abi: hookAbi, functionName: 'claimFor', args: [a.pot] }) }); }

  const n = Number(await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'count' }));
  for (let i = 0; i < n; i++) {
    const L = await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'launches', args: [BigInt(i)] });
    const [coin, collection, , , key] = L;
    const cfgP = await pub.readContract({ address: a.feeHook, abi: hookAbi, functionName: 'pools', args: [poolIdOf(key)] });
    const fly = cfgP[2]; const kind = await kindOf(pub, fly, st);
    // the 5% airdrop to the collection's NFT holders, for every coin
    if (a.airdrop) {
      const prep = await payouts.prepareAirdrop(coin, collection).catch((e) => ({ error: e.message }));
      if (prep?.call) jobs.push({ id: `airdrop:${coin}`, kind: 'airdrop', to: prep.call.address, ready: true, record: prep, collection, launchedAt: Number(cfgP[8]), quote: `${prep.rec.count} holders, ${prep.rec.nfts} NFTs`, data: encodeFunctionData(prep.call) });
      else if (prep?.error) jobs.push({ id: `airdrop:${coin}`, kind: 'airdrop', ready: false, why: prep.error });
    }
    // coin-holder rounds and their settlement, for coins whose flywheel feeds HolderPayouts
    if (kind === 'forward' && a.payouts) {
      for (const s of await payouts.expiredRounds(coin)) jobs.push({ id: `settle:${coin}:${s.round}`, kind: 'pull', to: s.call.address, ready: true, data: encodeFunctionData(s.call) });
      const prep = await payouts.prepareRound(coin, cfgP[8]).catch((e) => ({ error: e.message }));
      if (prep?.call) jobs.push({ id: `round:${coin}`, kind: 'round', to: prep.call.address, ready: true, record: prep, collection, launchedAt: Number(cfgP[8]), amountJig: prep.rec.total, usd: usd(BigInt(prep.rec.total)), quote: `round ${prep.rec.round}: ${prep.rec.count} holders`, data: encodeFunctionData(prep.call) });
      else if (prep?.error) jobs.push({ id: `round:${coin}`, kind: 'round', ready: false, why: prep.error });
    }
    if (kind === 'wallet' || kind === 'unknown' || kind === 'sweep') continue; // sweeps need a listing: the sweeper runs them by hand
    const owed = await claim(fly); const held = await bal(fly); const total = owed + held;
    if (kind === 'buyback') {
      const keeper = await pub.readContract({ address: fly, abi: probeAbi, functionName: 'keeper' });
      const job = { id: `buyback:${coin}`, kind: 'trade', to: fly, amountJig: total.toString(), usd: usd(total), ready: worth(total) && getAddress(keeper) === account.address, why: getAddress(keeper) !== account.address ? `keeper is ${keeper}` : worth(total) ? '' : `JIG worth under $${c.minUsd}` };
      if (job.ready) {
        const coinOut = await quoteGross({ from: a.jig, to: coin, hops: [{ key, zeroForOne: getAddress(key.currency0) === getAddress(a.jig) }] }, total);
        job.min = ((coinOut * BigInt(10_000 - c.slippageBps)) / 10_000n).toString(); job.quote = `${formatEther(total)} JIG -> ${formatEther(coinOut)} coin`;
        job.data = encodeFunctionData({ abi: moduleAbi, functionName: 'run', args: [BigInt(job.min)] });
      }
      jobs.push(job);
    } else {
      const amount = kind === 'drip' ? owed + (await pub.readContract({ address: fly, abi: probeAbi, functionName: 'undistributed' })) : owed;
      jobs.push({ id: `${kind}:${coin}`, kind: 'pull', to: fly, amountJig: amount.toString(), usd: usd(amount), ready: worth(amount), why: worth(amount) ? '' : `JIG worth under $${c.minUsd}`, data: encodeFunctionData({ abi: moduleAbi, functionName: 'pull' }) });
    }
  }
  writeState({ ...readState(), kinds: st.kinds });
  return { chainId: a.chainId, keeper: account.address, jigUsd: jp?.jigUsd ?? null, jobs };
}

let _busy = false;
/** One pass: run every job that is ready and due. Returns what it did. */
export async function tick({ force = false } = {}) {
  if (process.env.KEEPER_ENABLED !== '1' && !force) return { skipped: 'KEEPER_ENABLED is not 1' };
  if (_busy) return { skipped: 'a pass is already running' };
  _busy = true;
  try {
    const { a, account, pub, wallet } = clients();
    if (MAINNETS.has(a.chainId) && process.env.ALLOW_MAINNET !== '1') return { skipped: 'mainnet is disabled on this server' };
    let st = readState(); const c = cfg();
    if (st.day !== today()) { st.day = today(); st.txToday = 0; for (const j of Object.values(st.jobs)) j.runsToday = 0; }

    // a send that was interrupted: if the nonce moved past it, it went out; otherwise it never did
    for (const [id, j] of Object.entries(st.jobs)) {
      if (!j.inflight) continue;
      const nonceNow = await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
      if (j.inflight.tx) { const rc = await pub.getTransactionReceipt({ hash: j.inflight.tx }).catch(() => null); if (!rc && Date.now() - j.inflight.at < 30 * 60_000) continue; j.lastResult = rc ? rc.status : 'dropped'; }
      else j.lastResult = nonceNow > j.inflight.nonce ? 'sent before a restart (nonce moved)' : 'never sent';
      j.inflight = null; st.jobs[id] = j;
    }
    writeState(st);

    const status = await jigStatus().catch(() => null);
    if (status?.fees?.windowOpen) return { skipped: 'JIG launch window is open' };
    const p = await plan(); st = readState();
    const done = [];
    for (const job of p.jobs) {
      const hoursFor = (k) => (k === 'trade' ? c.tradeHours : k === 'round' ? c.roundHours : k === 'airdrop' ? c.airdropHours : c.pullHours);
      const j = st.jobs[job.id] ?? (st.jobs[job.id] = { runsToday: 0, failures: 0, nextAt: Date.now() + randHours(hoursFor(job.kind)) });
      if (j.inflight) { done.push({ id: job.id, skipped: 'a previous send is still unresolved' }); continue; } // never send twice
      if (!job.ready) continue;
      const nowS = Math.floor(Date.now() / 1000);
      if (job.kind === 'round') {
        // the creator's cadence: one round at a random moment inside each window since launch
        const s = coinSettings.get(job.collection);
        const prev = j.round?.cadence === s.cadence ? j.round : null;
        const sch = coinSettings.roundSchedule(job.launchedAt, s.cadence, nowS, prev);
        j.round = { cadence: s.cadence, index: sch.index, at: sch.at, end: sch.end, doneIndex: prev?.doneIndex };
        if (sch.at === null) continue; // this window's round is done
        if (!force && nowS < sch.at) { writeState(st); continue; }
        if (s.minRoundUsd > 0 && (job.usd ?? 0) < s.minRoundUsd) { j.round.doneIndex = sch.index; j.lastResult = `window ${sch.index} skipped: round worth $${(job.usd ?? 0).toFixed(2)}, under the creator's $${s.minRoundUsd}`; writeState(st); continue; }
      } else if (job.kind === 'airdrop') {
        const s = coinSettings.get(job.collection);
        const key = `${s.airdrop.mode}:${s.airdrop.days ?? ''}`;
        if (!j.airdrop || j.airdrop.key !== key) j.airdrop = { key, ...coinSettings.airdropAt(job.launchedAt, s.airdrop) };
        let due = nowS >= j.airdrop.at;
        if (!due && j.airdrop.soldOutTrigger) { try { const { totalSupply, maxSupply } = await readSupply(a.chainId, job.collection); due = maxSupply > 0n && totalSupply >= maxSupply; } catch {} }
        if (!force && !due) { writeState(st); continue; }
      } else if (!force && Date.now() < (j.nextAt ?? 0)) continue;
      if ((j.runsToday ?? 0) >= c.maxPerJobPerDay) continue;
      if (st.txToday >= c.maxTxPerDay) { done.push({ id: job.id, skipped: 'daily transaction cap' }); break; }
      // simulate first: a revert costs nothing
      try { await pub.call({ account: account.address, to: job.to, data: job.data }); }
      catch (e) { j.failures = (j.failures ?? 0) + 1; j.nextAt = Date.now() + 30 * 60_000 * 2 ** Math.min(j.failures, 5); j.lastError = `simulation: ${e.shortMessage ?? e.message}`; writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
      if (job.record) payouts.saveRecord(job.record.path, job.record.rec); // the tree is on disk before its root goes on chain
      const nonce = await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
      j.inflight = { at: Date.now(), nonce }; j.runsToday = (j.runsToday ?? 0) + 1; st.txToday += 1; writeState(st); // marker before the send
      try {
        const hash = await wallet.sendTransaction({ to: job.to, data: job.data, nonce });
        j.inflight.tx = hash; writeState(st);
        const rc = await pub.waitForTransactionReceipt({ hash, timeout: 5 * 60_000 });
        const gas = formatEther(rc.gasUsed * rc.effectiveGasPrice);
        ledger(`keeper,${job.id},${a.chainId},${hash},${rc.status},gas ${gas} ETH,${job.quote ?? ''},min ${job.min ?? ''}`);
        j.inflight = null; j.lastRunAt = Date.now(); j.lastTx = hash; j.lastResult = rc.status;
        if (rc.status === 'success') { j.failures = 0; j.nextAt = Date.now() + randHours(hoursFor(job.kind)); if (job.kind === 'round' && j.round) j.round.doneIndex = j.round.index; if (job.record) payouts.saveRecord(job.record.path, { ...job.record.rec, [job.kind === 'airdrop' ? 'setTx' : 'declaredTx']: hash, onChainAt: new Date().toISOString() }); }
        else { j.failures = (j.failures ?? 0) + 1; j.nextAt = Date.now() + 30 * 60_000 * 2 ** Math.min(j.failures, 5); }
        done.push({ id: job.id, tx: hash, status: rc.status, gasEth: gas, quote: job.quote });
      } catch (e) {
        j.failures = (j.failures ?? 0) + 1; j.nextAt = Date.now() + 30 * 60_000 * 2 ** Math.min(j.failures, 5); j.lastError = e.shortMessage ?? e.message;
        done.push({ id: job.id, error: j.lastError });
      }
      writeState(st);
    }
    return { at: new Date().toISOString(), done };
  } finally { _busy = false; }
}

export function state() { return readState(); }
