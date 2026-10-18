#!/usr/bin/env bash
# Go day on Robinhood Chain in one command (docs/MAINNET-PLAN.md "Day 2"), with the real keys from backend/.env.
#
#   1. Predict, on a local fork (nothing leaves the machine):
#        anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546 --chain-id 4663     (another terminal)
#        SAFE=0x... POT_SAFE=0x... MODE=fork FORK_RPC=http://127.0.0.1:8546 bash script/go-day.sh
#      -> go-day/predicted.json (every address and role, read back from the fork)
#   2. Set the server to the predicted addresses: node ../backend/scripts/go-day-env.mjs go-day/predicted.json
#   3. Live, only after the written go from both founders (CLAUDE.md rules 1 and 2):
#        SAFE=0x... POT_SAFE=0x... MODE=live ALLOW_MAINNET_DEPLOY=1 CONFIRM=both-founders-said-go bash script/go-day.sh
#      Runs the same sequence on Robinhood, checks every address against go-day/predicted.json and stops at the
#      first difference -> go-day/live.json.
#
# Inputs: SAFE (required: the TEAM Safe, receives every platform fee), POT_SAFE (required, a different Safe: owns
# PotVault and declares pot distributions; holds no team money. Jj 18 Oct: payouts never touch team money), START_TICK (default: from today's ETH price), ALLOWLIST_ROOT (default: the server's
# GET /admin/jig/allowlist root; must not be empty), JIG_SALT (default: the ground salt,
# docs/JIG-VANITY.md). Keys: JIG_DEPLOYER_PK (JIG, coin side) and LAUNCH_PK (the operating wallet: the NFT side), never
# printed. Neither wallet may send a Robinhood transaction between the fork prediction and the live run (the
# addresses come from their nonces); if one did, rerun MODE=fork.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."
MODE=${MODE:?MODE=fork or MODE=live}
SAFE=${SAFE:?SAFE required: the founders team Safe on Robinhood}
POT_SAFE=${POT_SAFE:?POT_SAFE required: a second Safe that owns the pot, never the team Safe}
set -a; . ../backend/.env; set +a
DPK=${JIG_DEPLOYER_PK:?JIG_DEPLOYER_PK missing from backend/.env}; OPK=${LAUNCH_PK:?LAUNCH_PK missing}
D=$(cast wallet address --private-key $DPK); OPS=$(cast wallet address --private-key $OPK)
JIG_SALT=${JIG_SALT:-0xfb52c5f2dbb21c000dc29b556bf5812f99456c1a006b4aec376c67a400d00a19}
WANT_JIG=0x0000f6Da041C6330C5f2389eA6c1BD5C5C011Ec7
[ "$(echo $D | tr 'A-F' 'a-f')" == "0xfb52c5f2dbb21c000dc29b556bf5812f99456c1a" ] || { echo "JIG_DEPLOYER_PK is not the deployer bound into the salt (0xFB52…6C1A)"; exit 1; }
[ "$(echo ${SAFE} | tr 'A-F' 'a-f')" != "$(echo $OPS | tr 'A-F' 'a-f')" ] || { echo "SAFE must not be the operating wallet"; exit 1; }
[ "$(echo ${POT_SAFE} | tr 'A-F' 'a-f')" != "$(echo $SAFE | tr 'A-F' 'a-f')" ] && [ "$(echo ${POT_SAFE} | tr 'A-F' 'a-f')" != "$(echo $OPS | tr 'A-F' 'a-f')" ] || { echo "POT_SAFE must be its own Safe: not the team Safe, not the operating wallet"; exit 1; }
mkdir -p go-day

if [ "$MODE" = fork ]; then
  R=${FORK_RPC:?FORK_RPC required}; case "$R" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "refusing: FORK_RPC must be a local fork"; exit 1;; esac
  trap 'rm -rf broadcast/*/4663 cache/*/4663' EXIT
  for a in $D $OPS; do cast rpc anvil_setBalance $a 0x2386F26FC10000 --rpc-url $R >/dev/null; done   # 0.01 ETH, as funded on the day
  OUTFILE=go-day/predicted.json
elif [ "$MODE" = live ]; then
  R=https://rpc.mainnet.chain.robinhood.com
  [ "${ALLOW_MAINNET_DEPLOY:-}" = 1 ] && [ "${CONFIRM:-}" = both-founders-said-go ] || { echo "live refused: needs ALLOW_MAINNET_DEPLOY=1 and CONFIRM=both-founders-said-go (rules 1 and 2)"; exit 1; }
  [ -f go-day/predicted.json ] || { echo "run MODE=fork first: go-day/predicted.json is missing"; exit 1; }
  for a in $D $OPS; do b=$(cast balance $a --rpc-url $R); [ "$b" -ge 3000000000000000 ] || { echo "$a holds $b wei on Robinhood: fund it with ~0.01 ETH"; exit 1; }; done
  OUTFILE=go-day/live.json
