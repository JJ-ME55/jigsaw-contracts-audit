// The keeper: the on-chain housekeeping nobody else will do, at random times, with a minimum out on every trade.
//
// Jobs (discovered from the chain each pass):
//   deepening        LPDeepening.run(minEthOut): sells half its JIG for ETH, adds both as locked JIG/ETH liquidity
//   buyback:<coin>   BuybackAndBurn.run(minCoinOut): buys the coin with the module's whole JIG, burns it
//   drip:<coin>      HolderDrip.pull(): moves the NFT holders' slice in and spreads it (every 4 to 8 hours; a token
//                    minted since the previous pull earns from the next one, swarm audit 6)
//   forward:<coin>   SnapshotForwarder.pull(): moves the coin holders' slice to HolderPayouts for the next round
//   pot              CreatorFeeHook.claimFor(pot): pushes the pot's JIG into PotVault (it cannot claim itself)
//   jigfees          JIGLaunch.collectFees(): the JIG pool's LP fees, half team, half pot
// Trades (deepening, buyback) run at a random time 2 to 10 hours after the last run, the whole balance at once
// (Jj, 15 Oct). Pulls and collects run every 4 to 8 hours. Nothing runs inside the JIG launch window (the hook
// charges the modules 60% and refuses the deepening's liquidity).
//
// Rule 4: a marker is written before every send, and the signed transaction's hash before it is broadcast (sender.mjs,
// shared with launches and reveals so nonces never collide); a pass never overlaps another; each job has a daily cap
// and backs off on failure; routine jobs share a daily transaction cap (airdrops have their own: they cannot wait);
// one coin's failure never stops the others; nothing runs while the JIG window status is unknown. Every send is ledgered.
// Serves only coins on collections our NFT factory made (CoinFactory is open to any collection creator), with every
// send's gas capped (KEEPER_GAS_CAP) and trade minimums quoted right before the send.
// Off unless KEEPER_ENABLED=1. Mainnets refused unless ALLOW_MAINNET=1.
import fs from 'node:fs';
import path from 'node:path';
import { createPublicClient, http, parseAbi, getAddress, formatEther, encodeFunctionData } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { CHAINS } from './launch.mjs';
import { DATA, ledger } from './store.mjs';
import { addresses, status as jigStatus, jigPrice } from './jig.mjs';
import { poolIdOf } from './v4state.mjs';
import { jigPoolKey, quoteGross } from './swap.mjs';
import * as payouts from './payouts.mjs';
import { ethPrice } from './builds.mjs';
import * as coinSettings from './coinSettings.mjs';
import { readSupply, isOurCollection } from './launch.mjs';
import { send as sendTx } from './sender.mjs';

