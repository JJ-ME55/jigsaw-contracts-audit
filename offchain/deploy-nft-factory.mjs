// Deploy the NFT collection implementation and factory on another chain, byte for byte the code live on Sepolia
// (contracts/reference/nft-factory-creation.json), with this chain's addresses as constructor arguments.
//   PLATFORM=0x.. RESERVE=0x.. PAUSER=0x.. CHAIN_RPC=https://... node scripts/deploy-nft-factory.mjs
// Mainnets (Ethereum, Robinhood) are refused unless ALLOW_MAINNET_DEPLOY=1 (rule 1). Uses LAUNCH_PK.
import fs from 'node:fs';
import { createPublicClient, createWalletClient, http, encodeAbiParameters, getAddress, parseAbi, keccak256 } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const ref = JSON.parse(fs.readFileSync(new URL('../../contracts/reference/nft-factory-creation.json', import.meta.url), 'utf8'));
const rpc = process.env.CHAIN_RPC; if (!rpc) throw new Error('CHAIN_RPC required');
const account = privateKeyToAccount(process.env.LAUNCH_PK);
const probe = createPublicClient({ transport: http(rpc) }); const chainId = await probe.getChainId();
if ((chainId === 1 || chainId === 4663) && process.env.ALLOW_MAINNET_DEPLOY !== '1') throw new Error('mainnet deploy refused: set ALLOW_MAINNET_DEPLOY=1 only after both founders said go in writing');
const chain = { id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } };
const pub = createPublicClient({ chain, transport: http(rpc) }); const wallet = createWalletClient({ account, chain, transport: http(rpc) });
// on a mainnet every role is required: a silent default to the deployer would make a hot key the payee for good
const mainnet = chainId === 1 || chainId === 4663;
for (const k of ['PLATFORM', 'RESERVE', 'PAUSER']) if (mainnet && !process.env[k]) throw new Error(`${k} is required on a mainnet`);
const [platform, reserve, pauser] = ['PLATFORM', 'RESERVE', 'PAUSER'].map((k) => getAddress(process.env[k] ?? account.address));

async function deploy(label, code, types, args) {
  const data = code + encodeAbiParameters(types.map((type) => ({ type })), args).slice(2);
  const hash = await wallet.sendTransaction({ data });
  const rc = await pub.waitForTransactionReceipt({ hash }); if (rc.status !== 'success') throw new Error(`${label} deploy failed ${hash}`);
  console.error(`  ${label} ${rc.contractAddress} gas ${rc.gasUsed} tx ${hash}`);
  return getAddress(rc.contractAddress);
}
const impl = await deploy('implementation', ref.implementation.creationWithoutArgs, ['address', 'address'], [platform, reserve]);
const factory = await deploy('factory', ref.factory.creationWithoutArgs, ['address', 'address', 'address'], [impl, platform, pauser]);
const f = parseAbi(['function implementation() view returns (address)', 'function PLATFORM() view returns (address)', 'function CREATE_FEE() view returns (uint256)']);
const [i2, p2, fee] = await Promise.all(['implementation', 'PLATFORM', 'CREATE_FEE'].map((fn) => pub.readContract({ address: factory, abi: f, functionName: fn })));
if (getAddress(i2) !== impl || getAddress(p2) !== platform) throw new Error('factory wiring mismatch');
console.log(JSON.stringify({ chainId, implementation: impl, factory, platform, reserve, pauser, createFeeWei: fee.toString(), implCodeHash: keccak256(await pub.getCode({ address: impl })) }));