else echo "MODE must be fork or live"; exit 1; fi
[ "$(cast chain-id --rpc-url $R)" = 4663 ] || { echo "not Robinhood Chain"; exit 1; }
[ -z "$(cast code $WANT_JIG --rpc-url $R | sed 's/^0x$//')" ] || { echo "JIG already exists at $WANT_JIG on this chain: never rerun DeployJIG (MAINNET-PLAN 'If the JIG deploy stops halfway')"; exit 1; }
[ "$(cast nonce $D --rpc-url $R)" = 0 ] || echo "note: the deployer's nonce is $(cast nonce $D --rpc-url $R), not 0; fine if the fork run saw the same"

START_TICK=${START_TICK:-$(cd ../backend && node scripts/jig-start-tick.mjs | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).START_TICK))")}
if [ -z "${ALLOWLIST_ROOT:-}" ]; then
  ALLOWLIST_ROOT=$(curl -s -H "x-admin-token: $ADMIN_TOKEN" https://nft-pad-backend.onrender.com/admin/jig/allowlist | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const j=JSON.parse(d);console.log(j.root||'')})")
fi
[ -n "$ALLOWLIST_ROOT" ] || { echo "the server's JIG allowlist is empty: add the wallets first (POST /admin/jig/allowlist); DeployJIG refuses an empty root on a mainnet"; exit 1; }
if [ "$MODE" = live ]; then
  P() { node -e "console.log(require('./go-day/predicted.json')['$1'])"; }
  for k in SAFE POT_SAFE START_TICK ALLOWLIST_ROOT; do [ "$(P $k | tr 'A-F' 'a-f')" == "$(eval echo \$$k | tr 'A-F' 'a-f')" ] || { echo "$k differs from the fork prediction ($(P $k)): rerun MODE=fork"; exit 1; }; done
fi
echo "mode $MODE  deployer $D  operating $OPS  safe $SAFE  pot safe $POT_SAFE  tick $START_TICK  allowlist $ALLOWLIST_ROOT"

out() { grep -E "$1" | awk '{print $NF}' | head -1; }
declare -A A
same() { # live: the address must be the one predicted
  A[$1]=$2; [ -n "$2" ] || { echo "FAIL: no address for $1. Last step's output:"; grep -iE "error|revert" go-day/last-step.log | head -5; exit 1; }
  if [ "$MODE" = live ]; then local want=$(P $1); [ "$(echo $want | tr 'A-F' 'a-f')" == "$(echo $2 | tr 'A-F' 'a-f')" ] || { echo "STOP: $1 is $2, predicted $want"; exit 1; }; fi
  printf "  %-16s %s\n" $1 $2
}
fs() { forge script "$@" --rpc-url $R --broadcast --slow --skip-simulation 2>&1 | tee go-day/last-step.log; }
export ALLOW_MAINNET_DEPLOY=1

echo "--- 1. DeployJIG (the 5-minute window opens at its last transaction)"
J=$(LAUNCH_PK=$DPK POT_OWNER=$POT_SAFE PLATFORM=$SAFE ALLOWLIST_ROOT=$ALLOWLIST_ROOT JIG_SALT=$JIG_SALT START_TICK=$START_TICK fs script/DeployJIG.s.sol)
same JIG_TOKEN "$(echo "$J" | out '^  JIG  ')"; same JIG_POT "$(echo "$J" | out 'PotVault ')"; same JIG_LAUNCH "$(echo "$J" | out 'JIGLaunch ')"; same JIG_LAUNCH_HOOK "$(echo "$J" | out 'LaunchHook')"
[ "$(echo ${A[JIG_TOKEN]} | tr 'A-F' 'a-f')" == "$(echo $WANT_JIG | tr 'A-F' 'a-f')" ] || { echo "STOP: JIG is not the vanity address"; exit 1; }
echo "--- 2. NFT side, from the operating wallet"
NFT=$(cd ../backend && CHAIN_RPC=$R LAUNCH_PK=$OPK PLATFORM=$SAFE RESERVE=${A[JIG_POT]} PAUSER=$OPS ALLOW_MAINNET_DEPLOY=1 node scripts/deploy-nft-factory.mjs | tail -1)
same RH_FACTORY "$(echo "$NFT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).factory))")"
same NFT_IMPL "$(echo "$NFT" | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>console.log(JSON.parse(d).implementation))")"
same RH_LAUNCHER "$(LAUNCH_PK=$OPK NFT_FACTORY=${A[RH_FACTORY]} OPERATOR=$OPS ADMIN=$SAFE fs script/DeployLauncher.s.sol | out '^  CollectionLauncher')"
PH=$(LAUNCH_PK=$OPK PLATFORM=$SAFE RESERVE=${A[JIG_POT]} OPERATOR=$OPS ADMIN=$SAFE fs script/DeployPhased.s.sol)
same PHASED_IMPL "$(echo "$PH" | out 'JigsawCollection impl')"; same RH_PHASED_FACTORY "$(echo "$PH" | out 'JigsawCollectionFactory')"
echo "--- 3. DeployRest"; same AIRDROP_CLAIM "$(LAUNCH_PK=$DPK POT=${A[JIG_POT]} fs script/DeployRest.s.sol | out AirdropClaim)"
echo "--- 4. DeployCoins (no launch fee)"
C=$(LAUNCH_PK=$DPK JIG=${A[JIG_TOKEN]} POT=${A[JIG_POT]} AIRDROP=${A[AIRDROP_CLAIM]} PLATFORM=$SAFE LAUNCH_FEE_WEI=0 fs script/DeployCoins.s.sol)
same CREATOR_FEE_HOOK "$(echo "$C" | out CreatorFeeHook)"; same COIN_FACTORY "$(echo "$C" | out CoinFactory)"
echo "--- 5. DeployDeepening"; same LP_DEEPENING "$(LAUNCH_PK=$DPK HOOK=${A[CREATOR_FEE_HOOK]} JIG=${A[JIG_TOKEN]} JIG_POOL_HOOK=${A[JIG_LAUNCH_HOOK]} KEEPER=$OPS fs script/DeployDeepening.s.sol | out 'LPDeepening ')"

