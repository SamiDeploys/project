#!/bin/bash
# -----------------------------------------------------------------------------
# Local PoS testnet starter (Geth + Prysm) with custom genesis fields preserved
# -----------------------------------------------------------------------------

set -euo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

############################################
# -------- USER / PROJECT OVERRIDES -------
############################################
# Your patched geth repo & genesis file
PROJECT_GETH_DIR=${PROJECT_GETH_DIR:-/home/ire/project/DFX}
PROJECT_GENESIS=${PROJECT_GENESIS:-/home/ire/project/DFX/genesis.json}

# Where to put all generated state/logs
NETWORK_DIR=${NETWORK_DIR:-./network}

# Number of validator nodes to spin up
NUM_NODES=${NUM_NODES:-2}

############################################
# ------------- PORT BLOCK ----------------
############################################
GETH_BOOTNODE_PORT=30301

GETH_HTTP_PORT=8000
GETH_WS_PORT=8100
GETH_AUTH_RPC_PORT=8200
GETH_METRICS_PORT=8300
GETH_NETWORK_PORT=8400

PRYSM_BEACON_RPC_PORT=4000
PRYSM_BEACON_GRPC_GATEWAY_PORT=4100
PRYSM_BEACON_P2P_TCP_PORT=4200
PRYSM_BEACON_P2P_UDP_PORT=4300
PRYSM_BEACON_MONITORING_PORT=4400

PRYSM_VALIDATOR_RPC_PORT=7000
PRYSM_VALIDATOR_GRPC_GATEWAY_PORT=7100
PRYSM_VALIDATOR_MONITORING_PORT=7200

############################################
# ------------ BINARIES -------------------
############################################
# Patched geth & (maybe) bootnode from your fork
GETH_BINARY="${PROJECT_GETH_DIR}/build/bin/geth"
DFX_BOOTNODE_BIN="${PROJECT_GETH_DIR}/build/bin/bootnode"

# Fallback bootnode if you didn’t build one in DFX
REPO_BOOTNODE_BIN="./dependencies/go-ethereum/build/bin/bootnode"

# Pick whichever bootnode exists
if [[ -x "$DFX_BOOTNODE_BIN" ]]; then
  GETH_BOOTNODE_BINARY="$DFX_BOOTNODE_BIN"
elif [[ -x "$REPO_BOOTNODE_BIN" ]]; then
  GETH_BOOTNODE_BINARY="$REPO_BOOTNODE_BIN"
else
  echo "No bootnode binary found. Build one (go build ./cmd/bootnode) or ensure ./dependencies/... exists."
  exit 1
fi

# Prysm (leave untouched)
PRYSM_CTL_BINARY=./dependencies/prysm/bazel-bin/cmd/prysmctl/prysmctl_/prysmctl
PRYSM_BEACON_BINARY=./dependencies/prysm/bazel-bin/cmd/beacon-chain/beacon-chain_/beacon-chain
PRYSM_VALIDATOR_BINARY=./dependencies/prysm/bazel-bin/cmd/validator/validator_/validator

############################################
# --------- REQUIREMENTS CHECKS -----------
############################################
command -v jq   >/dev/null || { echo "Error: jq is not installed.";   exit 1; }
command -v curl >/dev/null || { echo "Error: curl is not installed."; exit 1; }

[[ -x "$GETH_BINARY"         ]] || { echo "GETH not executable: $GETH_BINARY"; exit 1; }
[[ -x "$GETH_BOOTNODE_BINARY" ]] || { echo "BOOTNODE not executable: $GETH_BOOTNODE_BINARY"; exit 1; }
[[ -x "$PRYSM_CTL_BINARY"    ]] || { echo "prysmctl not executable: $PRYSM_CTL_BINARY"; exit 1; }
[[ -f "$PROJECT_GENESIS"     ]] || { echo "Custom genesis not found: $PROJECT_GENESIS"; exit 1; }

############################################
# -------------- CLEANUP ------------------
############################################
cleanup() {
  echo "Caught Ctrl+C. Killing background processes..."
  kill $(jobs -p) 2>/dev/null || true
  exit
}
trap 'cleanup' SIGINT

rm -rf "$NETWORK_DIR" || echo "no network directory"
mkdir -p "$NETWORK_DIR"
pkill geth          || echo "No existing geth processes"
pkill beacon-chain  || echo "No existing beacon-chain processes"
pkill validator     || echo "No existing validator processes"
pkill bootnode      || echo "No existing bootnode processes"

echo "================ Checking versions ================"

# jq
if command -v jq >/dev/null 2>&1; then
  echo "jq version: $(jq --version)"
else
  echo "jq not found in PATH"
fi

