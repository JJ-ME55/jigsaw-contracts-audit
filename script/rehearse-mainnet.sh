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
echo "--- 3. DeployPayouts"; PAYOUTS=$(JIG=$JIG PAYOUTS_OWNER=$OPS forge script script/DeployPayouts.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1 | out "HolderPayouts")
echo "--- 4. DeployCoins"; C=$(JIG=$JIG POT=$POT AIRDROP=$AIRDROP AIRDROP_OWNER=$OPS LAUNCH_FEE_WEI=60000000000000000 SALT_SEED=1 forge script script/DeployCoins.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1)
HOOK=$(echo "$C" | out "CreatorFeeHook"); FACTORY=$(echo "$C" | out "CoinFactory")
echo "--- 5. DeployDeepening"; DEEP=$(HOOK=$HOOK JIG=$JIG JIG_POOL_HOOK=$LHOOK KEEPER=$OPS forge script script/DeployDeepening.s.sol --rpc-url $F --broadcast --slow --skip-simulation 2>&1 | out "LPDeepening ")
echo "--- 6. operating wallet accepts AirdropClaim"; cast send $AIRDROP "acceptOwnership()" --private-key $OPS_PK --rpc-url $F >/dev/null

chk() { local got=$(cast call $1 "$2" --rpc-url $F | tail -1); local ok=$([ "$(echo $got | tr 'A-F' 'a-f')" == "$(echo $3 | tr 'A-F' 'a-f')" ] && echo OK || echo "WRONG ($got)"); printf "  %-34s %-44s %s\n" "$4" "$3" "$ok"; }
echo "--- roles read back from chain"
chk $POT "owner()(address)" $SAFE "PotVault owner = Safe"
chk $LAUNCH "platform()(address)" $SAFE "JIGLaunch platform = Safe"
chk $LHOOK "allowlistRoot()(bytes32)" $ALLOWLIST_ROOT "launch hook allowlist root"
chk $HOOK "platform()(address)" $SAFE "CreatorFeeHook platform = Safe"
chk $FACTORY "platform()(address)" $SAFE "CoinFactory platform = Safe"
chk $FACTORY "launchFeeWei()(uint256)" "60000000000000000 [6e16]" "CoinFactory launch fee"
chk $AIRDROP "owner()(address)" $OPS "AirdropClaim owner = operating"
chk $AIRDROP "factory()(address)" $FACTORY "AirdropClaim bound to factory"
chk $PAYOUTS "owner()(address)" $OPS "HolderPayouts owner = operating"
chk $DEEP "keeper()(address)" $OPS "LPDeepening keeper = operating"
chk $HOOK "deepening()(address)" $DEEP "hook bound to LPDeepening"
echo "JIG $JIG (salt-bound, CreateX); gas spent by the deployer: $(python -c "print((10.0 - $(cast balance $D --ether --rpc-url $F)))") ETH"
