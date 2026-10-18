#!/usr/bin/env bash
# Go-day rehearsal on a local fork of Robinhood Chain: the exact mainnet-mode deploy sequence with every required role,
# then the roles read back from chain. Nothing leaves the machine: it only talks to the fork at $FORK_RPC.
#   anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546 --chain-id 4663   (in another terminal)
#   FORK_RPC=http://127.0.0.1:8546 bash script/rehearse-mainnet.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
F=${FORK_RPC:?FORK_RPC required (a local fork, never a real RPC)}
case "$F" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "refusing: FORK_RPC must be a local fork"; exit 1;; esac
cd "$(dirname "$0")/.."
# the fork reports chain 4663: never leave its broadcast files where a real go-day run would write (and be read back)
trap 'rm -rf broadcast/*/4663 cache/*/4663 cache/rh-jig-plan.json' EXIT

# throwaway keys funded on the fork only
DEPLOYER_PK=$(cd ../backend && node -e "import('viem/accounts').then(m=>console.log(m.generatePrivateKey()))"); D=$(cast wallet address --private-key $DEPLOYER_PK)
OPS_PK=$(cd ../backend && node -e "import('viem/accounts').then(m=>console.log(m.generatePrivateKey()))"); OPS=$(cast wallet address --private-key $OPS_PK)
SAFE=0x000000000000000000000000000000000005AFE0
for a in $D $OPS; do cast rpc anvil_setBalance $a 0x8AC7230489E80000 --rpc-url $F >/dev/null; done
echo "deployer $D  operating $OPS  safe(stand-in) $SAFE"

export ALLOW_MAINNET_DEPLOY=1 LAUNCH_PK=$DEPLOYER_PK
export JIG_SALT=0x$(echo ${D:2} | tr 'A-F' 'a-f')00$(printf '%022x' 0xc011ec7)
export POT_OWNER=$SAFE PLATFORM=$SAFE ALLOWLIST_ROOT=0x$(printf '%064x' 1) START_TICK=${START_TICK:-202400}
out() { grep -E "$1" | awk '{print $NF}' | head -1; }

echo "--- refusal checks: each must fail for the stated reason, not for any other"
if env -u PLATFORM forge script script/DeployJIG.s.sol --rpc-url $F --broadcast --skip-simulation >/tmp/rh-refuse.log 2>&1; then echo "FAIL: deployed without PLATFORM"; exit 1; fi
grep -q 'environment variable "PLATFORM" not found' /tmp/rh-refuse.log && echo "  refused without PLATFORM: ok" || { echo "FAIL: refused, but not for PLATFORM:"; tail -5 /tmp/rh-refuse.log; exit 1; }
if ALLOW_MAINNET_DEPLOY=0 forge script script/DeployJIG.s.sol --rpc-url $F --broadcast --skip-simulation >/tmp/rh-refuse.log 2>&1; then echo "FAIL: deployed without ALLOW_MAINNET_DEPLOY"; exit 1; fi
grep -q 'ALLOW_MAINNET_DEPLOY' /tmp/rh-refuse.log && echo "  refused without ALLOW_MAINNET_DEPLOY: ok" || { echo "FAIL: refused, but not for ALLOW_MAINNET_DEPLOY:"; tail -5 /tmp/rh-refuse.log; exit 1; }

echo "--- 1. DeployJIG"; J=$(forge script script/DeployJIG.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1)
POT=$(echo "$J" | out "PotVault "); LAUNCH=$(echo "$J" | out "JIGLaunch "); JIG=$(echo "$J" | out "^  JIG  "); LHOOK=$(echo "$J" | out "LaunchHook")
echo "pot $POT launch $LAUNCH jig $JIG launchHook $LHOOK"
echo "--- 2. DeployRest"; AIRDROP=$(POT=$POT forge script script/DeployRest.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1 | out "AirdropClaim")
echo "--- 3. DeployCoins"; C=$(JIG=$JIG POT=$POT AIRDROP=$AIRDROP LAUNCH_FEE_WEI=0 SALT_SEED=1 forge script script/DeployCoins.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1)
HOOK=$(echo "$C" | out "CreatorFeeHook"); FACTORY=$(echo "$C" | out "CoinFactory")
echo "--- 4. DeployDeepening"; DEEP=$(HOOK=$HOOK JIG=$JIG JIG_POOL_HOOK=$LHOOK KEEPER=$OPS forge script script/DeployDeepening.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1 | out "LPDeepening ")
# the NFT side runs from the operating wallet (as on go day), so the JIG deployer's nonces stay as predicted
echo "--- 5. NFT factory (Loom, byte-identical to Sepolia)"
NFT=$(cd ../backend && CHAIN_RPC=$F LAUNCH_PK=$OPS_PK PLATFORM=$SAFE RESERVE=$POT PAUSER=$OPS ALLOW_MAINNET_DEPLOY=1 node scripts/deploy-nft-factory.mjs | tail -1)
NFT_FACTORY=$(echo "$NFT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).factory))"); NFT_IMPL=$(echo "$NFT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).implementation))")
echo "--- 6. DeployLauncher"; LAUNCHER=$(LAUNCH_PK=$OPS_PK NFT_FACTORY=$NFT_FACTORY OPERATOR=$OPS ADMIN=$SAFE forge script script/DeployLauncher.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1 | out "^  CollectionLauncher")
echo "--- 7. DeployPhased"; P=$(LAUNCH_PK=$OPS_PK PLATFORM=$SAFE RESERVE=$POT OPERATOR=$OPS ADMIN=$SAFE forge script script/DeployPhased.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1)
PIMPL=$(echo "$P" | out "JigsawCollection impl"); PFACT=$(echo "$P" | out "JigsawCollectionFactory")
echo "nft factory $NFT_FACTORY launcher $LAUNCHER phased $PFACT"

