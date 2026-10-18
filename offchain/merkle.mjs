// Merkle allowlists in the OpenZeppelin shape, shared by JIG's launch allowlist and the collections' phase lists:
// leaf = keccak256(bytes.concat(keccak256(abi.encode(address)))), pairs hashed in sorted order (MerkleProof), odd node
// carried up. JIGLaunchHook.isAllowlisted and JigsawCollection.mint verify exactly this.
import { keccak256, encodeAbiParameters, concat, getAddress, isAddress } from 'viem';

export const leafOf = (address) => keccak256(keccak256(encodeAbiParameters([{ type: 'address' }], [getAddress(address)])));
export const pair = (a, b) => (a.toLowerCase() < b.toLowerCase() ? keccak256(concat([a, b])) : keccak256(concat([b, a])));

// never .map(getAddress): the index would be read as a chain id (EIP-1191 checksum), so duplicates survived (internal round, 18 Oct)
export function buildTree(addresses) {
  const leaves = [...new Set(addresses.map((a) => getAddress(String(a).toLowerCase())))].map(leafOf).sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
  if (leaves.length === 0) return { root: null, layers: [] };
  const layers = [leaves];
  while (layers[layers.length - 1].length > 1) {
    const prev = layers[layers.length - 1]; const next = [];
    for (let i = 0; i < prev.length; i += 2) next.push(i + 1 < prev.length ? pair(prev[i], prev[i + 1]) : prev[i]);
    layers.push(next);
  }
  return { root: layers[layers.length - 1][0], layers };
}

export function proofFor(addresses, address) {
  if (!isAddress(address)) return { allowlisted: false, proof: [] };
  const { layers } = buildTree(addresses);
  if (!layers.length) return { allowlisted: false, proof: [] };
  let idx = layers[0].indexOf(leafOf(address));
  if (idx < 0) return { allowlisted: false, proof: [] };
  const proof = [];
  for (let l = 0; l < layers.length - 1; l++) {
    const layer = layers[l]; const sib = idx ^ 1;
    if (sib < layer.length) proof.push(layer[sib]);
    idx = Math.floor(idx / 2);
  }
  return { allowlisted: true, proof };
}

// Pure-JS check that mirrors MerkleProof.verify, for tests and for the admin view.
export function verify(root, address, proof) {
  let h = leafOf(address);
  for (const p of proof) h = pair(h, p);
  return h === root;
}

