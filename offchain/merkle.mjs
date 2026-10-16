// OpenZeppelin-compatible Merkle trees (double-hashed leaves, sorted pairs, odd node carried up), the shape every
// claim contract here verifies with MerkleProof: JIGLaunchHook (address leaves), HolderPayouts and AirdropClaim
// (address + amount leaves: keccak256(bytes.concat(keccak256(abi.encode(account, amount))))).
import { keccak256, encodeAbiParameters, concat, getAddress } from 'viem';

export const pair = (a, b) => (a.toLowerCase() < b.toLowerCase() ? keccak256(concat([a, b])) : keccak256(concat([b, a])));
export const amountLeaf = (account, amount) => keccak256(keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [getAddress(account), BigInt(amount)])));

/** Tree over leaves (hex). Returns { root, layers }. */
export function tree(leaves) {
  const sorted = [...new Set(leaves)].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
  if (!sorted.length) return { root: null, layers: [] };
  const layers = [sorted];
  while (layers[layers.length - 1].length > 1) {
    const prev = layers[layers.length - 1]; const next = [];
    for (let i = 0; i < prev.length; i += 2) next.push(i + 1 < prev.length ? pair(prev[i], prev[i + 1]) : prev[i]);
    layers.push(next);
  }
  return { root: layers[layers.length - 1][0], layers };
}

export function proof(layers, leaf) {
  if (!layers.length) return null;
  let idx = layers[0].indexOf(leaf); if (idx < 0) return null;
  const out = [];
  for (let l = 0; l < layers.length - 1; l++) { const sib = idx ^ 1; if (sib < layers[l].length) out.push(layers[l][sib]); idx = Math.floor(idx / 2); }
  return out;
}

export const verify = (root, leaf, prf) => prf.reduce((h, p) => pair(h, p), leaf) === root;

/** { account: amount } -> { root, claims: { account: { amount, proof } } } ready to store and serve. */
export function amountTree(allocations) {
  const entries = Object.entries(allocations).filter(([, v]) => BigInt(v) > 0n).map(([k, v]) => [getAddress(k), BigInt(v)]);
  const leaves = entries.map(([k, v]) => amountLeaf(k, v));
  const { root, layers } = tree(leaves);
  const claims = {};
  for (const [k, v] of entries) claims[k] = { amount: v.toString(), proof: proof(layers, amountLeaf(k, v)) };
  return { root, total: entries.reduce((s, [, v]) => s + v, 0n).toString(), count: entries.length, claims };
}