# curl
if command -v curl >/dev/null 2>&1; then
  echo "curl version: $(curl --version | head -n 1)"
else
  echo "curl not found in PATH"
fi

# geth
echo "Geth binary: $GETH_BINARY"
$GETH_BINARY version

# bootnode
echo "Bootnode binary: $GETH_BOOTNODE_BINARY"
if $GETH_BOOTNODE_BINARY --help 2>&1 | grep -q "Usage"; then
  echo "Bootnode binary does not support --version, showing help header:"
  $GETH_BOOTNODE_BINARY --help | head -n 1
else
  $GETH_BOOTNODE_BINARY version
fi

# prysm beacon
echo "Prysm Beacon binary: $PRYSM_BEACON_BINARY"
$PRYSM_BEACON_BINARY help >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "Beacon binary present (no --version support)"
else
  echo "Beacon binary failed to run"
fi

# prysm validator
echo "Prysm Validator binary: $PRYSM_VALIDATOR_BINARY"
$PRYSM_VALIDATOR_BINARY help >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "Validator binary present (no --version support)"
else
  echo "Validator binary failed to run"
fi

echo "================ Version check complete ================"







############################################
# ----------- BOOTNODE SETUP --------------
############################################
mkdir -p "$NETWORK_DIR/bootnode"
$GETH_BOOTNODE_BINARY -genkey "$NETWORK_DIR/bootnode/nodekey"

$GETH_BOOTNODE_BINARY \
  -nodekey "$NETWORK_DIR/bootnode/nodekey" \
  -addr=":$GETH_BOOTNODE_PORT" \
  -verbosity=5 > "$NETWORK_DIR/bootnode/bootnode.log" 2>&1 &

sleep 2
bootnode_enode=$(head -n 1 "$NETWORK_DIR/bootnode/bootnode.log")
if [[ "$bootnode_enode" != enode* ]]; then
  echo "Bootnode ENODE not found in log."
  exit 1
fi
echo "bootnode enode is: $bootnode_enode"

############################################
# ------ GENESIS + TAX FIELD PATCH --------
############################################
# Copy your genesis so prysmctl can read it
cp "$PROJECT_GENESIS" ./genesis.json

# Prysm will write out ./network/genesis.json and strip unknown fields.
# So we read then tax fields first, then merge them back in.
taxEnabled=$(jq -r '.config.taxEnabled // empty' "$PROJECT_GENESIS")
taxRate=$(jq -r '.config.taxRate // empty' "$PROJECT_GENESIS")
treasuryAddress=$(jq -r '.config.treasuryAddress // empty' "$PROJECT_GENESIS")

$PRYSM_CTL_BINARY testnet generate-genesis \
  --fork=deneb \
  --num-validators=$NUM_NODES \
  --chain-config-file=./config.yml \
  --geth-genesis-json-in=./genesis.json \
  --output-ssz=$NETWORK_DIR/genesis.ssz \
  --geth-genesis-json-out=$NETWORK_DIR/genesis.json

# Re-inject tax fields if they existed
if [[ -n "$taxEnabled" || -n "$taxRate" || -n "$treasuryAddress" ]]; then
  jq --argjson ten "${taxEnabled:-false}" \
     --argjson tr  "${taxRate:-0}" \
     --arg ta "${treasuryAddress:-0x0000000000000000000000000000000000000000}" \
     '.config.taxEnabled = $ten
      | .config.taxRate = $tr
      | .config.treasuryAddress = $ta' \
     "$NETWORK_DIR/genesis.json" > "$NETWORK_DIR/genesis.tmp" && mv "$NETWORK_DIR/genesis.tmp" "$NETWORK_DIR/genesis.json"
fi

############################################
# ----------- START NODES LOOP ------------
############################################
PRYSM_BOOTSTRAP_NODE=""
MIN_SYNC_PEERS=$((NUM_NODES/2))
echo "$MIN_SYNC_PEERS is minimum number of synced peers required"