const MAINNETS = new Set([1, 4663]);
const FILE = () => path.join(DATA, 'keeper.json');
const ZERO = '0x0000000000000000000000000000000000000000';
const env = (k, d) => (process.env[k] === undefined ? d : Number(process.env[k]));
const cfg = () => ({
  slippageBps: env('KEEPER_SLIPPAGE_BPS', 300),
  minUsd: env('KEEPER_MIN_USD', 5),                 // skip a job whose JIG is worth less than this (gas would eat it)
  maxTxPerDay: env('KEEPER_MAX_TX_PER_DAY', 24),   // the fixed jobs; each serviced coin adds txPerCoin (a flat cap starved newer coins, replica review)
  txPerCoin: env('KEEPER_TX_PER_COIN', 6),
  gasCap: BigInt(env('KEEPER_GAS_CAP', 3_000_000)),   // no keeper send may use more gas than this, whatever a module does
  maxPerJobPerDay: env('KEEPER_MAX_PER_JOB_PER_DAY', 3),
  tradeHours: [env('KEEPER_TRADE_MIN_H', 2), env('KEEPER_TRADE_MAX_H', 10)],
  pullHours: [env('KEEPER_PULL_MIN_H', 4), env('KEEPER_PULL_MAX_H', 8)],
  roundHours: [env('KEEPER_ROUND_MIN_H', 24), env('KEEPER_ROUND_MAX_H', 168)],   // coin-holder snapshot rounds: a random moment 1 to 7 days apart
  airdropHours: [env('KEEPER_AIRDROP_MIN_H', 24), env('KEEPER_AIRDROP_MAX_H', 72)], // only the retry spacing after an airdrop send; its timing comes from coinSettings.airdropAt
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
  return { a, account, pub: createPublicClient({ chain: c.chain, transport: http(c.rpc) }) };
}
/** What kind of module sits at `addr`. Only definite answers are cached (modules are immutable); an RPC error leaves it
 *  unknown for this pass instead of mislabelling the module for good (pre-audit review, 16 Oct). */
async function kindOf(pub, addr, st) {
  if (addr === ZERO) return 'wallet';
  if (st.kinds[addr]) return st.kinds[addr];
  let code; try { code = await pub.getCode({ address: addr }); } catch { return 'unknown'; }
  if (!code || code === '0x') return (st.kinds[addr] = 'wallet');
  // true = the function answered, false = the contract has no such function (reverted), null = could not tell (RPC)
  const has = async (fn) => {
    try { await pub.readContract({ address: addr, abi: probeAbi, functionName: fn }); return true; }
    catch (e) { const t = `${e?.name} ${e?.cause?.name} ${e?.shortMessage} ${e?.message}`; return /Revert|ZeroData|returned no data|execution reverted/i.test(t) ? false : null; }
  };
  const probes = {}; for (const fn of ['sweeper', 'payouts', 'undistributed', 'burned', 'keeper']) probes[fn] = await has(fn);
  if (Object.values(probes).some((v) => v === null)) return 'unknown';
  const kind = probes.sweeper ? 'sweep' : probes.payouts ? 'forward' : probes.undistributed ? 'drip' : probes.burned && probes.keeper ? 'buyback' : 'unknown';
  if (kind !== 'unknown') st.kinds[addr] = kind;
  return kind;
}

// airdrops first (their 7-day window cannot wait), then settlements, then rounds, then routine pulls and trades
const PRIORITY = { airdrop: 0, settle: 1, round: 2 };
const priorityOf = (job) => PRIORITY[job.kind] ?? (job.id.startsWith('settle:') ? 1 : 3);

/** Every job the chain currently implies. Reads only. Round and airdrop snapshots are NOT taken here: tick() takes them
 *  through job.prepare() only when the job is due, so a plan is cheap and GET /admin/keeper never scans a collection. */
export async function plan() {
  const { a, account, pub } = clients(); const st = readState(); const c = cfg();
  const jobs = [];
  const jp = await jigPrice().catch(() => null); const usd = (jig) => (jp?.jigUsd ? (Number(jig) / 1e18) * jp.jigUsd : null);
  const worth = (jig) => { if (jig <= 0n) return false; const u = usd(jig); return u === null || u >= c.minUsd; }; // never a zero pull, whatever the threshold
  const claim = (who) => pub.readContract({ address: a.feeHook, abi: hookAbi, functionName: 'claimable', args: [who] });
  const bal = (who) => pub.readContract({ address: a.jig, abi: erc20, functionName: 'balanceOf', args: [who] });
  // one failing read never stops the other jobs (pre-audit review, 16 Oct)
  const guard = async (id, fn) => { try { await fn(); } catch (e) { jobs.push({ id, kind: 'error', ready: false, why: `read failed: ${e.shortMessage ?? e.message}` }); } };

  if (a.deepening) await guard('deepening', async () => {
    const amount = (await bal(a.deepening)) + (await claim(a.deepening));
    const keeper = await pub.readContract({ address: a.deepening, abi: probeAbi, functionName: 'keeper' }).catch(() => null);
    const job = { id: 'deepening', kind: 'trade', to: a.deepening, amountJig: amount.toString(), usd: usd(amount), ready: worth(amount) && keeper && getAddress(keeper) === account.address, why: !keeper || getAddress(keeper) !== account.address ? `keeper is ${keeper}, not this wallet` : worth(amount) ? '' : `JIG worth under $${c.minUsd}` };
    // the minimum out is quoted right before the send (tick), never minutes earlier
    job.requote = async () => {
      const amt = (await bal(a.deepening)) + (await claim(a.deepening)); const half = amt / 2n;
      const ethOut = await quoteGross({ from: a.jig, to: ZERO, hops: [{ key: jigPoolKey(a), zeroForOne: false }] }, half);
      const min = (ethOut * BigInt(10_000 - c.slippageBps)) / 10_000n;
      return { min: min.toString(), quote: `${formatEther(half)} JIG -> ${formatEther(ethOut)} ETH`, data: encodeFunctionData({ abi: moduleAbi, functionName: 'run', args: [min] }) };
    };
    jobs.push(job);
    const tokenId = await pub.readContract({ address: a.deepening, abi: moduleAbi, functionName: 'tokenId' }).catch(() => 0n);
    if (tokenId > 0n) jobs.push({ id: 'deepfees', kind: 'pull', to: a.deepening, ready: true, data: encodeFunctionData({ abi: moduleAbi, functionName: 'collectFees' }) });
  });
  // the creator-coin launch fee follows LAUNCH_FEE_USD (default $149) in ETH; re-priced only on a drift above LAUNCH_FEE_DRIFT_BPS.
  // Where the platform is the Safe (Robinhood) the job only reports the number for a Safe transaction.
  if (a.factory) await guard('launchfee', async () => {
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
      jobs.push({ id: 'launchfee', kind: 'pull', to: a.factory, ready: !!mine && off > BigInt(drift), why: !mine ? `platform is ${plat}: the Safe sends setLaunchFee(${target}) when off by more than ${drift} bps (now ${off})` : off > BigInt(drift) ? '' : `within ${drift} bps`, quote: `${formatEther(cur)} -> ${formatEther(target)} ETH ($${usdTarget} at $${eth})`, data: encodeFunctionData({ abi: factoryAbi, functionName: 'setLaunchFee', args: [target] }) });
    }
  });
  if (a.launch) jobs.push({ id: 'jigfees', kind: 'pull', to: a.launch, ready: true, data: encodeFunctionData({ abi: moduleAbi, functionName: 'collectFees' }) });
  if (a.pot) await guard('pot', async () => { const owed = await claim(a.pot); jobs.push({ id: 'pot', kind: 'pull', to: a.feeHook, amountJig: owed.toString(), usd: usd(owed), ready: worth(owed), why: worth(owed) ? '' : `JIG worth under $${c.minUsd}`, data: encodeFunctionData({ abi: hookAbi, functionName: 'claimFor', args: [a.pot] }) }); });

  let n = 0; let coins = 0;
  await guard('coins', async () => { n = Number(await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'count' })); });
  for (let i = 0; i < n; i++) {
    await guard(`coin#${i}`, async () => {
      const L = await pub.readContract({ address: a.factory, abi: factoryAbi, functionName: 'launches', args: [BigInt(i)] });
      const [coin, collection, , , key] = L;
      const cfgP = await pub.readContract({ address: a.feeHook, abi: hookAbi, functionName: 'pools', args: [poolIdOf(key)] });
      const fly = cfgP[2]; const launchedAt = Number(cfgP[8]);
      // only coins on collections our NFT factory made: anyone can launch a coin for a contract that names them creator,
      // and a hostile one (huge totalSupply, endless owners, a gas-burning module) would stall the keeper (replica review)
      if (!(await isOurCollection(a.chainId, collection))) { jobs.push({ id: `coin:${coin}`, kind: 'skip', ready: false, why: `collection ${collection} was not made by our NFT factory: not serviced` }); return; }
      coins += 1;
      // the 5% airdrop to the collection's NFT holders, for every coin: the snapshot waits until it is due (tick)
      if (a.airdrop) await guard(`airdrop:${coin}`, async () => {
        const pend = await payouts.airdropPending(coin);
        if (pend.needed) jobs.push({ id: `airdrop:${coin}`, kind: 'airdrop', ready: true, lazy: true, collection, launchedAt, receivedAt: pend.receivedAt, prepare: () => payouts.prepareAirdrop(coin, collection) });
      });
      const kind = await kindOf(pub, fly, st);
      // coin-holder rounds and their settlement, for coins whose flywheel feeds HolderPayouts
      if (kind === 'forward' && a.payouts) await guard(`round:${coin}`, async () => {
        for (const s of await payouts.expiredRounds(coin)) jobs.push({ id: `settle:${coin}:${s.round}`, kind: 'pull', to: s.call.address, ready: true, data: encodeFunctionData(s.call) });
        const balance = await payouts.payoutBalance(coin);
        if (balance > 0n) jobs.push({ id: `round:${coin}`, kind: 'round', ready: true, lazy: true, collection, launchedAt, amountJig: balance.toString(), usd: usd(balance), prepare: () => payouts.prepareRound(coin, cfgP[8]) });
      });
      if (kind === 'unknown') { jobs.push({ id: `flywheel:${coin}`, kind: 'error', ready: false, why: `could not identify the flywheel module ${fly} this pass` }); return; }
      if (kind === 'wallet' || kind === 'sweep') return; // sweeps need a listing: the sweeper runs them by hand
      const owed = await claim(fly); const held = await bal(fly); const total = owed + held;
      if (kind === 'buyback') {
        const keeper = await pub.readContract({ address: fly, abi: probeAbi, functionName: 'keeper' });
        const job = { id: `buyback:${coin}`, kind: 'trade', to: fly, amountJig: total.toString(), usd: usd(total), ready: worth(total) && getAddress(keeper) === account.address, why: getAddress(keeper) !== account.address ? `keeper is ${keeper}` : worth(total) ? '' : `JIG worth under $${c.minUsd}` };
        job.requote = async () => {
          const amt = (await claim(fly)) + (await bal(fly));
          const coinOut = await quoteGross({ from: a.jig, to: coin, hops: [{ key, zeroForOne: getAddress(key.currency0) === getAddress(a.jig) }] }, amt);
          const min = (coinOut * BigInt(10_000 - c.slippageBps)) / 10_000n;
          return { min: min.toString(), quote: `${formatEther(amt)} JIG -> ${formatEther(coinOut)} coin`, data: encodeFunctionData({ abi: moduleAbi, functionName: 'run', args: [min] }) };
        };
        jobs.push(job);
      } else {
        // trusted reads only (the hook's claimable and the JIG balance): a module's own undistributed() could report value
        // that is not there and have the keeper pay gas for nothing (replica review)
        const amount = kind === 'drip' ? owed + held : owed;
        jobs.push({ id: `${kind}:${coin}`, kind: 'pull', to: fly, amountJig: amount.toString(), usd: usd(amount), ready: worth(amount), why: worth(amount) ? '' : `JIG worth under $${c.minUsd}`, data: encodeFunctionData({ abi: moduleAbi, functionName: 'pull' }) });
      }
    });
  }
  writeState({ ...readState(), kinds: st.kinds });
  jobs.sort((x, y) => priorityOf(x) - priorityOf(y));
  return { chainId: a.chainId, keeper: account.address, jigUsd: jp?.jigUsd ?? null, coins, jobs };
}