chk() { local got=$(cast call $1 "$2" --rpc-url $F | tail -1); local ok=$([ "$(echo $got | tr 'A-F' 'a-f')" == "$(echo $3 | tr 'A-F' 'a-f')" ] && echo OK || echo "WRONG ($got)"); printf "  %-34s %-44s %s\n" "$4" "$3" "$ok"; }
echo "--- roles read back from chain"
chk $POT "owner()(address)" $SAFE "PotVault owner = Safe"
chk $LAUNCH "platform()(address)" $SAFE "JIGLaunch platform = Safe"
chk $LHOOK "allowlistRoot()(bytes32)" $ALLOWLIST_ROOT "launch hook allowlist root"
chk $HOOK "platform()(address)" $SAFE "CreatorFeeHook platform = Safe"
chk $FACTORY "platform()(address)" $SAFE "CoinFactory platform = Safe"
chk $FACTORY "launchFeeWei()(uint256)" "0" "CoinFactory launch fee = 0"
chk $AIRDROP "owner()(address)" 0x0000000000000000000000000000000000000000 "AirdropClaim owner renounced"
chk $AIRDROP "factory()(address)" $FACTORY "AirdropClaim bound to factory"
chk $DEEP "keeper()(address)" $OPS "LPDeepening keeper = operating"
chk $HOOK "deepening()(address)" $DEEP "hook bound to LPDeepening"
chk $NFT_IMPL "PLATFORM()(address)" $SAFE "NFT impl PLATFORM = Safe"
chk $NFT_IMPL "RESERVE()(address)" $POT "NFT impl RESERVE = PotVault"
chk $LAUNCHER "factory()(address)" $NFT_FACTORY "launcher factory = NFT factory"
chk $LAUNCHER "operator()(address)" $OPS "launcher operator = operating"
chk $LAUNCHER "admin()(address)" $SAFE "launcher admin = Safe"
chk $PIMPL "PLATFORM()(address)" $SAFE "phased impl PLATFORM = Safe"
chk $PIMPL "RESERVE()(address)" $POT "phased impl RESERVE = PotVault"
chk $PFACT "implementation()(address)" $PIMPL "phased factory implementation"
chk $PFACT "operator()(address)" $OPS "phased factory operator = operating"
chk $PFACT "owner()(address)" $SAFE "phased factory owner = Safe"

if [ "${PARTIAL_DRILL:-1}" = "1" ]; then
  # "If the JIG deploy stops halfway" (docs/MAINNET-PLAN.md): a second deployer runs DeployJIG on a fork snapshot to
  # learn the planned transactions, the fork goes back, the first three (PotVault, JIGLaunch, JIG via CreateX) are
  # sent, then the rest by hand from run-latest.json with cast send. The addresses must equal the full run's.
  echo "--- drill: DeployJIG stopped after JIG landed, finished by hand"
  D2_PK=$(cd ../backend && node -e "import('viem/accounts').then(m=>console.log(m.generatePrivateKey()))"); D2=$(cast wallet address --private-key $D2_PK)
  cast rpc anvil_setBalance $D2 0x8AC7230489E80000 --rpc-url $F >/dev/null
  SNAP=$(cast rpc evm_snapshot --rpc-url $F | tr -d '"')
  SALT2=0x$(echo ${D2:2} | tr 'A-F' 'a-f')00$(printf '%022x' 0xc011ec7)
  FULL=$(LAUNCH_PK=$D2_PK JIG_SALT=$SALT2 forge script script/DeployJIG.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1)
  WANT_JIG=$(echo "$FULL" | out "^  JIG  "); WANT_HOOK=$(echo "$FULL" | out "LaunchHook"); WANT_LAUNCH=$(echo "$FULL" | out "JIGLaunch ")
  cp broadcast/DeployJIG.s.sol/4663/run-latest.json ./cache/rh-jig-plan.json
  cast rpc evm_revert $SNAP --rpc-url $F >/dev/null
  N=$(node -e "console.log(require('./cache/rh-jig-plan.json').transactions.length)")
  for i in $(seq 0 $((N - 1))); do
    TO=$(node -e "const t=require('./cache/rh-jig-plan.json').transactions[$i];console.log(t.transaction.to??'')"); IN=$(node -e "console.log(require('./cache/rh-jig-plan.json').transactions[$i].transaction.input)")
    [ $i -eq 3 ] && echo "  (stop here: the first three landed; finishing by hand)"
    if [ -z "$TO" ]; then cast send --private-key $D2_PK --rpc-url $F --create "$IN" >/dev/null; else cast send "$TO" "$IN" --private-key $D2_PK --rpc-url $F >/dev/null; fi
  done
  [ -n "$(cast code $WANT_JIG --rpc-url $F | sed 's/^0x$//')" ] && echo "  JIG at the planned address: ok" || { echo "FAIL: no JIG at $WANT_JIG"; exit 1; }
  [ -n "$(cast code $WANT_HOOK --rpc-url $F | sed 's/^0x$//')" ] && echo "  launch hook at the planned address: ok" || { echo "FAIL: no hook at $WANT_HOOK"; exit 1; }
  chk $WANT_HOOK "initialized()(bool)" true "  by-hand finish: pool launched"
  chk $WANT_LAUNCH "jig()(address)" $WANT_JIG "  by-hand finish: JIGLaunch bound"
fi
echo "JIG $JIG (salt-bound, CreateX); gas spent by the deployer: $(python -c "print((10.0 - $(cast balance $D --ether --rpc-url $F)))") ETH"
