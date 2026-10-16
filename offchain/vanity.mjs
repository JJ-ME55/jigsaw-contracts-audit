// The COLLECT ending for creator coins (Jj, 16 Oct): every coin's address ends in c011ec7.
//
// CoinFactory deploys a coin with CREATE2 and requires the salt's first 20 bytes to be the collection, so the grind
// needs the factory, the collection and the coin's init code hash (which depends on name and symbol; the factory
// reports it, so it is exactly what the contract will use). Foundry's `cast create2` does the search natively
// (~13M/s on 16 threads, measured 16 Oct; a 7-character ending is ~20 s there). One grind at a time; results cached
// on disk. Without cast on the machine the launch still works, just without the ending (state 'unavailable').
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createPublicClient, http, parseAbi, getAddress, isAddress } from 'viem';
import { CHAINS } from './launch.mjs';
import { DATA } from './store.mjs';
import { addresses } from './jig.mjs';

export const ENDING = (process.env.COIN_VANITY_ENDING ?? 'c011ec7').toLowerCase();
const FILE = () => path.join(DATA, 'vanity.json');
const read = () => { try { return JSON.parse(fs.readFileSync(FILE(), 'utf8')); } catch { return {}; } };
const write = (v) => { fs.mkdirSync(DATA, { recursive: true }); const t = FILE() + '.tmp'; fs.writeFileSync(t, JSON.stringify(v, null, 1)); fs.renameSync(t, FILE()); };
const factoryAbi = parseAbi(['function coinInitCodeHash(address collection, string name, string symbol) view returns (bytes32)', 'function predictCoin(address collection, string name, string symbol, bytes32 salt) view returns (address)']);

let _cast;
export function castBin() {
  if (_cast !== undefined) return _cast;
  for (const c of [process.env.CAST_BIN, 'cast', path.join(os.homedir(), '.foundry', 'bin', process.platform === 'win32' ? 'cast.exe' : 'cast')].filter(Boolean)) {
    try { if (spawnSync(c, ['--version'], { timeout: 10_000 }).status === 0) return (_cast = c); } catch {}
  }
  return (_cast = null);
}

const keyOf = (factory, collection, name, symbol) => `${getAddress(factory)}|${getAddress(collection)}|${name}|${symbol}|${ENDING}`;
const pub = () => { const a = addresses(); const c = CHAINS[a.chainId]; return createPublicClient({ chain: c.chain, transport: http(c.rpc) }); };

/** The plain salt every collection can use (no ending): the collection in the first 20 bytes, zeros after. */
export const plainSalt = (collection) => `${getAddress(collection).toLowerCase()}${'0'.repeat(24)}`;

let _running = null; const _queue = []; const MAX_QUEUE = Number(process.env.VANITY_MAX_QUEUE ?? 10);
/** State of the grind for these inputs; starts it if needed. { state: ready|grinding|queued|busy|unavailable|failed, salt?, coin? } */
export function request(collection, name, symbol) {
  const a = addresses(); if (!a.factory) throw new Error('COIN_FACTORY not set');
  if (!isAddress(collection)) throw new Error('collection address required');
  if (!name || !symbol) throw new Error('name and symbol are needed: they decide the coin address');
  const k = keyOf(a.factory, collection, name, symbol); const all = read();
  if (all[k]?.state === 'ready') return all[k];
  if (_running?.key === k) return { state: 'grinding', startedAt: _running.startedAt, ending: ENDING };
  if (_queue.some((q) => q.key === k)) return { state: 'queued', ending: ENDING };
  if (!castBin()) return { state: 'unavailable', reason: 'no grinder on this server (Foundry cast); the coin launches without the ending', ending: ENDING };
  if (all[k]?.state === 'failed' && Date.now() - all[k].at < 10 * 60_000) return all[k];
  // one queued grind per collection (a renamed coin replaces its older request) and a bounded queue, so a caller
  // cycling names cannot keep the grinder busy for everyone else (pre-audit review, 16 Oct)
  const col = getAddress(collection);
  const dup = _queue.findIndex((q) => q.collection === col); if (dup >= 0) _queue.splice(dup, 1);
  if (_queue.length >= MAX_QUEUE) return { state: 'busy', reason: `the grinder has ${_queue.length} coins waiting; try again in a few minutes, or launch without the ending`, ending: ENDING };
  _queue.push({ key: k, factory: a.factory, collection: col, name, symbol });
  pump();
  return { state: _running?.key === k ? 'grinding' : 'queued', ending: ENDING };
}

async function pump() {
  if (_running || !_queue.length) return;
  const job = _queue.shift(); _running = { key: job.key, startedAt: Date.now() };
  try {
    const hash = await pub().readContract({ address: job.factory, abi: factoryAbi, functionName: 'coinInitCodeHash', args: [job.collection, job.name, job.symbol] });
    const out = await new Promise((resolve, reject) => {
      const p = spawn(castBin(), ['create2', '--deployer', job.factory, '--caller', job.collection, '--init-code-hash', hash, '--ends-with', ENDING], { stdio: ['ignore', 'pipe', 'pipe'] });
      let buf = ''; p.stdout.on('data', (d) => (buf += d)); p.stderr.on('data', (d) => (buf += d));
      const t = setTimeout(() => { p.kill(); reject(new Error('grind timed out after 15 minutes')); }, 15 * 60_000);
      p.on('close', (code) => { clearTimeout(t); code === 0 ? resolve(buf) : reject(new Error(`cast exited ${code}: ${buf.slice(-200)}`)); });
    });
    const salt = /Salt:\s*(0x[0-9a-fA-F]{64}|\d+)/.exec(out)?.[1];
    if (!salt) throw new Error(`no salt in grinder output: ${out.slice(-200)}`);
    const salt32 = salt.startsWith('0x') ? salt : '0x' + BigInt(salt).toString(16).padStart(64, '0');
    // trust the contract, not the grinder: the factory's own prediction must end in the ending and keep the guard
    const coin = await pub().readContract({ address: job.factory, abi: factoryAbi, functionName: 'predictCoin', args: [job.collection, job.name, job.symbol, salt32] });
    if (!coin.toLowerCase().endsWith(ENDING)) throw new Error(`grinder salt gives ${coin}, not ...${ENDING}`);
    if (salt32.slice(2, 42).toLowerCase() !== job.collection.slice(2).toLowerCase()) throw new Error('grinder salt is not bound to the collection');
    const all = read(); all[job.key] = { state: 'ready', salt: salt32, coin, ending: ENDING, seconds: Math.round((Date.now() - _running.startedAt) / 1000), at: Date.now() }; write(all);
  } catch (e) {
    const all = read(); all[job.key] = { state: 'failed', error: e.message, at: Date.now() }; write(all);
  } finally { _running = null; pump(); }
}

/** For tests: the factory's own prediction for a salt. */
export const predict = (collection, name, symbol, salt) => pub().readContract({ address: addresses().factory, abi: factoryAbi, functionName: 'predictCoin', args: [getAddress(collection), name, symbol, salt] });