const hoursFor = (c, k) => (k === 'trade' ? c.tradeHours : k === 'round' ? c.roundHours : k === 'airdrop' ? c.airdropHours : c.pullHours);
const backoff = (j) => { j.failures = (j.failures ?? 0) + 1; j.nextAt = Date.now() + 30 * 60_000 * 2 ** Math.min(j.failures, 5); };

/** What a confirmed send changes in our records. Used by the normal path and by recovery after a restart. */
async function onSuccess(j, info, hash, c) {
  j.failures = 0; j.lastTx = hash; j.lastResult = 'success'; j.lastRunAt = Date.now(); j.lastError = null;
  j.nextAt = Date.now() + randHours(hoursFor(c, info.kind));
  if (info.kind === 'round' && j.round) { j.round.doneIndex = info.roundIndex ?? j.round.index; j.round.lastAt = Math.floor(Date.now() / 1000); }
  // the record was written to disk before the send; the marker carries only its path (a tree can be large)
  const rec = info.recordPath ? (() => { try { return JSON.parse(fs.readFileSync(info.recordPath, 'utf8')); } catch { return null; } })() : null;
  if (rec) {
    const final = { ...rec, [info.kind === 'airdrop' ? 'setTx' : 'declaredTx']: hash, onChainAt: new Date().toISOString() };
    if (info.kind === 'round') {
      // the root on chain must be the tree we serve, or every proof fails: say so loudly
      const onChain = await payouts.roundRoot(rec.coin, rec.round).catch(() => null);
      final.rootCheck = onChain === null ? 'unread' : onChain.toLowerCase() === String(rec.root).toLowerCase() ? 'match' : `MISMATCH (chain ${onChain})`;
      if (final.rootCheck.startsWith('MISMATCH')) j.lastError = `round ${rec.round} root on chain differs from the stored tree`;
    }
    payouts.saveRecord(info.recordPath, final);
  }
}