echo "--- 6. roles read back from chain"
BAD=0
chk() { local got=$(cast call $1 "$2" --rpc-url $R | tail -1 | awk '{print $1}'); if [ "$(echo $got | tr 'A-F' 'a-f')" == "$(echo $3 | tr 'A-F' 'a-f')" ]; then printf "  %-36s OK\n" "$4"; else printf "  %-36s WRONG: %s (want %s)\n" "$4" "$got" "$3"; BAD=1; fi; }
chk ${A[JIG_POT]} "owner()(address)" $POT_SAFE "PotVault owner = pot Safe"
chk ${A[JIG_LAUNCH]} "platform()(address)" $SAFE "JIGLaunch platform = Safe"
chk ${A[JIG_LAUNCH_HOOK]} "allowlistRoot()(bytes32)" $ALLOWLIST_ROOT "launch hook allowlist root"
chk ${A[CREATOR_FEE_HOOK]} "platform()(address)" $SAFE "CreatorFeeHook platform = Safe"
chk ${A[COIN_FACTORY]} "platform()(address)" $SAFE "CoinFactory platform = Safe"
chk ${A[COIN_FACTORY]} "launchFeeWei()(uint256)" 0 "CoinFactory launch fee = 0"
chk ${A[AIRDROP_CLAIM]} "owner()(address)" 0x0000000000000000000000000000000000000000 "AirdropClaim renounced"
chk ${A[AIRDROP_CLAIM]} "factory()(address)" ${A[COIN_FACTORY]} "AirdropClaim bound to factory"
chk ${A[LP_DEEPENING]} "keeper()(address)" $OPS "LPDeepening keeper = operating"
chk ${A[CREATOR_FEE_HOOK]} "deepening()(address)" ${A[LP_DEEPENING]} "hook bound to LPDeepening"
chk ${A[NFT_IMPL]} "PLATFORM()(address)" $SAFE "NFT impl PLATFORM = Safe"
chk ${A[NFT_IMPL]} "RESERVE()(address)" ${A[JIG_POT]} "NFT impl RESERVE = PotVault"
chk ${A[RH_LAUNCHER]} "operator()(address)" $OPS "launcher operator = operating"
chk ${A[RH_LAUNCHER]} "admin()(address)" $SAFE "launcher admin = Safe"
chk ${A[PHASED_IMPL]} "PLATFORM()(address)" $SAFE "phased impl PLATFORM = Safe"
chk ${A[PHASED_IMPL]} "RESERVE()(address)" ${A[JIG_POT]} "phased impl RESERVE = PotVault"
chk ${A[RH_PHASED_FACTORY]} "operator()(address)" $OPS "phased factory operator = operating"
chk ${A[RH_PHASED_FACTORY]} "owner()(address)" $SAFE "phased factory owner = Safe"

{ echo "{"; echo "  \"mode\": \"$MODE\", \"SAFE\": \"$SAFE\", \"POT_SAFE\": \"$POT_SAFE\", \"OPS\": \"$OPS\", \"START_TICK\": \"$START_TICK\", \"ALLOWLIST_ROOT\": \"$ALLOWLIST_ROOT\","
  for k in JIG_TOKEN JIG_POT JIG_LAUNCH JIG_LAUNCH_HOOK RH_FACTORY NFT_IMPL RH_LAUNCHER PHASED_IMPL RH_PHASED_FACTORY AIRDROP_CLAIM CREATOR_FEE_HOOK COIN_FACTORY; do echo "  \"$k\": \"${A[$k]}\","; done
  echo "  \"LP_DEEPENING\": \"${A[LP_DEEPENING]}\""; echo "}"; } > $OUTFILE
echo "wrote $OUTFILE"
[ $BAD = 0 ] || { echo "ROLES WRONG: fix before KEEPER_ENABLED=1"; exit 1; }
echo "all roles OK. Next: node ../backend/scripts/go-day-env.mjs $OUTFILE$([ $MODE = live ] && echo ' --keeper')"
