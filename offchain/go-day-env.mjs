// Go day: point the Render server at Robinhood using the addresses from contracts/script/go-day.sh.
//   node scripts/go-day-env.mjs ../contracts/go-day/predicted.json            dry run: prints what would change
//   node scripts/go-day-env.mjs ../contracts/go-day/predicted.json --apply    sets them, keeper off (MAINNET-PLAN step 3)
//   node scripts/go-day-env.mjs ../contracts/go-day/live.json --apply --keeper --go
//       after the live run with every role OK: keeper on; --go also sets ALLOW_MAINNET=1 (both founders, in writing)
// Then redeploy (bash scripts/rule5-check.sh first). Uses RENDER_API_KEY from .env; never prints it.
import fs from 'node:fs';
import path from 'node:path';
import { isAddress } from 'viem';

const env = Object.fromEntries(fs.readFileSync(path.join(import.meta.dirname, '..', '.env'), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]));
const [file, ...flags] = process.argv.slice(2);
if (!file) { console.error('usage: node scripts/go-day-env.mjs <go-day json> [--apply] [--keeper] [--go]'); process.exit(1); }
const j = JSON.parse(fs.readFileSync(path.resolve(file), 'utf8'));
const apply = flags.includes('--apply'), keeper = flags.includes('--keeper'), go = flags.includes('--go');
if (keeper && j.mode !== 'live') throw new Error('the keeper is switched on only from live.json');
if (go && j.mode !== 'live') throw new Error('ALLOW_MAINNET=1 only from live.json');

const keys = ['JIG_TOKEN', 'JIG_POT', 'JIG_LAUNCH', 'JIG_LAUNCH_HOOK', 'COIN_FACTORY', 'CREATOR_FEE_HOOK', 'AIRDROP_CLAIM', 'LP_DEEPENING', 'RH_FACTORY', 'RH_LAUNCHER', 'RH_PHASED_FACTORY'];
for (const k of [...keys, 'SAFE']) if (!isAddress(j[k] ?? '', { strict: false })) throw new Error(`${k} missing or not an address in ${file}`);
const set = { JIG_CHAIN_ID: '4663', ...Object.fromEntries(keys.map((k) => [k, j[k]])), PLATFORM_ADDRESS: j.SAFE, KEEPER_ENABLED: keeper ? '1' : '0', MOCK_SWARM: '0', ...(go ? { ALLOW_MAINNET: '1' } : {}) };
const remove = ['LAUNCH_FEE_USD', 'AIRDROP_PUSH_GATE', 'HOLDER_PAYOUTS'];   // no coin launch fee; pay-as-earned push; retired

for (const [k, v] of Object.entries(set)) console.log(`set    ${k}=${v}`);
for (const k of remove) console.log(`remove ${k}`);
if (!env.IPFS_GATEWAY?.includes('mypinata.cloud')) console.log('WARNING: IPFS_GATEWAY in .env is not the dedicated gateway; check it on Render');
if (!apply) { console.log('\ndry run: nothing sent (add --apply)'); process.exit(0); }

const KEY = env.RENDER_API_KEY; if (!KEY) throw new Error('RENDER_API_KEY not in .env');
const SVC = 'srv-db78c9ad0e5s73fkl8s0';
const api = (method, k, body) => fetch(`https://api.render.com/v1/services/${SVC}/env-vars/${k}`, { method, headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
for (const [k, v] of Object.entries(set)) { const r = await api('PUT', k, { value: v }); console.log(`${r.ok ? 'ok  ' : 'FAIL'} ${k} (${r.status})`); if (!r.ok) process.exitCode = 1; }
for (const k of remove) { const r = await api('DELETE', k); console.log(`${r.ok || r.status === 404 ? 'ok  ' : 'FAIL'} remove ${k} (${r.status})`); }
console.log('\nnow: bash scripts/rule5-check.sh, then redeploy the service');