let _busy = false;
/** One pass: run every job that is ready and due. Returns what it did. */
export async function tick({ force = false } = {}) {
  if (process.env.KEEPER_ENABLED !== '1' && !force) return { skipped: 'KEEPER_ENABLED is not 1' };
  if (_busy) return { skipped: 'a pass is already running' };
  _busy = true;
  try {
    const { a, account, pub } = clients();
    if (MAINNETS.has(a.chainId) && process.env.ALLOW_MAINNET !== '1') return { skipped: 'mainnet is disabled on this server' };
    let st = readState(); const c = cfg();
    if (st.day !== today()) { st.day = today(); st.txToday = 0; st.airdropsToday = 0; for (const j of Object.values(st.jobs)) j.runsToday = 0; }

    // A send interrupted by a restart: its hash was saved before broadcast. Resolve it from the chain; never guess.
    for (const j of Object.values(st.jobs)) {
      if (!j.inflight) continue;
      const f = j.inflight;
      if (!f.tx) { if (Date.now() - f.at > 5 * 60_000) { j.lastResult = 'never signed'; j.inflight = null; } continue; }
      const rc = await pub.getTransactionReceipt({ hash: f.tx }).catch(() => null);
      if (rc) { if (rc.status === 'success') await onSuccess(j, f, f.tx, c); else { j.lastResult = 'reverted'; j.lastTx = f.tx; backoff(j); } j.inflight = null; continue; }
      const mined = await pub.getTransactionCount({ address: account.address, blockTag: 'latest' });
      if (mined > f.nonce) {
        // the nonce is used; if our hash still has no receipt, another transaction took it
        const again = await pub.getTransactionReceipt({ hash: f.tx }).catch(() => null);
        if (again) { if (again.status === 'success') await onSuccess(j, f, f.tx, c); else { j.lastResult = 'reverted'; backoff(j); } }
        else {
          // a lagging node can miss a receipt that exists: only conclude 'replaced' after a few passes (replica review)
          f.missed = (f.missed ?? 0) + 1; if (f.missed < 3) continue;
          j.lastResult = 'replaced (its nonce was used by another transaction)'; backoff(j);
        }
        j.inflight = null; continue;
      }
      const tx = await pub.getTransaction({ hash: f.tx }).catch(() => null);
      if (tx || Date.now() - f.at < 30 * 60_000) continue; // still in the mempool, or too early to tell: wait, never resend
      j.lastResult = 'never broadcast (signed, not sent; nonce unused)'; backoff(j); j.inflight = null;
    }
    writeState(st);

    // fail closed: if the JIG window status cannot be read, do nothing this pass (inside the window the hook charges modules 60%)
    let status;
    try { status = await jigStatus(); } catch (e) { return { skipped: `JIG status unknown (${e.shortMessage ?? e.message}); not running` }; }
    if (status?.fees?.windowOpen) return { skipped: 'JIG launch window is open' };
    const p = await plan(); st = readState();
    const done = [];
    for (const job of p.jobs) {
      if (job.kind === 'error' || job.kind === 'skip') { done.push({ id: job.id, skipped: job.why }); continue; }
      if (!job.ready) continue;
      const j = st.jobs[job.id] ?? (st.jobs[job.id] = { runsToday: 0, failures: 0, nextAt: Date.now() + randHours(hoursFor(c, job.kind)) });
      if (j.inflight) { done.push({ id: job.id, skipped: 'a previous send is still unresolved' }); continue; } // never send twice
      if (!force && (j.failures ?? 0) > 0 && Date.now() < (j.nextAt ?? 0)) continue; // a failing job backs off, whatever its kind
      const nowS = Math.floor(Date.now() / 1000);
      if (job.kind === 'round') {
        // the creator's cadence: one round at a random moment inside each window since launch
        const s = coinSettings.get(job.collection);
        const prev = j.round?.cadence === s.cadence ? j.round : null;
        const sch = coinSettings.roundSchedule(job.launchedAt, s.cadence, nowS, prev);
        j.round = { cadence: s.cadence, index: sch.index, at: sch.at, end: sch.end, doneIndex: prev?.doneIndex, lastAt: j.round?.lastAt };
        if (sch.at === null) continue; // this window's round is done
        // a cadence change must not squeeze in an extra round: at least half the new period since the last one
        if (!force && j.round.lastAt && nowS - j.round.lastAt < coinSettings.CADENCES[s.cadence] / 2) { writeState(st); continue; }
        if (!force && nowS < sch.at) { writeState(st); continue; }
        // an unknown price is not $0: wait for the next pass instead of skipping the creator's whole window (replica review)
        if (s.minRoundUsd > 0 && (job.usd === null || job.usd === undefined)) { j.lastResult = 'JIG price unknown; the round waits for the next pass'; writeState(st); continue; }
        if (s.minRoundUsd > 0 && job.usd < s.minRoundUsd) { j.round.doneIndex = sch.index; j.lastResult = `window ${sch.index} skipped: round worth $${(job.usd ?? 0).toFixed(2)}, under the creator's $${s.minRoundUsd}`; writeState(st); continue; }
      } else if (job.kind === 'airdrop') {
        const s = coinSettings.get(job.collection);
        const key = `${s.airdrop.mode}:${s.airdrop.days ?? ''}`;
        if (!j.airdrop || j.airdrop.key !== key) j.airdrop = { key, ...coinSettings.airdropAt(job.launchedAt, s.airdrop) };
        // due at the creator's moment, on sell-out if chosen, and always before the claim's 7-day unset window closes
        let due = nowS >= j.airdrop.at || (job.receivedAt && nowS >= job.receivedAt + payouts.WINDOW_S - 12 * 3600);
        if (!due && j.airdrop.soldOutTrigger) { try { const { totalSupply, maxSupply } = await readSupply(a.chainId, job.collection); due = maxSupply > 0n && totalSupply >= maxSupply; } catch {} }
        if (!force && !due) { writeState(st); continue; }
      } else if (!force && Date.now() < (j.nextAt ?? 0)) continue;
      if ((j.runsToday ?? 0) >= c.maxPerJobPerDay) continue;
      // airdrops have their own daily allowance (they cannot wait behind routine pulls); everything else shares the cap
      if (job.kind === 'airdrop') { if ((st.airdropsToday ?? 0) >= env('KEEPER_MAX_AIRDROPS_PER_DAY', 20)) continue; }
      else if (st.txToday >= c.maxTxPerDay + c.txPerCoin * (p.coins ?? 0)) { done.push({ id: job.id, skipped: 'daily transaction cap' }); continue; }

      // the snapshot for a round or an airdrop is taken now, only when due
      let to = job.to, data = job.data, record = null;
      if (job.lazy) {
        let prep;
        try { prep = await job.prepare(); } catch (e) { backoff(j); j.lastError = `snapshot: ${e.message}`; writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
        if (!prep?.call) { j.lastResult = `nothing to ${job.kind === "round" ? "declare" : "set"} (empty, or already on chain)`; writeState(st); continue; }
        if (payouts.recordIsFinal(prep.path)) { j.lastError = `record ${prep.path} is already on chain; not overwriting`; backoff(j); writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
        to = prep.call.address; data = encodeFunctionData(prep.call); record = prep;
        job.quote = job.kind === 'round' ? `round ${prep.rec.round}: ${prep.rec.count} holders` : `${prep.rec.count} holders, ${prep.rec.nfts} NFTs`;
      }
      if (job.requote) {
        try { const q = await job.requote(); data = q.data; job.min = q.min; job.quote = q.quote; }
        catch (e) { backoff(j); j.lastError = `quote: ${e.shortMessage ?? e.message}`; writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
      }
      // simulate first (a revert costs nothing) and bound the gas: no module can make a keeper send expensive
      let gasLimit;
      try { await pub.call({ account: account.address, to, data }); gasLimit = await pub.estimateGas({ account: account.address, to, data }); }
      catch (e) { backoff(j); j.lastError = `simulation: ${e.shortMessage ?? e.message}`; writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
      gasLimit = (gasLimit * 13n) / 10n;
      if (gasLimit > c.gasCap) { backoff(j); j.lastError = `needs ${gasLimit} gas, over the ${c.gasCap} cap`; writeState(st); done.push({ id: job.id, error: j.lastError }); continue; }
      if (record) payouts.saveRecord(record.path, record.rec); // the tree is on disk before its root goes on chain
      const info = { kind: job.kind, roundIndex: j.round?.index, recordPath: record?.path };
      j.inflight = { at: Date.now(), ...info }; j.runsToday = (j.runsToday ?? 0) + 1;
      if (job.kind === 'airdrop') st.airdropsToday = (st.airdropsToday ?? 0) + 1; else st.txToday += 1;
      writeState(st); // marker before signing
      try {
        const { hash, receipt: rc } = await sendTx(a.chainId, { to, data, gas: gasLimit }, {
          allowRevert: true, timeoutMs: 5 * 60_000,
          onHash: (h, nonce) => { j.inflight.tx = h; j.inflight.nonce = nonce; writeState(st); }, // hash on disk before broadcast
        });
        const gas = formatEther(rc.gasUsed * rc.effectiveGasPrice);
        ledger(`keeper,${job.id},${a.chainId},${hash},${rc.status},gas ${gas} ETH,${job.quote ?? ''},min ${job.min ?? ''}`);
        if (rc.status === 'success') await onSuccess(j, info, hash, c); else { j.lastResult = 'reverted'; j.lastTx = hash; backoff(j); }
        j.inflight = null;
        done.push({ id: job.id, tx: hash, status: rc.status, gasEth: gas, quote: job.quote });
      } catch (e) {
        // broadcast but no receipt yet (timeout): the marker keeps its hash and the next pass resolves it from the chain
        if (!j.inflight?.tx) j.inflight = null;
        backoff(j); j.lastError = e.shortMessage ?? e.message;
        done.push({ id: job.id, error: j.lastError });
      }
      writeState(st);
    }
    return { at: new Date().toISOString(), done };
  } finally { _busy = false; }
}

export function state() { return readState(); }