for (( i=0; i<NUM_NODES; i++ )); do
  NODE_DIR=$NETWORK_DIR/node-$i
  mkdir -p "$NODE_DIR/execution" "$NODE_DIR/consensus" "$NODE_DIR/logs"

  geth_pw_file="$NODE_DIR/geth_password.txt"
  echo "" > "$geth_pw_file"

  cp ./config.yml                 "$NODE_DIR/consensus/config.yml"
  cp "$NETWORK_DIR/genesis.ssz"   "$NODE_DIR/consensus/genesis.ssz"
  cp "$NETWORK_DIR/genesis.json"  "$NODE_DIR/execution/genesis.json"

  # Create account (empty password)
  $GETH_BINARY account new --datadir "$NODE_DIR/execution" --password "$geth_pw_file"

  # Init execution client
  $GETH_BINARY init --datadir="$NODE_DIR/execution" "$NODE_DIR/execution/genesis.json"

  # Run execution client
  $GETH_BINARY \
    --networkid=${CHAIN_ID:-32382} \
    --http \
    --http.api=eth,net,web3 \
    --http.addr=127.0.0.1 \
    --http.corsdomain="*" \
    --http.port=$((GETH_HTTP_PORT + i)) \
    --port=$((GETH_NETWORK_PORT + i)) \
    --metrics.port=$((GETH_METRICS_PORT + i)) \
    --ws \
    --ws.api=eth,net,web3 \
    --ws.addr=127.0.0.1 \
    --ws.origins="*" \
    --ws.port=$((GETH_WS_PORT + i)) \
    --authrpc.vhosts="*" \
    --authrpc.addr=127.0.0.1 \
    --authrpc.jwtsecret="$NODE_DIR/execution/jwtsecret" \
    --authrpc.port=$((GETH_AUTH_RPC_PORT + i)) \
    --datadir="$NODE_DIR/execution" \
    --password="$geth_pw_file" \
    --bootnodes="$bootnode_enode" \
    --identity="node-$i" \
    --maxpendpeers=$NUM_NODES \
    --verbosity=3 \
    --syncmode=full > "$NODE_DIR/logs/geth.log" 2>&1 &

  sleep 5

  # Consensus client
  $PRYSM_BEACON_BINARY \
    --datadir="$NODE_DIR/consensus/beacondata" \
    --min-sync-peers=$MIN_SYNC_PEERS \
    --genesis-state="$NODE_DIR/consensus/genesis.ssz" \
    --bootstrap-node="$PRYSM_BOOTSTRAP_NODE" \
    --interop-eth1data-votes \
    --chain-config-file="$NODE_DIR/consensus/config.yml" \
    --contract-deployment-block=0 \
    --chain-id=${CHAIN_ID:-32382} \
    --rpc-host=127.0.0.1 \
    --rpc-port=$((PRYSM_BEACON_RPC_PORT + i)) \
    --grpc-gateway-host=127.0.0.1 \
    --grpc-gateway-port=$((PRYSM_BEACON_GRPC_GATEWAY_PORT + i)) \
    --execution-endpoint=http://localhost:$((GETH_AUTH_RPC_PORT + i)) \
    --accept-terms-of-use \
    --jwt-secret="$NODE_DIR/execution/jwtsecret" \
    --suggested-fee-recipient=0x123463a4b065722e99115d6c222f267d9cabb524 \
    --minimum-peers-per-subnet=0 \
    --p2p-tcp-port=$((PRYSM_BEACON_P2P_TCP_PORT + i)) \
    --p2p-udp-port=$((PRYSM_BEACON_P2P_UDP_PORT + i)) \
    --monitoring-port=$((PRYSM_BEACON_MONITORING_PORT + i)) \
    --verbosity=info \
    --slasher \
    --enable-debug-rpc-endpoints > "$NODE_DIR/logs/beacon.log" 2>&1 &

  # Validator
  $PRYSM_VALIDATOR_BINARY \
    --beacon-rpc-provider=localhost:$((PRYSM_BEACON_RPC_PORT + i)) \
    --datadir="$NODE_DIR/consensus/validatordata" \
    --accept-terms-of-use \
    --interop-num-validators=1 \
    --interop-start-index=$i \
    --rpc-port=$((PRYSM_VALIDATOR_RPC_PORT + i)) \
    --grpc-gateway-port=$((PRYSM_VALIDATOR_GRPC_GATEWAY_PORT + i)) \
    --monitoring-port=$((PRYSM_VALIDATOR_MONITORING_PORT + i)) \
    --graffiti="node-$i" \
    --chain-config-file="$NODE_DIR/consensus/config.yml" > "$NODE_DIR/logs/validator.log" 2>&1 &

  # Capture bootstrap ENR for later nodes
  if [[ -z "$PRYSM_BOOTSTRAP_NODE" ]]; then
    sleep 5
    PRYSM_BOOTSTRAP_NODE=$(curl -s localhost:4100/eth/v1/node/identity | jq -r '.data.enr')
    if [[ "$PRYSM_BOOTSTRAP_NODE" != enr* ]]; then
      echo "PRYSM_BOOTSTRAP_NODE does NOT start with enr"
      exit 1
    fi
    echo "PRYSM_BOOTSTRAP_NODE is valid: $PRYSM_BOOTSTRAP_NODE"
  fi
done

# Tail first node logs
tail -f "$NETWORK_DIR/node-0/logs/geth.log"

