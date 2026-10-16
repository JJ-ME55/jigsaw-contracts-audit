// Public randomness for reveals: drand quicknet (League of Entropy), 3-second rounds, unpredictable before each round
// is published. The seed for a reveal is the randomness of the first round AFTER the trigger, so nobody, including
// us, can know it while minting is open.
//
// Every round is verified here before it is used: the BLS signature (on G1, scheme bls-unchained-g1-rfc9380) is
// checked against quicknet's public key, which is pinned below, not fetched. Randomness = sha256(48-byte signature),
// drand's canonical rule (the same rule the on-chain verifier on Robinhood Chain, DrandRandomnessSource, uses).
// Mirrors are tried in turn: 404/425 means "not published yet" and is authoritative; 5xx or a network error moves on.
//
// SEED_SOURCE=manual with MANUAL_SEED exists for local tests only.
import { bls12_381 as bls } from '@noble/curves/bls12-381';
import { sha256 } from '@noble/hashes/sha256';

export const QUICKNET = {
  chainHash: '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971',
  publicKey: '83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a',
  genesis: 1_692_803_367,
  period: 3,
  dst: 'BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_', // exact, 43 bytes, no beacon id
};
const MIRRORS = (process.env.DRAND_URLS ?? 'https://api.drand.sh,https://api2.drand.sh,https://api3.drand.sh').split(',').map((u) => `${u.trim().replace(/\/$/, '')}/v2/beacons/quicknet`);

/** The first round whose publish time is strictly after `unixSeconds`. Round r publishes at genesis + (r-1)*period. */
export function roundAfter(unixSeconds) {
  return Math.floor((unixSeconds - QUICKNET.genesis) / QUICKNET.period) + 2;
}

/** true when `signatureHex` is quicknet's signature for `round`. */
export function verifyRound(round, signatureHex) {
  try {
    const be = new Uint8Array(8); new DataView(be.buffer).setBigUint64(0, BigInt(round));
    const point = bls.G1.hashToCurve(sha256(be), { DST: QUICKNET.dst });
    return bls.verifyShortSignature(signatureHex, point, QUICKNET.publicKey);
  } catch { return false; }
}

export const randomnessOf = (signatureHex) => '0x' + Buffer.from(sha256(Buffer.from(signatureHex, 'hex'))).toString('hex');

/** { round, randomness, signature, source } verified, or null if the round is not published yet. Throws if every mirror fails or a signature does not verify. */
export async function fetchRound(round) {
  const errors = [];
  for (const base of MIRRORS) {
    let r;
    try { r = await fetch(`${base}/rounds/${round}`, { signal: AbortSignal.timeout(10_000) }); }
    catch (e) { errors.push(`${base}: ${e.message}`); continue; }
    if (r.status === 404 || r.status === 425) return null; // authoritative: the round is in the future
    if (!r.ok) { errors.push(`${base}: ${r.status}`); continue; }
    const j = await r.json().catch(() => ({}));
    if (!j.signature) { errors.push(`${base}: no signature`); continue; }
    if (Number(j.round ?? round) !== Number(round)) { errors.push(`${base}: answered round ${j.round}`); continue; }
    if (!verifyRound(round, j.signature)) throw new Error(`drand round ${round} from ${base} has a signature that does not verify against quicknet's key`);
    return { round: Number(round), randomness: randomnessOf(j.signature), signature: j.signature, source: base };
  }
  throw new Error(`drand round ${round}: every mirror failed (${errors.join('; ')})`);
}

/** Seed for a reveal triggered at `triggeredAt` (unix seconds). null until the round is out (a few seconds). */
export async function seedFor(triggeredAt) {
  if ((process.env.SEED_SOURCE ?? 'drand') === 'manual') {
    const s = process.env.MANUAL_SEED; if (!/^0x[0-9a-fA-F]{64}$/.test(s ?? '')) throw new Error('SEED_SOURCE=manual needs MANUAL_SEED (0x + 32 bytes)');
    return { source: 'manual', round: 0, seed: s, verify: 'none' };
  }
  const round = roundAfter(triggeredAt);
  const got = await fetchRound(round);
  if (!got) return null;
  return { source: 'drand:quicknet', chainHash: QUICKNET.chainHash, round, seed: got.randomness, signature: got.signature, verified: 'bls12-381 G1 signature checked against the pinned quicknet key', verify: `https://api.drand.sh/v2/beacons/quicknet/rounds/${round}` };
}
