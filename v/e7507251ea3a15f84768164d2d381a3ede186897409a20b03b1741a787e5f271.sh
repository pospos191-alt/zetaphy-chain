#!/bin/bash
# ZETAPHY Chain — step 0 testnet node (single validator).
#
# Paste this whole file into Oracle Cloud when creating the instance:
#   Create instance -> Show advanced options -> Management -> Paste cloud-init script
# It runs once, as root, on first boot: installs Go, builds the chain from the
# public Cosmos EVM source (pinned commit), creates the genesis, and starts the
# node as a service. Takes ~15-60 minutes depending on the machine.
# Progress log on the server: /var/log/zetaphy-setup.log
#
# OPTIONAL: put your MetaMask address between the quotes to receive
# 1,000,000 test ZETAPHY at genesis (public address only, never a private key).
OWNER_EVM_ADDRESS="${OWNER_EVM_ADDRESS:-}"
# To JOIN a running ZETAPHY chain instead of starting one: its node's https
# name, e.g. JOIN="1-2-3-4.sslip.io" (genesis and peer address come from it).
JOIN="${JOIN:-}"
# Free Google Cloud e2-micro gives only 1 GB of outgoing traffic a month.
# LOW_EGRESS=1 keeps the node under it (fewer peers, gzip, a monthly guard
# that pauses the public RPC near the limit). "auto" turns it on by itself on
# a Google e2-micro; 0 turns it off. EGRESS_LIMIT_MB: where the guard stops.
LOW_EGRESS="${LOW_EGRESS:-auto}"
EGRESS_LIMIT_MB="${EGRESS_LIMIT_MB:-800}"
# The EVM JSON-RPC is public only through https (Caddy and rpc-guard, which
# allow the wallet and app methods and limit each IP). PUBLIC_HTTP_RPC=1 also
# opens plain http://<ip>:8545, without those limits (the faucet stays https only).
PUBLIC_HTTP_RPC="${PUBLIC_HTTP_RPC:-0}"

set -euo pipefail

# ---- Fixed parameters (decided 19 Oct 2026) --------------------------------
CHAIN_ID="zetaphy_77390-1"
EVM_CHAIN_ID=77390                 # free in ethereum-lists/chains as of 19 Oct 2026
DENOM="azetaphy"                   # 1 ZETAPHY = 10^18 azetaphy
MONIKER="${MONIKER:-zetaphy-validator-0}"
COSMOS_EVM_TAG="v0.7.3"
COSMOS_EVM_COMMIT="c3ae9067a7eadcdea55a5192226916deb44c71c4"
GO_VERSION="1.25.9"                # what cosmos/evm v0.7.3 go.mod requires
# IBC rate limits: ibc-apps rate-limiting, ported to ibc-go v11 by the patch below.
RATELIMIT_MOD="github.com/cosmos/ibc-apps/modules/rate-limiting/v10@v10.7.0"
RATELIMIT_SUM="h1:5X2o/xT1x1fltUrkhvDCOpFaRJK5/1M36/SCh873VOc="
# Stage 7, CosmWasm: wasmd v0.70.5 (x/wasm for SDK v0.54) on wasmvm v3.0.9,
# pinned with their hashes in the patched evmd/go.sum. libwasmvm (Rust) is a
# shared library inside the wasmvm Go module (so go.sum pins it too); it is
# checked again against wasmvm's release checksums.txt and installed in
# /usr/local/lib, for x86_64 and aarch64 (glibc >= 2.30: Ubuntu 24.04 has 2.39).
WASMVM_VERSION="v3.0.9"
WASMVM_SO_SHA256_x86_64="0d41aa842c004a6aa138291d1f9f99818479fec7aef024d419e4ad244f858ee4"
WASMVM_SO_SHA256_aarch64="7eeb256b7baecaf465c555260d4e21b6d2532f451a2c7b95fd8acef4c4da597e"

NODE_USER="zetaphy"
NODE_HOME="/home/${NODE_USER}/.zetaphy"          # chain data + config (no keys)
KEYS_DIR="/home/${NODE_USER}/.zetaphy-genesis-keys" # genesis keys, kept out of the node's home
BIN="/usr/local/bin/zetaphyd"
LOG="/var/log/zetaphy-setup.log"

# Test hooks (leave unset on Oracle): ZETAPHYD_BIN=<prebuilt evmd>, NO_SYSTEMD=1
ZETAPHYD_BIN="${ZETAPHYD_BIN:-}"
[ -n "$ZETAPHYD_BIN" ] && ZETAPHYD_BIN=$(readlink -f "$ZETAPHYD_BIN")   # the script later runs from the node user's home
NO_SYSTEMD="${NO_SYSTEMD:-}"
# Optional: your own DNS name for the public RPC (an A record pointing at this
# machine), e.g. PUBLIC_HOST=rpc.sawasdeecoin.com. Caddy serves it next to
# <ip>.sslip.io, and the wallet files (keplr.json, evm-chain.json) use it.
PUBLIC_HOST="${PUBLIC_HOST:-}"
[ -z "$PUBLIC_HOST" ] || [[ "$PUBLIC_HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
  || { echo "PUBLIC_HOST: a DNS name like rpc.example.com"; exit 1; }

# ---- The ZETAPHY changes to the Cosmos EVM source -------------------------
# Used in step 4 below, and by CI: setup-node.sh --patch-source <cosmos/evm checkout>
# Runs as the user who owns the checkout, with Go (and jq) on PATH.
#  - addresses start with "zetaphy1..." instead of "cosmos1...";
#  - stage 5: post-quantum ML-DSA (FIPS 204) signature check as an EVM
#    precompile at 0x...0900 (Cloudflare CIRCL v1.6.3);
#  - stage 5: accounts whose only key is ML-DSA-44 (crypto/mldsa44): plain
#    Cosmos txs signed post-quantum, sent through the JSON-RPC methods
#    zetaphy_pqAccount / zetaphy_sendCosmosTx (evmd/zetaphy_rpc.go);
#  - stage 2: half of each block's fees is burned (evmd/zetaphy_feeburn.go),
#    like EIP-1559's base fee; validators get the other half;
#  - stage 3: IBC rate limits (x/ratelimit): governance caps how much of a
#    denom may cross a channel per window (e.g. USDC from Noble). The code is
#    the published ibc-apps module (hash pinned above, checked by Go's
#    checksum database too), ported to ibc-go v11 by ZETAPHY_RL_PATCH.
#  - security core (evmd/zetaphy_security.go, docs/SECURITY-CORE.md), each
#    rule off until a governance vote turns it on: Q-day (ECDSA-signed txs
#    refused from a voted height; migration by quantum lock, or commit–reveal
#    for keys never used), the threat gate (a tx to a contract with an
#    enforced Neuro flag needs its sender's consent, precompile 0x…0901), and
#    the IBC large-transfer hold (big inbound transfers wait, the guardian
#    can return them to the sender).
#  - stage 7: CosmWasm (x/wasm, Rust contracts) beside the EVM
#    (evmd/zetaphy_cosmwasm.go): code upload by governance only, instantiate
#    by anyone; Q-day, quantum locks and the fee burn cover wasm txs; IBC
#    for contracts is off; a running chain gets it with "zetaphy-v4".
# The patches are at the end of this file. Their tests (zetaphy-chain/fork-tests
# on GitHub, kept out of this file so it fits Oracle's size limit) run in CI
# on every change, against this same patching.
zetaphy_patch_source() {
  local src=$1 self rl rldir part
  self=$(readlink -f "$0")
  sed -i 's/Bech32Prefix = "cosmos"/Bech32Prefix = "zetaphy"/' "$src/evmd/config/bech32.go"
  grep -q 'Bech32Prefix = "zetaphy"' "$src/evmd/config/bech32.go" || { echo "address prefix patch did not apply"; return 1; }
  rl=$(cd /tmp && GOFLAGS=-mod=mod go mod download -json "$RATELIMIT_MOD")
  [ "$(echo "$rl" | jq -r .Sum)" = "$RATELIMIT_SUM" ] || { echo "rate-limiting module hash mismatch"; return 1; }
  rldir=$(echo "$rl" | jq -r .Dir)
  mkdir -p "$src/x/ratelimit"
  (cd "$rldir" && cp -r keeper types client v2 migrations ibc_middleware.go module.go LICENSE "$src/x/ratelimit/")
  chmod -R u+w "$src/x/ratelimit"
  find "$src/x/ratelimit" -name '*_test.go' -delete
  find "$src/x/ratelimit" -name '*.go' -exec sed -i \
    -e 's#github.com/cosmos/ibc-apps/modules/rate-limiting/v10#github.com/cosmos/evm/x/ratelimit#g' \
    -e 's#github.com/cosmos/ibc-go/v10#github.com/cosmos/ibc-go/v11#g' \
    -e 's#"cosmossdk.io/store/#"github.com/cosmos/cosmos-sdk/store/v2/#g' \
    -e 's#"cosmossdk.io/log"#"cosmossdk.io/log/v2"#g' {} +
  # ibc-go v11 middlewares are set up after creation, so pointer receivers.
  sed -i -E 's/^func \((im|i) IBCMiddleware\)/func (\1 *IBCMiddleware)/' "$src/x/ratelimit/ibc_middleware.go"
  for part in RL PQ; do
    sed -n "/^: <<.ZETAPHY_${part}_PATCH.\$/,/^ZETAPHY_${part}_PATCH\$/p" "$self" | sed '1d;$d' | (cd "$src" && git apply -)
  done
  (cd "$src" && go vet ./precompiles/mldsa/ ./crypto/mldsa44/ ./x/ratelimit/...)
}
if [ "${1:-}" = "--patch-source" ]; then zetaphy_patch_source "$2"; exit 0; fi

# Standard EVM contracts at their usual addresses from block 1, so wallets and
# dev tools (Foundry, Hardhat, viem, Safe) work unchanged: the CREATE2
# deployer, Multicall3, Permit2 and the Safe singleton factory. Their runtime
# code is cosmos/evm v0.7.3's x/vm/types.DefaultPreinstalls (the list is at the
# end of this file); EIP-2935 is left out, as the chain installs it itself
# (ensureBlockHashHistory). Goes in app_state.evm.preinstalls; also used by
# zetaphy-network/scripts/devnet.sh: setup-node.sh --preinstalls
zetaphy_preinstalls() {
  sed -n "/^: <<.ZETAPHY_PREINSTALLS.\$/,/^ZETAPHY_PREINSTALLS\$/p" "$(readlink -f "$0")" | sed '1d;$d'
}
if [ "${1:-}" = "--preinstalls" ]; then zetaphy_preinstalls; exit 0; fi

# Commands run as the node user from its own home: started from another
# user's home (e.g. ~/setup.sh in Cloud Shell) the node binary cannot create
# its working files there ("mkdir data: permission denied").
SELF=$(readlink -f "$0")
node_home_dir() { cd "/home/$NODE_USER" 2>/dev/null || cd /tmp; }

# bash setup-node.sh --become-validator <ZETAPHY>: on a synced node that
# joined with JOIN=, stake that much from its "validator" key (the faucet
# gives 10) and become a validator.
if [ "${1:-}" = "--become-validator" ]; then
  amt=${2:?amount of ZETAPHY to stake}
  node_home_dir
  [[ "$amt" =~ ^[0-9]+$ ]] || { echo "amount: whole ZETAPHY"; exit 1; }
  zv() { su -s /bin/bash "$NODE_USER" -c "$BIN $* --home $NODE_HOME"; }
  [ "$(zv status | jq -r .sync_info.catching_up)" = false ] || { echo "still syncing; try again later"; exit 1; }
  f=$(su -s /bin/bash "$NODE_USER" -c 'mktemp')
  jq -n --argjson pk "$(zv comet show-validator)" --arg a "${amt}000000000000000000$DENOM" --arg m "$MONIKER-$(hostname -s)" \
    '{pubkey:$pk,amount:$a,moniker:$m,"commission-rate":"0.1","commission-max-rate":"0.2","commission-max-change-rate":"0.01","min-self-delegation":"1"}' \
    | su -s /bin/bash "$NODE_USER" -c "cat > $f"
  zv tx staking create-validator "$f" --from validator --keyring-backend test --keyring-dir "$KEYS_DIR" \
    --chain-id "$CHAIN_ID" --gas auto --gas-adjustment 1.5 --gas-prices "1000000000$DENOM" -y
  # The ML-DSA-44 key that signs this validator's votes alongside ed25519.
  sleep 12
  zv tx pq-vote-key --from validator --keyring-backend test --keyring-dir "$KEYS_DIR" \
    --chain-id "$CHAIN_ID" --gas 600000 --gas-prices "1000000000$DENOM" -y
  exit 0
fi

# One run at a time: a second copy (started twice, or again after a lost SSH
# session) would add the same keys and stop on an "overwrite?" prompt (EOF).
exec 9>/run/zetaphy-setup.lock
flock -n 9 || { echo "setup-node.sh is already running (tail -f $LOG)"; exit 1; }
touch "$LOG" && chmod 640 "$LOG"
exec > >(tee -a "$LOG") 2>&1
step() { echo; echo "== $(date -u +%FT%TZ) $*"; }

# 1,000,000,000 ZETAPHY total (plan model B). Amounts in azetaphy.
Z=000000000000000000               # 18 zeros
REWARDS=500000000$Z                # 50% node runners + validators (released later)
SWD_AIRDROP=200000000$Z            # 20% SWD holders (snapshot later)
COMMUNITY=150000000$Z              # 15% community fund
LIQUIDITY_TOTAL=100000000$Z        # 10% liquidity & partners (pays the two test grants below)
TEAM=50000000$Z                    # 5% team: locked 1 year, then linear to year 4
VALIDATOR_GRANT=1000000$Z          # from liquidity: validator account
OWNER_GRANT=1000000$Z              # from liquidity: your MetaMask (only if set)
FAUCET_GRANT=1000000$Z             # from liquidity: testnet faucet (zetaphy_faucet, 10 per newcomer)
SELF_STAKE=500000$Z

# ---------------------------------------------------------------------------
step "1/8 packages"
# Ubuntu's automatic updates may hold the package lock for a few minutes
# (often right after a machine starts): wait for it instead of failing.
apt_get() { apt-get -o DPkg::Lock::Timeout=900 "$@"; }
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  need=""
  for p in git jq curl make gcc; do command -v "$p" >/dev/null || need=1; done
  if [ -n "$need" ]; then apt_get update -y && apt_get install -y git jq curl build-essential ca-certificates; fi
fi

step "2/8 swap (small machines need it to compile)"
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$mem_kb" -lt 6000000 ] && ! swapon --show | grep -q . && [ -z "$NO_SYSTEMD" ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

step "3/8 user"
id "$NODE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$NODE_USER"
node_home_dir
as_node() { su -s /bin/bash "$NODE_USER" -c "$*"; }

step "4/8 build zetaphyd"
if [ -n "$ZETAPHYD_BIN" ]; then
  install -m 755 "$ZETAPHYD_BIN" "$BIN"
elif [ ! -x "$BIN" ] || [ -n "${FORCE_BUILD:-}" ]; then
  # Any Go >= 1.21 can fetch the exact toolchain the source asks for (GOTOOLCHAIN),
  # verified against Go's checksum database. Ubuntu 24.04's golang-go is 1.22.
  GO=$(command -v go || true)
  [ -z "$GO" ] && [ -x /usr/local/go/bin/go ] && GO=/usr/local/go/bin/go
  if [ -z "$GO" ]; then apt_get install -y golang-go && GO=$(command -v go); fi
  minor=$("$GO" env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')
  [ "$minor" -ge 21 ] || { echo "Go $("$GO" env GOVERSION) is too old; use Ubuntu 24.04"; exit 1; }
  src="/home/${NODE_USER}/src/evm"
  as_node "rm -rf '$src' && git clone -q --depth 1 --branch '$COSMOS_EVM_TAG' https://github.com/cosmos/evm.git '$src'"
  got=$(as_node "git -C '$src' rev-parse HEAD")
  [ "$got" = "$COSMOS_EVM_COMMIT" ] || { echo "source commit $got != pinned $COSMOS_EVM_COMMIT"; exit 1; }
  goenv="PATH=$(dirname "$GO"):\$PATH GOTOOLCHAIN=go${GO_VERSION}"
  # Under 3 GB of RAM (e.g. a 1 GB free VM): one compile at a time.
  [ "$mem_kb" -lt 3000000 ] && goenv="$goenv GOFLAGS=-p=1 GOGC=50"
  # The ZETAPHY changes (zetaphy_patch_source, above), as the node user.
  install -m 644 "$SELF" /tmp/zetaphy-setup-node.sh
  as_node "cd '$src' && $goenv bash /tmp/zetaphy-setup-node.sh --patch-source '$src'"
  as_node "cd '$src' && $goenv make install"
  install -m 755 "/home/${NODE_USER}/go/bin/evmd" "$BIN"
  [ "$(as_node "cd '$src/evmd' && $goenv go list -m -f '{{.Version}}' github.com/CosmWasm/wasmvm/v3")" = "$WASMVM_VERSION" ] || { echo "wasmvm is not $WASMVM_VERSION"; exit 1; }
  wasmvm_so="$(as_node "cd '$src/evmd' && $goenv go list -m -f '{{.Dir}}' github.com/CosmWasm/wasmvm/v3")/internal/api/libwasmvm.$(uname -m).so"
fi
# libwasmvm, the CosmWasm VM the binary links (stage 7), in /usr/local/lib:
# the copy in the wasmvm Go module just built against (go.sum verified it),
# or for a prebuilt binary (ZETAPHYD_BIN) wasmvm's own release file; either
# way checked against the pin at the top.
arch=$(uname -m); want_var="WASMVM_SO_SHA256_$arch"; want=${!want_var:-}
[ -n "$want" ] || { echo "CosmWasm: no libwasmvm for $arch (x86_64 or aarch64 only)"; exit 1; }
lib="/usr/local/lib/libwasmvm.$arch.so"
if ! echo "$want  $lib" | sha256sum -c --quiet - 2>/dev/null; then
  if [ -z "${wasmvm_so:-}" ]; then
    wasmvm_so=$(mktemp)
    curl -fsSL "https://github.com/CosmWasm/wasmvm/releases/download/$WASMVM_VERSION/libwasmvm.$arch.so" -o "$wasmvm_so"
  fi
  echo "$want  $wasmvm_so" | sha256sum -c --quiet - || { echo "libwasmvm hash mismatch"; exit 1; }
  install -m 644 "$wasmvm_so" "$lib" && ldconfig
fi
"$BIN" version
su -s /bin/bash "$NODE_USER" -c "$BIN q wasm libwasmvm-version" # the VM loads (CosmWasm)

# Runs the chain binary as the node user with the right home.
z() { su -s /bin/bash "$NODE_USER" -c "$BIN $*"; }
K="--keyring-backend test --keyring-dir $KEYS_DIR"

# A genesis that never got its validator (gentx) on a node that never made a
# block is from a run that stopped part-way: set it aside and redo step 5.
if [ -f "$NODE_HOME/config/genesis.json" ] && [ ! -d "$NODE_HOME/data/blockstore.db" ] \
  && [ "$(jq -r '"\(.initial_height // 1)/\(.app_state.genutil.gen_txs // [] | length)"' "$NODE_HOME/config/genesis.json" 2>/dev/null)" = 1/0 ]; then
  mv "$NODE_HOME/config/genesis.json" "$NODE_HOME/config/genesis.json.unfinished-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "genesis from an unfinished run moved aside"
fi
if [ ! -f "$NODE_HOME/config/genesis.json" ]; then
  step "5/8 keys and genesis"
  # Keys left by a run that stopped before genesis was written have no coins
  # and no chain; set them aside (not deleted) and start this step afresh.
  if [ -d "$KEYS_DIR" ] && [ -n "$(ls -A "$KEYS_DIR")" ]; then
    mv "$KEYS_DIR" "$KEYS_DIR.unfinished-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "keys from an unfinished run moved aside"
  fi
  as_node "mkdir -p '$KEYS_DIR' && chmod 700 '$KEYS_DIR'"
  backup="$KEYS_DIR/MNEMONICS-KEEP-SECRET.txt"
  as_node "umask 077 && : > '$backup'"
fi
if [ ! -f "$NODE_HOME/config/genesis.json" ] && [ -n "$JOIN" ]; then
  # Join: a full node of that chain; --become-validator later if wanted.
  out=$(z keys add validator $K --algo eth_secp256k1 --home "$NODE_HOME" --output json)
  echo "validator $(echo "$out" | jq -r .mnemonic)" | as_node "cat >> '$backup'"
  [ "$MONIKER" = zetaphy-validator-0 ] && MONIKER="zetaphy-$(hostname -s)"
  z init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME" >/dev/null
  z config set client chain-id "$CHAIN_ID" --home "$NODE_HOME"
  as_node "curl -fsS 'https://$JOIN/zetaphy/genesis.json' -o '$NODE_HOME/config/genesis.json' && curl -fsS 'https://$JOIN/zetaphy/peer' -o '$NODE_HOME/config/seed-peer'"
  z genesis validate-genesis --home "$NODE_HOME"
  [ "$(jq -r .chain_id "$NODE_HOME/config/genesis.json")" = "$CHAIN_ID" ] || { echo "$JOIN is not on $CHAIN_ID"; exit 1; }
elif [ ! -f "$NODE_HOME/config/genesis.json" ]; then
  for name in validator rewards swd-airdrop community liquidity team faucet; do
    out=$(z keys add "$name" $K --algo eth_secp256k1 --home "$NODE_HOME" --output json)
    echo "$name $(echo "$out" | jq -r .mnemonic)" | as_node "cat >> '$backup'"
  done
  addr() { z keys show "$1" -a $K --home "$NODE_HOME"; }

  z init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME" >/dev/null
  z config set client chain-id "$CHAIN_ID" --home "$NODE_HOME"
  G="$NODE_HOME/config/genesis.json"
  jqg() { as_node "jq '$1' '$G' > '$G.tmp' && mv '$G.tmp' '$G'"; }

  jqg ".app_state.staking.params.bond_denom=\"$DENOM\""
  jqg ".app_state.gov.params.min_deposit[0].denom=\"$DENOM\" | .app_state.gov.params.expedited_min_deposit[0].denom=\"$DENOM\""
  # Deposit to open a proposal: 1,000 ZETAPHY (5,000 expedited). The SDK
  # default is a few atto-units, which would let anyone spam proposals.
  jqg '.app_state.gov.params.min_deposit[0].amount="1000000000000000000000" | .app_state.gov.params.expedited_min_deposit[0].amount="5000000000000000000000"'
  jqg ".app_state.evm.params.evm_denom=\"$DENOM\" | .app_state.mint.params.mint_denom=\"$DENOM\""
  # Fixed supply: no inflation. Rewards come from the rewards pool in a later step.
  jqg '.app_state.mint.minter.inflation="0.000000000000000000" | .app_state.mint.params.inflation_rate_change="0.000000000000000000" | .app_state.mint.params.inflation_max="0.000000000000000000" | .app_state.mint.params.inflation_min="0.000000000000000000"'
  jqg ".app_state.bank.denom_metadata=[{\"description\":\"ZETAPHY Chain native token (testnet)\",\"denom_units\":[{\"denom\":\"$DENOM\",\"exponent\":0,\"aliases\":[\"attozetaphy\"]},{\"denom\":\"zetaphy\",\"exponent\":18,\"aliases\":[]}],\"base\":\"$DENOM\",\"display\":\"zetaphy\",\"name\":\"ZETAPHY\",\"symbol\":\"ZETAPHY\",\"uri\":\"\",\"uri_hash\":\"\"}]"
  # Sorted ascending (genesis validation requires it); 0x...0900 = ML-DSA (stage 5).
  jqg '.app_state.evm.params.active_static_precompiles=["0x0000000000000000000000000000000000000100","0x0000000000000000000000000000000000000400","0x0000000000000000000000000000000000000800","0x0000000000000000000000000000000000000801","0x0000000000000000000000000000000000000802","0x0000000000000000000000000000000000000803","0x0000000000000000000000000000000000000804","0x0000000000000000000000000000000000000805","0x0000000000000000000000000000000000000806","0x0000000000000000000000000000000000000807","0x0000000000000000000000000000000000000900"]'
  jqg ".app_state.erc20.native_precompiles=[\"0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE\"] | .app_state.erc20.token_pairs=[{contract_owner:1,erc20_address:\"0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE\",denom:\"$DENOM\",enabled:true}]"
  jqg '.consensus.params.block.max_gas="30000000" | .consensus.params.abci.vote_extensions_enable_height="1"'
  # Price a signature in simulate the same as the real check (eth_secp256k1
  # costs 21000). With the SDK default of 1000, wallets that simulate before
  # the account has a public key (Keplr) under-estimate gas by ~20000.
  jqg '.app_state.auth.params.sig_verify_cost_secp256k1="21000"'
  # Testnet: short votes so upgrade proposals can be tried quickly.
  jqg '.app_state.gov.params.voting_period="600s" | .app_state.gov.params.expedited_voting_period="300s" | .app_state.gov.params.max_deposit_period="600s"'
  # ZETAPHY v2 features (prevrandao, BLOCKHASH history, dEaD burn, proposer's
  # own certificate entry) from block 1 of a new chain: key 08 of
  # app_state.zetaphypq = activation height (`zetaphyd init` writes it too).
  # A chain already running turns them on with the "zetaphy-v2" upgrade.
  # EIP-2935 serves 8191 blocks; the EVM keeper's ring must match.
  # Key 0f = the security core (Q-day, threat gate, IBC hold; all off until
  # voted on) from block 1; a running chain gets it with "zetaphy-v3".
  jqg '.app_state.zetaphypq = (((.app_state.zetaphypq // []) | map(select(.key != "08" and .key != "0f" and .key != "20"))) + [{"key":"08","value":"0000000000000001"},{"key":"0f","value":"0000000000000001"},{"key":"20","value":"0000000000000001"}]) | .app_state.evm.params.history_serve_window = "8191"'
  # CosmWasm (stage 7): contract code is stored by a governance vote only
  # (gov.sh wasm-store); anyone instantiates it. `zetaphyd init` writes the
  # same; set here so it is explicit.
  jqg '.app_state.wasm.params = {"code_upload_access":{"permission":"Nobody","addresses":[]},"instantiate_default_permission":"Everybody"}'
  # Standard contracts (CREATE2 deployer, Multicall3, Permit2, Safe factory).
  pre=$(as_node mktemp) && zetaphy_preinstalls | as_node "cat > '$pre'"
  as_node "jq --slurpfile p '$pre' '.app_state.evm.preinstalls = \$p[0]' '$G' > '$G.tmp' && mv '$G.tmp' '$G' && rm -f '$pre'"

  # amounts exceed 64-bit integers, so do the arithmetic in python
  liquidity=$(python3 -c "print($LIQUIDITY_TOTAL - $VALIDATOR_GRANT)")
  z genesis add-genesis-account "$(addr validator)" "${VALIDATOR_GRANT}${DENOM}" --home "$NODE_HOME"
  if [ -n "$OWNER_EVM_ADDRESS" ]; then
    owner=$(z debug addr "$OWNER_EVM_ADDRESS" --home "$NODE_HOME" | awk '/Bech32 Acc/ {print $3}')
    [ -n "$owner" ] || { echo "OWNER_EVM_ADDRESS is not a valid 0x address"; exit 1; }
    z genesis add-genesis-account "$owner" "${OWNER_GRANT}${DENOM}" --home "$NODE_HOME"
    liquidity=$(python3 -c "print($liquidity - $OWNER_GRANT)")
  fi
  z genesis add-genesis-account "$(addr rewards)" "${REWARDS}${DENOM}" --home "$NODE_HOME"
  z genesis add-genesis-account "$(addr swd-airdrop)" "${SWD_AIRDROP}${DENOM}" --home "$NODE_HOME"
  z genesis add-genesis-account "$(addr community)" "${COMMUNITY}${DENOM}" --home "$NODE_HOME"
  z genesis add-genesis-account "$(addr faucet)" "${FAUCET_GRANT}${DENOM}" --home "$NODE_HOME"
  liquidity=$(python3 -c "print($liquidity - $FAUCET_GRANT)")
  z genesis add-genesis-account "$(addr liquidity)" "${liquidity}${DENOM}" --home "$NODE_HOME"
  # The faucet's key, for the node itself (zetaphy_faucet); testnet only.
  z keys unsafe-export-eth-key faucet $K --home "$NODE_HOME" 2>/dev/null | as_node "umask 077 && cat > '$NODE_HOME/config/faucet.key'"
  now=$(date +%s)
  z genesis add-genesis-account "$(addr team)" "${TEAM}${DENOM}" --home "$NODE_HOME" \
    --vesting-amount "${TEAM}${DENOM}" --vesting-start-time $((now + 365*86400)) --vesting-end-time $((now + 4*365*86400))

  total=$(as_node "jq -r '[.app_state.bank.balances[].coins[] | select(.denom==\"$DENOM\") | .amount | tonumber] | add' '$G'")
  python3 - "$total" <<'PY'
import sys
t = int(float(sys.argv[1]))
assert abs(t - 10**27) < 10**12, f"genesis supply {t} != 1,000,000,000 ZETAPHY"
PY

  z genesis gentx validator "${SELF_STAKE}${DENOM}" $K --chain-id "$CHAIN_ID" --home "$NODE_HOME" \
    --gas-prices "1000000000${DENOM}" --moniker "$MONIKER"
  z genesis collect-gentxs --home "$NODE_HOME" >/dev/null
  z genesis validate-genesis --home "$NODE_HOME"

fi

# Settings are re-applied on every run, so running the script again repairs them.
if [ "$LOW_EGRESS" = auto ]; then
  mt=$(curl -fsS -m 3 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null || true)
  case "$mt" in */e2-micro) LOW_EGRESS=1 ;; *) LOW_EGRESS=0 ;; esac
fi
[[ "$EGRESS_LIMIT_MB" =~ ^[0-9]+$ ]] || EGRESS_LIMIT_MB=800
[ "$LOW_EGRESS" = 1 ] && echo "low-egress mode: few peers, gzip, public RPC paused above ${EGRESS_LIMIT_MB} MB sent per month"

step "6/8 node settings"
C="$NODE_HOME/config/config.toml"; A="$NODE_HOME/config/app.toml"
# ML-DSA-44 vote key (back it up with priv_validator_key.json).
V="$NODE_HOME/config/pq_vote_key.seed"
[ -f "$V" ] || as_node "umask 077 && od -An -tx1 -N32 /dev/urandom | tr -d ' \\n' > '$V'"
as_node "sed -i -E 's/^timeout_commit = .*/timeout_commit = \"5s\"/' '$C'"            # ~5 s blocks
# Cosmos EVM's own mempool requires CometBFT to hand transactions to the app.
as_node "sed -i -E 's/^type = \"flood\"/type = \"app\"/' '$C'"
as_node "sed -i -E 's/^minimum-gas-prices = .*/minimum-gas-prices = \"1000000000$DENOM\"/' '$A'"
as_node "sed -i -E 's/^evm-chain-id = .*/evm-chain-id = $EVM_CHAIN_ID/' '$A'"
# Keep ~6 days of state, not all of it: disk stays small on free VMs.
as_node "sed -i -E 's/^pruning = .*/pruning = \"custom\"/; s/^pruning-keep-recent = .*/pruning-keep-recent = \"100000\"/; s/^pruning-interval = .*/pruning-interval = \"10\"/' '$A'"
[ "$mem_kb" -lt 3000000 ] && as_node "sed -i -E 's/^iavl-cache-size = .*/iavl-cache-size = 50000/' '$A'"
# CosmWasm: contract queries capped at 3M gas; the VM's module cache at
# 100 MiB, 32 MiB under 3 GB of RAM (it holds only contracts in use).
wcache=100; [ "$mem_kb" -lt 3000000 ] && wcache=32
as_node "grep -q '^\[wasm\]' '$A' || printf '\n[wasm]\nquery_gas_limit = 3000000\nmemory_cache_size = 100\n' >> '$A'"
as_node "sed -i -E 's/^memory_cache_size = .*/memory_cache_size = $wcache/' '$A'"
if [ "$LOW_EGRESS" = 1 ]; then
  # Few peers and a 256 KB/s ceiling per peer: other nodes still sync, slowly.
  as_node "sed -i -E 's/^max_num_inbound_peers = .*/max_num_inbound_peers = 4/; s/^max_num_outbound_peers = .*/max_num_outbound_peers = 2/; s/^send_rate = .*/send_rate = 262144/' '$C'"
fi
# A joined node dials the node it joined.
if [ -f "$NODE_HOME/config/seed-peer" ]; then
  peer=$(tr -cd 'a-f0-9@.:' < "$NODE_HOME/config/seed-peer")
  as_node "sed -i -E 's/^persistent_peers = .*/persistent_peers = \"$peer\"/' '$C'"
fi
# Public: P2P 26656, and https (Caddy -> rpc-guard) for the RPCs.
# Local only: EVM JSON-RPC 8545 (unless PUBLIC_HTTP_RPC=1), CometBFT RPC
# 26657, REST 1317, gRPC 9090. Wallets (MetaMask, Keplr, Leap, Cosmostation)
# reach them through Caddy (https).
rpc_bind=127.0.0.1; [ "$PUBLIC_HTTP_RPC" = 1 ] && rpc_bind=0.0.0.0
as_node "python3 - '$A' '$LOW_EGRESS' '$rpc_bind' <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
sec = re.search(r'(?ms)^\[json-rpc\].*?(?=^\[|\Z)', s).group(0)
new = re.sub(r'(?m)^enable = .*', 'enable = true', sec)
new = re.sub(r'(?m)^address = .*', 'address = \"' + sys.argv[3] + ':8545\"', new)
new = re.sub(r'(?m)^ws-address = .*', 'ws-address = \"127.0.0.1:8546\"', new)
new = re.sub(r'(?m)^api = .*', 'api = \"eth,net,web3,txpool,zetaphy\"', new)
# The port is public: keep one caller from tying the node up.
limits = {
    'allow-insecure-unlock': 'false',         # no account unlocking over RPC
    'gas-cap': '30000000',                    # eth_call / estimateGas gas ceiling = block max_gas (big deploys, e.g. a token + DAO, need ~12.5M)
    'evm-timeout': '\"3s\"',                  # eth_call wall-clock ceiling
    'logs-cap': '2000',                       # eth_getLogs results per call
    'block-range-cap': '2000',                # eth_getLogs block span per call
    'max-open-connections': '200',            # 0 meant unlimited
    'batch-request-limit': '50',
    'batch-response-max-size': '5000000',
    'http-body-limit': '1048576',             # 1 MB requests
}
if sys.argv[2] == '1':   # small replies: the free VM pays for every byte sent
    limits.update({'logs-cap': '500', 'block-range-cap': '500', 'batch-request-limit': '20', 'batch-response-max-size': '1000000'})
for k, v in limits.items():
    new = re.sub(r'(?m)^' + re.escape(k) + r' = .*', k + ' = ' + v, new)
s = s.replace(sec, new)
api = re.search(r'(?ms)^\[api\].*?(?=^\[|\Z)', s).group(0)
new = re.sub(r'(?m)^enable = .*', 'enable = true', api)
new = re.sub(r'(?m)^address = .*', 'address = \"tcp://127.0.0.1:1317\"', new)
new = re.sub(r'(?m)^enabled-unsafe-cors = .*', 'enabled-unsafe-cors = false', new)  # Caddy adds CORS
open(p, 'w').write(s.replace(api, new))
PY"

step "7/8 service"
START="$BIN start --home $NODE_HOME --chain-id $CHAIN_ID --json-rpc.api eth,net,web3,txpool,zetaphy"
# Use systemd only when it is actually running (it may be installed but off,
# e.g. on WSL without systemd=true); otherwise start the node in the background.
if [ -z "$NO_SYSTEMD" ] && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/zetaphyd.service <<UNIT
[Unit]
Description=ZETAPHY testnet node
After=network-online.target
Wants=network-online.target

[Service]
User=$NODE_USER
# The binary resolves a few paths from the working directory (upstream evmd
# reads data/upgrade-info.json while building its CLI); "/" is not writable.
WorkingDirectory=/home/$NODE_USER
ExecStart=$START
Restart=always
RestartSec=5
LimitNOFILE=65535
Environment=GOMEMLIMIT=$((mem_kb * 6 / 10 / 1024))MiB
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  # restart, not just start: a second run (new binary or settings) takes effect
  systemctl enable zetaphyd && systemctl restart zetaphyd
else
  as_node "cd /home/$NODE_USER && nohup $START > /home/$NODE_USER/zetaphyd.log 2>&1 &"
fi

# The genesis validator registers its vote key once the chain runs.
if [ -z "$JOIN" ] && [ ! -f "$V.registered" ]; then
  for _ in $(seq 1 60); do
    h=$(z status --home "$NODE_HOME" 2>/dev/null | jq -r '.sync_info.latest_block_height // 0' 2>/dev/null || true)
    [ "${h:-0}" -ge 2 ] 2>/dev/null && break; sleep 2
  done
  z tx pq-vote-key --from validator $K --home "$NODE_HOME" --chain-id "$CHAIN_ID" --gas 600000 \
    --gas-prices "1000000000$DENOM" -y -o json | grep -q '"code":0' && as_node "touch '$V.registered'" || echo "vote key not registered yet; run setup-node.sh again"
fi

step "8/8 firewall and https"
# Oracle's Ubuntu images reject everything except SSH in iptables; open the public ports.
if command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  ports="26656 80 443"; [ "$PUBLIC_HTTP_RPC" = 1 ] && ports="8545 $ports"
  for port in $ports; do
    iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport $port -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save || true
fi

ip=$(curl -fsS -m 5 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')
# HTTPS in front of 8545, for pages served over https (the web wallet): Caddy
# from Ubuntu's archive gets a free Let's Encrypt certificate for
# <ip>.sslip.io, a free DNS name that points at the IP. Not fatal if it fails.
host="${ip//./-}.sslip.io"
pubhost="${PUBLIC_HOST:-$host}"   # the name wallets are given
# It also publishes what another machine needs to JOIN this chain.
pub=/var/lib/zetaphy-public
mkdir -p $pub && install -m 644 "$NODE_HOME/config/genesis.json" $pub/ && install -m 644 "$SELF" $pub/setup-node.sh
echo "$(z comet show-node-id --home "$NODE_HOME")@$ip:26656" > $pub/peer
# Wallet settings for this node, for one-click "add network" buttons.
jq -n --arg h "https://$pubhost" --arg c "$CHAIN_ID" --arg d "$DENOM" '
  {denom: $d, cur: {coinDenom: "ZETAPHY", coinMinimalDenom: $d, coinDecimals: 18}} as $x |
  {chainId: $c, chainName: "ZETAPHY Testnet", rpc: ($h + "/rpc"), rest: ($h + "/rest"), bip44: {coinType: 60},
   bech32Config: {bech32PrefixAccAddr: "zetaphy", bech32PrefixAccPub: "zetaphypub", bech32PrefixValAddr: "zetaphyvaloper",
     bech32PrefixValPub: "zetaphyvaloperpub", bech32PrefixConsAddr: "zetaphyvalcons", bech32PrefixConsPub: "zetaphyvalconspub"},
   currencies: [$x.cur], stakeCurrency: $x.cur,
   feeCurrencies: [$x.cur + {gasPriceStep: {low: 1000000000, average: 2000000000, high: 4000000000}}],
   features: ["eth-address-gen", "eth-key-sign", "eth-secp256k1-cosmos", "force-enable-evm-ledger"], isTestnet: true, evm: {chainId: '"$EVM_CHAIN_ID"', rpc: $h}}' > $pub/keplr.json
jq -n --arg h "https://$pubhost" --arg id "$(printf '0x%x' "$EVM_CHAIN_ID")" \
  '{chainId: $id, chainName: "ZETAPHY Testnet", nativeCurrency: {name: "ZETAPHY", symbol: "ZTPHY", decimals: 18}, rpcUrls: [$h]}' > $pub/evm-chain.json
chmod 644 $pub/keplr.json $pub/evm-chain.json
if [ -z "$NO_SYSTEMD" ] && [ -d /run/systemd/system ] && [[ "$ip" =~ ^[0-9.]+$ ]]; then
  # https://$host/        EVM JSON-RPC (MetaMask and other EVM wallets)
  # https://$host/rpc/    CometBFT RPC   } Keplr, Leap, Cosmostation
  # https://$host/rest/   Cosmos REST    }
  # wss://$host/ws        EVM JSON-RPC over WebSocket (eth_subscribe: new blocks, logs)
  # https://$host/zetaphy/  files: genesis, peer, setup script, wallet configs
  # The two RPCs go through rpc-guard (zetaphyd rpc-guard): allowed methods
  # only (no websocket on /rpc), requests per minute and faucet grants per IP.
  cat > /etc/systemd/system/zetaphy-rpc-guard.service <<UNIT
[Unit]
Description=ZETAPHY public RPC filter (Caddy -> rpc-guard -> node)
After=zetaphyd.service

[Service]
User=$NODE_USER
WorkingDirectory=/home/$NODE_USER
ExecStart=$BIN rpc-guard --comet-listen 127.0.0.1:26667 --evm-listen 127.0.0.1:8547 --comet http://127.0.0.1:26657 --evm http://127.0.0.1:8545
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable zetaphy-rpc-guard >/dev/null 2>&1 && systemctl restart zetaphy-rpc-guard \
    || echo "rpc-guard did not start: systemctl status zetaphy-rpc-guard"
  { apt_get install -y caddy >/dev/null && cat > /etc/caddy/Caddyfile <<CADDY
$host${PUBLIC_HOST:+, $PUBLIC_HOST} {
	header ?Access-Control-Allow-Origin *
	header ?Access-Control-Allow-Headers "Content-Type"
	header ?Access-Control-Allow-Methods "GET, POST, OPTIONS"
	encode zstd gzip
	route {
		@preflight method OPTIONS
		respond @preflight 204
		@heavy path /rpc/dump_consensus_state* /rpc/unsafe* /rpc/genesis*
		respond @heavy 403
		handle_path /zetaphy/* {
			root * $pub
			file_server
		}
		handle_path /rest/* {
			reverse_proxy 127.0.0.1:1317
		}
		handle_path /rpc/* {
			reverse_proxy 127.0.0.1:26667
		}
		handle /ws {
			rewrite * /
			reverse_proxy 127.0.0.1:8546
		}
		reverse_proxy 127.0.0.1:8547
	}
}
CADDY
    systemctl restart caddy; } || echo "https setup failed; the RPC still works over http"
fi
# Low-egress guard: counts bytes sent this month; near the limit it stops
# Caddy and closes 8545 (the chain keeps running), and reopens next month.
if [ "$LOW_EGRESS" = 1 ] && [ -z "$NO_SYSTEMD" ] && [ -d /run/systemd/system ]; then
  cat > /usr/local/bin/zetaphy-egress-guard <<GUARD
#!/bin/bash
set -u
LIMIT=\$(( $EGRESS_LIMIT_MB * 1048576 ))
S=/var/lib/zetaphy-egress; mkdir -p \$S
ifc=\$(ip route show default | awk '{print \$5; exit}')
now=\$(cat /sys/class/net/\$ifc/statistics/tx_bytes)
month=\$(date -u +%Y-%m)
read -r m last used 2>/dev/null < \$S/state || { m=\$month; last=\$now; used=0; }
[[ "\$m\$last\$used" =~ ^[0-9-]+\$ ]] || { m=\$month; last=\$now; used=0; }
if [ "\$now" -ge "\$last" ]; then used=\$(( used + now - last )); else used=\$(( used + now )); fi  # counter resets on reboot
if [ "\$m" != "\$month" ]; then m=\$month; used=0; fi
echo "\$m \$now \$used" > \$S/state
echo "\$(date -u +%FT%TZ) sent this month: \$(( used / 1048576 )) MB of $EGRESS_LIMIT_MB MB" > \$S/status
# The rule closes 8545 to the outside only (! -i lo): the node's own tools, rpc-guard and
# zetaphy-validator reach it on 127.0.0.1. The rule of older versions blocked loopback too:
# it is removed on every run.
for ipt in iptables ip6tables; do
  command -v \$ipt >/dev/null || continue
  while \$ipt -D INPUT -p tcp --dport 8545 -j DROP 2>/dev/null; do :; done
done
if [ "\$used" -ge "\$LIMIT" ]; then
  # applied on every run: a reboot drops the iptables rule and starts Caddy again
  systemctl stop caddy 2>/dev/null
  for ipt in iptables ip6tables; do
    command -v \$ipt >/dev/null || continue
    \$ipt -C INPUT ! -i lo -p tcp --dport 8545 -j DROP 2>/dev/null || \$ipt -I INPUT 1 ! -i lo -p tcp --dport 8545 -j DROP
  done
  [ -f \$S/paused ] || { touch \$S/paused; logger -t zetaphy-egress "public RPC paused: \$(( used / 1048576 )) MB sent this month"; }
elif [ -f \$S/paused ]; then
  for ipt in iptables ip6tables; do
    command -v \$ipt >/dev/null || continue
    \$ipt -D INPUT ! -i lo -p tcp --dport 8545 -j DROP 2>/dev/null
  done
  systemctl start caddy 2>/dev/null; rm -f \$S/paused
  logger -t zetaphy-egress "public RPC reopened for \$month"
fi
GUARD
  chmod 755 /usr/local/bin/zetaphy-egress-guard
  cat > /etc/systemd/system/zetaphy-egress-guard.service <<UNIT
[Unit]
Description=ZETAPHY low-egress guard
[Service]
Type=oneshot
ExecStart=/usr/local/bin/zetaphy-egress-guard
UNIT
  cat > /etc/systemd/system/zetaphy-egress-guard.timer <<UNIT
[Unit]
Description=ZETAPHY low-egress guard every 10 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload && systemctl enable --now zetaphy-egress-guard.timer
fi
# A joined node asks the faucet of the node it joined for 10 ZETAPHY.
if [ -n "$JOIN" ]; then
  me=$(z debug addr "$(z keys show validator -a $K --home "$NODE_HOME")" --home "$NODE_HOME" | awk '/Address hex/ {print $3}')
  curl -fsS "https://$JOIN" -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zetaphy_faucet\",\"params\":[\"$me\"]}" || true
fi
cat <<INFO | tee "/home/$NODE_USER/NODE-INFO.txt"

ZETAPHY testnet node is starting.
  Chain ID (Cosmos):   $CHAIN_ID
  Chain ID (EVM):      $EVM_CHAIN_ID
  MetaMask RPC URL:    https://$pubhost  (needs ports 80 and 443 open)
  WebSocket RPC:       wss://$pubhost/ws  (eth_subscribe)
  Keplr / Leap:        RPC https://$pubhost/rpc  REST https://$pubhost/rest
                       (chain settings: https://$pubhost/zetaphy/keplr.json)
  Others join with:    JOIN=$host in setup-node.sh, then --become-validator 9
  Currency symbol:     ZETAPHY
  Genesis keys:        $KEYS_DIR (testnet only; MNEMONICS-KEEP-SECRET.txt)
  Back up:             $NODE_HOME/config/priv_validator_key.json and pq_vote_key.seed
                       (and the words in $KEYS_DIR/MNEMONICS-KEEP-SECRET.txt), offline
  Then lock it down:   sudo zetaphy-validator secure   (deletes the plaintext words file once you
                       confirm the backup; SSH keys only; security updates; asks first). Where
                       zetaphy-validator is not installed (the chain's first node):
                       curl -fsSL https://raw.githubusercontent.com/pospos191-alt/swd-amm/main/zetaphy-chain/join-validator.sh -o /tmp/zv && sudo bash /tmp/zv secure
  Logs:                journalctl -u zetaphyd -f
INFO

exit 0

# ---- ZETAPHY patches (applied in step 4; never executed as shell) ----
: <<'ZETAPHY_RL_PATCH'
diff --git a/x/ratelimit/ibc_middleware.go b/x/ratelimit/ibc_middleware.go
index c7e4cb2..5d6a8ab 100644
--- a/x/ratelimit/ibc_middleware.go
+++ b/x/ratelimit/ibc_middleware.go
@@ -18,16 +18,34 @@ var _ porttypes.Middleware = (*IBCMiddleware)(nil)
 
 type IBCMiddleware struct {
 	app    porttypes.IBCModule
-	keeper keeper.Keeper
+	keeper *keeper.Keeper
 }
 
-func NewIBCMiddleware(k keeper.Keeper, app porttypes.IBCModule) IBCMiddleware {
-	return IBCMiddleware{
+// NewIBCMiddleware wraps app. ZETAPHY port to ibc-go v11: the keeper is held
+// by pointer so SetICS4Wrapper reaches the keeper the packets go through.
+func NewIBCMiddleware(k *keeper.Keeper, app porttypes.IBCModule) *IBCMiddleware {
+	return &IBCMiddleware{
 		app:    app,
 		keeper: k,
 	}
 }
 
+// SetICS4Wrapper sets the wrapper below this middleware (core IBC for sends).
+func (im *IBCMiddleware) SetICS4Wrapper(wrapper porttypes.ICS4Wrapper) {
+	if wrapper == nil {
+		panic("ICS4Wrapper cannot be nil")
+	}
+	im.keeper.SetICS4Wrapper(wrapper)
+}
+
+// SetUnderlyingApplication sets the application this middleware wraps.
+func (im *IBCMiddleware) SetUnderlyingApplication(app porttypes.IBCModule) {
+	if app == nil {
+		panic("underlying application cannot be nil")
+	}
+	im.app = app
+}
+
 // OnChanOpenInit implements the IBCMiddleware interface
 func (im *IBCMiddleware) OnChanOpenInit(ctx sdk.Context,
 	order channeltypes.Order,
@@ -136,9 +154,13 @@ func (im *IBCMiddleware) OnAcknowledgementPacket(
 	acknowledgement []byte,
 	relayer sdk.AccAddress,
 ) error {
-	if err := im.keeper.AcknowledgeRateLimitedPacket(ctx, packet, acknowledgement); err != nil {
-		im.keeper.Logger(ctx).Error(fmt.Sprintf("ICS20 RateLimited OnAckPacket failed: %s", err.Error()))
-		return err
+	// A packet that is not ICS-20 data was never counted on send: leave it
+	// to the application below (ZETAPHY port).
+	if _, perr := keeper.ParsePacketInfo(packet, types.PACKET_SEND); perr == nil {
+		if err := im.keeper.AcknowledgeRateLimitedPacket(ctx, packet, acknowledgement); err != nil {
+			im.keeper.Logger(ctx).Error(fmt.Sprintf("ICS20 RateLimited OnAckPacket failed: %s", err.Error()))
+			return err
+		}
 	}
 	return im.app.OnAcknowledgementPacket(ctx, channelVersion, packet, acknowledgement, relayer)
 }
@@ -150,9 +172,11 @@ func (im *IBCMiddleware) OnTimeoutPacket(
 	packet channeltypes.Packet,
 	relayer sdk.AccAddress,
 ) error {
-	if err := im.keeper.TimeoutRateLimitedPacket(ctx, packet); err != nil {
-		im.keeper.Logger(ctx).Error(fmt.Sprintf("ICS20 RateLimited OnTimeoutPacket failed: %s", err.Error()))
-		return err
+	if _, perr := keeper.ParsePacketInfo(packet, types.PACKET_SEND); perr == nil {
+		if err := im.keeper.TimeoutRateLimitedPacket(ctx, packet); err != nil {
+			im.keeper.Logger(ctx).Error(fmt.Sprintf("ICS20 RateLimited OnTimeoutPacket failed: %s", err.Error()))
+			return err
+		}
 	}
 	return im.app.OnTimeoutPacket(ctx, channelVersion, packet, relayer)
 }
diff --git a/x/ratelimit/keeper/keeper.go b/x/ratelimit/keeper/keeper.go
index b7db0a2..e1bf9eb 100644
--- a/x/ratelimit/keeper/keeper.go
+++ b/x/ratelimit/keeper/keeper.go
@@ -11,14 +11,12 @@ import (
 
 	"github.com/cosmos/cosmos-sdk/codec"
 	sdk "github.com/cosmos/cosmos-sdk/types"
-	paramtypes "github.com/cosmos/cosmos-sdk/x/params/types"
 )
 
 type (
 	Keeper struct {
 		cdc          codec.BinaryCodec
 		storeService store.KVStoreService
-		paramstore   paramtypes.Subspace
 		authority    string
 		Schema       collections.Schema
 
@@ -41,7 +39,6 @@ type (
 func NewKeeper(
 	cdc codec.BinaryCodec,
 	storeService store.KVStoreService,
-	ps paramtypes.Subspace,
 	authority string,
 	bankKeeper types.BankKeeper,
 	channelKeeper types.ChannelKeeper,
@@ -53,7 +50,6 @@ func NewKeeper(
 	k := Keeper{
 		cdc:          cdc,
 		storeService: storeService,
-		paramstore:   ps,
 		authority:    authority,
 
 		PendingSendPackets:    collections.NewKeySet(sb, types.PendingSendPacketsKey, "pending_send_packets", pendingPacketKeyCodec),
@@ -81,6 +77,11 @@ func (k Keeper) GetAuthority() string {
 
 // SetIBCKeepers allows us to set the relevant IBC keepers post dependency
 // injection, as IBC doesn't support dependency injection yet.
+// SetICS4Wrapper sets where rate-limited packets are sent next.
+func (k *Keeper) SetICS4Wrapper(ics4Wrapper types.ICS4Wrapper) {
+	k.ics4Wrapper = ics4Wrapper
+}
+
 func (k *Keeper) SetIBCKeepers(channelKeeper types.ChannelKeeper, clientKeeper types.ClientKeeper, ics4Wrapper types.ICS4Wrapper) {
 	k.channelKeeper = channelKeeper
 	k.clientKeeper = clientKeeper
diff --git a/x/ratelimit/keeper/params.go b/x/ratelimit/keeper/params.go
index 90a3b5c..0c15141 100644
--- a/x/ratelimit/keeper/params.go
+++ b/x/ratelimit/keeper/params.go
@@ -11,7 +11,5 @@ func (k Keeper) GetParams(ctx sdk.Context) types.Params {
 	return types.NewParams()
 }
 
-// SetParams set the params
-func (k Keeper) SetParams(ctx sdk.Context, params types.Params) {
-	k.paramstore.SetParamSet(ctx, &params)
-}
+// SetParams is a no-op: the module has no parameters (ZETAPHY port: no x/params).
+func (k Keeper) SetParams(ctx sdk.Context, params types.Params) {}
diff --git a/x/ratelimit/module.go b/x/ratelimit/module.go
index f06ec14..98f8abe 100644
--- a/x/ratelimit/module.go
+++ b/x/ratelimit/module.go
@@ -170,7 +170,8 @@ func (am AppModule) EndBlock(_ sdk.Context) ([]abci.ValidatorUpdate, error) {
 	return []abci.ValidatorUpdate{}, nil
 }
 
-// IsAppModule implements module.AppModule.
-func (am AppModule) IsAppModule() {
-	panic("unimplemented")
-}
+// IsAppModule implements the appmodule.AppModule interface.
+func (am AppModule) IsAppModule() {}
+
+// IsOnePerModuleType implements the depinject.OnePerModuleType interface.
+func (am AppModule) IsOnePerModuleType() {}
ZETAPHY_RL_PATCH
: <<'ZETAPHY_PQ_PATCH'
diff --git a/ante/ante.go b/ante/ante.go
index 4db3133..57347cd 100644
--- a/ante/ante.go
+++ b/ante/ante.go
@@ -36,6 +36,9 @@ type HandlerOptions struct {
 	// use dynamic fee checker or the cosmos-sdk default one for native transactions
 	DynamicFeeChecker bool
 	PendingTxListener PendingTxListener
+	// ZETAPHY: decorators for Cosmos txs that run right after the context
+	// setup (CosmWasm's: simulation gas cap, tx counter, gas register).
+	ExtraCosmosDecorators []sdk.AnteDecorator
 }
 
 // Validate checks if the keepers are defined
diff --git a/ante/cosmos.go b/ante/cosmos.go
index d1bad06..9cb92e6 100644
--- a/ante/cosmos.go
+++ b/ante/cosmos.go
@@ -19,13 +19,16 @@ func newCosmosAnteHandler(ctx sdk.Context, options HandlerOptions) sdk.AnteHandl
 		txFeeChecker = evmante.NewDynamicFeeChecker(&feemarketParams)
 	}
 
-	return sdk.ChainAnteDecorators(
+	decorators := []sdk.AnteDecorator{
 		cosmosante.NewRejectMessagesDecorator(), // reject MsgEthereumTxs
 		cosmosante.NewAuthzLimiterDecorator( // disable the Msg types that cannot be included on an authz.MsgExec msgs field
 			sdk.MsgTypeURL(&evmtypes.MsgEthereumTx{}),
 			sdk.MsgTypeURL(&sdkvesting.MsgCreateVestingAccount{}),
 		),
 		ante.NewSetUpContextDecorator(),
+	}
+	decorators = append(decorators, options.ExtraCosmosDecorators...) // ZETAPHY
+	return sdk.ChainAnteDecorators(append(decorators,
 		ante.NewExtensionOptionsDecorator(options.ExtensionOptionChecker),
 		ante.NewValidateBasicDecorator(),
 		ante.NewTxTimeoutHeightDecorator(),
@@ -40,5 +43,5 @@ func newCosmosAnteHandler(ctx sdk.Context, options HandlerOptions) sdk.AnteHandl
 		ante.NewSigVerificationDecorator(options.AccountKeeper, options.SignModeHandler),
 		ante.NewIncrementSequenceDecorator(options.AccountKeeper),
 		ibcante.NewRedundantRelayDecorator(options.IBCKeeper),
-	)
+	)...)
 }
diff --git a/ante/sigverify.go b/ante/sigverify.go
index 2710573..f3d89ce 100644
--- a/ante/sigverify.go
+++ b/ante/sigverify.go
@@ -4,6 +4,7 @@ import (
 	"fmt"
 
 	"github.com/cosmos/evm/crypto/ethsecp256k1"
+	"github.com/cosmos/evm/crypto/mldsa44"
 
 	errorsmod "cosmossdk.io/errors"
 
@@ -21,6 +22,10 @@ var _ authante.SignatureVerificationGasConsumer = SigVerificationGasConsumer
 
 const (
 	Secp256k1VerifyCost uint64 = 21000
+	// MLDSA44VerifyCost matches the ML-DSA-44 precompile (about 80 µs per
+	// verification); the 1312-byte key and 2420-byte signature also pay
+	// the per-byte transaction size gas.
+	MLDSA44VerifyCost uint64 = 30000
 )
 
 // SigVerificationGasConsumer is the Cosmos EVM implementation of SignatureVerificationGasConsumer. It consumes gas
@@ -45,6 +50,13 @@ func SigVerificationGasConsumer(
 		// Ethereum keys
 		meter.ConsumeGas(Secp256k1VerifyCost, "ante verify: eth_secp256k1")
 		return nil
+	case *mldsa44.PubKey:
+		// ZETAPHY post-quantum accounts
+		meter.ConsumeGas(MLDSA44VerifyCost, "ante verify: mldsa44")
+		if !pubkey.Valid() {
+			return errorsmod.Wrap(errortypes.ErrInvalidPubKey, "invalid ML-DSA-44 public key")
+		}
+		return nil
 	case *secp256k1.PubKey:
 		// Cosmos keys
 		meter.ConsumeGas(params.SigVerifyCostSecp256k1, "ante verify: secp256k1")
diff --git a/crypto/codec/amino.go b/crypto/codec/amino.go
index 7d39df3..e0f69ae 100644
--- a/crypto/codec/amino.go
+++ b/crypto/codec/amino.go
@@ -2,6 +2,7 @@ package codec
 
 import (
 	"github.com/cosmos/evm/crypto/ethsecp256k1"
+	"github.com/cosmos/evm/crypto/mldsa44"
 
 	"github.com/cosmos/cosmos-sdk/codec"
 	"github.com/cosmos/cosmos-sdk/codec/legacy"
@@ -16,6 +17,7 @@ func RegisterCrypto(cdc *codec.LegacyAmino) {
 		ethsecp256k1.PubKeyName, nil)
 	cdc.RegisterConcrete(&ethsecp256k1.PrivKey{},
 		ethsecp256k1.PrivKeyName, nil)
+	cdc.RegisterConcrete(&mldsa44.PubKey{}, mldsa44.PubKeyName, nil)
 
 	keyring.RegisterLegacyAminoCodec(cdc)
 	cryptocodec.RegisterCrypto(cdc)
diff --git a/crypto/codec/codec.go b/crypto/codec/codec.go
index 2a938cf..2f3b613 100644
--- a/crypto/codec/codec.go
+++ b/crypto/codec/codec.go
@@ -2,6 +2,7 @@ package codec
 
 import (
 	"github.com/cosmos/evm/crypto/ethsecp256k1"
+	"github.com/cosmos/evm/crypto/mldsa44"
 
 	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
 	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
@@ -10,5 +11,7 @@ import (
 // RegisterInterfaces register the Cosmos EVM key concrete types.
 func RegisterInterfaces(registry codectypes.InterfaceRegistry) {
 	registry.RegisterImplementations((*cryptotypes.PubKey)(nil), &ethsecp256k1.PubKey{})
+	// ZETAPHY: accounts controlled by a post-quantum ML-DSA-44 key alone.
+	registry.RegisterImplementations((*cryptotypes.PubKey)(nil), &mldsa44.PubKey{})
 	registry.RegisterImplementations((*cryptotypes.PrivKey)(nil), &ethsecp256k1.PrivKey{})
 }
diff --git a/crypto/mldsa44/descriptor.go b/crypto/mldsa44/descriptor.go
new file mode 100644
index 0000000..4cddc32
--- /dev/null
+++ b/crypto/mldsa44/descriptor.go
@@ -0,0 +1,52 @@
+package mldsa44
+
+import (
+	"bytes"
+	"compress/gzip"
+
+	protov2 "google.golang.org/protobuf/proto"
+	"google.golang.org/protobuf/types/descriptorpb"
+)
+
+const (
+	protoFile = "zetaphy/crypto/mldsa44/keys.proto"
+	// ProtoName is the full protobuf name; the Any type URL is "/" + ProtoName.
+	ProtoName = "zetaphy.crypto.mldsa44.PubKey"
+)
+
+// fileDescriptor is the gzipped FileDescriptorProto of keys.proto, as
+// protoc-gen-gogo would embed it. The Cosmos SDK transaction decoder needs it
+// to resolve the public key's Any type URL.
+var fileDescriptor = buildDescriptor()
+
+func buildDescriptor() []byte {
+	fd := &descriptorpb.FileDescriptorProto{
+		Name:    protov2.String(protoFile),
+		Package: protov2.String("zetaphy.crypto.mldsa44"),
+		Syntax:  protov2.String("proto3"),
+		Options: &descriptorpb.FileOptions{GoPackage: protov2.String("github.com/cosmos/evm/crypto/mldsa44")},
+		MessageType: []*descriptorpb.DescriptorProto{{
+			Name: protov2.String("PubKey"),
+			Field: []*descriptorpb.FieldDescriptorProto{{
+				Name:     protov2.String("key"),
+				JsonName: protov2.String("key"),
+				Number:   protov2.Int32(1),
+				Label:    descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
+				Type:     descriptorpb.FieldDescriptorProto_TYPE_BYTES.Enum(),
+			}},
+		}},
+	}
+	raw, err := protov2.MarshalOptions{Deterministic: true}.Marshal(fd)
+	if err != nil {
+		panic(err)
+	}
+	var buf bytes.Buffer
+	w, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
+	if _, err := w.Write(raw); err != nil {
+		panic(err)
+	}
+	if err := w.Close(); err != nil {
+		panic(err)
+	}
+	return buf.Bytes()
+}
diff --git a/crypto/mldsa44/keys.pb.go b/crypto/mldsa44/keys.pb.go
new file mode 100644
index 0000000..e86a927
--- /dev/null
+++ b/crypto/mldsa44/keys.pb.go
@@ -0,0 +1,84 @@
+// Protobuf code for zetaphy/crypto/mldsa44/keys.proto, written by hand:
+//
+//	syntax = "proto3";
+//	package zetaphy.crypto.mldsa44;
+//	message PubKey { bytes key = 1; }
+//
+// The file descriptor is built in code (descriptor.go), so no protoc
+// toolchain is needed to build the chain.
+
+package mldsa44
+
+import (
+	proto "github.com/cosmos/gogoproto/proto"
+	"google.golang.org/protobuf/encoding/protowire"
+)
+
+// PubKey is an ML-DSA-44 (FIPS 204) public key: the raw 1312-byte encoding.
+type PubKey struct {
+	Key []byte `protobuf:"bytes,1,opt,name=key,proto3" json:"key,omitempty"`
+}
+
+func (m *PubKey) Reset()      { *m = PubKey{} }
+func (*PubKey) ProtoMessage() {}
+func (*PubKey) Descriptor() ([]byte, []int) {
+	return fileDescriptor, []int{0}
+}
+
+func init() {
+	proto.RegisterType((*PubKey)(nil), ProtoName)
+	proto.RegisterFile(protoFile, fileDescriptor)
+}
+
+func (m *PubKey) Size() int {
+	if m == nil || len(m.Key) == 0 {
+		return 0
+	}
+	return protowire.SizeTag(1) + protowire.SizeBytes(len(m.Key))
+}
+
+func (m *PubKey) Marshal() ([]byte, error) {
+	if m.Size() == 0 {
+		return []byte{}, nil
+	}
+	b := protowire.AppendTag(make([]byte, 0, m.Size()), 1, protowire.BytesType)
+	return protowire.AppendBytes(b, m.Key), nil
+}
+
+func (m *PubKey) MarshalTo(dAtA []byte) (int, error) {
+	b, _ := m.Marshal()
+	return copy(dAtA, b), nil
+}
+
+// MarshalToSizedBuffer writes at the end of dAtA, as gogoproto does.
+func (m *PubKey) MarshalToSizedBuffer(dAtA []byte) (int, error) {
+	b, _ := m.Marshal()
+	return copy(dAtA[len(dAtA)-len(b):], b), nil
+}
+
+// Unmarshal reads field 1 and skips unknown fields; malformed input is an error.
+func (m *PubKey) Unmarshal(dAtA []byte) error {
+	m.Key = nil
+	for len(dAtA) > 0 {
+		num, typ, n := protowire.ConsumeTag(dAtA)
+		if n < 0 {
+			return protowire.ParseError(n)
+		}
+		dAtA = dAtA[n:]
+		if num == 1 && typ == protowire.BytesType {
+			v, n := protowire.ConsumeBytes(dAtA)
+			if n < 0 {
+				return protowire.ParseError(n)
+			}
+			m.Key = append([]byte{}, v...)
+			dAtA = dAtA[n:]
+			continue
+		}
+		n = protowire.ConsumeFieldValue(num, typ, dAtA)
+		if n < 0 {
+			return protowire.ParseError(n)
+		}
+		dAtA = dAtA[n:]
+	}
+	return nil
+}
diff --git a/crypto/mldsa44/mldsa44.go b/crypto/mldsa44/mldsa44.go
new file mode 100644
index 0000000..62d63ad
--- /dev/null
+++ b/crypto/mldsa44/mldsa44.go
@@ -0,0 +1,72 @@
+// Package mldsa44 lets an account on the chain be controlled by an
+// ML-DSA-44 (FIPS 204) key alone: a post-quantum signature on ordinary
+// Cosmos transactions, with no ECDSA key anywhere.
+//
+// The address is the first 20 bytes of sha256("zetaphy/mldsa44\x00" || public key). Signatures are
+// pure ML-DSA with an empty context over the SIGN_MODE_DIRECT sign bytes.
+package mldsa44
+
+import (
+	"bytes"
+	"crypto/sha256"
+	"crypto/subtle"
+	"fmt"
+
+	"github.com/cloudflare/circl/sign/mldsa/mldsa44"
+
+	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
+)
+
+const (
+	// KeyType is the PubKey.Type() string.
+	KeyType = "mldsa44"
+	// PubKeyName is the amino name.
+	PubKeyName = "zetaphy/PubKeyMLDSA44"
+	// PubKeySize and SignatureSize are fixed by FIPS 204 for ML-DSA-44.
+	PubKeySize    = mldsa44.PublicKeySize
+	SignatureSize = mldsa44.SignatureSize
+)
+
+var _ cryptotypes.PubKey = &PubKey{}
+
+// AddressPrefix separates ML-DSA-44 addresses from every other
+// sha256(...)[:20] address in the SDK (module accounts, ed25519, multisig).
+const AddressPrefix = "zetaphy/mldsa44\x00"
+
+// Address is sha256(AddressPrefix || key)[:20].
+func (m *PubKey) Address() cryptotypes.Address {
+	h := sha256.Sum256(append([]byte(AddressPrefix), m.Key...))
+	return cryptotypes.Address(h[:20])
+}
+
+func (m *PubKey) Bytes() []byte { return m.Key }
+
+func (m *PubKey) String() string { return fmt.Sprintf("PubKeyMLDSA44{%X}", m.Key) }
+
+func (m *PubKey) Type() string { return KeyType }
+
+func (m *PubKey) Equals(other cryptotypes.PubKey) bool {
+	o, ok := other.(*PubKey)
+	return ok && len(m.Key) == len(o.Key) && subtle.ConstantTimeCompare(m.Key, o.Key) == 1
+}
+
+// VerifySignature checks a pure ML-DSA-44 signature (empty context) over msg.
+func (m *PubKey) VerifySignature(msg, sig []byte) bool {
+	if len(m.Key) != PubKeySize || len(sig) != SignatureSize {
+		return false
+	}
+	var pk mldsa44.PublicKey
+	if pk.UnmarshalBinary(m.Key) != nil {
+		return false
+	}
+	return mldsa44.Verify(&pk, msg, nil, sig)
+}
+
+// Valid reports whether the key has the right size and decodes.
+func (m *PubKey) Valid() bool {
+	if len(m.Key) != PubKeySize {
+		return false
+	}
+	var pk mldsa44.PublicKey
+	return pk.UnmarshalBinary(bytes.Clone(m.Key)) == nil
+}
diff --git a/evmd/app.go b/evmd/app.go
index 204345c..e7cffda 100644
--- a/evmd/app.go
+++ b/evmd/app.go
@@ -14,6 +14,10 @@ import (
 	_ "github.com/ethereum/go-ethereum/eth/tracers/js"
 	_ "github.com/ethereum/go-ethereum/eth/tracers/native"
 
+	"github.com/CosmWasm/wasmd/x/wasm"
+	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
+	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
+
 	abci "github.com/cometbft/cometbft/abci/types"
 	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
 
@@ -36,6 +40,10 @@ import (
 	feemarketkeeper "github.com/cosmos/evm/x/feemarket/keeper"
 	feemarkettypes "github.com/cosmos/evm/x/feemarket/types"
 	ibccallbackskeeper "github.com/cosmos/evm/x/ibc/callbacks/keeper"
+	"github.com/cosmos/evm/x/ratelimit"
+	ratelimitkeeper "github.com/cosmos/evm/x/ratelimit/keeper"
+	ratelimittypes "github.com/cosmos/evm/x/ratelimit/types"
+	ratelimitv2 "github.com/cosmos/evm/x/ratelimit/v2"
 	"github.com/cosmos/evm/x/vm"
 	evmkeeper "github.com/cosmos/evm/x/vm/keeper"
 	vmrunner "github.com/cosmos/evm/x/vm/runner"
@@ -179,6 +187,19 @@ type EVMD struct {
 	IBCKeeper      *ibckeeper.Keeper // IBC Keeper must be a pointer in the app, so we can SetRouter on it correctly
 	TransferKeeper *transferkeeper.Keeper
 	CallbackKeeper ibccallbackskeeper.ContractKeeper
+	// ZETAPHY: per-denom, per-channel IBC flow limits set by governance
+	RateLimitKeeper *ratelimitkeeper.Keeper
+	pqHome          string // ZETAPHY: node home, for the ML-DSA vote key file
+	// ZETAPHY security core (zetaphy_security.go)
+	secPrecompile *securityPrecompile
+	// ZETAPHY v5 (zetaphy_future.go)
+	aiPrecompile     *aiPrecompile
+	immunePrecompile *immunePrecompile
+	guardPrecompile  *guardPrecompile
+	ibcHoldStack     *ibcHoldMiddleware
+	// ZETAPHY stage 7: CosmWasm contracts (zetaphy_cosmwasm.go)
+	WasmKeeper     wasmkeeper.Keeper
+	wasmNodeConfig wasmtypes.NodeConfig
 
 	// Cosmos EVM keepers
 	FeeMarketKeeper feemarketkeeper.Keeper
@@ -238,9 +259,11 @@ func NewExampleApp(
 		govtypes.StoreKey, consensusparamtypes.StoreKey,
 		upgradetypes.StoreKey, feegrant.StoreKey, evidencetypes.StoreKey, authzkeeper.StoreKey,
 		// ibc keys
-		ibcexported.StoreKey, ibctransfertypes.StoreKey,
+		ibcexported.StoreKey, ibctransfertypes.StoreKey, ratelimittypes.StoreKey,
 		// Cosmos EVM store keys
 		evmtypes.StoreKey, feemarkettypes.StoreKey, erc20types.StoreKey,
+		pqStoreKey,         // ZETAPHY: quantum locks and validator vote keys
+		wasmtypes.StoreKey, // ZETAPHY: CosmWasm contracts
 	)
 	oKeys := storetypes.NewObjectStoreKeys(banktypes.ObjectStoreKey, evmtypes.ObjectKey)
 
@@ -487,6 +510,12 @@ func NewExampleApp(
 
 	// enable virtual fee collection
 	app.EVMKeeper.EnableVirtualFeeCollection()
+	app.EVMKeeper.SetRandomFn(app.prevRandao) // ZETAPHY: block.prevrandao from the PQ certificate (zetaphy_random.go)
+	// ZETAPHY: the security precompile at 0x…0901 (zetaphy_secprecompile.go)
+	app.secPrecompile = newSecurityPrecompile(app)
+	// ZETAPHY v5 (zetaphy_future.go): AI 0x…0902, immune 0x…0903, account guard 0x…0904
+	app.aiPrecompile, app.immunePrecompile, app.guardPrecompile = newAIPrecompile(app), newImmunePrecompile(app), newGuardPrecompile(app)
+	app.EVMKeeper.SetZetaphyPrecompiles(app.zetaphyPrecompile)
 
 	app.Erc20Keeper = erc20keeper.NewKeeper(
 		keys[erc20types.StoreKey],
@@ -530,9 +559,38 @@ func NewExampleApp(
 	callbacksMiddleware.SetUnderlyingApplication(transferStack)
 	transferStack = callbacksMiddleware
 
+	// ZETAPHY: IBC rate limits (x/ratelimit, ported from ibc-apps to ibc-go
+	// v11) on top of the stack. Governance sets a cap per denom and channel
+	// (e.g. USDC from Noble) as a share of supply per time window; a packet
+	// that would go over it is refused. Sends from the transfer keeper (and
+	// the ICS-20 precompile, which uses it) pass through the same check.
+	app.RateLimitKeeper = ratelimitkeeper.NewKeeper(
+		appCodec,
+		runtime.NewKVStoreService(keys[ratelimittypes.StoreKey]),
+		authAddr,
+		app.BankKeeper,
+		app.IBCKeeper.ChannelKeeper,
+		app.IBCKeeper.ClientKeeper,
+		app.IBCKeeper.ChannelKeeper,
+	)
+	rateLimitMiddleware := ratelimit.NewIBCMiddleware(app.RateLimitKeeper, transferStack)
+	app.TransferKeeper.WithICS4Wrapper(rateLimitMiddleware)
+	transferStack = rateLimitMiddleware
+	// ZETAPHY: large inbound transfers wait (async acknowledgement) on top of
+	// everything else (zetaphy_ibchold.go).
+	app.ibcHoldStack = newIBCHoldMiddleware(app, transferStack)
+	transferStack = app.ibcHoldStack
+
 	var transferStackV2 ibcapi.IBCModule
 	transferStackV2 = transferv2.NewIBCModule(app.TransferKeeper)
 	transferStackV2 = erc20v2.NewIBCMiddleware(transferStackV2, app.Erc20Keeper)
+	rateLimitV2 := ratelimitv2.NewIBCMiddleware(*app.RateLimitKeeper, transferStackV2)
+	transferStackV2 = &rateLimitV2
+	transferStackV2 = &ibcHoldV2{app: transferStackV2, z: app} // ZETAPHY: over the hold threshold is refused on v2
+
+	// ZETAPHY: CosmWasm (zetaphy_cosmwasm.go). Its IBC ports get no route below:
+	// IBC for contracts is off; their ICS-20 transfers use the stack above.
+	app.wasmNodeConfig = app.setupWasm(appOpts, homePath)
 
 	// Create static IBC router, add transfer route, then set and seal it
 	ibcRouter := porttypes.NewRouter()
@@ -570,7 +628,7 @@ func NewExampleApp(
 		slashing.NewAppModule(appCodec, app.SlashingKeeper, app.AccountKeeper, app.BankKeeper, app.StakingKeeper, nil, app.interfaceRegistry),
 		distr.NewAppModule(appCodec, app.DistrKeeper, app.AccountKeeper, app.BankKeeper, app.StakingKeeper, nil),
 		staking.NewAppModule(appCodec, app.StakingKeeper, app.AccountKeeper, app.BankKeeper, nil),
-		upgrade.NewAppModule(app.UpgradeKeeper, app.AccountKeeper.AddressCodec()),
+		newZetaphyUpgradeModule(upgrade.NewAppModule(app.UpgradeKeeper, app.AccountKeeper.AddressCodec()), app.UpgradeKeeper), // ZETAPHY: early binaries for listed upgrades (zetaphy_upgradeguard.go)
 		evidence.NewAppModule(app.EvidenceKeeper),
 		authzmodule.NewAppModule(appCodec, app.AuthzKeeper, app.AccountKeeper, app.BankKeeper, app.interfaceRegistry),
 		consensus.NewAppModule(appCodec, app.ConsensusParamsKeeper),
@@ -579,10 +637,13 @@ func NewExampleApp(
 		ibc.NewAppModule(app.IBCKeeper),
 		ibctm.NewAppModule(tmLightClientModule),
 		transferModule,
+		ratelimit.NewAppModule(appCodec, *app.RateLimitKeeper),
 		// Cosmos EVM modules
 		vmModule,
 		feemarket.NewAppModule(app.FeeMarketKeeper),
 		erc20.NewAppModule(app.Erc20Keeper, app.AccountKeeper),
+		// ZETAPHY: CosmWasm, last: contracts may call any module
+		wasm.NewAppModule(appCodec, &app.WasmKeeper, app.StakingKeeper, app.AccountKeeper, app.BankKeeper, app.MsgServiceRouter(), nil),
 	)
 
 	// BasicModuleManager defines the module BasicManager which is in charge of setting up basic,
@@ -598,6 +659,8 @@ func NewExampleApp(
 			ibctransfertypes.ModuleName: transfer.AppModuleBasic{},
 		},
 	)
+	app.BasicModuleManager[pqStoreKey] = pqGenesisBasic{}             // ZETAPHY: app_state.zetaphypq in `init` (zetaphy_upgrade.go)
+	app.BasicModuleManager[wasmtypes.ModuleName] = wasmGenesisBasic{} // ZETAPHY: upload by governance only in `init` (zetaphy_cosmwasm.go)
 	app.BasicModuleManager.RegisterLegacyAminoCodec(legacyAmino)
 	app.BasicModuleManager.RegisterInterfaces(interfaceRegistry)
 
@@ -618,7 +681,7 @@ func NewExampleApp(
 		minttypes.ModuleName,
 
 		// IBC modules
-		ibcexported.ModuleName, ibctransfertypes.ModuleName,
+		ibcexported.ModuleName, ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 
 		// Cosmos EVM BeginBlockers
 		erc20types.ModuleName, feemarkettypes.ModuleName,
@@ -631,6 +694,7 @@ func NewExampleApp(
 		authz.ModuleName, feegrant.ModuleName,
 		consensusparamtypes.ModuleName,
 		vestingtypes.ModuleName,
+		wasmtypes.ModuleName,
 	)
 
 	// NOTE: the feemarket module should go last in order of end blockers that are actually doing something,
@@ -645,12 +709,13 @@ func NewExampleApp(
 		evmtypes.ModuleName, erc20types.ModuleName, feemarkettypes.ModuleName,
 
 		// no-ops
-		ibcexported.ModuleName, ibctransfertypes.ModuleName,
+		ibcexported.ModuleName, ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 		distrtypes.ModuleName,
 		slashingtypes.ModuleName, minttypes.ModuleName,
 		genutiltypes.ModuleName, evidencetypes.ModuleName, authz.ModuleName,
 		feegrant.ModuleName, upgradetypes.ModuleName, consensusparamtypes.ModuleName,
 		vestingtypes.ModuleName,
+		wasmtypes.ModuleName,
 	)
 
 	// NOTE: The genutils module must occur after staking so that pools are
@@ -670,9 +735,10 @@ func NewExampleApp(
 		feemarkettypes.ModuleName,
 		erc20types.ModuleName,
 
-		ibctransfertypes.ModuleName,
+		ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 		genutiltypes.ModuleName, evidencetypes.ModuleName, authz.ModuleName,
 		feegrant.ModuleName, upgradetypes.ModuleName, vestingtypes.ModuleName,
+		wasmtypes.ModuleName, // ZETAPHY: after IBC transfer and genutil, as in wasmd
 	}
 	app.ModuleManager.SetOrderInitGenesis(genesisModuleOrder...)
 	app.ModuleManager.SetOrderExportGenesis(genesisModuleOrder...)
@@ -684,10 +750,14 @@ func NewExampleApp(
 	if err = app.ModuleManager.RegisterServices(app.configurator); err != nil {
 		panic(fmt.Sprintf("failed to register services in module manager: %s", err.Error()))
 	}
+	app.registerEVMCall()                // ZETAPHY: post-quantum messages (zetaphy_pqcall.go)
+	app.setPQVoteHandlers(homePath)      // ZETAPHY: ML-DSA-44 vote signatures (zetaphy_pqguard.go)
+	app.EVMKeeper.SetHooks(pqHooks{app}) // ZETAPHY: quantum lock from MetaMask
 
 	// RegisterUpgradeHandlers is used for registering any on-chain upgrades.
 	// Make sure it's called after `app.ModuleManager` and `app.configurator` are set.
 	app.RegisterUpgradeHandlers()
+	app.registerZetaphyUpgrades() // ZETAPHY: "zetaphy-v2" (zetaphy_upgrade.go)
 
 	autocliv1.RegisterQueryServer(app.GRPCQueryRouter(), runtimeservices.NewAutoCLIQueryService(app.ModuleManager.Modules))
 
@@ -730,6 +800,10 @@ func NewExampleApp(
 	if err := app.configureEVMMempool(appOpts, logger); err != nil {
 		panic(fmt.Sprintf("failed to configure EVM mempool: %s", err.Error()))
 	}
+	if app.EVMMempool == nil { // ZETAPHY: the vote certificate is needed either way
+		h := baseapp.NewDefaultProposalHandler(sdkmempool.NoOpMempool{}, NewNoCheckProposalTxVerifier(app.BaseApp))
+		app.pqProposalHandlers(h.PrepareProposalHandler(), h.ProcessProposalHandler())
+	}
 
 	// In v0.46, the SDK introduces _postHandlers_. PostHandlers are like
 	// antehandlers, but are run _after_ the `runMsgs` execution. They are also
@@ -751,6 +825,13 @@ func NewExampleApp(
 	// upgrade.
 	app.setPostHandler()
 
+	// ZETAPHY: state sync snapshots carry the contract code too.
+	if manager := app.SnapshotManager(); manager != nil {
+		if err := manager.RegisterExtensions(wasmkeeper.NewWasmSnapshotter(app.CommitMultiStore(), &app.WasmKeeper)); err != nil {
+			panic(fmt.Errorf("failed to register wasm snapshot extension: %w", err))
+		}
+	}
+
 	// At startup, after all modules have been registered, check that all prot
 	// annotations are correct.
 	protoFiles, err := proto.MergedRegistry()
@@ -777,6 +858,7 @@ func NewExampleApp(
 
 		// set global evm variables from KV store
 		vmModule.HydrateGlobals(ctx)
+		app.wasmPinnedCodes(ctx) // ZETAPHY: pinned contracts into the VM cache
 	}
 
 	vmrunner.SetRunner(bApp, txnrunner.NewSTMRunner(
@@ -807,12 +889,14 @@ func (app *EVMD) setAnteHandler(txConfig client.TxConfig, maxGasWanted uint64) {
 		MaxTxGasWanted:         maxGasWanted,
 		DynamicFeeChecker:      true,
 		PendingTxListener:      app.onPendingTx,
+		// ZETAPHY: wasmd's ante decorators for Cosmos txs (zetaphy_cosmwasm.go)
+		ExtraCosmosDecorators: app.wasmAnteDecorators(app.wasmNodeConfig),
 	}
 	if err := options.Validate(); err != nil {
 		panic(err)
 	}
 
-	app.SetAnteHandler(evmante.NewAnteHandler(options))
+	app.SetAnteHandler(app.pqLockAnte(evmante.NewAnteHandler(options))) // ZETAPHY: quantum locks
 }
 
 func (app *EVMD) onPendingTx(hash common.Hash) {
@@ -842,7 +926,22 @@ func (app *EVMD) Name() string { return app.BaseApp.Name() }
 
 // BeginBlocker application updates every begin block
 func (app *EVMD) BeginBlocker(ctx sdk.Context) (sdk.BeginBlock, error) {
-	return app.ModuleManager.BeginBlock(ctx)
+	// ZETAPHY: burn before distribution pays validators. The module manager
+	// replaces the event manager, so keep the burn's events and add them.
+	em := sdk.NewEventManager()
+	app.burnFees(ctx.WithEventManager(em))
+	// ZETAPHY v2, from the activation height only (zetaphy_upgrade.go):
+	app.burnDead(ctx.WithEventManager(em))      // ZETAPHY sent to 0x…dEaD leaves the supply
+	app.ensureBlockHashHistory(ctx)             // BLOCKHASH needs the EIP-2935 contract (zetaphy_random.go)
+	app.secBeginBlock(ctx.WithEventManager(em)) // Q-day migrations and held IBC transfers due (zetaphy_security.go)
+	// ZETAPHY: evidence switch (zetaphy_pqcert.go); its events join the burn's
+	bb, err := app.ModuleManager.BeginBlock(app.pqFilterEvidence(ctx.WithEventManager(em)))
+	if err != nil {
+		return bb, err
+	}
+	app.breakerBeginBlock(ctx.WithEventManager(em)) // ZETAPHY v5: pause bridges the validators tripped (zetaphy_breaker.go)
+	bb.Events = append(em.ABCIEvents(), bb.Events...)
+	return bb, nil
 }
 
 // EndBlocker application updates every end block
@@ -869,10 +968,24 @@ func (app *EVMD) InitChainer(ctx sdk.Context, req *abci.RequestInitChain) (*abci
 		panic(err)
 	}
 
-	return app.ModuleManager.InitGenesis(ctx, app.appCodec, genesisState)
+	if raw, ok := genesisState[pqStoreKey]; ok { // ZETAPHY: quantum locks and vote keys
+		if err := app.pqInitGenesis(ctx, raw); err != nil {
+			panic(err)
+		}
+		delete(genesisState, pqStoreKey)
+	}
+	res, err := app.ModuleManager.InitGenesis(ctx, app.appCodec, genesisState)
+	if err == nil {
+		app.secMirrorAfterGenesis(ctx) // ZETAPHY: security-core heights into EVM storage
+	}
+	return res, err
 }
 
-func (app *EVMD) PreBlocker(ctx sdk.Context, _ *abci.RequestFinalizeBlock) (*sdk.ResponsePreBlock, error) {
+func (app *EVMD) PreBlocker(ctx sdk.Context, req *abci.RequestFinalizeBlock) (*sdk.ResponsePreBlock, error) {
+	if err := app.pqPreBlock(ctx, req); err != nil { // ZETAPHY: post-quantum vote certificate
+		return nil, err
+	}
+	app.zxPreBlock(ctx, req) // ZETAPHY v5: immune scores and breaker flags from the vote extensions (zetaphy_immune.go)
 	return app.ModuleManager.PreBlock(ctx)
 }
 
diff --git a/evmd/cmd/evmd/cmd/root.go b/evmd/cmd/evmd/cmd/root.go
index 4da3349..4574a48 100644
--- a/evmd/cmd/evmd/cmd/root.go
+++ b/evmd/cmd/evmd/cmd/root.go
@@ -22,6 +22,8 @@ import (
 	"github.com/cosmos/evm/utils"
 	"github.com/cosmos/evm/x/vm/types"
 
+	"github.com/CosmWasm/wasmd/x/wasm"
+
 	"cosmossdk.io/log/v2"
 	confixcmd "cosmossdk.io/tools/confix/cmd"
 	"github.com/cosmos/cosmos-sdk/store/v2"
@@ -174,6 +176,7 @@ func initRootCmd(rootCmd *cobra.Command, evmApp *evmd.EVMD) {
 		pruning.Cmd(sdkAppCreator, defaultNodeHome),
 		snapshot.Cmd(sdkAppCreator),
 		NewTestnetCmd(evmApp.BasicModuleManager, banktypes.GenesisBalancesIterator{}, appCreator{}),
+		evmd.RPCGuardCmd(), // ZETAPHY: the public RPC filter (setup-node.sh)
 	)
 
 	// add Cosmos EVM' flavored TM commands to start server, etc.
@@ -204,7 +207,9 @@ func initRootCmd(rootCmd *cobra.Command, evmApp *evmd.EVMD) {
 	}
 }
 
-func addModuleInitFlags(_ *cobra.Command) {}
+// ZETAPHY: --wasm.* start flags ([wasm] in app.toml) and the check that
+// the linked libwasmvm matches the wasmvm Go package.
+func addModuleInitFlags(startCmd *cobra.Command) { wasm.AddModuleInitFlags(startCmd) }
 
 func queryCommand() *cobra.Command {
 	cmd := &cobra.Command{
@@ -223,6 +228,7 @@ func queryCommand() *cobra.Command {
 		authcmd.QueryTxCmd(),
 		sdkserver.QueryBlockCmd(),
 		sdkserver.QueryBlockResultsCmd(),
+		evmd.NeuroQueryCmd(), // ZETAPHY v5: q neuro model-at <height>
 	)
 
 	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")
@@ -249,6 +255,8 @@ func txCommand() *cobra.Command {
 		authcmd.GetEncodeCommand(),
 		authcmd.GetDecodeCommand(),
 		authcmd.GetSimulateCmd(),
+		evmd.PQVoteKeyCmd(), evmd.QuantumLockCmd(), evmd.PQEvidenceProposalCmd(), // ZETAPHY
+		evmd.SecurityProposalCmd(), evmd.QDayCommitCmd(), evmd.QDayRevealCmd(), evmd.IBCHoldCancelCmd(), // ZETAPHY security core
 	)
 
 	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")
diff --git a/evmd/config/permissions.go b/evmd/config/permissions.go
index 312b521..6b8033d 100644
--- a/evmd/config/permissions.go
+++ b/evmd/config/permissions.go
@@ -14,6 +14,8 @@ import (
 	feemarkettypes "github.com/cosmos/evm/x/feemarket/types"
 	vmtypes "github.com/cosmos/evm/x/vm/types"
 	transfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
+
+	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
 	corevm "github.com/ethereum/go-ethereum/core/vm"
 )
 
@@ -58,6 +60,7 @@ var maccPerms = map[string][]string{
 	stakingtypes.BondedPoolName:    {authtypes.Burner, authtypes.Staking},
 	stakingtypes.NotBondedPoolName: {authtypes.Burner, authtypes.Staking},
 	govtypes.ModuleName:            {authtypes.Burner},
+	wasmtypes.ModuleName:           {authtypes.Burner}, // ZETAPHY: CosmWasm (BankMsg::Burn)
 
 	// Cosmos EVM modules
 	vmtypes.ModuleName:        {authtypes.Minter, authtypes.Burner},
diff --git a/evmd/export.go b/evmd/export.go
index 9fdd8ef..e6ff55d 100644
--- a/evmd/export.go
+++ b/evmd/export.go
@@ -36,6 +36,9 @@ func (app *EVMD) ExportAppStateAndValidators(forZeroHeight bool, jailAllowedAddr
 		return servertypes.ExportedApp{}, err
 	}
 
+	if genState[pqStoreKey], err = app.pqExportGenesis(ctx); err != nil { // ZETAPHY
+		return servertypes.ExportedApp{}, err
+	}
 	appState, err := json.MarshalIndent(genState, "", "  ")
 	if err != nil {
 		return servertypes.ExportedApp{}, err
diff --git a/evmd/go.mod b/evmd/go.mod
index e503386..cbc3a7e 100644
--- a/evmd/go.mod
+++ b/evmd/go.mod
@@ -4,20 +4,24 @@ go 1.25.9
 
 require (
 	cosmossdk.io/api v1.0.0
-	cosmossdk.io/client/v2 v2.0.0-beta.10.0.20260227212600-39d4711b8970
+	cosmossdk.io/client/v2 v2.11.0
 	cosmossdk.io/core v1.1.0
 	cosmossdk.io/errors v1.1.0
 	cosmossdk.io/log/v2 v2.1.0
 	cosmossdk.io/math v1.5.3
 	cosmossdk.io/tools/confix v0.1.2
+	github.com/CosmWasm/wasmd v0.70.5
+	github.com/CosmWasm/wasmvm/v3 v3.0.9
+	github.com/cloudflare/circl v1.6.3
 	github.com/cometbft/cometbft v0.39.3
 	github.com/cosmos/cosmos-db v1.1.3
 	github.com/cosmos/cosmos-sdk v0.54.3
 	github.com/cosmos/cosmos-sdk/store/v2 v2.0.0
 	github.com/cosmos/evm v0.2.0
 	github.com/cosmos/gogoproto v1.7.2
-	github.com/cosmos/ibc-go/v11 v11.0.0
-	github.com/ethereum/go-ethereum v1.16.8
+	github.com/cosmos/ibc-go/v11 v11.2.0
+	github.com/ethereum/go-ethereum v1.17.0
+	github.com/grpc-ecosystem/grpc-gateway v1.16.0
 	github.com/onsi/ginkgo/v2 v2.23.4
 	github.com/onsi/gomega v1.38.0
 	github.com/spf13/cast v1.10.0
@@ -25,8 +29,9 @@ require (
 	github.com/spf13/pflag v1.0.10
 	github.com/spf13/viper v1.21.0
 	github.com/stretchr/testify v1.11.1
-	golang.org/x/sync v0.20.0
+	golang.org/x/sync v0.22.0
 	google.golang.org/grpc v1.80.0
+	google.golang.org/protobuf v1.36.11
 )
 
 require (
@@ -117,6 +122,7 @@ require (
 	github.com/desertbit/timer v1.0.1 // indirect
 	github.com/dgraph-io/badger/v4 v4.9.1 // indirect
 	github.com/dgraph-io/ristretto/v2 v2.4.0 // indirect
+	github.com/distribution/reference v0.6.0 // indirect
 	github.com/dlclark/regexp2 v1.7.0 // indirect
 	github.com/dop251/goja v0.0.0-20230605162241-28ee0ee714f3 // indirect
 	github.com/dunglas/httpsfv v1.1.0 // indirect
@@ -154,6 +160,7 @@ require (
 	github.com/google/btree v1.1.3 // indirect
 	github.com/google/flatbuffers v25.2.10+incompatible // indirect
 	github.com/google/go-cmp v0.7.0 // indirect
+	github.com/google/gofuzz v1.2.0 // indirect
 	github.com/google/orderedcode v0.0.1 // indirect
 	github.com/google/pprof v0.0.0-20250403155104-27863c87afa6 // indirect
 	github.com/google/s2a-go v0.1.9 // indirect
@@ -164,7 +171,6 @@ require (
 	github.com/gorilla/mux v1.8.1 // indirect
 	github.com/gorilla/websocket v1.5.3 // indirect
 	github.com/grpc-ecosystem/go-grpc-middleware v1.4.0 // indirect
-	github.com/grpc-ecosystem/grpc-gateway v1.16.0 // indirect
 	github.com/grpc-ecosystem/grpc-gateway/v2 v2.28.0 // indirect
 	github.com/gsterjov/go-libsecret v0.0.0-20161001094733-a6f4afe4910c // indirect
 	github.com/hashicorp/aws-sdk-go-base/v2 v2.0.0-beta.72 // indirect
@@ -191,7 +197,7 @@ require (
 	github.com/jackpal/go-nat-pmp v1.0.2 // indirect
 	github.com/jbenet/go-temp-err-catcher v0.1.0 // indirect
 	github.com/jmhodges/levigo v1.0.0 // indirect
-	github.com/klauspost/compress v1.18.5 // indirect
+	github.com/klauspost/compress v1.19.1 // indirect
 	github.com/klauspost/cpuid/v2 v2.3.0 // indirect
 	github.com/koron/go-ssdp v0.0.6 // indirect
 	github.com/kr/pretty v0.3.1 // indirect
@@ -235,9 +241,10 @@ require (
 	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
 	github.com/oasisprotocol/curve25519-voi v0.0.0-20251114093237-2ab5a27a1729 // indirect
 	github.com/oklog/run v1.2.0 // indirect
+	github.com/opencontainers/go-digest v1.0.0 // indirect
 	github.com/pbnjay/memory v0.0.0-20210728143218-7b4eea64cf58 // indirect
 	github.com/pelletier/go-toml/v2 v2.2.4 // indirect
-	github.com/petermattis/goid v0.0.0-20260113132338-7c7de50cc741 // indirect
+	github.com/petermattis/goid v0.0.0-20260226131333-17d1149c6ac6 // indirect
 	github.com/pion/datachannel v1.5.10 // indirect
 	github.com/pion/dtls/v2 v2.2.12 // indirect
 	github.com/pion/dtls/v3 v3.1.2 // indirect
@@ -263,19 +270,20 @@ require (
 	github.com/planetscale/vtprotobuf v0.6.1-0.20240319094008-0393e58bdf10 // indirect
 	github.com/pmezard/go-difflib v1.0.1-0.20181226105442-5d4384ee4fb2 // indirect
 	github.com/power-devops/perfstat v0.0.0-20240221224432-82ca36839d55 // indirect
-	github.com/prometheus/client_golang v1.23.2 // indirect
+	github.com/prometheus/client_golang v1.24.1 // indirect
 	github.com/prometheus/client_model v0.6.2 // indirect
-	github.com/prometheus/common v0.67.5 // indirect
-	github.com/prometheus/procfs v0.20.1 // indirect
+	github.com/prometheus/common v0.70.1 // indirect
+	github.com/prometheus/procfs v0.21.1 // indirect
 	github.com/quic-go/qpack v0.6.0 // indirect
-	github.com/quic-go/quic-go v0.59.0 // indirect
-	github.com/quic-go/webtransport-go v0.10.0 // indirect
+	github.com/quic-go/quic-go v0.60.0 // indirect
+	github.com/quic-go/webtransport-go v0.11.1 // indirect
 	github.com/rcrowley/go-metrics v0.0.0-20250401214520-65e299d6c5c9 // indirect
 	github.com/rogpeppe/go-internal v1.14.1 // indirect
 	github.com/rs/cors v1.11.1 // indirect
-	github.com/rs/zerolog v1.35.0 // indirect
+	github.com/rs/zerolog v1.35.1 // indirect
 	github.com/sagikazarmark/locafero v0.12.0 // indirect
 	github.com/sasha-s/go-deadlock v0.3.9 // indirect
+	github.com/shamaton/msgpack/v2 v2.2.3 // indirect
 	github.com/shirou/gopsutil v3.21.11+incompatible // indirect
 	github.com/shirou/gopsutil/v4 v4.26.4 // indirect
 	github.com/spaolacci/murmur3 v1.1.0 // indirect
@@ -342,22 +350,21 @@ require (
 	go.yaml.in/yaml/v2 v2.4.4 // indirect
 	go.yaml.in/yaml/v3 v3.0.4 // indirect
 	golang.org/x/arch v0.26.0 // indirect
-	golang.org/x/crypto v0.50.0 // indirect
+	golang.org/x/crypto v0.54.0 // indirect
 	golang.org/x/exp v0.0.0-20260312153236-7ab1446f8b90 // indirect
-	golang.org/x/mod v0.34.0 // indirect
-	golang.org/x/net v0.53.0 // indirect
+	golang.org/x/mod v0.37.0 // indirect
+	golang.org/x/net v0.57.0 // indirect
 	golang.org/x/oauth2 v0.36.0 // indirect
-	golang.org/x/sys v0.43.0 // indirect
-	golang.org/x/telemetry v0.0.0-20260311193753-579e4da9a98c // indirect
-	golang.org/x/term v0.42.0 // indirect
-	golang.org/x/text v0.36.0 // indirect
+	golang.org/x/sys v0.47.0 // indirect
+	golang.org/x/telemetry v0.0.0-20260625142307-59b4966ccb57 // indirect
+	golang.org/x/term v0.45.0 // indirect
+	golang.org/x/text v0.40.0 // indirect
 	golang.org/x/time v0.15.0 // indirect
-	golang.org/x/tools v0.43.0 // indirect
+	golang.org/x/tools v0.47.0 // indirect
 	google.golang.org/api v0.276.0 // indirect
 	google.golang.org/genproto v0.0.0-20260414002931-afd174a4e478 // indirect
 	google.golang.org/genproto/googleapis/api v0.0.0-20260414002931-afd174a4e478 // indirect
 	google.golang.org/genproto/googleapis/rpc v0.0.0-20260414002931-afd174a4e478 // indirect
-	google.golang.org/protobuf v1.36.11 // indirect
 	gopkg.in/yaml.v2 v2.4.0 // indirect
 	gopkg.in/yaml.v3 v3.0.1 // indirect
 	gotest.tools/v3 v3.5.2 // indirect
@@ -372,6 +379,10 @@ replace (
 	// use cosmos fork of keyring
 	github.com/99designs/keyring => github.com/cosmos/keyring v1.2.0
 	github.com/cosmos/evm => ../
+	// ZETAPHY: keep IBC at the audited v11.0.0 (wasmd v0.70.5 asks for
+	// v11.2.0, whose test app links ibc-go's own rate-limiting module next
+	// to x/ratelimit; wasmd v0.70.0-v0.70.2 were built on v11.0.0)
+	github.com/cosmos/ibc-go/v11 => github.com/cosmos/ibc-go/v11 v11.0.0
 	// use Cosmos geth fork
 	// branch: release/1.17
 	github.com/ethereum/go-ethereum => github.com/cosmos/go-ethereum v1.17.2-cosmos-0
diff --git a/evmd/go.sum b/evmd/go.sum
index 92d6f82..193e955 100644
--- a/evmd/go.sum
+++ b/evmd/go.sum
@@ -24,8 +24,8 @@ cloud.google.com/go/trace v1.13.0 h1:RfqsqPOiSCG8ql50UZt5F65KrVa1zbY9mJrO7xvZfbE
 cloud.google.com/go/trace v1.13.0/go.mod h1:r+bdAn16dKLSV1G2D5v3e58IlQlizfxWrUfjx7kM7X0=
 cosmossdk.io/api v1.0.0 h1:qTV8OPVEwcBPwp2b9p4Qy4noZyihJ+sOMaWL/VT+RCc=
 cosmossdk.io/api v1.0.0/go.mod h1:fKRljeYk+04p4T8Shdyv+uH2fSVyzHoWrvDAs/7OxfI=
-cosmossdk.io/client/v2 v2.0.0-beta.10.0.20260227212600-39d4711b8970 h1:hRL2KLqyVnbOfb2UzNQUZ0IXdL8TsHSGeYyF3tbcfcM=
-cosmossdk.io/client/v2 v2.0.0-beta.10.0.20260227212600-39d4711b8970/go.mod h1:cgdrvgMJ23AzeYIXQtcIyw283R9heNuGXHoHYJ5KvdM=
+cosmossdk.io/client/v2 v2.11.0 h1:k3hg9liNjrLv5P/PEle8wcihSwQ/ALCr1fja2sp5His=
+cosmossdk.io/client/v2 v2.11.0/go.mod h1:wJNFx9sSqSDE3QeXIU6DRZDagqdv98j6O7hmjnfGa2I=
 cosmossdk.io/collections v1.4.0 h1:b373bkxCxKiRbapxZ42TRmcKJEnBVBebdQVk9I5IkkE=
 cosmossdk.io/collections v1.4.0/go.mod h1:gxbieVY3tjbvWlkm3yOXf7sGyDrVi12haZH+sek6whw=
 cosmossdk.io/core v1.1.0 h1:iJ7j2DjNsFzg4/z4ImNQYzy2D4LfMCsaQ8Lrz1KCmxk=
@@ -51,6 +51,10 @@ github.com/Azure/go-ansiterm v0.0.0-20250102033503-faa5f7b0171c h1:udKWzYgxTojEK
 github.com/Azure/go-ansiterm v0.0.0-20250102033503-faa5f7b0171c/go.mod h1:xomTg63KZ2rFqZQzSB4Vz2SUXa1BpHTVz9L5PTmPC4E=
 github.com/BurntSushi/toml v0.3.1/go.mod h1:xHWCNGjB5oqiDr8zfno3MHue2Ht5sIBksp03qcyfWMU=
 github.com/BurntSushi/xgb v0.0.0-20160522181843-27f122750802/go.mod h1:IVnqGOEym/WlBOVXweHU+Q+/VP0lqqI8lqeDx9IjBqo=
+github.com/CosmWasm/wasmd v0.70.5 h1:9HxdLFGHy2ZA121MZGVTSJqjeBTrShAXFI7Hr+4ldho=
+github.com/CosmWasm/wasmd v0.70.5/go.mod h1:KUtQdhbr0pwlCdSpwsOmnquSl+1lA9t4pNS+VsJLxW4=
+github.com/CosmWasm/wasmvm/v3 v3.0.9 h1:pQGrS3w8udbKvumbNUBrZgZXfDM+3mHXRdZ0EOVn3zU=
+github.com/CosmWasm/wasmvm/v3 v3.0.9/go.mod h1:oknpb1bFERvvKcY7vHRp1F/Y/z66xVrsl7n9uWkOAlM=
 github.com/DataDog/datadog-go v3.2.0+incompatible/go.mod h1:LButxg5PwREeZtORoXG3tL4fMGNddJ+vMq1mwgfaqoQ=
 github.com/DataDog/datadog-go v4.8.3+incompatible h1:fNGaYSuObuQb5nzeTQqowRAd9bpDIRRV4/gUtIBjh8Q=
 github.com/DataDog/datadog-go v4.8.3+incompatible/go.mod h1:LButxg5PwREeZtORoXG3tL4fMGNddJ+vMq1mwgfaqoQ=
@@ -220,6 +224,8 @@ github.com/circonus-labs/circonus-gometrics v2.3.1+incompatible/go.mod h1:nmEj6D
 github.com/circonus-labs/circonusllhist v0.1.3/go.mod h1:kMXHVDlOchFAehlya5ePtbp5jckzBHf4XRpQvBOLI+I=
 github.com/clbanning/x2j v0.0.0-20191024224557-825249438eec/go.mod h1:jMjuTZXRI4dUb/I5gc9Hdhagfvm9+RyrPryS/auMzxE=
 github.com/client9/misspell v0.3.4/go.mod h1:qj6jICC3Q7zFZvVWo7KLAzC3yx5G7kyvSDkc90ppPyw=
+github.com/cloudflare/circl v1.6.3 h1:9GPOhQGF9MCYUeXyMYlqTR6a5gTrgR/fBLXvUgtVcg8=
+github.com/cloudflare/circl v1.6.3/go.mod h1:2eXP6Qfat4O/Yhh8BznvKnJ+uzEoTQ6jVKJRn81BiS4=
 github.com/cloudwego/base64x v0.1.6 h1:t11wG9AECkCDk5fMSoxmufanudBtJ+/HemLstXDLI2M=
 github.com/cloudwego/base64x v0.1.6/go.mod h1:OFcloc187FXDaYHvrNIjxSe8ncn0OOM8gEHfghB2IPU=
 github.com/cncf/udpa/go v0.0.0-20191209042840-269d4d468f6f/go.mod h1:M8M6+tZqaGXZJjfX53e64911xZQV5JYwmTeXPW+k8Sc=
@@ -336,6 +342,8 @@ github.com/dgraph-io/ristretto/v2 v2.4.0/go.mod h1:0KsrXtXvnv0EqnzyowllbVJB8yBon
 github.com/dgrijalva/jwt-go v3.2.0+incompatible/go.mod h1:E3ru+11k8xSBh+hMPgOLZmtrrCbhqsmaPHjLKYnJCaQ=
 github.com/dgryski/go-farm v0.0.0-20240924180020-3414d57e47da h1:aIftn67I1fkbMa512G+w+Pxci9hJPB8oMnkcP3iZF38=
 github.com/dgryski/go-farm v0.0.0-20240924180020-3414d57e47da/go.mod h1:SqUrOPUnsFjfmXRMNPybcSiG0BgUW2AuFH8PAnS2iTw=
+github.com/distribution/reference v0.6.0 h1:0IXCQ5g4/QMHHkarYzh5l+u8T3t73zM5QvfrDyIgxBk=
+github.com/distribution/reference v0.6.0/go.mod h1:BbU0aIcezP1/5jX/8MP0YiH4SdvB5Y4f/wlDRiLyi3E=
 github.com/dlclark/regexp2 v1.4.1-0.20201116162257-a2a8dda75c91/go.mod h1:2pZnwuY/m+8K6iRw6wQdMtk+rH5tNGR1i55kozfMjCc=
 github.com/dlclark/regexp2 v1.7.0 h1:7lJfhqlPssTb1WQx4yvTHN0uElPEv52sbaECrAQxjAo=
 github.com/dlclark/regexp2 v1.7.0/go.mod h1:DHkYz0B9wPfa6wondMfaivmHpzrQ3v9q8cnmRbL6yW8=
@@ -682,8 +690,8 @@ github.com/kisielk/gotool v1.0.0/go.mod h1:XhKaO+MFFWcvkIS/tQcRk01m1F5IRFswLeQ+o
 github.com/kkdai/bstream v0.0.0-20161212061736-f391b8402d23/go.mod h1:J+Gs4SYgM6CZQHDETBtE9HaSEkGmuNXF86RwHhHUvq4=
 github.com/klauspost/compress v1.10.3/go.mod h1:aoV0uJVorq1K+umq18yTdKaF57EivdYsUV+/s2qKfXs=
 github.com/klauspost/compress v1.11.7/go.mod h1:aoV0uJVorq1K+umq18yTdKaF57EivdYsUV+/s2qKfXs=
-github.com/klauspost/compress v1.18.5 h1:/h1gH5Ce+VWNLSWqPzOVn6XBO+vJbCNGvjoaGBFW2IE=
-github.com/klauspost/compress v1.18.5/go.mod h1:cwPg85FWrGar70rWktvGQj8/hthj3wpl0PGDogxkrSQ=
+github.com/klauspost/compress v1.19.1 h1:VsB4HPswih7mmZ8WleSFQ75c/Ui1M4trX5oAsJnhSlk=
+github.com/klauspost/compress v1.19.1/go.mod h1:cwPg85FWrGar70rWktvGQj8/hthj3wpl0PGDogxkrSQ=
 github.com/klauspost/cpuid/v2 v2.0.9/go.mod h1:FInQzS24/EEf25PyTYn52gqo7WaD8xa0213Md/qVLRg=
 github.com/klauspost/cpuid/v2 v2.2.4/go.mod h1:RVVoqg1df56z8g3pUjL/3lE5UfnlrJX8tyFgg4nqhuY=
 github.com/klauspost/cpuid/v2 v2.3.0 h1:S4CRMLnYUhGeDFDqkGriYKdfoFlDnMtqTiI/sFzhA9Y=
@@ -895,8 +903,8 @@ github.com/performancecopilot/speed v3.0.0+incompatible/go.mod h1:/CLtqpZ5gBg1M9
 github.com/peterh/liner v1.1.1-0.20190123174540-a2c9a5303de7 h1:oYW+YCJ1pachXTQmzR3rNLYGGz4g/UgFcjb28p/viDM=
 github.com/peterh/liner v1.1.1-0.20190123174540-a2c9a5303de7/go.mod h1:CRroGNssyjTd/qIG2FyxByd2S8JEAZXBl4qUrZf8GS0=
 github.com/petermattis/goid v0.0.0-20250813065127-a731cc31b4fe/go.mod h1:pxMtw7cyUw6B2bRH0ZBANSPg+AoSud1I1iyJHI69jH4=
-github.com/petermattis/goid v0.0.0-20260113132338-7c7de50cc741 h1:KPpdlQLZcHfTMQRi6bFQ7ogNO0ltFT4PmtwTLW4W+14=
-github.com/petermattis/goid v0.0.0-20260113132338-7c7de50cc741/go.mod h1:pxMtw7cyUw6B2bRH0ZBANSPg+AoSud1I1iyJHI69jH4=
+github.com/petermattis/goid v0.0.0-20260226131333-17d1149c6ac6 h1:rh2lKw/P/EqHa724vYH2+VVQ1YnW4u6EOXl0PMAovZE=
+github.com/petermattis/goid v0.0.0-20260226131333-17d1149c6ac6/go.mod h1:pxMtw7cyUw6B2bRH0ZBANSPg+AoSud1I1iyJHI69jH4=
 github.com/pierrec/lz4 v1.0.2-0.20190131084431-473cd7ce01a1/go.mod h1:3/3N9NVKO0jef7pBehbT1qWhCMrIgbYNnFAZCqQ5LRc=
 github.com/pierrec/lz4 v2.0.5+incompatible/go.mod h1:pdkljMzZIN41W+lC3N2tnIh5sFi+IEE17M5jbnwPHcY=
 github.com/pingcap/errors v0.11.4 h1:lFuQV/oaUMGcD2tqt+01ROSmJs75VG1ToEOkZIZ4nE4=
@@ -971,8 +979,8 @@ github.com/prometheus/client_golang v1.3.0/go.mod h1:hJaj2vgQTGQmVCsAACORcieXFeD
 github.com/prometheus/client_golang v1.4.0/go.mod h1:e9GMxYsXl05ICDXkRhurwBS4Q3OK1iX/F2sw+iXX5zU=
 github.com/prometheus/client_golang v1.7.1/go.mod h1:PY5Wy2awLA44sXw4AOSfFBetzPP4j5+D6mVACh+pe2M=
 github.com/prometheus/client_golang v1.11.1/go.mod h1:Z6t4BnS23TR94PD6BsDNk8yVqroYurpAkEiz0P2BEV0=
-github.com/prometheus/client_golang v1.23.2 h1:Je96obch5RDVy3FDMndoUsjAhG5Edi49h0RJWRi/o0o=
-github.com/prometheus/client_golang v1.23.2/go.mod h1:Tb1a6LWHB3/SPIzCoaDXI4I8UHKeFTEQ1YCr+0Gyqmg=
+github.com/prometheus/client_golang v1.24.1 h1:JnJkREXzWxUdCuPFpIWZiPispT9xVV59uiuyR2bPlnU=
+github.com/prometheus/client_golang v1.24.1/go.mod h1:F+oSRECHg4sse5ucfYpYDeIv/hu68Zo0uoHKetWnzcE=
 github.com/prometheus/client_model v0.0.0-20180712105110-5c3871d89910/go.mod h1:MbSGuTsp3dbXC40dX6PRTWyKYBIrTGTE9sqQNg2J8bo=
 github.com/prometheus/client_model v0.0.0-20190115171406-56726106282f/go.mod h1:MbSGuTsp3dbXC40dX6PRTWyKYBIrTGTE9sqQNg2J8bo=
 github.com/prometheus/client_model v0.0.0-20190129233127-fd36f4220a90/go.mod h1:xMI15A0UPsDsEKsMN9yxemIoYk6Tm2C1GtYGdfGttqA=
@@ -988,8 +996,8 @@ github.com/prometheus/common v0.9.1/go.mod h1:yhUN8i9wzaXS3w1O07YhxHEBxD+W35wd8b
 github.com/prometheus/common v0.10.0/go.mod h1:Tlit/dnDKsSWFlCLTWaA1cyBgKHSMdTB80sz/V91rCo=
 github.com/prometheus/common v0.15.0/go.mod h1:U+gB1OBLb1lF3O42bTCL+FK18tX9Oar16Clt/msog/s=
 github.com/prometheus/common v0.26.0/go.mod h1:M7rCNAaPfAosfx8veZJCuw84e35h3Cfd9VFqTh1DIvc=
-github.com/prometheus/common v0.67.5 h1:pIgK94WWlQt1WLwAC5j2ynLaBRDiinoAb86HZHTUGI4=
-github.com/prometheus/common v0.67.5/go.mod h1:SjE/0MzDEEAyrdr5Gqc6G+sXI67maCxzaT3A2+HqjUw=
+github.com/prometheus/common v0.70.1 h1:1HvjP4D5oL3t8RsPlwxA9onvvStjtIHYE5XuuwOi/PY=
+github.com/prometheus/common v0.70.1/go.mod h1:VdFUQDMZK3VLkurFUVhia6uys/0suUp86TJz5qbJRhc=
 github.com/prometheus/procfs v0.0.0-20181005140218-185b4288413d/go.mod h1:c3At6R/oaqEKCNdg8wHV1ftS6bRYblBhIjjI8uT2IGk=
 github.com/prometheus/procfs v0.0.0-20190117184657-bf6a532e95b1/go.mod h1:c3At6R/oaqEKCNdg8wHV1ftS6bRYblBhIjjI8uT2IGk=
 github.com/prometheus/procfs v0.0.2/go.mod h1:TjEm7ze935MbeOT/UhFTIMYKhuLP4wbCsTZCD3I8kEA=
@@ -997,16 +1005,18 @@ github.com/prometheus/procfs v0.0.8/go.mod h1:7Qr8sr6344vo1JqZ6HhLceV9o3AJ1Ff+Gx
 github.com/prometheus/procfs v0.1.3/go.mod h1:lV6e/gmhEcM9IjHGsFOCxxuZ+z1YqCvr4OA4YeYWdaU=
 github.com/prometheus/procfs v0.3.0/go.mod h1:lV6e/gmhEcM9IjHGsFOCxxuZ+z1YqCvr4OA4YeYWdaU=
 github.com/prometheus/procfs v0.6.0/go.mod h1:cz+aTbrPOrUb4q7XlbU9ygM+/jj0fzG6c1xBZuNvfVA=
-github.com/prometheus/procfs v0.20.1 h1:XwbrGOIplXW/AU3YhIhLODXMJYyC1isLFfYCsTEycfc=
-github.com/prometheus/procfs v0.20.1/go.mod h1:o9EMBZGRyvDrSPH1RqdxhojkuXstoe4UlK79eF5TGGo=
+github.com/prometheus/procfs v0.21.1 h1:GljZCt+zSTS+NZq88cyQ1LjZ+RCHp3uVuabBWA5+OJI=
+github.com/prometheus/procfs v0.21.1/go.mod h1:aB55Cww9pdSJVHk0hUf0inxWyyjPogFIjmHKYgMKmtY=
 github.com/prysmaticlabs/gohashtree v0.0.4-beta h1:H/EbCuXPeTV3lpKeXGPpEV9gsUpkqOOVnWapUyeWro4=
 github.com/prysmaticlabs/gohashtree v0.0.4-beta/go.mod h1:BFdtALS+Ffhg3lGQIHv9HDWuHS8cTvHZzrHWxwOtGOs=
+github.com/quic-go/go-ossfuzz-seeds v0.1.0 h1:APacT+iIaNF6fd8AGEiN3bT/Jtkd2jz4v4TzM7MFjy0=
+github.com/quic-go/go-ossfuzz-seeds v0.1.0/go.mod h1:3IOHRbJIc+L6YKMwfDtJAM9Vj9k0YY4muhuyUYk5tbk=
 github.com/quic-go/qpack v0.6.0 h1:g7W+BMYynC1LbYLSqRt8PBg5Tgwxn214ZZR34VIOjz8=
 github.com/quic-go/qpack v0.6.0/go.mod h1:lUpLKChi8njB4ty2bFLX2x4gzDqXwUpaO1DP9qMDZII=
-github.com/quic-go/quic-go v0.59.0 h1:OLJkp1Mlm/aS7dpKgTc6cnpynnD2Xg7C1pwL6vy/SAw=
-github.com/quic-go/quic-go v0.59.0/go.mod h1:upnsH4Ju1YkqpLXC305eW3yDZ4NfnNbmQRCMWS58IKU=
-github.com/quic-go/webtransport-go v0.10.0 h1:LqXXPOXuETY5Xe8ITdGisBzTYmUOy5eSj+9n4hLTjHI=
-github.com/quic-go/webtransport-go v0.10.0/go.mod h1:LeGIXr5BQKE3UsynwVBeQrU1TPrbh73MGoC6jd+V7ow=
+github.com/quic-go/quic-go v0.60.0 h1:xcQioE8OM66UQLeUMHltK1CCcOu3JbVB4JAQdDQSB+0=
+github.com/quic-go/quic-go v0.60.0/go.mod h1:wpKpjmPpftl30sL6pFh7REVpjbcCVy4zt2vDyK1TuJk=
+github.com/quic-go/webtransport-go v0.11.1 h1:rrFQMO+7/52ZDJ04fsrjIaWqn6q1z1MYo9iVFq6JtbA=
+github.com/quic-go/webtransport-go v0.11.1/go.mod h1:SHgEzUFVyj+9WUSuGB1P6Zd351Pww2leWV3SwlTovkA=
 github.com/rcrowley/go-metrics v0.0.0-20181016184325-3113b8401b8a/go.mod h1:bCqnVzQkZxMG4s8nGwiZ5l3QUCyqpo9Y+/ZMZ9VjZe4=
 github.com/rcrowley/go-metrics v0.0.0-20250401214520-65e299d6c5c9 h1:bsUq1dX0N8AOIL7EB/X911+m4EHsnWEHeJ0c+3TTBrg=
 github.com/rcrowley/go-metrics v0.0.0-20250401214520-65e299d6c5c9/go.mod h1:bCqnVzQkZxMG4s8nGwiZ5l3QUCyqpo9Y+/ZMZ9VjZe4=
@@ -1022,8 +1032,8 @@ github.com/rogpeppe/go-internal v1.14.1/go.mod h1:MaRKkUm5W0goXpeCfT7UZI6fk/L7L7
 github.com/rs/cors v1.7.0/go.mod h1:gFx+x8UowdsKA9AchylcLynDq+nNFfI8FkUZdN/jGCU=
 github.com/rs/cors v1.11.1 h1:eU3gRzXLRK57F5rKMGMZURNdIG4EoAmX8k94r9wXWHA=
 github.com/rs/cors v1.11.1/go.mod h1:XyqrcTp5zjWr1wsJ8PIRZssZ8b/WMcMf71DJnit4EMU=
-github.com/rs/zerolog v1.35.0 h1:VD0ykx7HMiMJytqINBsKcbLS+BJ4WYjz+05us+LRTdI=
-github.com/rs/zerolog v1.35.0/go.mod h1:EjML9kdfa/RMA7h/6z6pYmq1ykOuA8/mjWaEvGI+jcw=
+github.com/rs/zerolog v1.35.1 h1:m7xQeoiLIiV0BCEY4Hs+j2NG4Gp2o2KPKmhnnLiazKI=
+github.com/rs/zerolog v1.35.1/go.mod h1:EjML9kdfa/RMA7h/6z6pYmq1ykOuA8/mjWaEvGI+jcw=
 github.com/russross/blackfriday/v2 v2.0.1/go.mod h1:+Rmxgy9KzJVeS9/2gXHxylqXiyQDYRxCVz55jmeOWTM=
 github.com/russross/blackfriday/v2 v2.1.0 h1:JIOH55/0cWyOuilr9/qlrm0BSXldqnqwMsf35Ld67mk=
 github.com/russross/blackfriday/v2 v2.1.0/go.mod h1:+Rmxgy9KzJVeS9/2gXHxylqXiyQDYRxCVz55jmeOWTM=
@@ -1034,6 +1044,8 @@ github.com/samuel/go-zookeeper v0.0.0-20190923202752-2cc03de413da/go.mod h1:gi+0
 github.com/sasha-s/go-deadlock v0.3.9 h1:fiaT9rB7g5sr5ddNZvlwheclN9IP86eFW9WgqlEQV+w=
 github.com/sasha-s/go-deadlock v0.3.9/go.mod h1:KuZj51ZFmx42q/mPaYbRk0P1xcwe697zsJKE03vD4/Y=
 github.com/sean-/seed v0.0.0-20170313163322-e2103e2c3529/go.mod h1:DxrIzT+xaE7yg65j358z/aeFdxmN0P9QXhEzd20vsDc=
+github.com/shamaton/msgpack/v2 v2.2.3 h1:uDOHmxQySlvlUYfQwdjxyybAOzjlQsD1Vjy+4jmO9NM=
+github.com/shamaton/msgpack/v2 v2.2.3/go.mod h1:6khjYnkx73f7VQU7wjcFS9DFjs+59naVWJv1TB7qdOI=
 github.com/shirou/gopsutil v3.21.11+incompatible h1:+1+c1VGhc88SSonWP6foOcLhvnKlUeu/erjjvaPEYiI=
 github.com/shirou/gopsutil v3.21.11+incompatible/go.mod h1:5b4v6he4MtMOwMlS0TUMTu2PcXUg8+E1lC7eC3UO/RA=
 github.com/shirou/gopsutil/v4 v4.26.4 h1:B4SXVbcwTyrocPHEmWBC4uCYr4Xcu3MK1TXqbprAOWY=
@@ -1273,8 +1285,8 @@ golang.org/x/crypto v0.8.0/go.mod h1:mRqEX+O9/h5TFCrQhkgjo2yKi0yYA+9ecGkdQoHrywE
 golang.org/x/crypto v0.9.0/go.mod h1:yrmDGqONDYtNj3tH8X9dzUun2m2lzPa9ngI6/RUPGR0=
 golang.org/x/crypto v0.12.0/go.mod h1:NF0Gs7EO5K4qLn+Ylc+fih8BSTeIjAP05siRnAh98yw=
 golang.org/x/crypto v0.18.0/go.mod h1:R0j02AL6hcrfOiy9T4ZYp/rcWeMxM3L6QYxlOuEG1mg=
-golang.org/x/crypto v0.50.0 h1:zO47/JPrL6vsNkINmLoo/PH1gcxpls50DNogFvB5ZGI=
-golang.org/x/crypto v0.50.0/go.mod h1:3muZ7vA7PBCE6xgPX7nkzzjiUq87kRItoJQM1Yo8S+Q=
+golang.org/x/crypto v0.54.0 h1:YLIA59K4fiNzHzjnZt2tUJQjQtUWfWbeHBqKtk3eScw=
+golang.org/x/crypto v0.54.0/go.mod h1:KWL8ny2AZdGR2cWmzeHrp2azQPGogOv+HeQaVEXC2dk=
 golang.org/x/exp v0.0.0-20190121172915-509febef88a4/go.mod h1:CJ0aWSM057203Lf6IL+f9T1iT9GByDxfZKAQTCR3kQA=
 golang.org/x/exp v0.0.0-20190306152737-a1d7652674e8/go.mod h1:CJ0aWSM057203Lf6IL+f9T1iT9GByDxfZKAQTCR3kQA=
 golang.org/x/exp v0.0.0-20200331195152-e8c3332aa8e5/go.mod h1:4M0jN8W1tt0AVLNr8HDosyJCDCDuyL9N9+3m7wDWgKw=
@@ -1295,8 +1307,8 @@ golang.org/x/mod v0.2.0/go.mod h1:s0Qsj1ACt9ePp/hMypM3fl4fZqREWJwdYDEqhRiZZUA=
 golang.org/x/mod v0.3.0/go.mod h1:s0Qsj1ACt9ePp/hMypM3fl4fZqREWJwdYDEqhRiZZUA=
 golang.org/x/mod v0.6.0-dev.0.20220419223038-86c51ed26bb4/go.mod h1:jJ57K6gSWd91VN4djpZkiMVwK6gcyfeH4XE8wZrZaV4=
 golang.org/x/mod v0.8.0/go.mod h1:iBbtSCu2XBx23ZKBPSOrRkjjQPZFPuis4dIYUhu/chs=
-golang.org/x/mod v0.34.0 h1:xIHgNUUnW6sYkcM5Jleh05DvLOtwc6RitGHbDk4akRI=
-golang.org/x/mod v0.34.0/go.mod h1:ykgH52iCZe79kzLLMhyCUzhMci+nQj+0XkbXpNYtVjY=
+golang.org/x/mod v0.37.0 h1:vF1DjpVEshcIqoEaauuHebaLk1O1forxjxBaVn884JQ=
+golang.org/x/mod v0.37.0/go.mod h1:m8S8VeM9r4dzDwjrKO0a1sZP3YjeMamRRlD+fmR2Q/0=
 golang.org/x/net v0.0.0-20180719180050-a680a1efc54d/go.mod h1:mL1N/T3taQHkDXs73rZJwtUhF3w3ftmwwsq0BUmARs4=
 golang.org/x/net v0.0.0-20180724234803-3673e40ba225/go.mod h1:mL1N/T3taQHkDXs73rZJwtUhF3w3ftmwwsq0BUmARs4=
 golang.org/x/net v0.0.0-20180826012351-8a410e7b638d/go.mod h1:mL1N/T3taQHkDXs73rZJwtUhF3w3ftmwwsq0BUmARs4=
@@ -1333,8 +1345,8 @@ golang.org/x/net v0.9.0/go.mod h1:d48xBJpPfHeWQsugry2m+kC02ZBRGRgulfHnEXEuWns=
 golang.org/x/net v0.10.0/go.mod h1:0qNGK6F8kojg2nk9dLZ2mShWaEBan6FAoqfSigmmuDg=
 golang.org/x/net v0.14.0/go.mod h1:PpSgVXXLK0OxS0F31C1/tv6XNguvCrnXIDrFMspZIUI=
 golang.org/x/net v0.20.0/go.mod h1:z8BVo6PvndSri0LbOE3hAn0apkU+1YvI6E70E9jsnvY=
-golang.org/x/net v0.53.0 h1:d+qAbo5L0orcWAr0a9JweQpjXF19LMXJE8Ey7hwOdUA=
-golang.org/x/net v0.53.0/go.mod h1:JvMuJH7rrdiCfbeHoo3fCQU24Lf5JJwT9W3sJFulfgs=
+golang.org/x/net v0.57.0 h1:K5+3DljvIuDG9/Jv9rvyMywYNFCQ9RSUY6OOTTkT+tE=
+golang.org/x/net v0.57.0/go.mod h1:KpXc8iv+r3XplLAG/f7Jsf9RPszJzdR0f58q9vGOuEU=
 golang.org/x/oauth2 v0.0.0-20180821212333-d2e6202438be/go.mod h1:N/0e6XlmueqKjAGxoOufVs8QHGRruUQn6yWY3a++T0U=
 golang.org/x/oauth2 v0.0.0-20190226205417-e64efc72b421/go.mod h1:gOpvHmFTYa4IltrdGE7lF6nIHvwfUNPOp7c8zoXwtLw=
 golang.org/x/oauth2 v0.0.0-20200107190931-bf48bf16ab8d/go.mod h1:gOpvHmFTYa4IltrdGE7lF6nIHvwfUNPOp7c8zoXwtLw=
@@ -1351,8 +1363,8 @@ golang.org/x/sync v0.0.0-20201207232520-09787c993a3a/go.mod h1:RxMgew5VJxzue5/jJ
 golang.org/x/sync v0.0.0-20210220032951-036812b2e83c/go.mod h1:RxMgew5VJxzue5/jJTE5uejpjVlOe/izrB70Jof72aM=
 golang.org/x/sync v0.0.0-20220722155255-886fb9371eb4/go.mod h1:RxMgew5VJxzue5/jJTE5uejpjVlOe/izrB70Jof72aM=
 golang.org/x/sync v0.1.0/go.mod h1:RxMgew5VJxzue5/jJTE5uejpjVlOe/izrB70Jof72aM=
-golang.org/x/sync v0.20.0 h1:e0PTpb7pjO8GAtTs2dQ6jYa5BWYlMuX047Dco/pItO4=
-golang.org/x/sync v0.20.0/go.mod h1:9xrNwdLfx4jkKbNva9FpL6vEN7evnE43NNNJQ2LF3+0=
+golang.org/x/sync v0.22.0 h1:SZjpbeLmrCk4xhRSZFNZW5gFUeCeFgjekvI/+gfScek=
+golang.org/x/sync v0.22.0/go.mod h1:9xrNwdLfx4jkKbNva9FpL6vEN7evnE43NNNJQ2LF3+0=
 golang.org/x/sys v0.0.0-20180823144017-11551d06cbcc/go.mod h1:STP8DvDyc/dI5b8T5hshtkjS+E42TnysNCUPdjciGhY=
 golang.org/x/sys v0.0.0-20180830151530-49385e6e1522/go.mod h1:STP8DvDyc/dI5b8T5hshtkjS+E42TnysNCUPdjciGhY=
 golang.org/x/sys v0.0.0-20180905080454-ebe1bf3edb33/go.mod h1:STP8DvDyc/dI5b8T5hshtkjS+E42TnysNCUPdjciGhY=
@@ -1415,10 +1427,10 @@ golang.org/x/sys v0.8.0/go.mod h1:oPkhp1MJrh7nUepCBck5+mAzfO9JrbApNNgaTdGDITg=
 golang.org/x/sys v0.11.0/go.mod h1:oPkhp1MJrh7nUepCBck5+mAzfO9JrbApNNgaTdGDITg=
 golang.org/x/sys v0.16.0/go.mod h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA=
 golang.org/x/sys v0.21.0/go.mod h1:/VUhepiaJMQUp4+oa/7Zr1D23ma6VTLIYjOOTFZPUcA=
-golang.org/x/sys v0.43.0 h1:Rlag2XtaFTxp19wS8MXlJwTvoh8ArU6ezoyFsMyCTNI=
-golang.org/x/sys v0.43.0/go.mod h1:4GL1E5IUh+htKOUEOaiffhrAeqysfVGipDYzABqnCmw=
-golang.org/x/telemetry v0.0.0-20260311193753-579e4da9a98c h1:6a8FdnNk6bTXBjR4AGKFgUKuo+7GnR3FX5L7CbveeZc=
-golang.org/x/telemetry v0.0.0-20260311193753-579e4da9a98c/go.mod h1:TpUTTEp9frx7rTdLpC9gFG9kdI7zVLFTFFlqaH2Cncw=
+golang.org/x/sys v0.47.0 h1:o7XGOvZQCADBQQ4Y7VNq2dRWQR7JmOUW8Kxx4ZsNgWs=
+golang.org/x/sys v0.47.0/go.mod h1:4GL1E5IUh+htKOUEOaiffhrAeqysfVGipDYzABqnCmw=
+golang.org/x/telemetry v0.0.0-20260625142307-59b4966ccb57 h1:nwGZBCt+FnXUrGsj5vjzAsEmkcaFvd82BbOjECiFYZc=
+golang.org/x/telemetry v0.0.0-20260625142307-59b4966ccb57/go.mod h1:3AWMyWHS+caVoiEXpiq6+tzKA40J4vQT3MYr80ZtQpc=
 golang.org/x/term v0.0.0-20201126162022-7de9c90e9dd1/go.mod h1:bj7SfCRtBDWHUb9snDiAeCFNEtKQo2Wmx5Cou7ajbmo=
 golang.org/x/term v0.0.0-20210927222741-03fcf44c2211/go.mod h1:jbD1KX2456YbFQfuXm/mYQcufACuNUgVhRMnK/tPxf8=
 golang.org/x/term v0.5.0/go.mod h1:jMB1sMXY+tzblOD4FWmEbocvup2/aLOaQEp7JmGp78k=
@@ -1427,8 +1439,8 @@ golang.org/x/term v0.7.0/go.mod h1:P32HKFT3hSsZrRxla30E9HqToFYAQPCMs/zFMBUFqPY=
 golang.org/x/term v0.8.0/go.mod h1:xPskH00ivmX89bAKVGSKKtLOWNx2+17Eiy94tnKShWo=
 golang.org/x/term v0.11.0/go.mod h1:zC9APTIj3jG3FdV/Ons+XE1riIZXG4aZ4GTHiPZJPIU=
 golang.org/x/term v0.16.0/go.mod h1:yn7UURbUtPyrVJPGPq404EukNFxcm/foM+bV/bfcDsY=
-golang.org/x/term v0.42.0 h1:UiKe+zDFmJobeJ5ggPwOshJIVt6/Ft0rcfrXZDLWAWY=
-golang.org/x/term v0.42.0/go.mod h1:Dq/D+snpsbazcBG5+F9Q1n2rXV8Ma+71xEjTRufARgY=
+golang.org/x/term v0.45.0 h1:NwWyBmoJCbfTHpxrWoZ9C6/VxOf7ic219I8xZZFdrf0=
+golang.org/x/term v0.45.0/go.mod h1:9aqxs0blBcrm/n0L9QW0aRVD+ktan8ssZromtqJC43w=
 golang.org/x/text v0.3.0/go.mod h1:NqM8EUOU14njkJ3fqMW+pc6Ldnwhi/IjpwHt7yyuwOQ=
 golang.org/x/text v0.3.2/go.mod h1:bEr9sfX3Q8Zfm5fL9x+3itogRgK3+ptLWKqgva+5dAk=
 golang.org/x/text v0.3.3/go.mod h1:5Zoc/QRtKVWzQhOtBMvqHzDpF6irO9z98xDceosuGiQ=
@@ -1441,8 +1453,8 @@ golang.org/x/text v0.8.0/go.mod h1:e1OnstbJyHTd6l/uOt8jFFHp6TRDWZR/bV3emEE/zU8=
 golang.org/x/text v0.9.0/go.mod h1:e1OnstbJyHTd6l/uOt8jFFHp6TRDWZR/bV3emEE/zU8=
 golang.org/x/text v0.12.0/go.mod h1:TvPlkZtksWOMsz7fbANvkp4WM8x/WCo/om8BMLbz+aE=
 golang.org/x/text v0.14.0/go.mod h1:18ZOQIKpY8NJVqYksKHtTdi31H5itFRjB5/qKTNYzSU=
-golang.org/x/text v0.36.0 h1:JfKh3XmcRPqZPKevfXVpI1wXPTqbkE5f7JA92a55Yxg=
-golang.org/x/text v0.36.0/go.mod h1:NIdBknypM8iqVmPiuco0Dh6P5Jcdk8lJL0CUebqK164=
+golang.org/x/text v0.40.0 h1:Ub2Z6/xjgF1WrYQz2nuITOEegKFtiIy+rieRJ5lHZKs=
+golang.org/x/text v0.40.0/go.mod h1:hpnzDAfGV753zIKo+wk3u1bVKCGPbrnF7+7LBF/UHVY=
 golang.org/x/time v0.0.0-20180412165947-fbb02b2291d2/go.mod h1:tRJNPiyCQ0inRvYxbN9jk5I+vvW/OXSQhTDSoE431IQ=
 golang.org/x/time v0.0.0-20191024005414-555d28b269f0/go.mod h1:tRJNPiyCQ0inRvYxbN9jk5I+vvW/OXSQhTDSoE431IQ=
 golang.org/x/time v0.15.0 h1:bbrp8t3bGUeFOx08pvsMYRTCVSMk89u4tKbNOZbp88U=
@@ -1468,8 +1480,8 @@ golang.org/x/tools v0.0.0-20200619180055-7c47624df98f/go.mod h1:EkVYQZoAsY45+roY
 golang.org/x/tools v0.0.0-20210106214847-113979e3529a/go.mod h1:emZCQorbCU4vsT4fOWvOPXz4eW1wZW4PmDk9uLelYpA=
 golang.org/x/tools v0.1.12/go.mod h1:hNGJHUnrk76NpqgfD5Aqm5Crs+Hm0VOH/i9J2+nxYbc=
 golang.org/x/tools v0.6.0/go.mod h1:Xwgl3UAJ/d3gWutnCtw505GrjyAbvKui8lOU390QaIU=
-golang.org/x/tools v0.43.0 h1:12BdW9CeB3Z+J/I/wj34VMl8X+fEXBxVR90JeMX5E7s=
-golang.org/x/tools v0.43.0/go.mod h1:uHkMso649BX2cZK6+RpuIPXS3ho2hZo4FVwfoy1vIk0=
+golang.org/x/tools v0.47.0 h1:7Kn5x/d1svx/PzryTsqeoZN4TZwqeH5pGWjefhLi/1Q=
+golang.org/x/tools v0.47.0/go.mod h1:dFHnyTvFWY212G+h7ZY4Vsp/K3U4/7W9TyVaAul8uCA=
 golang.org/x/xerrors v0.0.0-20190717185122-a985d3407aa7/go.mod h1:I/5z698sn9Ka8TeJc9MKroUUfqBBauWjQqLJ2OPfmY0=
 golang.org/x/xerrors v0.0.0-20191011141410-1b5146add898/go.mod h1:I/5z698sn9Ka8TeJc9MKroUUfqBBauWjQqLJ2OPfmY0=
 golang.org/x/xerrors v0.0.0-20191204190536-9bdfabe68543/go.mod h1:I/5z698sn9Ka8TeJc9MKroUUfqBBauWjQqLJ2OPfmY0=
diff --git a/evmd/mempool.go b/evmd/mempool.go
index d6af75f..1c4fec7 100644
--- a/evmd/mempool.go
+++ b/evmd/mempool.go
@@ -52,6 +52,7 @@ func (app *EVMD) configureEVMMempool(appOpts servertypes.AppOptions, logger log.
 	)
 
 	app.EVMMempool = mempool
+	mempool.SetZetaphyCheck(app.zetaphyMempoolCheck) // ZETAPHY: the threat gate and the v5 account guard at submission
 
 	// create ABCI handlers
 	proposalHandler := baseapp.NewDefaultProposalHandler(mempool, NewNoCheckProposalTxVerifier(app.BaseApp))
@@ -61,8 +62,8 @@ func (app *EVMD) configureEVMMempool(appOpts servertypes.AppOptions, logger log.
 	checkTxHandler := mempool.NewCheckTxHandler(app.TxDecode, checkTxTimeout)
 
 	// set handlers and the mempool
-	app.SetPrepareProposal(proposalHandler.PrepareProposalHandler())
-	app.SetProcessProposal(proposalHandler.ProcessProposalHandler())
+	// ZETAPHY: with the post-quantum vote certificate (zetaphy_pqcert.go)
+	app.pqProposalHandlers(proposalHandler.PrepareProposalHandler(), proposalHandler.ProcessProposalHandler())
 	app.SetInsertTxHandler(insertTxHandler)
 	app.SetReapTxsHandler(reapTxsHandler)
 	app.SetCheckTxHandler(checkTxHandler)
diff --git a/evmd/zetaphy_aimodel.go b/evmd/zetaphy_aimodel.go
new file mode 100644
index 0000000..ac86d04
--- /dev/null
+++ b/evmd/zetaphy_aimodel.go
@@ -0,0 +1,276 @@
+package evmd
+
+// ZETAPHY v5 AI precompile at 0x…0902: a small gradient-boosted tree model
+// (GBDT) that governance stores in chain state, evaluated with integers only,
+// so every node gets the same answer.
+//
+//	score(bytes features) view returns (uint16 bps)
+//	    features: the model's feature vector, each an int32 (big-endian,
+//	    4 bytes; the exporter's scale is 1e4); returns the calibrated
+//	    probability in basis points (0..10000). Reverts when no model is set
+//	    or the length is not 4 × the model's feature count.
+//	model() view returns (bytes32 sha256, uint16 features, uint16 trees, uint32 nodes)
+//
+// Model format "ZGB1" (zetaphy-chain/tools/gbdt-export.mjs makes it from
+// Neuro's ml/model.json):
+//
+//	"ZGB1" | features u16 | trees u16 | base int32
+//	per tree: nodes u16, then per node (14 bytes):
+//	    feature u16 (0xFFFF: leaf) | threshold int32 | left u16 | right u16 | value int32
+//
+// A row goes left when x[feature] <= threshold. Values and base are logits
+// × 1e4 with the calibration already folded in. Children must come after
+// their parent, so every walk ends within the tree's node count.
+// Limits: 64 KiB, 512 trees, 255 nodes per tree, 1024 features.
+//
+// Gas: 2,000 + 6 per input word (RequiredGas), then 40 per tree and 8 per
+// node visited. The model is read without KV gas and parsed once per
+// version (cached by its sha256).
+
+import (
+	"bytes"
+	"crypto/sha256"
+	"encoding/binary"
+	"errors"
+	"fmt"
+	"sync"
+
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	cmn "github.com/cosmos/evm/precompiles/common"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+)
+
+const (
+	gbdtMaxBytes    = 64 << 10
+	gbdtMaxTrees    = 512
+	gbdtMaxNodes    = 255
+	gbdtMaxFeatures = 1024
+	gbdtNodeSize    = 14
+	gbdtLeaf        = 0xFFFF
+)
+
+type gbdtNode struct {
+	feature     uint16
+	threshold   int32
+	left, right uint16
+	value       int32
+}
+
+type gbdtModel struct {
+	hash     [32]byte
+	features int
+	base     int64
+	trees    [][]gbdtNode
+	nodes    int
+}
+
+// parseGBDT checks and decodes a model.
+func parseGBDT(b []byte) (*gbdtModel, error) {
+	if len(b) > gbdtMaxBytes {
+		return nil, fmt.Errorf("model larger than %d bytes", gbdtMaxBytes)
+	}
+	if len(b) < 12 || string(b[:4]) != "ZGB1" {
+		return nil, errors.New(`model: want "ZGB1" header`)
+	}
+	m := &gbdtModel{hash: sha256.Sum256(b), features: int(binary.BigEndian.Uint16(b[4:]))}
+	nt := int(binary.BigEndian.Uint16(b[6:]))
+	m.base = int64(int32(binary.BigEndian.Uint32(b[8:]))) // #nosec G115 -- two's complement int32
+	if m.features == 0 || m.features > gbdtMaxFeatures || nt == 0 || nt > gbdtMaxTrees {
+		return nil, fmt.Errorf("model: 1..%d features and 1..%d trees", gbdtMaxFeatures, gbdtMaxTrees)
+	}
+	p := 12
+	for t := 0; t < nt; t++ {
+		if p+2 > len(b) {
+			return nil, fmt.Errorf("model: tree %d truncated", t)
+		}
+		n := int(binary.BigEndian.Uint16(b[p:]))
+		p += 2
+		if n == 0 || n > gbdtMaxNodes || p+n*gbdtNodeSize > len(b) {
+			return nil, fmt.Errorf("model: tree %d: 1..%d nodes, all present", t, gbdtMaxNodes)
+		}
+		tree := make([]gbdtNode, n)
+		for i := range tree {
+			q := b[p+i*gbdtNodeSize:]
+			nd := gbdtNode{feature: binary.BigEndian.Uint16(q), threshold: int32(binary.BigEndian.Uint32(q[2:])), // #nosec G115 -- int32
+				left: binary.BigEndian.Uint16(q[6:]), right: binary.BigEndian.Uint16(q[8:]), value: int32(binary.BigEndian.Uint32(q[10:]))} // #nosec G115 -- int32
+			if nd.feature != gbdtLeaf {
+				if int(nd.feature) >= m.features {
+					return nil, fmt.Errorf("model: tree %d node %d: feature %d out of range", t, i, nd.feature)
+				}
+				if int(nd.left) <= i || int(nd.right) <= i || int(nd.left) >= n || int(nd.right) >= n {
+					return nil, fmt.Errorf("model: tree %d node %d: children must come after the node", t, i)
+				}
+			}
+			tree[i] = nd
+		}
+		p += n * gbdtNodeSize
+		m.trees = append(m.trees, tree)
+		m.nodes += n
+	}
+	if p != len(b) {
+		return nil, errors.New("model: trailing bytes")
+	}
+	return m, nil
+}
+
+// eval returns the raw margin (logit × 1e4) and the number of nodes visited.
+func (m *gbdtModel) eval(x []int32) (int64, int) {
+	z, visited := m.base, 0
+	for _, t := range m.trees {
+		i := 0
+		for {
+			visited++
+			nd := t[i]
+			if nd.feature == gbdtLeaf {
+				z += int64(nd.value)
+				break
+			}
+			if x[nd.feature] <= nd.threshold {
+				i = int(nd.left)
+			} else {
+				i = int(nd.right)
+			}
+		}
+	}
+	return z, visited
+}
+
+// sigmoidTable[i] = round(10000 / (1 + e^-((i-32)/4))): z from -8 to 8 by 0.25.
+var sigmoidTable = [65]int64{3, 4, 6, 7, 9, 12, 15, 19, 25, 32, 41, 52, 67, 86, 110, 141, 180, 230, 293, 373, 474, 601, 759, 953,
+	1192, 1480, 1824, 2227, 2689, 3208, 3775, 4378, 5000, 5622, 6225, 6792, 7311, 7773, 8176, 8520, 8808, 9047, 9241, 9399, 9526,
+	9627, 9707, 9770, 9820, 9859, 9890, 9914, 9933, 9948, 9959, 9968, 9975, 9981, 9985, 9988, 9991, 9993, 9994, 9996, 9997}
+
+// sigmoidBps: the logistic function of z (logit × 1e4) in basis points,
+// piecewise linear between the table's points (integers only).
+func sigmoidBps(z int64) uint16 {
+	const step = 2500 // 0.25 in logit × 1e4
+	if z <= -32*step {
+		return 0
+	}
+	if z >= 32*step {
+		return 10000
+	}
+	u := z + 32*step
+	i, r := u/step, u%step
+	v := sigmoidTable[i] + (sigmoidTable[i+1]-sigmoidTable[i])*r/step
+	return uint16(v) // #nosec G115 -- 0..10000
+}
+
+const aiPrecompileABIJSON = `[
+ {"type":"function","name":"score","stateMutability":"view","inputs":[{"name":"features","type":"bytes"}],"outputs":[{"name":"bps","type":"uint16"}]},
+ {"type":"function","name":"model","stateMutability":"view","inputs":[],"outputs":[{"name":"sha256","type":"bytes32"},{"name":"features","type":"uint16"},{"name":"trees","type":"uint16"},{"name":"nodes","type":"uint32"}]},
+ {"type":"function","name":"modelEpochs","stateMutability":"view","inputs":[],"outputs":[{"name":"registry","type":"address"}]}
+]`
+
+// AIABI is the AI precompile's ABI.
+var AIABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(aiPrecompileABIJSON)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+type aiPrecompile struct {
+	cmn.Precompile
+	app   *EVMD
+	mu    sync.Mutex
+	cache *gbdtModel
+}
+
+func newAIPrecompile(app *EVMD) *aiPrecompile {
+	return &aiPrecompile{Precompile: cmn.Precompile{
+		KvGasConfig: storetypes.KVGasConfig(), TransientKVGasConfig: storetypes.TransientGasConfig(),
+		ContractAddress: AIPrecompileAddress,
+	}, app: app}
+}
+
+func (*aiPrecompile) Name() string { return "zetaphy-ai" }
+
+func (p *aiPrecompile) RequiredGas(input []byte) uint64 {
+	return 2000 + 6*uint64((len(input)+31)/32) // #nosec G115 -- input length
+}
+
+func (p *aiPrecompile) Run(evm *vm.EVM, contract *vm.Contract, readonly bool) ([]byte, error) {
+	return p.RunNativeAction(evm, contract, func(ctx sdk.Context) ([]byte, error) {
+		method, args, err := cmn.SetupABI(AIABI, contract, readonly, func(*abi.Method) bool { return false })
+		if err != nil {
+			return nil, err
+		}
+		if v := contract.Value(); v != nil && !v.IsZero() {
+			return nil, errors.New("the AI precompile takes no value")
+		}
+		if method.Name == "modelEpochs" { // the Neuro ModelEpochs registry governance set (zetaphy_modelat.go)
+			reg, _ := p.app.modelEpochsAddr(ctx)
+			return method.Outputs.Pack(reg)
+		}
+		m := p.model(ctx)
+		switch method.Name {
+		case "model":
+			if m == nil {
+				return method.Outputs.Pack(common.Hash{}, uint16(0), uint16(0), uint32(0))
+			}
+			return method.Outputs.Pack(common.Hash(m.hash), uint16(m.features), uint16(len(m.trees)), uint32(m.nodes)) // #nosec G115 -- limits above
+		case "score":
+			if m == nil {
+				return nil, errors.New("no model is set (governance: security-proposal ai-model)")
+			}
+			x, err := gbdtFeatures(args[0].([]byte), m.features)
+			if err != nil {
+				return nil, err
+			}
+			ctx.GasMeter().ConsumeGas(40*uint64(len(m.trees)), "zetaphy ai trees") // #nosec G115 -- limits above
+			z, visited := m.eval(x)
+			ctx.GasMeter().ConsumeGas(8*uint64(visited), "zetaphy ai nodes") // #nosec G115 -- limits above
+			return method.Outputs.Pack(sigmoidBps(z))
+		}
+		return nil, fmt.Errorf("unknown method %s", method.Name)
+	})
+}
+
+func gbdtFeatures(b []byte, n int) ([]int32, error) {
+	if len(b) != 4*n {
+		return nil, fmt.Errorf("features: want %d int32 values (%d bytes), got %d bytes", n, 4*n, len(b))
+	}
+	x := make([]int32, n)
+	for i := range x {
+		x[i] = int32(binary.BigEndian.Uint32(b[4*i:])) // #nosec G115 -- int32
+	}
+	return x, nil
+}
+
+// model: the stored model, parsed once per content.
+func (p *aiPrecompile) model(ctx sdk.Context) *gbdtModel {
+	raw := p.app.secRaw(ctx).Get(aiModelKey)
+	if len(raw) == 0 {
+		return nil
+	}
+	h := sha256.Sum256(raw)
+	p.mu.Lock()
+	defer p.mu.Unlock()
+	if p.cache != nil && p.cache.hash == h {
+		return p.cache
+	}
+	m, err := parseGBDT(raw) // checked when governance set it
+	if err != nil {
+		return nil
+	}
+	p.cache = m
+	return m
+}
+
+// AIScore evaluates the stored model for a feature vector outside the EVM
+// (the immune system may use it; tests). ok is false without a model.
+func (app *EVMD) AIScore(ctx sdk.Context, features []int32) (uint16, bool) {
+	m := app.aiPrecompile.model(ctx)
+	if m == nil || len(features) != m.features {
+		return 0, false
+	}
+	z, _ := m.eval(features)
+	return sigmoidBps(z), true
+}
diff --git a/evmd/zetaphy_breaker.go b/evmd/zetaphy_breaker.go
new file mode 100644
index 0000000..69f3dd0
--- /dev/null
+++ b/evmd/zetaphy_breaker.go
@@ -0,0 +1,343 @@
+package evmd
+
+// ZETAPHY v5 bridge circuit breaker.
+//
+// Governance watches up to breakerMax bridge contracts (BridgeGuard, the
+// Saphan lock boxes, …) by naming the event that marks an outflow:
+//
+//	{"bridge":"0x…","topic":"0x<event topic0>","recipient_topic":2,"amount_word":0,
+//	 "min_volume":"1000000000000000000000","vol_mult_bps":50000,"new_ratio_bps":5000,
+//	 "baseline_shift":7,"enabled":true}
+//
+// e.g. BridgeGuard's Outbound(bytes32 indexed route, address indexed from,
+// uint256 amount): recipient in topic 2, amount in data word 0.
+//
+// Every block, each node adds up (deterministically, from the receipts' logs)
+// per bridge: the outflow volume, the number of outflows and how many went to
+// a recipient never seen before. A baseline is the exponential moving average
+// of the per-block volume (alpha = 2^-baseline_shift, idle blocks count as 0).
+//
+// Each validator then judges block N in its vote on N+1 and flags the bridge
+// when, in N, volume >= min_volume, volume >= baseline × vol_mult_bps / 1e4
+// and new recipients / outflows >= new_ratio_bps / 1e4. If validators with
+// more than 2/3 of the power flag it (checked in block N+2 with their
+// signatures, zetaphy_immune.go), the chain calls the bridge's pause() from
+// the breaker address (BreakerAddress) at the start of block N+2. Governance
+// must have made that address a guardian/pauser of the bridge (for
+// BridgeGuard: setGuardian(BreakerAddress, true)). The breaker fires once,
+// then stays tripped: unpause is the bridge's own governance-only function,
+// and "breaker-rearm" (governance) lets it fire again.
+
+import (
+	"bytes"
+	"encoding/binary"
+	"encoding/json"
+	"fmt"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+
+	errorsmod "cosmossdk.io/errors"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+
+	"github.com/cosmos/evm/x/vm/statedb"
+)
+
+// BreakerAddress calls pause() on a tripped bridge (a module address: no key).
+var BreakerAddress = common.BytesToAddress(authtypes.NewModuleAddress("zetaphy-breaker"))
+
+// breakerPauseSelector: pause().
+var breakerPauseSelector = []byte{0x84, 0x56, 0xcb, 0x59}
+
+const breakerPauseGas = 300_000
+
+type breakerCfg struct {
+	Bridge         string `json:"bridge"`
+	Topic          string `json:"topic"`
+	RecipientTopic uint8  `json:"recipient_topic"` // 1..3; 0: the event has no recipient (new_ratio is then ignored)
+	AmountWord     uint8  `json:"amount_word"`     // data word with the amount
+	MinVolume      string `json:"min_volume"`      // smallest units
+	VolMultBps     uint32 `json:"vol_mult_bps"`    // >= 10000
+	NewRatioBps    uint16 `json:"new_ratio_bps"`   // 0..10000
+	BaselineShift  uint8  `json:"baseline_shift"`  // 1..10 (default 7: ~128 blocks)
+	Enabled        bool   `json:"enabled"`
+
+	bridge    common.Address
+	topicHash common.Hash
+	minVolume *big.Int
+}
+
+func (c *breakerCfg) check() error {
+	if !common.IsHexAddress(c.Bridge) {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: bridge must be a 0x address")
+	}
+	c.bridge = common.HexToAddress(c.Bridge)
+	if !c.Enabled {
+		return nil
+	}
+	tb := common.FromHex(c.Topic)
+	if len(tb) != 32 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: topic must be 32 bytes (the event's topic0)")
+	}
+	c.topicHash = common.BytesToHash(tb)
+	if c.RecipientTopic > 3 || c.AmountWord > 15 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: recipient_topic 0..3, amount_word 0..15")
+	}
+	v, ok := new(big.Int).SetString(c.MinVolume, 10)
+	if !ok || v.Sign() <= 0 || v.BitLen() > 255 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: min_volume must be a positive whole number")
+	}
+	c.minVolume = v
+	if c.VolMultBps < 10000 || c.NewRatioBps > 10000 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: vol_mult_bps >= 10000, new_ratio_bps <= 10000")
+	}
+	if c.BaselineShift == 0 {
+		c.BaselineShift = 7
+	}
+	if c.BaselineShift > 10 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: baseline_shift 1..10")
+	}
+	return nil
+}
+
+func breakerKey(pfx byte, b common.Address) []byte { return append([]byte{pfx}, b.Bytes()...) }
+
+func (app *EVMD) setBreaker(ctx sdk.Context, c breakerCfg) error {
+	if err := c.check(); err != nil {
+		return err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if !c.Enabled {
+		for _, p := range []byte{breakerCfgPfx, breakerStatsPfx, breakerTripPfx, breakerPausePfx} {
+			st.Delete(breakerKey(p, c.bridge))
+		}
+		return nil
+	}
+	if app.breakerConfig(ctx, c.bridge) == nil && len(app.breakerConfigs(ctx)) >= breakerMax {
+		return errorsmod.Wrapf(errortypes.ErrInvalidRequest, "breaker: at most %d bridges", breakerMax)
+	}
+	if len(app.EVMKeeper.GetCode(ctx, app.EVMKeeper.GetCodeHash(ctx, c.bridge))) == 0 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "breaker: no contract at that address")
+	}
+	c.Bridge, c.Topic = c.bridge.Hex(), c.topicHash.Hex()
+	bz, _ := json.Marshal(c)
+	st.Set(breakerKey(breakerCfgPfx, c.bridge), bz)
+	return nil
+}
+
+func (app *EVMD) breakerConfig(ctx sdk.Context, b common.Address) *breakerCfg {
+	raw := app.secRaw(ctx).Get(breakerKey(breakerCfgPfx, b))
+	if raw == nil {
+		return nil
+	}
+	var c breakerCfg
+	if json.Unmarshal(raw, &c) != nil || c.check() != nil || !c.Enabled {
+		return nil
+	}
+	return &c
+}
+
+// breakerConfigs: the watched bridges, by address.
+func (app *EVMD) breakerConfigs(ctx sdk.Context) []*breakerCfg {
+	var out []*breakerCfg
+	p := []byte{breakerCfgPfx}
+	it := app.secRaw(ctx).Iterator(p, storetypes.PrefixEndBytes(p))
+	defer it.Close()
+	for ; it.Valid() && len(out) < breakerMax; it.Next() {
+		if c := app.breakerConfig(ctx, common.BytesToAddress(it.Key()[1:])); c != nil {
+			out = append(out, c)
+		}
+	}
+	return out
+}
+
+// breakerStats: the last block with outflows and the baseline before it.
+type breakerStats struct {
+	height               int64
+	volume               *big.Int
+	count, newRecipients uint32
+	baseline             *big.Int // EMA of per-block volume up to height-1
+}
+
+func (app *EVMD) breakerStatsOf(ctx sdk.Context, b common.Address) breakerStats {
+	s := breakerStats{volume: new(big.Int), baseline: new(big.Int)}
+	v := app.secRaw(ctx).Get(breakerKey(breakerStatsPfx, b))
+	if len(v) != 8+32+4+4+32 {
+		return s
+	}
+	s.height = int64(binary.BigEndian.Uint64(v)) // #nosec G115 -- block heights
+	s.volume.SetBytes(v[8:40])
+	s.count, s.newRecipients = binary.BigEndian.Uint32(v[40:]), binary.BigEndian.Uint32(v[44:])
+	s.baseline.SetBytes(v[48:80])
+	return s
+}
+
+func (s breakerStats) bytes() []byte {
+	out := u64(uint64(s.height)) // #nosec G115 -- block heights
+	out = append(out, common.LeftPadBytes(s.volume.Bytes(), 32)...)
+	out = binary.BigEndian.AppendUint32(out, s.count)
+	out = binary.BigEndian.AppendUint32(out, s.newRecipients)
+	return append(out, common.LeftPadBytes(s.baseline.Bytes(), 32)...)
+}
+
+var maxU256 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))
+
+// roll moves the stats to block h: the old block's volume and the idle
+// blocks in between go into the baseline.
+func (s *breakerStats) roll(h int64, shift uint8) {
+	if s.height == h {
+		return
+	}
+	if s.height > 0 {
+		// baseline += (volume - baseline) >> shift, then idle blocks decay it
+		d := new(big.Int).Sub(s.volume, s.baseline)
+		s.baseline.Add(s.baseline, d.Rsh(d, uint(shift)))
+		if d.Sign() < 0 && s.baseline.Sign() < 0 {
+			s.baseline.SetInt64(0)
+		}
+		for i := s.height + 1; i < h && s.baseline.Sign() > 0; i++ {
+			if i-s.height > int64(16)<<shift {
+				s.baseline.SetInt64(0)
+				break
+			}
+			s.baseline.Sub(s.baseline, new(big.Int).Rsh(s.baseline, uint(shift)))
+		}
+	}
+	s.height, s.volume, s.count, s.newRecipients = h, new(big.Int), 0, 0
+}
+
+// breakerNoteLogs counts a successful tx's outflows of watched bridges.
+func (app *EVMD) breakerNoteLogs(ctx sdk.Context, logs []*ethtypes.Log) {
+	if len(logs) == 0 || !app.futV5(ctx, ctx.BlockHeight()) || ctx.ExecMode() != sdk.ExecModeFinalize {
+		return
+	}
+	var cfgs []*breakerCfg
+	loaded := false
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	for _, l := range logs {
+		if l == nil || len(l.Topics) == 0 {
+			continue
+		}
+		if !loaded {
+			cfgs, loaded = app.breakerConfigs(ctx), true
+			if len(cfgs) == 0 {
+				return
+			}
+		}
+		for _, c := range cfgs {
+			if l.Address != c.bridge || l.Topics[0] != c.topicHash {
+				continue
+			}
+			w := int(c.AmountWord)
+			if len(l.Data) < 32*(w+1) || (c.RecipientTopic > 0 && len(l.Topics) <= int(c.RecipientTopic)) {
+				continue
+			}
+			amt := new(big.Int).SetBytes(l.Data[32*w : 32*(w+1)])
+			s := app.breakerStatsOf(ctx, c.bridge)
+			s.roll(ctx.BlockHeight(), c.BaselineShift)
+			s.volume.Add(s.volume, amt)
+			if s.volume.Cmp(maxU256) > 0 {
+				s.volume.Set(maxU256)
+			}
+			s.count++
+			if c.RecipientTopic > 0 {
+				seen := append(breakerKey(breakerSeenPfx, c.bridge), l.Topics[c.RecipientTopic][12:]...)
+				if !st.Has(seen) {
+					st.Set(seen, []byte{})
+					s.newRecipients++
+				}
+			}
+			st.Set(breakerKey(breakerStatsPfx, c.bridge), s.bytes())
+		}
+	}
+}
+
+// BreakerFlag is the default validator rule for block stats s.
+func BreakerFlag(c *breakerCfg, s breakerStats) bool {
+	if s.volume.Cmp(c.minVolume) < 0 {
+		return false
+	}
+	// volume × 1e4 >= baseline × vol_mult_bps
+	l := new(big.Int).Mul(s.volume, big.NewInt(10000))
+	r := new(big.Int).Mul(s.baseline, big.NewInt(int64(c.VolMultBps)))
+	if l.Cmp(r) < 0 {
+		return false
+	}
+	if c.RecipientTopic == 0 || s.count == 0 {
+		return true
+	}
+	return uint64(s.newRecipients)*10000 >= uint64(c.NewRatioBps)*uint64(s.count)
+}
+
+// breakerFlags: the bridges this validator flags for block h (state after h).
+func (app *EVMD) breakerFlags(ctx sdk.Context, h int64) []common.Address {
+	var out []common.Address
+	for _, c := range app.breakerConfigs(ctx) {
+		if app.secRaw(ctx).Has(breakerKey(breakerTripPfx, c.bridge)) {
+			continue // already tripped: nothing more to say
+		}
+		if s := app.breakerStatsOf(ctx, c.bridge); s.height == h && BreakerFlag(c, s) {
+			out = append(out, c.bridge)
+		}
+	}
+	return out
+}
+
+func (app *EVMD) breakerSchedulePause(ctx sdk.Context, b common.Address, powerBps int64) {
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if app.breakerConfig(ctx, b) == nil || st.Has(breakerKey(breakerTripPfx, b)) {
+		return
+	}
+	st.Set(breakerKey(breakerPausePfx, b), []byte{})
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_breaker_flagged", sdk.NewAttribute("bridge", b.Hex()), sdk.NewAttribute("power_bps", fmt.Sprint(powerBps))))
+}
+
+// breakerBeginBlock calls pause() on bridges the validators tripped. A
+// failing call (no pauser role, out of gas) is recorded, never fatal.
+func (app *EVMD) breakerBeginBlock(ctx sdk.Context) {
+	if !app.futV5(ctx, ctx.BlockHeight()) {
+		return
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	p := []byte{breakerPausePfx}
+	it := st.Iterator(p, storetypes.PrefixEndBytes(p))
+	var due []common.Address
+	for ; it.Valid() && len(due) < breakerMax; it.Next() {
+		due = append(due, common.BytesToAddress(it.Key()[1:]))
+	}
+	_ = it.Close()
+	for _, b := range due {
+		st.Delete(breakerKey(breakerPausePfx, b))
+		ok := app.breakerCallPause(ctx, b)
+		st.Set(breakerKey(breakerTripPfx, b), append(u64(uint64(ctx.BlockHeight())), map[bool]byte{false: 0, true: 1}[ok])) // #nosec G115 -- block heights
+		ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_breaker_pause", sdk.NewAttribute("bridge", b.Hex()), sdk.NewAttribute("ok", fmt.Sprint(ok))))
+	}
+}
+
+func (app *EVMD) breakerCallPause(ctx sdk.Context, b common.Address) (ok bool) {
+	c, write := ctx.CacheContext()
+	c = c.WithGasMeter(storetypes.NewInfiniteGasMeter()).WithKVGasConfig(storetypes.GasConfig{}).
+		WithTransientKVGasConfig(storetypes.GasConfig{})
+	defer func() {
+		if r := recover(); r != nil {
+			ok = false
+		}
+	}()
+	sdb := statedb.New(c, app.EVMKeeper, statedb.NewEmptyTxConfig())
+	res, err := app.EVMKeeper.ApplyMessage(c, sdb, core.Message{
+		From: BreakerAddress, To: &b, Value: new(big.Int), GasLimit: breakerPauseGas, Data: bytes.Clone(breakerPauseSelector),
+		GasPrice: new(big.Int), GasFeeCap: new(big.Int), GasTipCap: new(big.Int), AccessList: ethtypes.AccessList{},
+		SkipNonceChecks: true,
+	}, nil, true, false, true)
+	if err != nil || res == nil || res.Failed() {
+		return false
+	}
+	write()
+	return true
+}
diff --git a/evmd/zetaphy_cosmwasm.go b/evmd/zetaphy_cosmwasm.go
new file mode 100644
index 0000000..a786a35
--- /dev/null
+++ b/evmd/zetaphy_cosmwasm.go
@@ -0,0 +1,316 @@
+package evmd
+
+// ZETAPHY stage 7: CosmWasm (Rust smart contracts, x/wasm from wasmd) next
+// to the EVM, on the same chain, accounts and coins.
+//
+// Security defaults (docs/SECURITY-CORE.md, "CosmWasm"):
+//   - code upload: governance only (CodeUploadAccess = Nobody; a gov
+//     proposal with MsgStoreCode, or MsgUpdateParams for an allow-list);
+//     instantiate: everybody, unless the stored code says otherwise;
+//   - code size: 800 KiB, also for code stored by proposal;
+//   - wasm txs are ordinary Cosmos txs: the quantum lock, Q-day (ML-DSA-44
+//     signers only) and the fee burn apply to them unchanged;
+//   - what a contract dispatches is checked too (wasmGuard below): it cannot
+//     use an authz grant of a quantum-locked account, send EVM txs or ZETAPHY
+//     post-quantum messages, or open IBC channels / send raw IBC packets.
+//     ICS-20 transfers from contracts go through the full transfer stack
+//     (rate limits; inbound: the large-transfer hold);
+//   - IBC for wasm ports (wasm.<addr>, wasm2<addr>) is off: no route is
+//     registered, so no channel can be opened to a contract. Opening it
+//     later is a governance-scheduled upgrade with its own review;
+//   - the threat gate stays EVM-only: the ThreatRegistry flags 20-byte EVM
+//     contracts and Neuro reads EVM bytecode, while contract addresses here
+//     are 32 bytes. A contract cannot call an EVM contract as itself
+//     (MsgEVMCall needs a 20-byte sender, MsgEthereumTx is refused below),
+//     and a MsgEVMCall it runs through authz is checked where it runs.
+//
+// Upgrade path: a new chain has x/wasm from genesis (DefaultGenesis below,
+// setup-node.sh); a running chain gets the "zetaphy-v4" upgrade, which adds
+// the wasm store and sets the parameters above (it includes v2 and v3).
+
+import (
+	"context"
+	"encoding/json"
+	"fmt"
+	"os"
+	"path/filepath"
+	"strings"
+	"sync"
+
+	wasmvmtypes "github.com/CosmWasm/wasmvm/v3/types"
+
+	"github.com/CosmWasm/wasmd/x/wasm"
+	wasmkeeper "github.com/CosmWasm/wasmd/x/wasm/keeper"
+	"github.com/CosmWasm/wasmd/x/wasm/keeper/wasmtesting"
+	wasmtypes "github.com/CosmWasm/wasmd/x/wasm/types"
+
+	errorsmod "cosmossdk.io/errors"
+
+	"github.com/cosmos/cosmos-sdk/baseapp"
+	"github.com/cosmos/cosmos-sdk/codec"
+	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
+	"github.com/cosmos/cosmos-sdk/runtime"
+	servertypes "github.com/cosmos/cosmos-sdk/server/types"
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/types/module"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+	distrkeeper "github.com/cosmos/cosmos-sdk/x/distribution/keeper"
+	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+// ZetaphyV4UpgradeName adds CosmWasm to a chain that runs without it.
+const ZetaphyV4UpgradeName = "zetaphy-v4"
+
+// ZetaphyMaxWasmSize: the largest contract code, uncompressed (wasmd's
+// default for MsgStoreCode); code stored by proposal gets the same cap
+// instead of wasmd's 3 MiB.
+const ZetaphyMaxWasmSize = 800 * 1024
+
+// ErrWasmGuard is the refusal of a message a contract dispatched (codespace "zetaphy", code 30).
+var ErrWasmGuard = errorsmod.Register("zetaphy", 30, "not allowed from a CosmWasm contract")
+
+func init() {
+	wasmtypes.MaxWasmSize = ZetaphyMaxWasmSize
+	wasmtypes.MaxProposalWasmSize = ZetaphyMaxWasmSize
+}
+
+// ZetaphyWasmParams: upload by governance only, instantiate by everybody.
+func ZetaphyWasmParams() wasmtypes.Params {
+	return wasmtypes.Params{CodeUploadAccess: wasmtypes.AllowNobody, InstantiateDefaultPermission: wasmtypes.AccessTypeEverybody}
+}
+
+// setupWasm creates the wasm keeper (after the IBC, transfer and EVM keepers).
+func (app *EVMD) setupWasm(appOpts servertypes.AppOptions, homePath string) wasmtypes.NodeConfig {
+	nodeConfig, err := wasm.ReadNodeConfig(appOpts)
+	if err != nil {
+		panic(fmt.Sprintf("error while reading wasm config: %s", err))
+	}
+	opts := []wasmkeeper.Option{
+		wasmkeeper.WithMessageHandlerDecorator(func(old wasmkeeper.Messenger) wasmkeeper.Messenger {
+			return wasmGuardMessenger{next: old}
+		}),
+	}
+	wasmDir := wasmVMDir(homePath)
+	if wasmDir == "" {
+		// An app without a home only serves the CLI's encoding setup: no VM
+		// (wasmvm would take a directory and its lock for nothing).
+		opts = append(opts, wasmkeeper.WithWasmEngine(&wasmtesting.MockWasmEngine{}))
+	}
+	app.WasmKeeper = wasmkeeper.NewKeeper(
+		app.appCodec,
+		runtime.NewKVStoreService(app.keys[wasmtypes.StoreKey]),
+		app.AccountKeeper,
+		app.BankKeeper,
+		app.StakingKeeper,
+		distrkeeper.NewQuerier(app.DistrKeeper),
+		app.IBCKeeper.ChannelKeeper,
+		app.IBCKeeper.ChannelKeeper,
+		app.IBCKeeper.ChannelKeeperV2,
+		app.TransferKeeper,
+		wasmGuardRouter{app: app, next: app.MsgServiceRouter()},
+		app.GRPCQueryRouter(),
+		wasmDir,
+		nodeConfig,
+		wasmtypes.VMConfig{},
+		wasmkeeper.BuiltInCapabilities(),
+		authtypes.NewModuleAddress("gov").String(),
+		opts...,
+	)
+	return nodeConfig
+}
+
+// wasmDirsInUse: the VM directories of the apps of this process. wasmvm
+// locks its directory; a second app in the same process (tests, in-process
+// testnets) gets a temporary one.
+var wasmDirsInUse sync.Map
+
+func wasmVMDir(home string) string {
+	if home == "" {
+		return ""
+	}
+	d := filepath.Join(home, "wasm")
+	if _, used := wasmDirsInUse.LoadOrStore(d, true); used {
+		t, err := os.MkdirTemp("", "zetaphy-wasm-")
+		if err != nil {
+			panic(err)
+		}
+		return t
+	}
+	return d
+}
+
+// wasmAnteDecorators run in the Cosmos tx ante chain right after its context
+// setup, as in wasmd: simulation gas capped (by [wasm] simulation_gas_limit,
+// or the block gas limit), the tx position for wasm txs, the gas register,
+// and the per-tx contract cache discount.
+func (app *EVMD) wasmAnteDecorators(nodeConfig wasmtypes.NodeConfig) []sdk.AnteDecorator {
+	return []sdk.AnteDecorator{
+		wasmkeeper.NewLimitSimulationGasDecorator(nodeConfig.SimulationGasLimit),
+		wasmOnlyDecorator{wasmkeeper.NewCountTXDecorator(runtime.NewKVStoreService(app.keys[wasmtypes.StoreKey]))},
+		wasmkeeper.NewGasRegisterDecorator(app.WasmKeeper.GetGasRegister()),
+		wasmkeeper.NewTxContractsDecorator(),
+	}
+}
+
+// wasmOnlyDecorator runs its decorator only for txs with a wasm message.
+// The tx counter is a single key every counted tx writes; keeping other txs
+// out of it keeps them parallel under the block-STM runner.
+type wasmOnlyDecorator struct{ d sdk.AnteDecorator }
+
+func (w wasmOnlyDecorator) AnteHandle(ctx sdk.Context, tx sdk.Tx, sim bool, next sdk.AnteHandler) (sdk.Context, error) {
+	if !hasWasmMsg(tx.GetMsgs(), 0) {
+		return next(ctx, tx, sim)
+	}
+	return w.d.AnteHandle(ctx, tx, sim, next)
+}
+
+func hasWasmMsg(msgs []sdk.Msg, depth int) bool {
+	for _, m := range msgs {
+		if strings.HasPrefix(sdk.MsgTypeURL(m), "/cosmwasm.wasm.") {
+			return true
+		}
+		if ex, ok := m.(*authz.MsgExec); ok && depth < 4 {
+			if inner, err := ex.GetMessages(); err == nil && hasWasmMsg(inner, depth+1) {
+				return true
+			}
+		}
+	}
+	return false
+}
+
+// ---- what contracts may dispatch
+
+// wasmGuardMessenger: no IBC channel traffic from contracts (their ports
+// have no route); ICS-20 transfers (IbcMsg::Transfer) pass, as a normal
+// MsgTransfer through the transfer stack.
+type wasmGuardMessenger struct{ next wasmkeeper.Messenger }
+
+func (g wasmGuardMessenger) DispatchMsg(ctx sdk.Context, contractAddr sdk.AccAddress, portID string, msg wasmvmtypes.CosmosMsg) ([]sdk.Event, [][]byte, [][]*codectypes.Any, error) {
+	if msg.IBC2 != nil || (msg.IBC != nil && msg.IBC.Transfer == nil) {
+		return nil, nil, nil, errorsmod.Wrap(ErrWasmGuard, "IBC channels for contracts are off on ZETAPHY; ICS-20 transfers are allowed")
+	}
+	return g.next.DispatchMsg(ctx, contractAddr, portID, msg)
+}
+
+// wasmGuardRouter is the message router the wasm keeper dispatches through.
+type wasmGuardRouter struct {
+	app  *EVMD
+	next *baseapp.MsgServiceRouter
+}
+
+func (r wasmGuardRouter) Handler(msg sdk.Msg) baseapp.MsgServiceHandler {
+	h := r.next.Handler(msg)
+	if h == nil {
+		return nil
+	}
+	return func(ctx sdk.Context, m sdk.Msg) (*sdk.Result, error) {
+		if err := r.app.wasmGuard(ctx, m, 0); err != nil {
+			return nil, err
+		}
+		return h(ctx, m)
+	}
+}
+
+// wasmGuard refuses, from a contract: EVM txs and ZETAPHY's account
+// messages (they are for keys, a contract has none), and any message, also
+// inside authz, on behalf of a quantum-locked account (the ante handler
+// refuses those for signed txs; a contract holding an older grant must not
+// get around it).
+func (app *EVMD) wasmGuard(ctx sdk.Context, m sdk.Msg, depth int) error {
+	url := sdk.MsgTypeURL(m)
+	if url == sdk.MsgTypeURL(&evmtypes.MsgEthereumTx{}) || strings.HasPrefix(url, "/zetaphy.") {
+		return errorsmod.Wrapf(ErrWasmGuard, "%s", url)
+	}
+	signers, _, err := app.appCodec.GetMsgV1Signers(m)
+	if err != nil {
+		return err
+	}
+	for _, s := range signers {
+		if app.pqController(ctx, s) != nil {
+			return errorsmod.Wrapf(errortypes.ErrUnauthorized, "%s is quantum-locked: only its ML-DSA-44 controller can act for it", sdk.AccAddress(s))
+		}
+	}
+	if ex, ok := m.(*authz.MsgExec); ok {
+		if depth >= 4 {
+			return errorsmod.Wrap(ErrWasmGuard, "authz nested too deep")
+		}
+		inner, err := ex.GetMessages()
+		if err != nil {
+			return err
+		}
+		for _, im := range inner {
+			if err := app.wasmGuard(ctx, im, depth+1); err != nil {
+				return err
+			}
+		}
+	}
+	return nil
+}
+
+// ---- genesis and upgrade
+
+// wasmGenesisBasic is x/wasm's module basic with ZETAPHY's parameters in
+// its default genesis (what `zetaphyd init` and DefaultGenesis write).
+type wasmGenesisBasic struct{ wasm.AppModuleBasic }
+
+func (wasmGenesisBasic) DefaultGenesis(cdc codec.JSONCodec) json.RawMessage {
+	return cdc.MustMarshalJSON(&wasmtypes.GenesisState{Params: ZetaphyWasmParams()})
+}
+
+// zetaphyWasmMigrations runs the module migrations of an upgrade and, when
+// x/wasm is new on this chain (its genesis just ran with wasmd's defaults),
+// sets ZETAPHY's parameters.
+func (app *EVMD) zetaphyWasmMigrations(c context.Context, fromVM module.VersionMap) (module.VersionMap, error) {
+	_, had := fromVM[wasmtypes.ModuleName]
+	vm, err := app.ModuleManager.RunMigrations(c, app.Configurator(), fromVM)
+	if err != nil || had {
+		return vm, err
+	}
+	if err := app.WasmKeeper.SetParams(c, ZetaphyWasmParams()); err != nil {
+		return nil, err
+	}
+	sdk.UnwrapSDKContext(c).Logger().Info("CosmWasm added", "upload", "governance only", "instantiate", "everybody")
+	return vm, nil
+}
+
+// registerZetaphyV4 (from registerZetaphyUpgrades): "zetaphy-v4" turns on
+// what v3 does when it is not on yet, then adds x/wasm.
+func (app *EVMD) registerZetaphyV4() {
+	app.UpgradeKeeper.SetUpgradeHandler(ZetaphyV4UpgradeName,
+		func(c context.Context, _ upgradetypes.Plan, fromVM module.VersionMap) (module.VersionMap, error) {
+			ctx := sdk.UnwrapSDKContext(c)
+			if !app.zetaphyV2(ctx, ctx.BlockHeight()+1) {
+				p := app.EVMKeeper.GetParams(ctx)
+				p.HistoryServeWindow = evmtypes.DefaultHistoryServeWindow
+				if err := app.EVMKeeper.SetParams(ctx, p); err != nil {
+					return nil, err
+				}
+				app.setZetaphyV2Height(ctx, ctx.BlockHeight()+1)
+			}
+			if a := app.secV3Height(ctx); a == 0 || a > ctx.BlockHeight()+1 {
+				app.setSecV3Height(ctx, ctx.BlockHeight()+1)
+			}
+			ctx.Logger().Info("ZETAPHY v4 (CosmWasm) scheduled", "from_height", ctx.BlockHeight()+1)
+			return app.zetaphyWasmMigrations(c, fromVM)
+		})
+}
+
+// zetaphyStoreUpgrades: the stores an upgrade to this binary adds. A chain
+// reaching any ZETAPHY upgrade with this binary has no wasm store yet (a
+// chain started with it never needs those upgrades).
+func zetaphyStoreUpgrades() *storetypes.StoreUpgrades {
+	return &storetypes.StoreUpgrades{Added: []string{wasmtypes.StoreKey}}
+}
+
+// wasmPinnedCodes loads pinned contracts into the VM's cache at start (they
+// are not persisted there).
+func (app *EVMD) wasmPinnedCodes(ctx sdk.Context) {
+	if err := app.WasmKeeper.InitializePinnedCodes(ctx); err != nil {
+		panic(fmt.Sprintf("failed to initialize pinned wasm codes: %s", err))
+	}
+}
diff --git a/evmd/zetaphy_faucetpow.go b/evmd/zetaphy_faucetpow.go
new file mode 100644
index 0000000..796f884
--- /dev/null
+++ b/evmd/zetaphy_faucetpow.go
@@ -0,0 +1,180 @@
+package evmd
+
+// ZETAPHY testnet faucet behind a proof of work: zetaphy_faucetPow, for the
+// hub's "Mine testnet ZETAPHY" page. This is not mining: no block, coin or
+// reward comes from the work, and ZETAPHY stays proof of stake. The work is a
+// captcha a browser solves so one person cannot drain the faucet with many
+// addresses or internet addresses: every grant costs minutes of a computer.
+// The grant itself is zetaphy_faucet's (faucetGrant in zetaphy_rpc.go): the
+// same key and amount, the same daily cap and per-address cooldown, nothing
+// for an address that already has funds, and only through this machine's
+// https address (rpc-guard counts calls per IP).
+//
+// A proof for address A at block height h is an 8-byte nonce such that
+//
+//	sha256(chainId (8 bytes, big-endian) || hash of block h (32) || A (20) || nonce (8))
+//
+// starts with at least the difficulty's number of zero bits. h must be one of
+// the last FaucetPowMaxAge blocks (no work done in advance), the proof binds A
+// (it cannot be handed to another address), and an (address, height) pair
+// gets one grant. Nothing is stored on chain: the used pairs are kept in
+// memory and dropped once their height is too old to be used anyway.
+//
+// The difficulty is FaucetPowBits, or the number in <home>/config/faucet-pow-bits
+// (FaucetPowMinBits to FaucetPowMaxBits; read on every call, no restart).
+
+import (
+	"context"
+	"crypto/sha256"
+	"encoding/binary"
+	"fmt"
+	"math/bits"
+	"os"
+	"path/filepath"
+	"strconv"
+	"strings"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+
+	rpctypes "github.com/cosmos/evm/rpc/types"
+)
+
+const (
+	// FaucetPowBits: 2^30 tries on average, about 2–5 minutes for a laptop
+	// browser with two threads (measured numbers in zetaphy-hub/README.md).
+	FaucetPowBits     = 30
+	FaucetPowMinBits  = 12
+	FaucetPowMaxBits  = 48
+	FaucetPowMaxAge   = 100 // blocks (about 8 minutes at 5 s a block)
+	faucetPowBitsFile = "faucet-pow-bits"
+	faucetPowProof    = "sha256(chainId as 8 bytes big-endian || hash of block `height` (eth_getBlockByNumber) || address (20 bytes) || nonce (8 bytes)) starts with `bits` zero bits"
+)
+
+type powUse struct {
+	to     common.Address
+	height uint64
+}
+
+// FaucetPowDigest is the hash a proof must start with zero bits.
+func FaucetPowDigest(chainID uint64, blockHash []byte, to common.Address, nonce []byte) [32]byte {
+	b := make([]byte, 0, 68)
+	b = binary.BigEndian.AppendUint64(b, chainID)
+	b = append(b, blockHash...)
+	b = append(b, to.Bytes()...)
+	b = append(b, nonce...)
+	return sha256.Sum256(b)
+}
+
+// powZeroBits: the leading zero bits of a hash.
+func powZeroBits(h [32]byte) int {
+	for i, x := range h {
+		if x != 0 {
+			return i*8 + bits.LeadingZeros8(x)
+		}
+	}
+	return 256
+}
+
+// faucetPowBits: the operator's difficulty file, else FaucetPowBits.
+func (a *ZetaphyAPI) faucetPowBits() int {
+	raw, err := os.ReadFile(filepath.Join(a.clientCtx.HomeDir, "config", faucetPowBitsFile))
+	if err != nil {
+		return FaucetPowBits
+	}
+	n, err := strconv.Atoi(strings.TrimSpace(string(raw)))
+	if err != nil || n < FaucetPowMinBits || n > FaucetPowMaxBits {
+		return FaucetPowBits
+	}
+	return n
+}
+
+// FaucetPowInfo: what a miner needs before it starts.
+type FaucetPowInfo struct {
+	Enabled         bool         `json:"enabled"` // the faucet has its key on this node
+	Bits            int          `json:"bits"`
+	Reward          *hexutil.Big `json:"reward"`
+	ChainID         uint64       `json:"chainId"`
+	LatestHeight    uint64       `json:"latestHeight"`
+	MaxAgeBlocks    uint64       `json:"maxAgeBlocks"`
+	RemainingToday  int          `json:"remainingToday"` // grants left today (UTC), all addresses together
+	PerDay          int          `json:"perDay"`
+	CooldownSeconds int64        `json:"cooldownSeconds"` // per address, shared with zetaphy_faucet
+	Proof           string       `json:"proof"`
+}
+
+// FaucetPowInfo (zetaphy_faucetPowInfo): the difficulty, the reward, how old
+// a proof's block may be, and today's remaining grants.
+func (a *ZetaphyAPI) FaucetPowInfo(ctx context.Context) (*FaucetPowInfo, error) {
+	latest, err := a.backend.BlockNumber(ctx)
+	if err != nil {
+		return nil, err
+	}
+	out := &FaucetPowInfo{
+		Bits: a.faucetPowBits(), Reward: (*hexutil.Big)(FaucetAmount), ChainID: a.backend.ChainConfig().ChainID.Uint64(),
+		LatestHeight: uint64(latest), MaxAgeBlocks: FaucetPowMaxAge, PerDay: FaucetPerDay,
+		CooldownSeconds: int64(faucetCooldown.Seconds()), Proof: faucetPowProof,
+	}
+	faucet.Lock()
+	defer faucet.Unlock()
+	_, err = a.faucetKey()
+	out.Enabled = err == nil
+	faucetDay(faucetNow().UTC())
+	out.RemainingToday = max(0, FaucetPerDay-faucet.count)
+	return out, nil
+}
+
+// FaucetPow (zetaphy_faucetPow) sends FaucetAmount to address for a proof of
+// work at a recent block (see the top of this file).
+func (a *ZetaphyAPI) FaucetPow(ctx context.Context, address string, height hexutil.Uint64, nonce hexutil.Bytes) (*FaucetResult, error) {
+	addr, err := parseAccount(address)
+	if err != nil {
+		return nil, fmt.Errorf("invalid address: %w", err)
+	}
+	to := common.BytesToAddress(addr)
+	if err := faucetPeerOK(ctx); err != nil {
+		return nil, err
+	}
+	if len(nonce) != 8 {
+		return nil, fmt.Errorf("nonce: 8 bytes (0x and 16 hex digits)")
+	}
+	n, err := a.backend.BlockNumber(ctx)
+	if err != nil {
+		return nil, err
+	}
+	latest, h := uint64(n), uint64(height)
+	if h == 0 || h > latest {
+		return nil, fmt.Errorf("block %d is not there yet (latest %d)", h, latest)
+	}
+	if latest-h >= FaucetPowMaxAge {
+		return nil, fmt.Errorf("the proof's block %d is too old: use one of the last %d blocks (latest %d)", h, FaucetPowMaxAge, latest)
+	}
+	blk, err := a.backend.CometBlockByNumber(ctx, rpctypes.BlockNumber(h)) // #nosec G115 -- block heights
+	if err != nil || blk == nil || blk.Block == nil || len(blk.BlockID.Hash) != 32 {
+		return nil, fmt.Errorf("block %d not found", h)
+	}
+	need := a.faucetPowBits()
+	if got := powZeroBits(FaucetPowDigest(a.backend.ChainConfig().ChainID.Uint64(), blk.BlockID.Hash, to, nonce)); got < need {
+		return nil, fmt.Errorf("the proof has %d leading zero bits; %d are needed", got, need)
+	}
+	faucet.Lock()
+	defer faucet.Unlock()
+	if faucet.powUsed == nil {
+		faucet.powUsed = map[powUse]uint64{}
+	}
+	for k, kh := range faucet.powUsed {
+		if kh+FaucetPowMaxAge <= latest {
+			delete(faucet.powUsed, k)
+		}
+	}
+	use := powUse{to, h}
+	if _, used := faucet.powUsed[use]; used {
+		return nil, fmt.Errorf("this proof was used already; mine a new one")
+	}
+	res, err := a.faucetGrant(ctx, to)
+	if err != nil {
+		return nil, err
+	}
+	faucet.powUsed[use] = h
+	return res, nil
+}
diff --git a/evmd/zetaphy_feeburn.go b/evmd/zetaphy_feeburn.go
new file mode 100644
index 0000000..a68e4a1
--- /dev/null
+++ b/evmd/zetaphy_feeburn.go
@@ -0,0 +1,83 @@
+package evmd
+
+import (
+	"github.com/ethereum/go-ethereum/common"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+// ZETAPHY: half of every block's transaction fees is burned, the other half
+// goes to validators as usual. Like EIP-1559's burned base fee, this makes
+// heavy use of the chain shrink the supply instead of only paying validators.
+//
+// It runs at the start of each block, before the distribution module pays
+// out what the fee collector received in the previous block. The fee
+// collector has no burn permission, so the coins move to the EVM module
+// (which has it) and are burned there, all-or-nothing in a cached context.
+const FeeBurnPercent = 50
+
+func (app *EVMD) burnFees(ctx sdk.Context) {
+	denom := evmtypes.GetEVMCoinDenom()
+	collector := app.AccountKeeper.GetModuleAddress(authtypes.FeeCollectorName)
+	if collector == nil || denom == "" {
+		return
+	}
+	bal := app.BankKeeper.GetBalance(ctx, collector, denom)
+	burn := bal.Amount.MulRaw(FeeBurnPercent).QuoRaw(100)
+	if !burn.IsPositive() {
+		return
+	}
+	coins := sdk.NewCoins(sdk.NewCoin(denom, burn))
+	cctx, write := ctx.CacheContext()
+	if err := app.BankKeeper.SendCoinsFromModuleToModule(cctx, authtypes.FeeCollectorName, evmtypes.ModuleName, coins); err != nil {
+		ctx.Logger().Error("fee burn: move to burner failed", "err", err)
+		return
+	}
+	if err := app.BankKeeper.BurnCoins(cctx, evmtypes.ModuleName, coins); err != nil {
+		ctx.Logger().Error("fee burn: burn failed", "err", err)
+		return
+	}
+	write()
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_fee_burn", sdk.NewAttribute("amount", coins.String())))
+}
+
+// DeadAddress is the conventional burn address. ZETAPHY sent to it (Neuro
+// sends 5% of its fees there) used to stay counted in the total supply; from
+// the v2 activation height (zetaphy_upgrade.go) each block it is really
+// burned, also at the start of the block. Other denoms at that address are
+// left as they are.
+//
+// Only the spendable part is burned. Anyone could make 0x…dEaD a vesting or
+// permanently locked account before the first burn (MsgCreateVestingAccount
+// to an address without an account); moving the whole balance would then
+// fail every block. Coins locked that way stay at dEaD (they were the
+// creator's own and can never be spent); everything sent there afterwards is
+// spendable and burned.
+var DeadAddress = common.HexToAddress("0x000000000000000000000000000000000000dEaD")
+
+func (app *EVMD) burnDead(ctx sdk.Context) {
+	denom := evmtypes.GetEVMCoinDenom()
+	if denom == "" || !app.zetaphyV2(ctx, ctx.BlockHeight()) {
+		return
+	}
+	dead := sdk.AccAddress(DeadAddress.Bytes())
+	amt := app.BankKeeper.SpendableCoin(ctx, dead, denom).Amount // zero when there is no account
+	if !amt.IsPositive() {
+		return
+	}
+	coins := sdk.NewCoins(sdk.NewCoin(denom, amt))
+	cctx, write := ctx.CacheContext()
+	if err := app.BankKeeper.SendCoinsFromAccountToModule(cctx, dead, evmtypes.ModuleName, coins); err != nil {
+		ctx.Logger().Error("dead burn: move to burner failed", "err", err)
+		return
+	}
+	if err := app.BankKeeper.BurnCoins(cctx, evmtypes.ModuleName, coins); err != nil {
+		ctx.Logger().Error("dead burn: burn failed", "err", err)
+		return
+	}
+	write()
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_dead_burn", sdk.NewAttribute("amount", coins.String())))
+}
diff --git a/evmd/zetaphy_future.go b/evmd/zetaphy_future.go
new file mode 100644
index 0000000..2863fea
--- /dev/null
+++ b/evmd/zetaphy_future.go
@@ -0,0 +1,291 @@
+package evmd
+
+// ZETAPHY v5: protocol-level protection research, all off until governance
+// (or, for accounts, the account itself) turns it on. docs/future/chain-protocol.md.
+//
+//   - AI precompile (zetaphy_aimodel.go, 0x…0902): an integer-only
+//     gradient-boosted tree model, set by governance, scores a feature vector.
+//   - Immune system (zetaphy_immune.go, 0x…0903): validators score the
+//     contracts deployed in a block from their bytecode and put the scores in
+//     their vote extension, after the ML-DSA vote signature; the median is
+//     recorded on chain and readable through a ThreatRegistry-compatible view.
+//   - Bridge circuit breaker (zetaphy_breaker.go): validators flag an
+//     anomalous outflow of a watched bridge in the same vote extension; on a
+//     2/3 supermajority the chain calls the bridge's pause(). Only
+//     governance unpauses (on the bridge) and re-arms (here).
+//   - Protected accounts and anomaly hold (zetaphy_guard.go, 0x…0904):
+//     opt-in, per account; the hold covers the native coin and ERC-20s.
+//   - Neuro model by height (zetaphy_modelat.go): governance points the
+//     chain at a ModelEpochs registry; ModelVersionAt reads it.
+//
+// Upgrade path, as the security core: a new chain has v5 from block 1 (key
+// 0x20 = 1 in app_state.zetaphypq); a running chain gets "zetaphy-v5", which
+// sets 0x20 to the upgrade height + 1. Below it nothing changes: the three
+// addresses are empty accounts and vote extensions carry the signature only.
+
+import (
+	"bytes"
+	"context"
+	"encoding/json"
+	"fmt"
+	"strings"
+
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	errorsmod "cosmossdk.io/errors"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/types/module"
+	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
+)
+
+// Keys of the zetaphypq store used by v5.
+var (
+	futV5Key          = []byte{0x20} // height (8) from which v5 applies
+	aiModelKey        = []byte{0x21} // the GBDT model (binary, zetaphy_aimodel.go)
+	immuneParamsKey   = []byte{0x22} // immuneParams (JSON)
+	immunePendingPfx  = byte(0x23)   // || height (8) || contract (20) -> {}: deployed in that block, to be scored
+	immuneScorePfx    = byte(0x24)   // || contract (20) -> score (2) || height (8) || voters' power share bps (2)
+	breakerCfgPfx     = byte(0x25)   // || bridge (20) -> breakerCfg (JSON)
+	breakerStatsPfx   = byte(0x26)   // || bridge (20) -> breakerStats (binary)
+	breakerSeenPfx    = byte(0x27)   // || bridge (20) || recipient (20) -> {}
+	breakerTripPfx    = byte(0x28)   // || bridge (20) -> height (8) || pause call ok (1)
+	breakerPausePfx   = byte(0x29)   // || bridge (20) -> {}: pause due in this block's BeginBlock
+	guardProtectPfx   = byte(0x2A)   // || account (20) -> guardProtection (binary)
+	guardQueuePfx     = byte(0x2B)   // || account (20) || target (20) -> usable from, unix s (8)
+	holdCfgPfx        = byte(0x2C)   // || account (20) -> holdCfg (binary)
+	holdStatsPfx      = byte(0x2D)   // || account (20) -> holdStats (binary)
+	holdTokenPfx      = byte(0x2E)   // || account (20) || token (20) -> holdRule (binary)
+	holdTokenStatsPfx = byte(0x2F)   // || account (20) || token (20) -> holdStats (binary)
+	modelEpochsKey    = []byte{0x30} // the ModelEpochs registry, EVM address (20) (zetaphy_modelat.go)
+)
+
+// futKeyKnown: v5 prefixes a genesis may carry.
+func futKeyKnown(p byte) bool { return p >= 0x20 && p <= 0x30 }
+
+// ZetaphyV5UpgradeName turns v5 on for a running chain (from the next block).
+const ZetaphyV5UpgradeName = "zetaphy-v5"
+
+// The v5 precompiles (on from the v5 height, whatever active_static_precompiles says).
+var (
+	AIPrecompileAddress     = common.HexToAddress("0x0000000000000000000000000000000000000902")
+	ImmunePrecompileAddress = common.HexToAddress("0x0000000000000000000000000000000000000903")
+	GuardPrecompileAddress  = common.HexToAddress("0x0000000000000000000000000000000000000904")
+)
+
+// ErrGuard is the refusal of the protected-account mode and the anomaly hold
+// (codespace "zetaphy", code 31).
+var ErrGuard = errorsmod.Register("zetaphy", 31, "account guard")
+
+func (app *EVMD) futV5Height(ctx sdk.Context) int64 {
+	return int64(readU64(app.secRaw(ctx).Get(futV5Key))) // #nosec G115 -- block heights
+}
+
+// futV5 reports whether block h runs with v5.
+func (app *EVMD) futV5(ctx sdk.Context, h int64) bool {
+	a := app.futV5Height(ctx)
+	return a > 0 && h >= a
+}
+
+func (app *EVMD) setFutV5Height(ctx sdk.Context, h int64) {
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(futV5Key, u64(uint64(h))) // #nosec G115 -- block heights
+}
+
+// MsgSetFuture sets one v5 parameter (governance only). Kind and data:
+//
+//	ai-model       the binary model (zetaphy_aimodel.go); empty removes it
+//	immune         immuneParams as JSON
+//	breaker        breakerCfg as JSON (enabled false removes the bridge)
+//	breaker-rearm  {"bridge":"0x…"}: forget a trip, so the breaker can fire again
+//	model-epochs   {"address":"0x…"}: the Neuro ModelEpochs registry ("" removes it; zetaphy_modelat.go)
+type MsgSetFuture struct {
+	Authority string
+	Kind      string
+	Data      []byte
+}
+
+// MsgZXVotes is put by the proposer next to the vote certificate: the v5
+// part of each validator's vote extension for the previous block, with the
+// CometBFT signature over the whole extension (zetaphy_immune.go). It is
+// never signed or fee-paying.
+type MsgZXVotes struct {
+	Signer  string
+	Height  uint64
+	Round   uint64
+	Entries []byte
+}
+
+func (m *MsgSetFuture) Reset() { *m = MsgSetFuture{} }
+func (m *MsgSetFuture) String() string {
+	return fmt.Sprintf("MsgSetFuture{%s %d bytes}", m.Kind, len(m.Data))
+}
+func (*MsgSetFuture) ProtoMessage()               {}
+func (*MsgSetFuture) Descriptor() ([]byte, []int) { return pqCallDescriptor, []int{14} }
+func (m *MsgSetFuture) Marshal() ([]byte, error)  { return pqMarshal(14, m) }
+func (m *MsgSetFuture) Unmarshal(b []byte) error  { return pqUnmarshal(14, b, m) }
+func (m *MsgSetFuture) Size() int                 { return pqSize(m) }
+func (m *MsgZXVotes) Reset()                      { *m = MsgZXVotes{} }
+func (m *MsgZXVotes) String() string              { return fmt.Sprintf("MsgZXVotes{%d}", m.Height) }
+func (*MsgZXVotes) ProtoMessage()                 {}
+func (*MsgZXVotes) Descriptor() ([]byte, []int)   { return pqCallDescriptor, []int{15} }
+func (m *MsgZXVotes) Marshal() ([]byte, error)    { return pqMarshal(15, m) }
+func (m *MsgZXVotes) Unmarshal(b []byte) error    { return pqUnmarshal(15, b, m) }
+func (m *MsgZXVotes) Size() int                   { return pqSize(m) }
+
+// futJSON decodes governance JSON strictly (unknown fields refused).
+func futJSON(data []byte, v any) error {
+	d := json.NewDecoder(bytes.NewReader(data))
+	d.DisallowUnknownFields()
+	if err := d.Decode(v); err != nil {
+		return errorsmod.Wrapf(errortypes.ErrInvalidRequest, "data: %v", err)
+	}
+	return nil
+}
+
+func (app *EVMD) setFuture(ctx sdk.Context, m *MsgSetFuture) (gogoproto.Message, error) {
+	if m.Authority != govAuthority() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can change v5 settings")
+	}
+	if !app.futV5(ctx, ctx.BlockHeight()) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "v5 is not active on this chain yet (zetaphy-v5 upgrade)")
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	switch m.Kind {
+	case "ai-model":
+		if len(m.Data) == 0 {
+			st.Delete(aiModelKey)
+			break
+		}
+		if _, err := parseGBDT(m.Data); err != nil {
+			return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "ai-model: %v", err)
+		}
+		st.Set(aiModelKey, m.Data)
+	case "immune":
+		var p immuneParams
+		if err := futJSON(m.Data, &p); err != nil {
+			return nil, err
+		}
+		if err := p.validate(); err != nil {
+			return nil, err
+		}
+		bz, _ := json.Marshal(p)
+		st.Set(immuneParamsKey, bz)
+	case "breaker":
+		var c breakerCfg
+		if err := futJSON(m.Data, &c); err != nil {
+			return nil, err
+		}
+		if err := app.setBreaker(ctx, c); err != nil {
+			return nil, err
+		}
+	case "breaker-rearm":
+		var c struct {
+			Bridge string `json:"bridge"`
+		}
+		if err := futJSON(m.Data, &c); err != nil {
+			return nil, err
+		}
+		if !common.IsHexAddress(c.Bridge) {
+			return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "bridge: a 0x address")
+		}
+		b := common.HexToAddress(c.Bridge)
+		st.Delete(append([]byte{breakerTripPfx}, b.Bytes()...))
+		st.Delete(append([]byte{breakerPausePfx}, b.Bytes()...))
+	case "model-epochs":
+		if err := app.setModelEpochs(ctx, m.Data); err != nil {
+			return nil, err
+		}
+	default:
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "kind %q: ai-model, immune, breaker, breaker-rearm or model-epochs", m.Kind)
+	}
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_v5_set", sdk.NewAttribute("kind", m.Kind), sdk.NewAttribute("bytes", fmt.Sprint(len(m.Data)))))
+	return &MsgPQResponse{}, nil
+}
+
+// futPrecompile: the v5 precompiles, from the v5 height.
+func (app *EVMD) futPrecompile(ctx sdk.Context, addr common.Address) (vm.PrecompiledContract, bool) {
+	if addr != AIPrecompileAddress && addr != ImmunePrecompileAddress && addr != GuardPrecompileAddress {
+		return nil, false
+	}
+	if !app.futV5(ctx, ctx.BlockHeight()) {
+		return nil, false
+	}
+	switch addr {
+	case AIPrecompileAddress:
+		return app.aiPrecompile, true
+	case ImmunePrecompileAddress:
+		return app.immunePrecompile, true
+	}
+	return app.guardPrecompile, true
+}
+
+// registerZetaphyV5 (from registerZetaphyUpgrades): "zetaphy-v5" turns v5 on
+// from the block after the upgrade. It needs a chain that already ran
+// zetaphy-v4 (it adds no store).
+func (app *EVMD) registerZetaphyV5() {
+	app.UpgradeKeeper.SetUpgradeHandler(ZetaphyV5UpgradeName,
+		func(c context.Context, _ upgradetypes.Plan, fromVM module.VersionMap) (module.VersionMap, error) {
+			ctx := sdk.UnwrapSDKContext(c)
+			if a := app.futV5Height(ctx); a == 0 || a > ctx.BlockHeight()+1 {
+				app.setFutV5Height(ctx, ctx.BlockHeight()+1)
+			}
+			ctx.Logger().Info("ZETAPHY v5 scheduled", "from_height", ctx.BlockHeight()+1)
+			return app.ModuleManager.RunMigrations(c, app.Configurator(), fromVM)
+		})
+}
+
+// futProposalMsg: the v5 kinds of `zetaphyd tx security-proposal`.
+//
+//	ai-model <model.hex file | ->        (- removes the model)
+//	immune '<json>'                      e.g. '{"enabled":true,"enforce_bps":9000,"hold_bps":8000,"protect_bps":7000}'
+//	breaker '<json>'                     see breakerCfg
+//	breaker-rearm <bridge 0x…>
+//	model-epochs <ModelEpochs 0x… | ->  (- removes it)
+func futProposalMsg(args []string, readFile func(string) ([]byte, error)) (sdk.Msg, string, error) {
+	gov := govAuthority()
+	if len(args) != 2 {
+		return nil, "", fmt.Errorf("%s takes one argument", args[0])
+	}
+	switch args[0] {
+	case "ai-model":
+		if args[1] == "-" {
+			return &MsgSetFuture{Authority: gov, Kind: "ai-model"}, "Remove the AI precompile model", nil
+		}
+		raw, err := readFile(args[1])
+		if err != nil {
+			return nil, "", err
+		}
+		bz, err := secHex(strings.TrimSpace(string(raw)))
+		if err != nil {
+			return nil, "", fmt.Errorf("%s: hex expected: %w", args[1], err)
+		}
+		if _, err := parseGBDT(bz); err != nil {
+			return nil, "", err
+		}
+		return &MsgSetFuture{Authority: gov, Kind: "ai-model", Data: bz}, fmt.Sprintf("AI precompile model (%d bytes)", len(bz)), nil
+	case "immune", "breaker":
+		if !json.Valid([]byte(args[1])) {
+			return nil, "", fmt.Errorf("%s: JSON expected", args[0])
+		}
+		return &MsgSetFuture{Authority: gov, Kind: args[0], Data: []byte(args[1])}, fmt.Sprintf("v5 %s settings", args[0]), nil
+	case "breaker-rearm":
+		if !common.IsHexAddress(args[1]) {
+			return nil, "", fmt.Errorf("breaker-rearm <bridge 0x…>")
+		}
+		data, _ := json.Marshal(map[string]string{"bridge": args[1]})
+		return &MsgSetFuture{Authority: gov, Kind: "breaker-rearm", Data: data}, "Re-arm the bridge circuit breaker for " + args[1], nil
+	case "model-epochs":
+		if args[1] == "-" {
+			return &MsgSetFuture{Authority: gov, Kind: "model-epochs", Data: []byte(`{"address":""}`)}, "Remove the Neuro ModelEpochs registry", nil
+		}
+		if !common.IsHexAddress(args[1]) {
+			return nil, "", fmt.Errorf("model-epochs <ModelEpochs 0x… | ->")
+		}
+		data, _ := json.Marshal(map[string]string{"address": common.HexToAddress(args[1]).Hex()})
+		return &MsgSetFuture{Authority: gov, Kind: "model-epochs", Data: data}, "Neuro ModelEpochs registry " + args[1], nil
+	}
+	return nil, "", fmt.Errorf("unknown proposal %q", args[0])
+}
diff --git a/evmd/zetaphy_guard.go b/evmd/zetaphy_guard.go
new file mode 100644
index 0000000..765eb30
--- /dev/null
+++ b/evmd/zetaphy_guard.go
@@ -0,0 +1,1083 @@
+package evmd
+
+// ZETAPHY v5 account guard (precompile 0x…0904): two opt-in protections for
+// the account that signs a transaction. An account that never opts in is
+// never checked beyond two store reads.
+//
+// Protected-account mode (protect(mode, delaySeconds)):
+//
+//	mode 2 "reject": the account's txs that call, pay, approve or transfer
+//	       tokens to a high-risk contract are refused;
+//	mode 1 "delay queue": the same txs go through only after the account
+//	       queued that target (queue(target)) at least delaySeconds earlier
+//	       (then for one day).
+//	High-risk: an immune score >= protect_bps (default 7000,
+//	zetaphy_immune.go), or an enforced flag in the ThreatRegistry that the
+//	threat gate points at (asked even while the gate is off).
+//	Checked: tx.to, and the spender / recipient argument of approve,
+//	increaseAllowance, setApprovalForAll, transfer, transferFrom,
+//	safeTransferFrom and Permit2's approve; bank sends to such an address.
+//	Turning it on or stronger is immediate; weaker or off waits
+//	max(delay, 1 day), so a stolen key cannot switch it off first.
+//
+// Anomaly hold (holdOptIn(guardian, timeoutSeconds, minAmount, multBps)):
+//
+//	the chain keeps, per account, the number of native outflows and their
+//	moving average (alpha 1/8). An outflow above minAmount that is either
+//	among the first 5 or above average × multBps / 1e4 is held: refused
+//	until the account has a release that covers it. requestRelease(amount)
+//	by the account becomes usable after timeout, or at once when the
+//	guardian (a second key: an ML-DSA-44 account through MsgEVMCall, a
+//	passkey wallet contract, …) calls confirmRelease(account). A release is
+//	usable for one day. The guardian (or the account) can cancelRelease;
+//	opting out waits the timeout and the guardian can cancel it
+//	(cancelOptOut).
+//
+//	Native outflows: Ethereum tx value, MsgEVMCall value, bank sends, IBC
+//	MsgTransfer and the ICS-20 precompile, MsgConvertCoin to another
+//	address, and transfer / transferFrom(self, …) / approve /
+//	increaseAllowance on the native coin's ERC-20 interface (0xEeee…EEeE,
+//	or any token pair of the EVM denom).
+//
+//	ERC-20 rules (holdToken(token, minAmount, multBps), up to 16 per
+//	account, under the same guardian and timeout): the same profile and
+//	release model per token, with its own threshold in the token's units.
+//	Outflows of a token: transfer, transferFrom(self, …), bank / IBC sends
+//	and MsgConvertCoin of the token's coin (token pairs: erc20/0x… and IBC
+//	denoms with an ERC-20 interface), MsgConvertERC20 to another address.
+//	Approvals (approve, increaseAllowance, Permit2's approve) are checked
+//	against the profile like an outflow of the approved amount, but do not
+//	teach it; an unlimited approval is therefore always held until a
+//	release covers it. requestTokenRelease / confirmTokenRelease /
+//	cancelTokenRelease, holdTokenOptOut (waits the timeout) and
+//	cancelTokenOptOut (the guardian) work as the native ones.
+//
+// Limits (docs/future/chain-protocol.md): only what the signer's own
+// messages say is seen: a contract that moves tokens internally (a router
+// spending an earlier approval, a smart wallet, multicall, an off-chain
+// EIP-2612 permit or Permit2 signature used by someone else) is not; nor
+// are approvals given before opting in. A tx refused in a block (the state
+// changed after CheckTx) fails there without running.
+
+import (
+	"bytes"
+	"encoding/binary"
+	"errors"
+	"fmt"
+	"math/big"
+
+	transfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	errorsmod "cosmossdk.io/errors"
+
+	cmn "github.com/cosmos/evm/precompiles/common"
+	"github.com/cosmos/evm/precompiles/ics20"
+	erc20types "github.com/cosmos/evm/x/erc20/types"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
+)
+
+const (
+	guardDay        = 86400
+	guardMinDelay   = 3600
+	guardMaxDelay   = 30 * guardDay
+	holdWarmup      = 5
+	guardModeOff    = 0
+	guardModeQueue  = 1
+	guardModeReject = 2
+)
+
+// ---- protected-account mode
+
+type guardProtection struct {
+	mode, pendMode   uint8
+	delay, pendDelay uint64
+	pendAt           int64
+}
+
+func (app *EVMD) guardProtectionRaw(ctx sdk.Context, a common.Address) guardProtection {
+	v := app.secRaw(ctx).Get(append([]byte{guardProtectPfx}, a.Bytes()...))
+	if len(v) != 26 {
+		return guardProtection{}
+	}
+	return guardProtection{mode: v[0], delay: binary.BigEndian.Uint64(v[1:]), pendMode: v[9], pendDelay: binary.BigEndian.Uint64(v[10:]),
+		pendAt: int64(binary.BigEndian.Uint64(v[18:]))} // #nosec G115 -- unix seconds
+}
+
+// guardProtectionOf: the settings in force at the block time.
+func (app *EVMD) guardProtectionOf(ctx sdk.Context, a common.Address) guardProtection {
+	p := app.guardProtectionRaw(ctx, a)
+	if p.pendAt > 0 && ctx.BlockTime().Unix() >= p.pendAt {
+		return guardProtection{mode: p.pendMode, delay: p.pendDelay}
+	}
+	return p
+}
+
+func (app *EVMD) setGuardProtection(ctx sdk.Context, a common.Address, p guardProtection) {
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	k := append([]byte{guardProtectPfx}, a.Bytes()...)
+	if p.mode == guardModeOff && p.pendAt == 0 {
+		st.Delete(k)
+		return
+	}
+	v := append([]byte{p.mode}, u64(p.delay)...)
+	v = append(append(v, p.pendMode), u64(p.pendDelay)...)
+	st.Set(k, append(v, u64(uint64(p.pendAt))...)) // #nosec G115 -- unix seconds
+}
+
+func guardStronger(n, cur guardProtection) bool {
+	if n.mode != cur.mode {
+		return n.mode > cur.mode
+	}
+	return n.mode != guardModeQueue || n.delay >= cur.delay
+}
+
+// guardProtect sets the mode; returns when it applies.
+func (app *EVMD) guardProtect(ctx sdk.Context, a common.Address, mode uint8, delay uint64) (int64, error) {
+	if mode > guardModeReject {
+		return 0, errors.New("protect: mode 0 (off), 1 (delay queue) or 2 (reject)")
+	}
+	if mode == guardModeQueue && (delay < guardMinDelay || delay > guardMaxDelay) {
+		return 0, fmt.Errorf("protect: the delay queue needs %d..%d seconds", guardMinDelay, guardMaxDelay)
+	}
+	if mode != guardModeQueue {
+		delay = 0
+	}
+	now := ctx.BlockTime().Unix()
+	cur := app.guardProtectionOf(ctx, a)
+	n := guardProtection{mode: mode, delay: delay}
+	if guardStronger(n, cur) {
+		app.setGuardProtection(ctx, a, n)
+		return now, nil
+	}
+	wait := int64(max(cur.delay, guardDay)) // #nosec G115 -- at most 30 days
+	at := now + wait
+	app.setGuardProtection(ctx, a, guardProtection{mode: cur.mode, delay: cur.delay, pendMode: mode, pendDelay: delay, pendAt: at})
+	return at, nil
+}
+
+func guardQueueKey(a, target common.Address) []byte {
+	return append(append([]byte{guardQueuePfx}, a.Bytes()...), target.Bytes()...)
+}
+
+// guardHighRisk: the target is a contract the protected mode stops.
+func (app *EVMD) guardHighRisk(ctx sdk.Context, target common.Address) (bool, string) {
+	if threatSystemAddress(target) {
+		return false, ""
+	}
+	if s, _, _, ok := app.immuneScore(ctx, target); ok && s >= app.immuneParams(ctx).ProtectBps {
+		return true, fmt.Sprintf("immune score %d bps", s)
+	}
+	if v := app.secRaw(ctx).Get(gateKey); len(v) == 21 && app.secV3(ctx) {
+		reg := common.BytesToAddress(v[:20])
+		if reg != (common.Address{}) && reg != target {
+			if on, _ := app.threatEnforced(ctx, reg, target); on {
+				return true, "enforced flag in the ThreatRegistry " + reg.Hex()
+			}
+		}
+	}
+	return false, ""
+}
+
+// guardTargets: the addresses a call hands value or allowance to.
+func guardTargets(to *common.Address, data []byte) []common.Address {
+	var out []common.Address
+	if to != nil {
+		out = append(out, *to)
+	}
+	if len(data) < 4 {
+		return out
+	}
+	word := func(i int) (common.Address, bool) {
+		if i < 0 || len(data) < 4+32*(i+1) {
+			return common.Address{}, false
+		}
+		return common.BytesToAddress(data[4+32*i : 4+32*(i+1)]), true
+	}
+	arg := -1
+	switch binary.BigEndian.Uint32(data) {
+	case 0x095ea7b3, 0x39509351, 0xa22cb465, 0xa9059cbb: // approve, increaseAllowance, setApprovalForAll, transfer
+		arg = 0
+	case 0x23b872dd, 0x42842e0e, 0xb88d4fde, 0xf242432a, 0x2eb2c2d6, 0x87517c45: // transferFrom, safeTransferFrom ×2, ERC-1155 ×2, Permit2 approve
+		arg = 1
+	}
+	if a, ok := word(arg); ok {
+		out = append(out, a)
+	}
+	return out
+}
+
+func (app *EVMD) guardCheckProtected(ctx sdk.Context, from common.Address, targets []common.Address) error {
+	p := app.guardProtectionOf(ctx, from)
+	if p.mode == guardModeOff {
+		return nil
+	}
+	now := ctx.BlockTime().Unix()
+	for _, t := range targets {
+		risky, why := app.guardHighRisk(ctx, t)
+		if !risky {
+			continue
+		}
+		if p.mode == guardModeQueue {
+			if f := int64(readU64(app.secRaw(ctx).Get(guardQueueKey(from, t)))); f > 0 && now >= f && now < f+guardDay { // #nosec G115 -- unix seconds
+				continue
+			}
+			return errorsmod.Wrapf(ErrGuard, "%s is protected: %s is high-risk (%s). Queue it first with queue(%s) on %s; it can be used %d s later, for a day",
+				from.Hex(), t.Hex(), why, t.Hex(), GuardPrecompileAddress.Hex(), p.delay)
+		}
+		return errorsmod.Wrapf(ErrGuard, "%s is protected: %s is high-risk (%s); refused. Turning protection off takes at least a day",
+			from.Hex(), t.Hex(), why)
+	}
+	return nil
+}
+
+// ---- anomaly hold
+
+type holdCfg struct {
+	guardian      common.Address
+	timeout       uint64
+	minAmount     *big.Int
+	multBps       uint32
+	optOutAt      int64
+	releaseAmount *big.Int
+	releaseReady  int64
+}
+
+func (app *EVMD) holdCfgOf(ctx sdk.Context, a common.Address) *holdCfg {
+	v := app.secRaw(ctx).Get(append([]byte{holdCfgPfx}, a.Bytes()...))
+	if len(v) != 20+8+32+4+8+32+8 {
+		return nil
+	}
+	c := &holdCfg{guardian: common.BytesToAddress(v[:20]), timeout: binary.BigEndian.Uint64(v[20:]), minAmount: new(big.Int).SetBytes(v[28:60]),
+		multBps: binary.BigEndian.Uint32(v[60:]), optOutAt: int64(binary.BigEndian.Uint64(v[64:])), // #nosec G115 -- unix seconds
+		releaseAmount: new(big.Int).SetBytes(v[72:104]), releaseReady: int64(binary.BigEndian.Uint64(v[104:]))} // #nosec G115 -- unix seconds
+	if c.optOutAt > 0 && ctx.BlockTime().Unix() >= c.optOutAt {
+		return nil // opted out
+	}
+	return c
+}
+
+func (app *EVMD) setHoldCfg(ctx sdk.Context, a common.Address, c *holdCfg) {
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	k := append([]byte{holdCfgPfx}, a.Bytes()...)
+	if c == nil {
+		st.Delete(k)
+		st.Delete(append([]byte{holdStatsPfx}, a.Bytes()...))
+		return
+	}
+	v := append(c.guardian.Bytes(), u64(c.timeout)...)
+	v = append(v, common.LeftPadBytes(c.minAmount.Bytes(), 32)...)
+	v = binary.BigEndian.AppendUint32(v, c.multBps)
+	v = append(v, u64(uint64(c.optOutAt))...) // #nosec G115 -- unix seconds
+	v = append(v, common.LeftPadBytes(c.releaseAmount.Bytes(), 32)...)
+	st.Set(k, append(v, u64(uint64(c.releaseReady))...)) // #nosec G115 -- unix seconds
+}
+
+func (app *EVMD) holdStatsOf(ctx sdk.Context, a common.Address) (uint64, *big.Int) {
+	return app.holdStatsAt(ctx, append([]byte{holdStatsPfx}, a.Bytes()...))
+}
+
+func holdValidRule(minAmount *big.Int, multBps uint32) error {
+	if minAmount == nil || minAmount.Sign() <= 0 || minAmount.BitLen() > 255 || multBps < 10000 || multBps > 1_000_000 {
+		return errors.New("minAmount > 0, multBps 10000..1000000")
+	}
+	return nil
+}
+
+func (app *EVMD) holdOptIn(ctx sdk.Context, a, guardian common.Address, timeout uint64, minAmount *big.Int, multBps uint32) error {
+	if app.holdCfgOf(ctx, a) != nil {
+		return errors.New("holdOptIn: already opted in (opt out first; that waits the timeout)")
+	}
+	if guardian == (common.Address{}) || guardian == a {
+		return errors.New("holdOptIn: the guardian must be another account (a second key)")
+	}
+	if timeout < guardMinDelay || timeout > guardMaxDelay {
+		return fmt.Errorf("holdOptIn: timeout %d..%d seconds", guardMinDelay, guardMaxDelay)
+	}
+	if err := holdValidRule(minAmount, multBps); err != nil {
+		return fmt.Errorf("holdOptIn: %w", err)
+	}
+	// A fresh start: the profile and the token rules of an earlier opt-in go.
+	app.setHoldCfg(ctx, a, nil)
+	app.holdClearTokens(ctx, a)
+	app.setHoldCfg(ctx, a, &holdCfg{guardian: guardian, timeout: timeout, minAmount: minAmount, multBps: multBps, releaseAmount: new(big.Int)})
+	return nil
+}
+
+// holdRule is one profile rule of the hold: the native coin's (from
+// holdCfg) or a token's.
+type holdRule struct {
+	minAmount     *big.Int
+	multBps       uint32
+	optOutAt      int64 // token rules only; the native rule ends with the account's opt-out
+	releaseAmount *big.Int
+	releaseReady  int64
+}
+
+func (app *EVMD) holdStatsAt(ctx sdk.Context, key []byte) (uint64, *big.Int) {
+	v := app.secRaw(ctx).Get(key)
+	if len(v) != 40 {
+		return 0, new(big.Int)
+	}
+	return binary.BigEndian.Uint64(v), new(big.Int).SetBytes(v[8:])
+}
+
+// holdEval applies a rule to an outflow. check is what leaves the account
+// or is approved; learn is the part that teaches the profile (approvals do
+// not). In a block it also updates the profile and uses up the release
+// (save writes the rule back).
+func (app *EVMD) holdEval(ctx sdk.Context, statsKey []byte, r *holdRule, check, learn *big.Int, save func(), held func(count uint64, avg *big.Int) error) error {
+	if check.Sign() <= 0 {
+		return nil
+	}
+	count, avg := app.holdStatsAt(ctx, statsKey)
+	breaks := false
+	if check.Cmp(r.minAmount) > 0 {
+		lim := new(big.Int).Mul(avg, big.NewInt(int64(r.multBps)))
+		breaks = count < holdWarmup || new(big.Int).Mul(check, big.NewInt(10000)).Cmp(lim) > 0
+	}
+	now := ctx.BlockTime().Unix()
+	useRelease := false
+	if breaks {
+		if r.releaseReady > 0 && now >= r.releaseReady && now < r.releaseReady+guardDay && check.Cmp(r.releaseAmount) <= 0 {
+			useRelease = true
+		} else {
+			return held(count, avg)
+		}
+	}
+	if ctx.ExecMode() != sdk.ExecModeFinalize {
+		return nil
+	}
+	if useRelease {
+		r.releaseAmount.Sub(r.releaseAmount, check)
+		if r.releaseAmount.Sign() == 0 {
+			r.releaseReady = 0
+		}
+		save()
+	}
+	if learn == nil || learn.Sign() <= 0 {
+		return nil
+	}
+	if count == 0 {
+		avg.Set(learn)
+	} else { // avg += (learn - avg) / 8
+		d := new(big.Int).Sub(learn, avg)
+		avg.Add(avg, d.Quo(d, big.NewInt(8)))
+	}
+	for avg.BitLen() > 255 {
+		avg.Rsh(avg, 1)
+	}
+	v := append(u64(count+1), common.LeftPadBytes(avg.Bytes(), 32)...)
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(statsKey, v)
+	return nil
+}
+
+func holdBps(m uint32) string { return fmt.Sprintf("×%d.%02d", m/10000, m%10000/100) }
+
+// holdCheck applies the native rule to an outflow of the native coin.
+func (app *EVMD) holdCheck(ctx sdk.Context, a common.Address, check, learn *big.Int) error {
+	c := app.holdCfgOf(ctx, a)
+	if c == nil {
+		return nil
+	}
+	r := &holdRule{minAmount: c.minAmount, multBps: c.multBps, releaseAmount: c.releaseAmount, releaseReady: c.releaseReady}
+	return app.holdEval(ctx, append([]byte{holdStatsPfx}, a.Bytes()...), r, check, learn,
+		func() { c.releaseAmount, c.releaseReady = r.releaseAmount, r.releaseReady; app.setHoldCfg(ctx, a, c) },
+		func(count uint64, avg *big.Int) error {
+			return errorsmod.Wrapf(ErrGuard, "outflow of %s from %s is held: it breaks the account's profile (average %s over %d outflows, threshold %s, minimum %s). "+
+				"Call requestRelease(%s) on %s; it can go %d s later, or at once when the guardian %s calls confirmRelease",
+				check, a.Hex(), avg, count, holdBps(c.multBps), c.minAmount, check, GuardPrecompileAddress.Hex(), c.timeout, c.guardian.Hex())
+		})
+}
+
+// ---- ERC-20 rules of the anomaly hold
+
+const holdMaxTokens = 16
+
+var (
+	// Permit2's canonical address (a preinstall, setup-node.sh).
+	permit2Address = common.HexToAddress("0x000000000022D473030F116dDEE9F6B43aC78BA3")
+	ics20Address   = common.HexToAddress(evmtypes.ICS20PrecompileAddress)
+)
+
+func holdTokenKey(a, token common.Address) []byte {
+	return append(append([]byte{holdTokenPfx}, a.Bytes()...), token.Bytes()...)
+}
+
+func holdTokenStatsKey(a, token common.Address) []byte {
+	return append(append([]byte{holdTokenStatsPfx}, a.Bytes()...), token.Bytes()...)
+}
+
+// holdTokenRaw: the stored rule, opted out or not.
+func (app *EVMD) holdTokenRaw(ctx sdk.Context, a, token common.Address) *holdRule {
+	v := app.secRaw(ctx).Get(holdTokenKey(a, token))
+	if len(v) != 32+4+8+32+8 {
+		return nil
+	}
+	return &holdRule{minAmount: new(big.Int).SetBytes(v[:32]), multBps: binary.BigEndian.Uint32(v[32:]),
+		optOutAt: int64(binary.BigEndian.Uint64(v[36:])), releaseAmount: new(big.Int).SetBytes(v[44:76]), // #nosec G115 -- unix seconds
+		releaseReady: int64(binary.BigEndian.Uint64(v[76:]))} // #nosec G115 -- unix seconds
+}
+
+// holdTokenRuleOf: the token rule in force (the account opted in, the
+// token not opted out).
+func (app *EVMD) holdTokenRuleOf(ctx sdk.Context, a, token common.Address) *holdRule {
+	if app.holdCfgOf(ctx, a) == nil {
+		return nil
+	}
+	r := app.holdTokenRaw(ctx, a, token)
+	if r == nil || (r.optOutAt > 0 && ctx.BlockTime().Unix() >= r.optOutAt) {
+		return nil
+	}
+	return r
+}
+
+func (app *EVMD) setHoldTokenRule(ctx sdk.Context, a, token common.Address, r *holdRule) {
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if r == nil {
+		st.Delete(holdTokenKey(a, token))
+		st.Delete(holdTokenStatsKey(a, token))
+		return
+	}
+	v := append(common.LeftPadBytes(r.minAmount.Bytes(), 32), binary.BigEndian.AppendUint32(nil, r.multBps)...)
+	v = append(v, u64(uint64(r.optOutAt))...) // #nosec G115 -- unix seconds
+	v = append(v, common.LeftPadBytes(r.releaseAmount.Bytes(), 32)...)
+	st.Set(holdTokenKey(a, token), append(v, u64(uint64(r.releaseReady))...)) // #nosec G115 -- unix seconds
+}
+
+// holdTokenList: the tokens with a stored rule (at most holdMaxTokens), in
+// store order.
+func (app *EVMD) holdTokenList(ctx sdk.Context, a common.Address) []common.Address {
+	pfx := append([]byte{holdTokenPfx}, a.Bytes()...)
+	it := storetypes.KVStorePrefixIterator(app.secRaw(ctx), pfx)
+	defer it.Close()
+	var out []common.Address
+	for ; it.Valid() && len(out) < holdMaxTokens; it.Next() {
+		if k := it.Key(); len(k) == len(pfx)+20 {
+			out = append(out, common.BytesToAddress(k[len(pfx):]))
+		}
+	}
+	return out
+}
+
+func (app *EVMD) holdClearTokens(ctx sdk.Context, a common.Address) {
+	for _, t := range app.holdTokenList(ctx, a) {
+		app.setHoldTokenRule(ctx, a, t, nil)
+	}
+}
+
+// holdNativeToken: the token is an ERC-20 interface of the EVM coin itself
+// (0xEeee…EEeE on ZETAPHY): its outflows count under the native rule.
+func (app *EVMD) holdNativeToken(ctx sdk.Context, token common.Address) bool {
+	p, ok := app.Erc20Keeper.GetTokenPair(ctx, app.Erc20Keeper.GetTokenPairID(ctx, token.Hex()))
+	return ok && p.Denom == evmtypes.GetEVMCoinDenom()
+}
+
+func (app *EVMD) holdTokenOptIn(ctx sdk.Context, a, token common.Address, minAmount *big.Int, multBps uint32) error {
+	if app.holdCfgOf(ctx, a) == nil {
+		return errors.New("holdToken: opt in first (holdOptIn); a token rule uses the account's guardian and timeout")
+	}
+	if token == (common.Address{}) || app.holdNativeToken(ctx, token) {
+		return errors.New("holdToken: that is the native coin, which the account's main rule already covers")
+	}
+	if app.holdTokenRuleOf(ctx, a, token) != nil {
+		return errors.New("holdToken: that token is held already (opt it out first; that waits the timeout)")
+	}
+	if err := holdValidRule(minAmount, multBps); err != nil {
+		return fmt.Errorf("holdToken: %w", err)
+	}
+	if app.holdTokenRaw(ctx, a, token) == nil && len(app.holdTokenList(ctx, a)) >= holdMaxTokens {
+		return fmt.Errorf("holdToken: at most %d tokens per account", holdMaxTokens)
+	}
+	app.setHoldTokenRule(ctx, a, token, nil) // an opted-out rule and its profile go
+	app.setHoldTokenRule(ctx, a, token, &holdRule{minAmount: minAmount, multBps: multBps, releaseAmount: new(big.Int)})
+	return nil
+}
+
+// holdTokenCheck applies a token rule to an outflow of that token.
+func (app *EVMD) holdTokenCheck(ctx sdk.Context, a, token common.Address, check, learn *big.Int) error {
+	r := app.holdTokenRuleOf(ctx, a, token)
+	if r == nil {
+		return nil
+	}
+	c := app.holdCfgOf(ctx, a)
+	return app.holdEval(ctx, holdTokenStatsKey(a, token), r, check, learn,
+		func() { app.setHoldTokenRule(ctx, a, token, r) },
+		func(count uint64, avg *big.Int) error {
+			return errorsmod.Wrapf(ErrGuard, "outflow (or approval) of %s of token %s from %s is held: it breaks the account's profile for that token (average %s over %d outflows, threshold %s, minimum %s). "+
+				"Call requestTokenRelease(%s, %s) on %s; it can go %d s later, or at once when the guardian %s calls confirmTokenRelease",
+				check, token.Hex(), a.Hex(), avg, count, holdBps(r.multBps), r.minAmount, token.Hex(), check, GuardPrecompileAddress.Hex(), c.timeout, c.guardian.Hex())
+		})
+}
+
+// holdFlow is one outflow of an asset: the zero address is the native coin.
+type holdFlow struct {
+	asset  common.Address
+	amount *big.Int
+	learn  bool // a transfer (true) or an approval (false)
+}
+
+// holdTokenAsset: where an outflow of token counts for account a.
+func (app *EVMD) holdTokenAsset(ctx sdk.Context, a, token common.Address) (common.Address, bool) {
+	if app.secRaw(ctx).Has(holdTokenKey(a, token)) {
+		return token, true
+	}
+	if app.holdNativeToken(ctx, token) {
+		return common.Address{}, true
+	}
+	return common.Address{}, false
+}
+
+// holdDenomAsset: where an outflow of a bank coin counts (the coin of a
+// token pair counts as its ERC-20).
+func (app *EVMD) holdDenomAsset(ctx sdk.Context, a common.Address, denom string) (common.Address, bool) {
+	if denom == evmtypes.GetEVMCoinDenom() {
+		return common.Address{}, true
+	}
+	if common.IsHexAddress(denom) {
+		return common.Address{}, false
+	}
+	p, ok := app.Erc20Keeper.GetTokenPair(ctx, app.Erc20Keeper.GetTokenPairID(ctx, denom))
+	if !ok || !common.IsHexAddress(p.Erc20Address) {
+		return common.Address{}, false
+	}
+	return app.holdTokenAsset(ctx, a, common.HexToAddress(p.Erc20Address))
+}
+
+// holdCallFlows: the token outflows a call's calldata states for the
+// signer (ERC-20 transfer / transferFrom(self, …) / approve /
+// increaseAllowance, Permit2's approve, the ICS-20 precompile's transfer).
+func (app *EVMD) holdCallFlows(ctx sdk.Context, from, to common.Address, data []byte) []holdFlow {
+	if len(data) < 4 {
+		return nil
+	}
+	word := func(i int) []byte {
+		if len(data) < 4+32*(i+1) {
+			return nil
+		}
+		return data[4+32*i : 4+32*(i+1)]
+	}
+	num := func(i int) *big.Int {
+		if w := word(i); w != nil {
+			return new(big.Int).SetBytes(w)
+		}
+		return nil
+	}
+	var out []holdFlow
+	token := func(t common.Address, amt *big.Int, learn bool) {
+		if amt == nil || amt.Sign() <= 0 {
+			return
+		}
+		if asset, ok := app.holdTokenAsset(ctx, from, t); ok {
+			out = append(out, holdFlow{asset, amt, learn})
+		}
+	}
+	switch binary.BigEndian.Uint32(data) {
+	case 0xa9059cbb: // transfer(to, amount)
+		token(to, num(1), true)
+	case 0x23b872dd: // transferFrom(from, to, amount): the signer's own tokens
+		if w := word(0); w != nil && common.BytesToAddress(w) == from {
+			token(to, num(2), true)
+		}
+	case 0x095ea7b3, 0x39509351: // approve, increaseAllowance(spender, amount)
+		token(to, num(1), false)
+	case 0x87517c45: // Permit2 approve(token, spender, amount uint160, expiration)
+		if to == permit2Address {
+			if w := word(0); w != nil {
+				token(common.BytesToAddress(w), num(2), false)
+			}
+		}
+	}
+	if m, ok := ics20.ABI.Methods[ics20.TransferMethod]; ok && to == ics20Address && bytes.Equal(data[:4], m.ID) {
+		if args, err := m.Inputs.Unpack(data[4:]); err == nil && len(args) >= 5 {
+			denom, _ := args[2].(string)
+			amt, _ := args[3].(*big.Int)
+			sender, _ := args[4].(common.Address)
+			if amt != nil && amt.Sign() > 0 && sender == from {
+				if asset, ok := app.holdDenomAsset(ctx, from, denom); ok {
+					out = append(out, holdFlow{asset, amt, true})
+				}
+			}
+		}
+	}
+	return out
+}
+
+// holdFlows: every outflow of an action, the native value included.
+func (app *EVMD) holdFlows(ctx sdk.Context, act guardAction) []holdFlow {
+	var out []holdFlow
+	if act.value != nil && act.value.Sign() > 0 {
+		out = append(out, holdFlow{common.Address{}, act.value, true})
+	}
+	// The hold's lookups are free (only opted-in accounts get here).
+	ctx = ctx.WithGasMeter(storetypes.NewInfiniteGasMeter()).WithKVGasConfig(storetypes.GasConfig{})
+	if act.to != nil {
+		out = append(out, app.holdCallFlows(ctx, act.from, *act.to, act.data)...)
+	}
+	for _, c := range act.coins {
+		if c.Amount.IsPositive() {
+			if asset, ok := app.holdDenomAsset(ctx, act.from, c.Denom); ok {
+				out = append(out, holdFlow{asset, c.Amount.BigInt(), true})
+			}
+		}
+	}
+	for _, t := range act.tokens {
+		if t.amount != nil && t.amount.Sign() > 0 {
+			if asset, ok := app.holdTokenAsset(ctx, act.from, t.token); ok {
+				out = append(out, holdFlow{asset, t.amount, true})
+			}
+		}
+	}
+	return out
+}
+
+// ---- the ante rule
+
+type guardTokenOut struct {
+	token  common.Address
+	amount *big.Int
+}
+
+type guardAction struct {
+	from   common.Address
+	to     *common.Address
+	value  *big.Int  // the native coin
+	data   []byte    // calldata
+	coins  sdk.Coins // the other bank coins sent
+	tokens []guardTokenOut
+}
+
+// guardSplitCoins: the native amount, and the other coins.
+func guardSplitCoins(cs sdk.Coins) (*big.Int, sdk.Coins) {
+	denom := evmtypes.GetEVMCoinDenom()
+	var other sdk.Coins
+	for _, c := range cs {
+		if c.Denom != denom {
+			other = append(other, c)
+		}
+	}
+	return cs.AmountOf(denom).BigInt(), other
+}
+
+func guardActionsOf(tx sdk.Tx) []guardAction {
+	var out []guardAction
+	msgs := append([]sdk.Msg{}, tx.GetMsgs()...)
+	for i := 0; i < len(msgs) && i < 64; i++ {
+		switch m := msgs[i].(type) {
+		case *authz.MsgExec:
+			if inner, err := m.GetMessages(); err == nil {
+				msgs = append(msgs, inner...)
+			}
+		case *evmtypes.MsgEthereumTx:
+			if t := m.AsTransaction(); t != nil {
+				out = append(out, guardAction{from: common.BytesToAddress(m.From), to: t.To(), value: t.Value(), data: t.Data()})
+			}
+		case *MsgEVMCall:
+			if isGovAddr(m.Sender) {
+				continue
+			}
+			from := m.Sender
+			if m.AsOwner != "" {
+				from = m.AsOwner
+			}
+			f, err := pqAddr(from)
+			if err != nil {
+				continue
+			}
+			var to *common.Address
+			if common.IsHexAddress(m.To) {
+				t := common.HexToAddress(m.To)
+				to = &t
+			}
+			v, _ := new(big.Int).SetString(m.Value, 10)
+			if v == nil || v.Sign() < 0 {
+				v = new(big.Int)
+			}
+			out = append(out, guardAction{from: common.BytesToAddress(f), to: to, value: v, data: m.Data})
+		case *banktypes.MsgSend:
+			f, err1 := pqAddr(m.FromAddress)
+			t, err2 := pqAddr(m.ToAddress)
+			if err1 != nil || err2 != nil {
+				continue
+			}
+			to := common.BytesToAddress(t)
+			v, other := guardSplitCoins(m.Amount)
+			out = append(out, guardAction{from: common.BytesToAddress(f), to: &to, value: v, coins: other})
+		case *banktypes.MsgMultiSend:
+			for _, in := range m.Inputs {
+				if f, err := pqAddr(in.Address); err == nil {
+					v, other := guardSplitCoins(in.Coins)
+					out = append(out, guardAction{from: common.BytesToAddress(f), value: v, coins: other})
+				}
+			}
+			for _, o := range m.Outputs {
+				if t, err := pqAddr(o.Address); err == nil && len(m.Inputs) > 0 {
+					if f, err := pqAddr(m.Inputs[0].Address); err == nil {
+						to := common.BytesToAddress(t)
+						out = append(out, guardAction{from: common.BytesToAddress(f), to: &to, value: new(big.Int)})
+					}
+				}
+			}
+		case *transfertypes.MsgTransfer: // to another chain
+			if f, err := pqAddr(m.Sender); err == nil && !m.Token.Amount.IsNil() {
+				v, other := guardSplitCoins(sdk.Coins{m.Token})
+				out = append(out, guardAction{from: common.BytesToAddress(f), value: v, coins: other})
+			}
+		case *erc20types.MsgConvertERC20: // token -> coin, for receiver
+			r, err := pqAddr(m.Receiver)
+			if err != nil || !common.IsHexAddress(m.Sender) || !common.IsHexAddress(m.ContractAddress) || m.Amount.IsNil() {
+				continue
+			}
+			from, to := common.HexToAddress(m.Sender), common.BytesToAddress(r)
+			if to == from {
+				continue
+			}
+			out = append(out, guardAction{from: from, to: &to, value: new(big.Int),
+				tokens: []guardTokenOut{{common.HexToAddress(m.ContractAddress), m.Amount.BigInt()}}})
+		case *erc20types.MsgConvertCoin: // coin -> token, for receiver
+			f, err := pqAddr(m.Sender)
+			if err != nil || !common.IsHexAddress(m.Receiver) || m.Coin.Amount.IsNil() {
+				continue
+			}
+			from, to := common.BytesToAddress(f), common.HexToAddress(m.Receiver)
+			if to == from {
+				continue
+			}
+			v, other := guardSplitCoins(sdk.Coins{m.Coin})
+			out = append(out, guardAction{from: from, to: &to, value: v, coins: other})
+		}
+	}
+	return out
+}
+
+func (app *EVMD) guardEnrolled(ctx sdk.Context, a common.Address) bool {
+	st := app.secRaw(ctx)
+	return st.Has(append([]byte{guardProtectPfx}, a.Bytes()...)) || st.Has(append([]byte{holdCfgPfx}, a.Bytes()...))
+}
+
+// guardActions runs both rules over a tx's actions.
+func (app *EVMD) guardActions(ctx sdk.Context, acts []guardAction) error {
+	if len(acts) == 0 || !app.futV5(ctx, ctx.BlockHeight()) {
+		return nil
+	}
+	type key struct{ from, asset common.Address }
+	type sum struct{ check, learn *big.Int }
+	sums := map[key]*sum{}
+	var order []key // in order of first appearance: deterministic
+	for _, act := range acts {
+		if !app.guardEnrolled(ctx, act.from) {
+			continue
+		}
+		if err := app.guardCheckProtected(ctx, act.from, guardTargets(act.to, act.data)); err != nil {
+			return err
+		}
+		if app.holdCfgOf(ctx, act.from) == nil {
+			continue
+		}
+		for _, f := range app.holdFlows(ctx, act) {
+			k := key{act.from, f.asset}
+			if sums[k] == nil {
+				sums[k] = &sum{new(big.Int), new(big.Int)}
+				order = append(order, k)
+			}
+			sums[k].check.Add(sums[k].check, f.amount)
+			if f.learn {
+				sums[k].learn.Add(sums[k].learn, f.amount)
+			}
+		}
+	}
+	for _, k := range order {
+		var err error
+		if k.asset == (common.Address{}) {
+			err = app.holdCheck(ctx, k.from, sums[k].check, sums[k].learn)
+		} else {
+			err = app.holdTokenCheck(ctx, k.from, k.asset, sums[k].check, sums[k].learn)
+		}
+		if err != nil {
+			return err
+		}
+	}
+	return nil
+}
+
+func (app *EVMD) guardTx(ctx sdk.Context, tx sdk.Tx) error {
+	if !app.futV5(ctx, ctx.BlockHeight()) {
+		return nil
+	}
+	return app.guardActions(ctx, guardActionsOf(tx))
+}
+
+// guardMempoolCheck: the same rules when an EVM tx is submitted.
+func (app *EVMD) guardMempoolCheck(from common.Address, tx *ethtypes.Transaction) error {
+	ctx, err := app.CreateQueryContext(0, false)
+	if err != nil {
+		return nil
+	}
+	ctx = ctx.WithBlockHeight(ctx.BlockHeight() + 1).WithExecMode(sdk.ExecModeCheck)
+	return app.guardActions(ctx, []guardAction{{from: from, to: tx.To(), value: tx.Value(), data: tx.Data()}})
+}
+
+// zetaphyMempoolCheck: the checks the EVM mempool runs at submission.
+func (app *EVMD) zetaphyMempoolCheck(from common.Address, tx *ethtypes.Transaction) error {
+	if err := app.threatMempoolCheck(from, tx); err != nil {
+		return err
+	}
+	return app.guardMempoolCheck(from, tx)
+}
+
+// ---- precompile 0x…0904
+
+const guardABIJSON = `[
+ {"type":"function","name":"protect","stateMutability":"nonpayable","inputs":[{"name":"mode","type":"uint8"},{"name":"delaySeconds","type":"uint64"}],"outputs":[{"name":"effectiveAt","type":"uint64"}]},
+ {"type":"function","name":"protection","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"mode","type":"uint8"},{"name":"delaySeconds","type":"uint64"},{"name":"pendingMode","type":"uint8"},{"name":"pendingAt","type":"uint64"}]},
+ {"type":"function","name":"queue","stateMutability":"nonpayable","inputs":[{"name":"target","type":"address"}],"outputs":[{"name":"usableFrom","type":"uint64"}]},
+ {"type":"function","name":"queuedFrom","stateMutability":"view","inputs":[{"name":"account","type":"address"},{"name":"target","type":"address"}],"outputs":[{"name":"usableFrom","type":"uint64"}]},
+ {"type":"function","name":"highRisk","stateMutability":"view","inputs":[{"name":"target","type":"address"}],"outputs":[{"name":"risky","type":"bool"},{"name":"why","type":"string"}]},
+ {"type":"function","name":"holdOptIn","stateMutability":"nonpayable","inputs":[{"name":"guardian","type":"address"},{"name":"timeoutSeconds","type":"uint64"},{"name":"minAmount","type":"uint256"},{"name":"multBps","type":"uint32"}],"outputs":[]},
+ {"type":"function","name":"holdOptOut","stateMutability":"nonpayable","inputs":[],"outputs":[{"name":"at","type":"uint64"}]},
+ {"type":"function","name":"cancelOptOut","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"}],"outputs":[]},
+ {"type":"function","name":"requestRelease","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"}],"outputs":[{"name":"readyAt","type":"uint64"}]},
+ {"type":"function","name":"confirmRelease","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"}],"outputs":[]},
+ {"type":"function","name":"cancelRelease","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"}],"outputs":[]},
+ {"type":"function","name":"holdToken","stateMutability":"nonpayable","inputs":[{"name":"token","type":"address"},{"name":"minAmount","type":"uint256"},{"name":"multBps","type":"uint32"}],"outputs":[]},
+ {"type":"function","name":"holdTokenOptOut","stateMutability":"nonpayable","inputs":[{"name":"token","type":"address"}],"outputs":[{"name":"at","type":"uint64"}]},
+ {"type":"function","name":"cancelTokenOptOut","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"},{"name":"token","type":"address"}],"outputs":[]},
+ {"type":"function","name":"requestTokenRelease","stateMutability":"nonpayable","inputs":[{"name":"token","type":"address"},{"name":"amount","type":"uint256"}],"outputs":[{"name":"readyAt","type":"uint64"}]},
+ {"type":"function","name":"confirmTokenRelease","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"},{"name":"token","type":"address"}],"outputs":[]},
+ {"type":"function","name":"cancelTokenRelease","stateMutability":"nonpayable","inputs":[{"name":"account","type":"address"},{"name":"token","type":"address"}],"outputs":[]},
+ {"type":"function","name":"holdTokenState","stateMutability":"view","inputs":[{"name":"account","type":"address"},{"name":"token","type":"address"}],"outputs":[{"name":"minAmount","type":"uint256"},{"name":"multBps","type":"uint32"},{"name":"count","type":"uint64"},{"name":"average","type":"uint256"},{"name":"releaseAmount","type":"uint256"},{"name":"releaseReadyAt","type":"uint64"},{"name":"optOutAt","type":"uint64"}]},
+ {"type":"function","name":"holdTokens","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"tokens","type":"address[]"}]},
+ {"type":"function","name":"holdState","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"guardian","type":"address"},{"name":"timeoutSeconds","type":"uint64"},{"name":"minAmount","type":"uint256"},{"name":"multBps","type":"uint32"},{"name":"count","type":"uint64"},{"name":"average","type":"uint256"},{"name":"releaseAmount","type":"uint256"},{"name":"releaseReadyAt","type":"uint64"},{"name":"optOutAt","type":"uint64"}]}
+]`
+
+// GuardABI is the account guard precompile's ABI.
+var GuardABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(guardABIJSON)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+type guardPrecompile struct {
+	cmn.Precompile
+	app *EVMD
+}
+
+func newGuardPrecompile(app *EVMD) *guardPrecompile {
+	return &guardPrecompile{Precompile: cmn.Precompile{
+		KvGasConfig: storetypes.KVGasConfig(), TransientKVGasConfig: storetypes.TransientGasConfig(),
+		ContractAddress: GuardPrecompileAddress,
+	}, app: app}
+}
+
+func (*guardPrecompile) Name() string { return "zetaphy-guard" }
+
+func guardIsTx(m *abi.Method) bool { return !m.IsConstant() }
+
+func (p *guardPrecompile) RequiredGas(input []byte) uint64 {
+	if len(input) < 4 {
+		return 0
+	}
+	m, err := GuardABI.MethodById(input[:4])
+	if err != nil {
+		return 0
+	}
+	return p.Precompile.RequiredGas(input, guardIsTx(m))
+}
+
+func (p *guardPrecompile) Run(evm *vm.EVM, contract *vm.Contract, readonly bool) ([]byte, error) {
+	return p.RunNativeAction(evm, contract, func(ctx sdk.Context) ([]byte, error) {
+		method, args, err := cmn.SetupABI(GuardABI, contract, readonly, guardIsTx)
+		if err != nil {
+			return nil, err
+		}
+		if v := contract.Value(); v != nil && !v.IsZero() {
+			return nil, errors.New("the guard precompile takes no value")
+		}
+		return p.execute(ctx, method, args, contract.Caller())
+	})
+}
+
+func (p *guardPrecompile) execute(ctx sdk.Context, method *abi.Method, args []any, caller common.Address) ([]byte, error) {
+	app, now := p.app, ctx.BlockTime().Unix()
+	event := func(name string, attrs ...string) {
+		e := sdk.NewEvent("zetaphy_guard_"+name, sdk.NewAttribute("account", caller.Hex()))
+		for i := 0; i+1 < len(attrs); i += 2 {
+			e = e.AppendAttributes(sdk.NewAttribute(attrs[i], attrs[i+1]))
+		}
+		ctx.EventManager().EmitEvent(e)
+	}
+	switch method.Name {
+	case "protect":
+		at, err := app.guardProtect(ctx, caller, args[0].(uint8), args[1].(uint64))
+		if err != nil {
+			return nil, err
+		}
+		event("protect", "mode", fmt.Sprint(args[0]), "effective_at", fmt.Sprint(at))
+		return method.Outputs.Pack(uint64(at)) // #nosec G115 -- unix seconds
+	case "protection":
+		cur := app.guardProtectionOf(ctx, args[0].(common.Address))
+		raw := app.guardProtectionRaw(ctx, args[0].(common.Address))
+		if raw.pendAt <= now {
+			raw.pendMode, raw.pendAt = 0, 0
+		}
+		return method.Outputs.Pack(cur.mode, cur.delay, raw.pendMode, uint64(raw.pendAt)) // #nosec G115 -- unix seconds
+	case "queue":
+		pr := app.guardProtectionOf(ctx, caller)
+		if pr.mode != guardModeQueue {
+			return nil, errors.New("queue: only in protection mode 1 (delay queue)")
+		}
+		target := args[0].(common.Address)
+		from := now + int64(pr.delay)                                                             // #nosec G115 -- at most 30 days
+		ctx.KVStore(app.GetKey(pqStoreKey)).Set(guardQueueKey(caller, target), u64(uint64(from))) // #nosec G115 -- unix seconds
+		event("queue", "target", target.Hex(), "usable_from", fmt.Sprint(from))
+		return method.Outputs.Pack(uint64(from)) // #nosec G115 -- unix seconds
+	case "queuedFrom":
+		return method.Outputs.Pack(readU64(app.secRaw(ctx).Get(guardQueueKey(args[0].(common.Address), args[1].(common.Address)))))
+	case "highRisk":
+		ctx.GasMeter().ConsumeGas(threatGateGas, "zetaphy guard risk check")
+		r, why := app.guardHighRisk(ctx, args[0].(common.Address))
+		return method.Outputs.Pack(r, why)
+	case "holdOptIn":
+		if err := app.holdOptIn(ctx, caller, args[0].(common.Address), args[1].(uint64), args[2].(*big.Int), args[3].(uint32)); err != nil {
+			return nil, err
+		}
+		event("hold_opt_in", "guardian", args[0].(common.Address).Hex())
+		return method.Outputs.Pack()
+	case "holdOptOut":
+		c := app.holdCfgOf(ctx, caller)
+		if c == nil {
+			return nil, errors.New("holdOptOut: not opted in")
+		}
+		if c.optOutAt == 0 {
+			c.optOutAt = now + int64(c.timeout) // #nosec G115 -- at most 30 days
+			app.setHoldCfg(ctx, caller, c)
+		}
+		event("hold_opt_out", "at", fmt.Sprint(c.optOutAt))
+		return method.Outputs.Pack(uint64(c.optOutAt)) // #nosec G115 -- unix seconds
+	case "cancelOptOut", "confirmRelease", "cancelRelease":
+		acct := args[0].(common.Address)
+		c := app.holdCfgOf(ctx, acct)
+		if c == nil {
+			return nil, errors.New("that account is not opted in")
+		}
+		if caller != c.guardian && (method.Name != "cancelRelease" || caller != acct) {
+			return nil, errors.New("only the account's guardian (or, to cancel a release, the account)")
+		}
+		switch method.Name {
+		case "cancelOptOut":
+			c.optOutAt = 0
+		case "confirmRelease":
+			if c.releaseAmount.Sign() == 0 {
+				return nil, errors.New("confirmRelease: nothing was requested")
+			}
+			c.releaseReady = now
+		case "cancelRelease":
+			c.releaseAmount, c.releaseReady = new(big.Int), 0
+		}
+		app.setHoldCfg(ctx, acct, c)
+		event(method.Name, "for", acct.Hex())
+		return method.Outputs.Pack()
+	case "requestRelease":
+		c := app.holdCfgOf(ctx, caller)
+		amt := args[0].(*big.Int)
+		if c == nil || amt.Sign() <= 0 || amt.BitLen() > 255 {
+			return nil, errors.New("requestRelease: opt in first, and ask for a positive amount")
+		}
+		c.releaseAmount, c.releaseReady = new(big.Int).Set(amt), now+int64(c.timeout) // #nosec G115 -- at most 30 days
+		app.setHoldCfg(ctx, caller, c)
+		event("request_release", "amount", amt.String(), "ready_at", fmt.Sprint(c.releaseReady))
+		return method.Outputs.Pack(uint64(c.releaseReady)) // #nosec G115 -- unix seconds
+	case "holdToken":
+		token := args[0].(common.Address)
+		if err := app.holdTokenOptIn(ctx, caller, token, args[1].(*big.Int), args[2].(uint32)); err != nil {
+			return nil, err
+		}
+		event("hold_token", "token", token.Hex())
+		return method.Outputs.Pack()
+	case "holdTokenOptOut":
+		token := args[0].(common.Address)
+		c, r := app.holdCfgOf(ctx, caller), app.holdTokenRuleOf(ctx, caller, token)
+		if c == nil || r == nil {
+			return nil, errors.New("holdTokenOptOut: that token is not held")
+		}
+		if r.optOutAt == 0 {
+			r.optOutAt = now + int64(c.timeout) // #nosec G115 -- at most 30 days
+			app.setHoldTokenRule(ctx, caller, token, r)
+		}
+		event("hold_token_opt_out", "token", token.Hex(), "at", fmt.Sprint(r.optOutAt))
+		return method.Outputs.Pack(uint64(r.optOutAt)) // #nosec G115 -- unix seconds
+	case "cancelTokenOptOut", "confirmTokenRelease", "cancelTokenRelease":
+		acct, token := args[0].(common.Address), args[1].(common.Address)
+		c, r := app.holdCfgOf(ctx, acct), app.holdTokenRuleOf(ctx, acct, token)
+		if c == nil || r == nil {
+			return nil, errors.New("that account does not hold that token")
+		}
+		if caller != c.guardian && (method.Name != "cancelTokenRelease" || caller != acct) {
+			return nil, errors.New("only the account's guardian (or, to cancel a release, the account)")
+		}
+		switch method.Name {
+		case "cancelTokenOptOut":
+			r.optOutAt = 0
+		case "confirmTokenRelease":
+			if r.releaseAmount.Sign() == 0 {
+				return nil, errors.New("confirmTokenRelease: nothing was requested")
+			}
+			r.releaseReady = now
+		case "cancelTokenRelease":
+			r.releaseAmount, r.releaseReady = new(big.Int), 0
+		}
+		app.setHoldTokenRule(ctx, acct, token, r)
+		event(method.Name, "for", acct.Hex(), "token", token.Hex())
+		return method.Outputs.Pack()
+	case "requestTokenRelease":
+		token, amt := args[0].(common.Address), args[1].(*big.Int)
+		c, r := app.holdCfgOf(ctx, caller), app.holdTokenRuleOf(ctx, caller, token)
+		if c == nil || r == nil || amt.Sign() <= 0 {
+			return nil, errors.New("requestTokenRelease: hold the token first (holdToken), and ask for a positive amount")
+		}
+		// up to 2^256-1: an unlimited approval can be released too
+		r.releaseAmount, r.releaseReady = new(big.Int).Set(amt), now+int64(c.timeout) // #nosec G115 -- at most 30 days
+		app.setHoldTokenRule(ctx, caller, token, r)
+		event("request_token_release", "token", token.Hex(), "amount", amt.String(), "ready_at", fmt.Sprint(r.releaseReady))
+		return method.Outputs.Pack(uint64(r.releaseReady)) // #nosec G115 -- unix seconds
+	case "holdTokenState":
+		a, token := args[0].(common.Address), args[1].(common.Address)
+		r := app.holdTokenRuleOf(ctx, a, token)
+		if r == nil {
+			return method.Outputs.Pack(new(big.Int), uint32(0), uint64(0), new(big.Int), new(big.Int), uint64(0), uint64(0))
+		}
+		n, avg := app.holdStatsAt(ctx, holdTokenStatsKey(a, token))
+		return method.Outputs.Pack(r.minAmount, r.multBps, n, avg, r.releaseAmount, uint64(r.releaseReady), uint64(r.optOutAt)) // #nosec G115 -- unix seconds
+	case "holdTokens":
+		a := args[0].(common.Address)
+		var out []common.Address
+		for _, t := range app.holdTokenList(ctx, a) {
+			if app.holdTokenRuleOf(ctx, a, t) != nil {
+				out = append(out, t)
+			}
+		}
+		if out == nil {
+			out = []common.Address{}
+		}
+		return method.Outputs.Pack(out)
+	case "holdState":
+		a := args[0].(common.Address)
+		c := app.holdCfgOf(ctx, a)
+		if c == nil {
+			return method.Outputs.Pack(common.Address{}, uint64(0), new(big.Int), uint32(0), uint64(0), new(big.Int), new(big.Int), uint64(0), uint64(0))
+		}
+		n, avg := app.holdStatsOf(ctx, a)
+		return method.Outputs.Pack(c.guardian, c.timeout, c.minAmount, c.multBps, n, avg, c.releaseAmount, uint64(c.releaseReady), uint64(c.optOutAt)) // #nosec G115 -- unix seconds
+	}
+	return nil, fmt.Errorf("unknown method %s", method.Name)
+}
diff --git a/evmd/zetaphy_ibchold.go b/evmd/zetaphy_ibchold.go
new file mode 100644
index 0000000..20a1db1
--- /dev/null
+++ b/evmd/zetaphy_ibchold.go
@@ -0,0 +1,516 @@
+package evmd
+
+// ZETAPHY IBC large-transfer hold.
+//
+// The top of the ICS-20 stack (above the rate limit). An inbound transfer of
+// a denom at or over its governance threshold (MsgSetIBCHoldRule: a minimum
+// amount, and/or a share of the denom's supply in basis points; "*" covers
+// denoms without a rule: a share of the supply, applied only from its
+// minimum amount up, so that small transfers of a denom with little or no
+// supply here are not all held) is not delivered at once: the packet is received
+// (so it cannot time out on the source chain) but its acknowledgement is
+// left open, and the packet waits in the zetaphypq store for the hold delay
+// (MsgSetIBCHold, default 6 h). Nothing is minted or unescrowed meanwhile.
+//   - After the delay, BeginBlock delivers it through the rest of the stack
+//     (rate limit, callbacks, ERC-20, transfer) as if it had just arrived,
+//     and writes the acknowledgement that stack gives. Over the rate limit
+//     at that moment, or any other failure (a panic, or running out of the
+//     IBCHoldReleaseGas each delivery gets): an error acknowledgement, and
+//     the source chain refunds the sender. A block stops releasing after
+//     ibcReleasesPerBlock transfers or ibcReleaseBlockGas gas.
+//   - Before that, the guardian (a governance-set account or contract, e.g.
+//     a multisig; governance itself can too) may cancel it: an error
+//     acknowledgement is written and the source chain refunds the sender.
+//     The guardian can only return a transfer to where it came from; it can
+//     never take it.
+// At most IBCHoldMaxOpen transfers wait at once, and IBCHoldMaxPerDenom of
+// one denom: a transfer over the threshold that would go beyond either is
+// refused at once (an error acknowledgement, refunded on the source chain),
+// so the waiting list and the state it takes stay bounded. Releases stay in
+// order of release time.
+// Every hold, release and cancellation is an event; zetaphy_ibcHolds lists
+// the waiting ones. IBC v2 (Eureka) packets cannot wait like this here: one
+// over the threshold is refused at once (refunded on the source chain).
+// x/ratelimit stays as it was.
+
+import (
+	"bytes"
+	"encoding/json"
+	"errors"
+	"fmt"
+
+	gogoproto "github.com/cosmos/gogoproto/proto"
+
+	errorsmod "cosmossdk.io/errors"
+	sdkmath "cosmossdk.io/math"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
+
+	transfertypes "github.com/cosmos/ibc-go/v11/modules/apps/transfer/types"
+	channeltypes "github.com/cosmos/ibc-go/v11/modules/core/04-channel/types"
+	channeltypesv2 "github.com/cosmos/ibc-go/v11/modules/core/04-channel/v2/types"
+	porttypes "github.com/cosmos/ibc-go/v11/modules/core/05-port/types"
+	ibcapi "github.com/cosmos/ibc-go/v11/modules/core/api"
+	ibcexported "github.com/cosmos/ibc-go/v11/modules/core/exported"
+)
+
+const (
+	// IBCHoldDefaultDelay: 6 hours, unless governance sets another.
+	IBCHoldDefaultDelay = 6 * 3600
+	IBCHoldMinDelay     = 60
+	IBCHoldMaxDelay     = 7 * 86400
+	ibcReleasesPerBlock = 20
+	// ibcReleaseBlockGas: BeginBlock stops releasing once the deliveries of
+	// this block used this much gas; the rest wait for the next block.
+	ibcReleaseBlockGas = 10_000_000
+)
+
+// IBCHoldReleaseGas caps the gas of one delivery in BeginBlock (whose own
+// gas meter is infinite): a transfer whose delivery runs out (e.g. an
+// ERC-20 conversion into a contract that burns gas) gets an error
+// acknowledgement and is refunded on the source chain. A variable only so
+// the fork tests can lower it.
+var IBCHoldReleaseGas uint64 = 3_000_000
+
+// IBCHoldMaxOpen and IBCHoldMaxPerDenom bound the transfers waiting at once
+// (all denoms, and one denom as named here). Variables only so the fork
+// tests can lower them.
+var (
+	IBCHoldMaxOpen     uint64 = 2000
+	IBCHoldMaxPerDenom uint64 = 100
+)
+
+// ibcHold is a held inbound transfer.
+type ibcHold struct {
+	ID        uint64 `json:"id"`
+	Packet    []byte `json:"packet"` // channeltypes.Packet (protobuf)
+	Version   string `json:"version"`
+	Relayer   []byte `json:"relayer"`
+	Channel   string `json:"channel"` // this chain's channel
+	Denom     string `json:"denom"`   // the denom it becomes here
+	Amount    string `json:"amount"`
+	Sender    string `json:"sender"`
+	Receiver  string `json:"receiver"`
+	HeldAt    int64  `json:"held_at"`
+	ReleaseAt int64  `json:"release_at"`
+	Stuck     string `json:"stuck,omitempty"` // why delivering it failed (e.g. the channel closed)
+}
+
+func holdKey(id uint64) []byte { return append([]byte{holdPfx}, u64(id)...) }
+func holdQueueKey(at int64, id uint64) []byte {
+	return append(append([]byte{holdQueuePfx}, u64(uint64(at))...), u64(id)...) // #nosec G115 -- unix seconds
+}
+func holdRuleKey(denom string) []byte  { return append([]byte{holdRulePfx}, denom...) }
+func holdDenomKey(denom string) []byte { return append([]byte{holdDenomPfx}, denom...) }
+
+// ibcHoldCount adds delta (+1 or -1) to the open-hold counters of denom and
+// of all denoms (never below 0).
+func ibcHoldCount(st storetypes.KVStore, denom string, delta int) {
+	for _, k := range [][]byte{holdCountKey, holdDenomKey(denom)} {
+		n := readU64(st.Get(k))
+		switch {
+		case delta > 0:
+			n++
+		case n > 0:
+			n--
+		}
+		if n == 0 {
+			st.Delete(k)
+		} else {
+			st.Set(k, u64(n))
+		}
+	}
+}
+
+// ibcHoldParams: the delay in seconds and the guardian (nil: none).
+func (app *EVMD) ibcHoldParams(ctx sdk.Context) (int64, []byte) {
+	v := app.secRaw(ctx).Get(holdParamsKey)
+	d := int64(readU64(v)) // #nosec G115 -- bounded by IBCHoldMaxDelay
+	if d == 0 {
+		d = IBCHoldDefaultDelay
+	}
+	if len(v) == 28 {
+		return d, v[8:]
+	}
+	return d, nil
+}
+
+// ibcHoldRule: the rule for denom (or "*"): minimum amount and supply share.
+func (app *EVMD) ibcHoldRule(ctx sdk.Context, denom string) (sdkmath.Int, uint64, bool) {
+	min, bps, ok, _ := app.ibcHoldRuleFor(ctx, denom)
+	return min, bps, ok
+}
+
+// ibcHoldRuleFor also says whether the rule found is the "*" rule.
+func (app *EVMD) ibcHoldRuleFor(ctx sdk.Context, denom string) (sdkmath.Int, uint64, bool, bool) {
+	st := app.secRaw(ctx)
+	v := st.Get(holdRuleKey(denom))
+	star := false
+	if v == nil {
+		v, star = st.Get(holdRuleKey("*")), true
+	}
+	if len(v) < 8 {
+		return sdkmath.ZeroInt(), 0, false, false
+	}
+	min, ok := sdkmath.NewIntFromString(string(v[8:]))
+	if !ok {
+		min = sdkmath.ZeroInt()
+	}
+	return min, readU64(v), true, star
+}
+
+// ibcHoldNeeded: a transfer of amount of denom (as named here) must wait.
+// A denom's own rule: amount >= its minimum, or >= its share of the supply
+// here. The "*" rule: amount >= its share of the supply here, counted only
+// from its minimum amount up (a denom not seen here yet has supply 0, so
+// without that minimum every transfer of it would be held).
+func (app *EVMD) ibcHoldNeeded(ctx sdk.Context, denom string, amount sdkmath.Int) bool {
+	min, bps, ok, star := app.ibcHoldRuleFor(ctx, denom)
+	if !ok || !amount.IsPositive() {
+		return false
+	}
+	if star && amount.LT(min) {
+		return false
+	}
+	if !star && min.IsPositive() && amount.GTE(min) {
+		return true
+	}
+	if bps > 0 {
+		supply := app.BankKeeper.GetSupply(ctx, denom).Amount
+		return amount.MulRaw(10000).GTE(supply.Mul(sdkmath.NewIntFromUint64(bps)))
+	}
+	return false
+}
+
+// ibcLocalDenom: the denom an inbound ICS-20 token becomes on this chain.
+func ibcLocalDenom(d transfertypes.Denom, srcPort, srcChan, dstPort, dstChan string) string {
+	if d.HasPrefix(srcPort, srcChan) { // it is going home: unescrowed here
+		d.Trace = d.Trace[1:]
+		return d.IBCDenom()
+	}
+	d.Trace = append([]transfertypes.Hop{transfertypes.NewHop(dstPort, dstChan)}, d.Trace...)
+	return d.IBCDenom()
+}
+
+func (app *EVMD) ibcHoldOn(ctx sdk.Context) bool {
+	if !app.secV3(ctx) {
+		return false
+	}
+	it := app.secRaw(ctx).Iterator([]byte{holdRulePfx}, []byte{holdRulePfx + 1})
+	defer it.Close()
+	return it.Valid()
+}
+
+// ---- IBC v1 middleware
+
+type ibcHoldMiddleware struct {
+	app porttypes.IBCModule
+	z   *EVMD
+}
+
+var _ porttypes.IBCModule = (*ibcHoldMiddleware)(nil)
+
+func newIBCHoldMiddleware(z *EVMD, app porttypes.IBCModule) *ibcHoldMiddleware {
+	return &ibcHoldMiddleware{app: app, z: z}
+}
+
+func (m *ibcHoldMiddleware) OnChanOpenInit(ctx sdk.Context, order channeltypes.Order, hops []string, port, ch string, cp channeltypes.Counterparty, v string) (string, error) {
+	return m.app.OnChanOpenInit(ctx, order, hops, port, ch, cp, v)
+}
+
+func (m *ibcHoldMiddleware) OnChanOpenTry(ctx sdk.Context, order channeltypes.Order, hops []string, port, ch string, cp channeltypes.Counterparty, v string) (string, error) {
+	return m.app.OnChanOpenTry(ctx, order, hops, port, ch, cp, v)
+}
+
+func (m *ibcHoldMiddleware) OnChanOpenAck(ctx sdk.Context, port, ch, cpCh, cpV string) error {
+	return m.app.OnChanOpenAck(ctx, port, ch, cpCh, cpV)
+}
+
+func (m *ibcHoldMiddleware) OnChanOpenConfirm(ctx sdk.Context, port, ch string) error {
+	return m.app.OnChanOpenConfirm(ctx, port, ch)
+}
+
+func (m *ibcHoldMiddleware) OnChanCloseInit(ctx sdk.Context, port, ch string) error {
+	return m.app.OnChanCloseInit(ctx, port, ch)
+}
+
+func (m *ibcHoldMiddleware) OnChanCloseConfirm(ctx sdk.Context, port, ch string) error {
+	return m.app.OnChanCloseConfirm(ctx, port, ch)
+}
+
+func (m *ibcHoldMiddleware) OnAcknowledgementPacket(ctx sdk.Context, v string, p channeltypes.Packet, ack []byte, r sdk.AccAddress) error {
+	return m.app.OnAcknowledgementPacket(ctx, v, p, ack, r)
+}
+
+func (m *ibcHoldMiddleware) OnTimeoutPacket(ctx sdk.Context, v string, p channeltypes.Packet, r sdk.AccAddress) error {
+	return m.app.OnTimeoutPacket(ctx, v, p, r)
+}
+
+func (m *ibcHoldMiddleware) SetICS4Wrapper(w porttypes.ICS4Wrapper) { m.app.SetICS4Wrapper(w) }
+
+// UnmarshalPacketData lets middlewares above read the packet (callbacks).
+func (m *ibcHoldMiddleware) UnmarshalPacketData(ctx sdk.Context, port, ch string, bz []byte) (any, string, error) {
+	if u, ok := m.app.(porttypes.PacketDataUnmarshaler); ok {
+		return u.UnmarshalPacketData(ctx, port, ch, bz)
+	}
+	return nil, "", errors.New("the application below does not unmarshal packet data")
+}
+
+func (m *ibcHoldMiddleware) OnRecvPacket(ctx sdk.Context, version string, packet channeltypes.Packet, relayer sdk.AccAddress) ibcexported.Acknowledgement {
+	if m.z.ibcHoldOn(ctx) {
+		if data, err := transfertypes.UnmarshalPacketData(packet.GetData(), version, ""); err == nil {
+			amount, ok := sdkmath.NewIntFromString(data.Token.Amount)
+			denom := ibcLocalDenom(data.Token.Denom, packet.SourcePort, packet.SourceChannel, packet.DestinationPort, packet.DestinationChannel)
+			if ok && m.z.ibcHoldNeeded(ctx, denom, amount) {
+				if err := m.z.ibcHoldStore(ctx, version, packet, relayer, denom, data); err != nil {
+					// Not held (the waiting list is full): refused, so the
+					// source chain refunds the sender.
+					return channeltypes.NewErrorAcknowledgement(err)
+				}
+				return nil // asynchronous: acknowledged on release or cancellation
+			}
+		}
+	}
+	return m.app.OnRecvPacket(ctx, version, packet, relayer)
+}
+
+func (app *EVMD) ibcHoldStore(ctx sdk.Context, version string, packet channeltypes.Packet, relayer sdk.AccAddress, denom string, data transfertypes.InternalTransferRepresentation) error {
+	pb, err := packet.Marshal()
+	if err != nil {
+		return err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if readU64(st.Get(holdCountKey)) >= IBCHoldMaxOpen || readU64(st.Get(holdDenomKey(denom))) >= IBCHoldMaxPerDenom {
+		return errors.New("too many large transfers are waiting on ZETAPHY: this one is refused (refunded); send it again later")
+	}
+	id := readU64(st.Get(holdSeqKey)) + 1
+	delay, _ := app.ibcHoldParams(ctx)
+	h := ibcHold{ID: id, Packet: pb, Version: version, Relayer: relayer, Channel: packet.DestinationChannel, Denom: denom,
+		Amount: data.Token.Amount, Sender: data.Sender, Receiver: data.Receiver, HeldAt: ctx.BlockTime().Unix(), ReleaseAt: ctx.BlockTime().Unix() + delay}
+	bz, err := json.Marshal(h)
+	if err != nil {
+		return err
+	}
+	st.Set(holdSeqKey, u64(id))
+	st.Set(holdKey(id), bz)
+	st.Set(holdQueueKey(h.ReleaseAt, id), []byte{})
+	ibcHoldCount(st, denom, 1)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold", sdk.NewAttribute("id", fmt.Sprint(id)),
+		sdk.NewAttribute("channel", h.Channel), sdk.NewAttribute("sequence", fmt.Sprint(packet.Sequence)), sdk.NewAttribute("denom", denom),
+		sdk.NewAttribute("amount", h.Amount), sdk.NewAttribute("sender", h.Sender), sdk.NewAttribute("receiver", h.Receiver),
+		sdk.NewAttribute("release_at", fmt.Sprint(h.ReleaseAt))))
+	return nil
+}
+
+func (app *EVMD) ibcHoldGet(ctx sdk.Context, id uint64) (*ibcHold, channeltypes.Packet, error) {
+	var h ibcHold
+	var p channeltypes.Packet
+	bz := ctx.KVStore(app.GetKey(pqStoreKey)).Get(holdKey(id))
+	if bz == nil {
+		return nil, p, errorsmod.Wrapf(errortypes.ErrNotFound, "no held transfer %d", id)
+	}
+	if err := json.Unmarshal(bz, &h); err != nil {
+		return nil, p, err
+	}
+	return &h, p, p.Unmarshal(h.Packet)
+}
+
+// ibcHoldReleaseDue delivers the held transfers whose delay is over.
+func (app *EVMD) ibcHoldReleaseDue(ctx sdk.Context) {
+	if app.ibcHoldStack == nil {
+		return
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	it := st.Iterator([]byte{holdQueuePfx}, holdQueueKey(ctx.BlockTime().Unix()+1, 0))
+	var ids []uint64
+	var keys [][]byte
+	for ; it.Valid() && len(ids) < ibcReleasesPerBlock; it.Next() {
+		keys = append(keys, bytes.Clone(it.Key()))
+		ids = append(ids, readU64(it.Key()[9:]))
+	}
+	_ = it.Close()
+	var used uint64
+	for i, id := range ids {
+		if used >= ibcReleaseBlockGas {
+			break // the rest stay queued for the next block
+		}
+		st.Delete(keys[i])
+		used += app.ibcHoldRelease(ctx, id)
+	}
+}
+
+// ibcHoldRelease delivers one held transfer and returns the gas its
+// delivery used (at most IBCHoldReleaseGas).
+func (app *EVMD) ibcHoldRelease(ctx sdk.Context, id uint64) uint64 {
+	h, packet, err := app.ibcHoldGet(ctx, id)
+	if err != nil {
+		return 0
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	stuck := func(why string) {
+		h.Stuck = why
+		if bz, err := json.Marshal(h); err == nil {
+			st.Set(holdKey(id), bz)
+		}
+		ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_stuck", sdk.NewAttribute("id", fmt.Sprint(id)), sdk.NewAttribute("reason", why)))
+	}
+	appCtx, writeApp := ctx.CacheContext()
+	meter := storetypes.NewGasMeter(IBCHoldReleaseGas)
+	appCtx = appCtx.WithGasMeter(meter)
+	var ack ibcexported.Acknowledgement
+	if perr := func() (perr error) {
+		defer func() {
+			if r := recover(); r != nil {
+				perr = fmt.Errorf("delivery failed: %v", r)
+			}
+		}()
+		ack = app.ibcHoldStack.app.OnRecvPacket(appCtx, h.Version, packet, h.Relayer)
+		return nil
+	}(); perr != nil {
+		// Out of gas or a panic: nothing of the delivery is kept, the source
+		// chain refunds the sender (only the ABCI code is in the ack bytes).
+		ack = channeltypes.NewErrorAcknowledgement(perr)
+	}
+	used := meter.GasConsumedToLimit()
+	if ack != nil {
+		ackCtx, writeAck := ctx.CacheContext()
+		if err := app.IBCKeeper.ChannelKeeper.WriteAcknowledgement(ackCtx, packet, ack); err != nil {
+			stuck(err.Error())
+			return used
+		}
+		writeAck()
+	}
+	if ack == nil || ack.Success() {
+		writeApp()
+	}
+	st.Delete(holdKey(id))
+	ibcHoldCount(st, h.Denom, -1)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_released", sdk.NewAttribute("id", fmt.Sprint(id)),
+		sdk.NewAttribute("success", fmt.Sprint(ack == nil || ack.Success()))))
+	return used
+}
+
+// ibcHoldCancel returns a held transfer to its sender (an error
+// acknowledgement); by must be the guardian or governance.
+func (app *EVMD) ibcHoldCancel(ctx sdk.Context, by []byte, id uint64) error {
+	_, guardian := app.ibcHoldParams(ctx)
+	if !(guardian != nil && bytes.Equal(by, guardian)) && !bytes.Equal(by, authtypes.NewModuleAddress(govtypes.ModuleName)) {
+		return errorsmod.Wrap(errortypes.ErrUnauthorized, "only the IBC hold guardian or governance can return a held transfer")
+	}
+	h, packet, err := app.ibcHoldGet(ctx, id)
+	if err != nil {
+		return err
+	}
+	ack := channeltypes.NewErrorAcknowledgement(fmt.Errorf("held transfer %d returned to its sender by the ZETAPHY guardian", id))
+	if err := app.IBCKeeper.ChannelKeeper.WriteAcknowledgement(ctx, packet, ack); err != nil {
+		return err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	st.Delete(holdKey(id))
+	st.Delete(holdQueueKey(h.ReleaseAt, id))
+	ibcHoldCount(st, h.Denom, -1)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_cancelled", sdk.NewAttribute("id", fmt.Sprint(id)),
+		sdk.NewAttribute("by", sdk.AccAddress(by).String()), sdk.NewAttribute("sender", h.Sender), sdk.NewAttribute("amount", h.Amount), sdk.NewAttribute("denom", h.Denom)))
+	return nil
+}
+
+func (app *EVMD) ibcHoldCancelMsg(ctx sdk.Context, m *MsgIBCHoldCancel) (gogoproto.Message, error) {
+	by, err := pqAddr(m.Signer)
+	if err != nil {
+		return nil, err
+	}
+	return &MsgPQResponse{}, app.ibcHoldCancel(ctx, by, m.Id)
+}
+
+func (app *EVMD) setIBCHold(ctx sdk.Context, m *MsgSetIBCHold) (gogoproto.Message, error) {
+	if m.Authority != govAuthority() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can set the IBC hold")
+	}
+	if m.DelaySeconds < IBCHoldMinDelay || m.DelaySeconds > IBCHoldMaxDelay {
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "delay_seconds: %d to %d", IBCHoldMinDelay, IBCHoldMaxDelay)
+	}
+	v := u64(m.DelaySeconds)
+	if m.Guardian != "" {
+		g, err := pqAddr(m.Guardian)
+		if err != nil {
+			return nil, err
+		}
+		v = append(v, g...)
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(holdParamsKey, v)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_params", sdk.NewAttribute("delay_seconds", fmt.Sprint(m.DelaySeconds)), sdk.NewAttribute("guardian", m.Guardian)))
+	return &MsgPQResponse{}, nil
+}
+
+func (app *EVMD) setIBCHoldRule(ctx sdk.Context, m *MsgSetIBCHoldRule) (gogoproto.Message, error) {
+	if m.Authority != govAuthority() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can set IBC hold rules")
+	}
+	if m.Denom == "" || len(m.Denom) > 128 {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "denom: 1 to 128 characters (\"*\" for every denom without its own rule)")
+	}
+	min := sdkmath.ZeroInt()
+	if m.MinAmount != "" {
+		var ok bool
+		if min, ok = sdkmath.NewIntFromString(m.MinAmount); !ok || min.IsNegative() {
+			return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "min_amount: a whole number of the denom's base unit")
+		}
+	}
+	if m.SupplyBps > 10000 || (m.Denom == "*" && min.IsPositive() && m.SupplyBps == 0) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "supply_bps: 0 to 10000; the \"*\" rule takes a supply share (its min_amount is the amount from which the share applies)")
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if min.IsZero() && m.SupplyBps == 0 {
+		st.Delete(holdRuleKey(m.Denom))
+	} else {
+		st.Set(holdRuleKey(m.Denom), append(u64(m.SupplyBps), min.String()...))
+	}
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_rule", sdk.NewAttribute("denom", m.Denom),
+		sdk.NewAttribute("min_amount", min.String()), sdk.NewAttribute("supply_bps", fmt.Sprint(m.SupplyBps))))
+	return &MsgPQResponse{}, nil
+}
+
+// ---- IBC v2: no asynchronous hold; over the threshold is refused
+
+type ibcHoldV2 struct {
+	app ibcapi.IBCModule
+	z   *EVMD
+}
+
+func (m *ibcHoldV2) OnSendPacket(ctx sdk.Context, src, dst string, seq uint64, p channeltypesv2.Payload, signer sdk.AccAddress) error {
+	return m.app.OnSendPacket(ctx, src, dst, seq, p, signer)
+}
+
+func (m *ibcHoldV2) OnTimeoutPacket(ctx sdk.Context, src, dst string, seq uint64, p channeltypesv2.Payload, r sdk.AccAddress) error {
+	return m.app.OnTimeoutPacket(ctx, src, dst, seq, p, r)
+}
+
+func (m *ibcHoldV2) OnAcknowledgementPacket(ctx sdk.Context, src, dst string, seq uint64, ack []byte, p channeltypesv2.Payload, r sdk.AccAddress) error {
+	return m.app.OnAcknowledgementPacket(ctx, src, dst, seq, ack, p, r)
+}
+
+func (m *ibcHoldV2) UnmarshalPacketData(p channeltypesv2.Payload) (any, error) {
+	if u, ok := m.app.(ibcapi.PacketDataUnmarshaler); ok {
+		return u.UnmarshalPacketData(p)
+	}
+	return nil, errors.New("the application below does not unmarshal packet data")
+}
+
+func (m *ibcHoldV2) OnRecvPacket(ctx sdk.Context, src, dst string, seq uint64, p channeltypesv2.Payload, r sdk.AccAddress) channeltypesv2.RecvPacketResult {
+	if m.z.ibcHoldOn(ctx) {
+		if data, err := transfertypes.UnmarshalPacketData(p.Value, p.Version, p.Encoding); err == nil {
+			amount, ok := sdkmath.NewIntFromString(data.Token.Amount)
+			denom := ibcLocalDenom(data.Token.Denom, p.SourcePort, src, p.DestinationPort, dst)
+			if ok && m.z.ibcHoldNeeded(ctx, denom, amount) {
+				err := fmt.Errorf("a transfer this large is held for review on ZETAPHY, which IBC v2 cannot do: send it over an IBC v1 channel")
+				ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_ibc_hold_refused_v2", sdk.NewAttribute("denom", denom), sdk.NewAttribute("amount", data.Token.Amount)))
+				return channeltypesv2.RecvPacketResult{Status: channeltypesv2.PacketStatus_Failure, Acknowledgement: channeltypes.NewErrorAcknowledgement(err).Acknowledgement()}
+			}
+		}
+	}
+	return m.app.OnRecvPacket(ctx, src, dst, seq, p, r)
+}
diff --git a/evmd/zetaphy_immune.go b/evmd/zetaphy_immune.go
new file mode 100644
index 0000000..7191070
--- /dev/null
+++ b/evmd/zetaphy_immune.go
@@ -0,0 +1,822 @@
+package evmd
+
+// ZETAPHY v5 chain immune system: validators score new contracts in their
+// vote extensions; the chain records the median.
+//
+// Timeline (ABCI++ makes a vote before the block it votes on runs, so the
+// vote at height H sees the state after H-1):
+//
+//	block N        a contract is deployed (a top-level creation: an
+//	               Ethereum tx or a MsgEVMCall without "to"); it is put in
+//	               the pending list of N (at most immuneMaxPerBlock, more
+//	               are left unscored with an event)
+//	vote on N+1    each validator scores the pending contracts of N from
+//	               their runtime bytecode (immuneCodeScore, a deterministic
+//	               subset of Neuro's rules) and adds the scores to its vote
+//	               extension, after the ML-DSA-44 vote signature
+//	block N+2      the proposer carries those extensions (MsgZXVotes, next to
+//	               the vote certificate); every node checks each one against
+//	               the validator's CometBFT signature and records, per
+//	               contract, the power-weighted median score, if validators
+//	               with more than 2/3 of the power sent one
+//
+// Vote extension layout: [ML-DSA-44 signature, 2420 bytes, when the
+// validator signs] || [v5 payload, when it has something to say]:
+//
+//	"ZX1" | n u8 | n × (contract 20 | score u16) | m u8 | m × bridge 20
+//
+// (contracts and bridges strictly increasing; the bridges are those the
+// validator flags, zetaphy_breaker.go). The PQ certificate keeps using the
+// signature part only, so its format and rule are unchanged. Before the v5
+// height a payload is refused, as any extra byte was before.
+//
+// Readable on chain through 0x…0903: scoreOf, and the ThreatRegistry views
+// isContractEnforced / isContractHeld (score at or above governance's
+// enforce_bps / hold_bps), so the threat gate (gov.sh threat-gate
+// 0x…0903 on) and BridgeGuard.setThreats can use it directly.
+
+import (
+	"bytes"
+	"encoding/binary"
+	"encoding/json"
+	"errors"
+	"fmt"
+	"math/big"
+	"sort"
+
+	circl "github.com/cloudflare/circl/sign/mldsa/mldsa44"
+	abci "github.com/cometbft/cometbft/abci/types"
+	cryptoenc "github.com/cometbft/cometbft/crypto/encoding"
+	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
+	protoio "github.com/cosmos/gogoproto/io"
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	errorsmod "cosmossdk.io/errors"
+
+	cmn "github.com/cosmos/evm/precompiles/common"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+)
+
+const (
+	immuneMaxPerBlock = 16  // contracts scored per block
+	breakerMax        = 4   // watched bridges
+	zxMaxEntries      = 200 // validators in one MsgZXVotes
+	zxMaxPayload      = 3 + 1 + immuneMaxPerBlock*22 + 1 + breakerMax*20
+	zxMaxEntriesBytes = 1 << 20
+)
+
+// immuneParams (governance, MsgSetFuture kind "immune").
+type immuneParams struct {
+	Enabled    bool   `json:"enabled"`
+	EnforceBps uint16 `json:"enforce_bps"` // isContractEnforced from this score (0: never)
+	HoldBps    uint16 `json:"hold_bps"`    // isContractHeld from this score (0: never)
+	ProtectBps uint16 `json:"protect_bps"` // protected accounts treat a contract as high-risk from this score (0: 7000)
+}
+
+func (p immuneParams) validate() error {
+	if p.EnforceBps > 10000 || p.HoldBps > 10000 || p.ProtectBps > 10000 {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "scores are basis points: 0..10000")
+	}
+	return nil
+}
+
+func (app *EVMD) immuneParams(ctx sdk.Context) immuneParams {
+	var p immuneParams
+	if raw := app.secRaw(ctx).Get(immuneParamsKey); raw != nil {
+		_ = json.Unmarshal(raw, &p)
+	}
+	if p.ProtectBps == 0 {
+		p.ProtectBps = 7000
+	}
+	return p
+}
+
+// ---- bytecode score (a deterministic subset of zetaphy-neuro/src rules)
+
+const (
+	selMint = iota + 1
+	selBlacklist
+	selFee
+	selTrading
+	selTaxWallet
+)
+
+// immuneSelectors: Neuro's selectors (src/selectors.generated.js) of the
+// categories that make a token dangerous to hold.
+var immuneSelectors = map[uint32]int{
+	0x40c10f19: selMint, 0xa0712d68: selMint, 0x449a52f8: selMint, 0xcc872b66: selMint,
+	0xf9f92be4: selBlacklist, 0x404e5129: selBlacklist, 0x153b0d1e: selBlacklist, 0x44337ea1: selBlacklist,
+	0x537df3b6: selBlacklist, 0xfe575a87: selBlacklist, 0xb515566a: selBlacklist, 0x00b8cf2a: selBlacklist,
+	0xd34628cc: selBlacklist, 0x0ecb93c0: selBlacklist, 0xe4997dc5: selBlacklist, 0xf3bdc228: selBlacklist,
+	0x69fe0e2d: selFee, 0x0b78f9c0: selFee, 0xc4081a4c: selFee, 0x2e5bb6ff: selFee, 0x0cc835a3: selFee, 0x8b4cee08: selFee,
+	0x6db79437: selFee, 0xcec10c11: selFee, 0xc647b20e: selFee, 0x5cb23e12: selFee, 0x55e2e974: selFee, 0xe5dc6b21: selFee,
+	0x8095d564: selFee, 0xc17b5b8c: selFee, 0xec1f3f63: selFee, 0x2ff5fe1e: selFee, 0x57d0a982: selFee, 0x233e8700: selFee,
+	0xdc1052e2: selFee, 0x8cd09d50: selFee,
+	0xea414b28: selTaxWallet, 0x5d098b38: selTaxWallet,
+	0x8a8c523c: selTrading, 0xc9567bf9: selTrading, 0xc2e5ec04: selTrading, 0x8f70ccf7: selTrading, 0x293230b8: selTrading, 0xca72a4e7: selTrading,
+}
+
+// CodeFeatures is what immuneCodeScore reads from runtime bytecode.
+type CodeFeatures struct {
+	Size                                                  int
+	MinimalProxy                                          bool
+	SelfDestruct, DelegateCall, CallCode, Create2, Origin bool
+	ERC20                                                 bool
+	Mint, Blacklist, Fee, Trading, TaxWallet              int
+}
+
+var minimalProxyPrefix = common.FromHex("363d3d373d3d3d363d73")
+var minimalProxySuffix = common.FromHex("5af43d82803e903d91602b57fd5bf3")
+
+// ImmuneCodeFeatures walks the opcodes (skipping PUSH data, as Neuro's
+// src/bytecode.js) of the code without its Solidity metadata.
+func ImmuneCodeFeatures(code []byte) CodeFeatures {
+	f := CodeFeatures{Size: len(code)}
+	if len(code) == 45 && bytes.HasPrefix(code, minimalProxyPrefix) && bytes.HasSuffix(code, minimalProxySuffix) {
+		f.MinimalProxy = true
+		return f
+	}
+	end := len(code)
+	if end >= 4 { // CBOR metadata: its length is in the last 2 bytes
+		ml := int(code[end-2])<<8 | int(code[end-1])
+		if s := end - 2 - ml; ml > 0 && s > 0 && code[s] >= 0xa1 && code[s] <= 0xa5 {
+			end = s
+		}
+	}
+	var transfer, balanceOf, approve bool
+	for pc := 0; pc < end; pc++ {
+		op := code[pc]
+		switch op {
+		case 0xff:
+			f.SelfDestruct = true
+		case 0xf4:
+			f.DelegateCall = true
+		case 0xf2:
+			f.CallCode = true
+		case 0xf5:
+			f.Create2 = true
+		case 0x32:
+			f.Origin = true
+		}
+		if op >= 0x60 && op <= 0x7f {
+			n := int(op) - 0x5f
+			if n <= 4 && pc+n < len(code) {
+				var sel uint32
+				for _, b := range code[pc+1 : pc+1+n] {
+					sel = sel<<8 | uint32(b)
+				}
+				switch sel {
+				case 0xa9059cbb:
+					transfer = true
+				case 0x70a08231:
+					balanceOf = true
+				case 0x095ea7b3:
+					approve = true
+				}
+				switch immuneSelectors[sel] {
+				case selMint:
+					f.Mint++
+				case selBlacklist:
+					f.Blacklist++
+				case selFee:
+					f.Fee++
+				case selTrading:
+					f.Trading++
+				case selTaxWallet:
+					f.TaxWallet++
+				}
+			}
+			pc += n
+		}
+	}
+	f.ERC20 = transfer && balanceOf && approve
+	return f
+}
+
+// Score in basis points: 0 (nothing found) .. 10000.
+func (f CodeFeatures) Score() uint16 {
+	if f.Size == 0 {
+		return 0
+	}
+	if f.MinimalProxy {
+		return 1000 // behaviour is the target's: not judged here
+	}
+	s := 0
+	add := func(on bool, w int) {
+		if on {
+			s += w
+		}
+	}
+	add(f.SelfDestruct, 2000)
+	add(f.CallCode, 2000)
+	add(f.DelegateCall, 1500)
+	add(f.Origin, 1000) // tx.origin checks: a honeypot pattern
+	add(f.Create2, 500)
+	if f.ERC20 {
+		add(f.Blacklist > 0, 2500)
+		add(f.Fee > 0, 1500)
+		add(f.Trading > 0, 1000)
+		add(f.Mint > 0, 1000)
+		add(f.TaxWallet > 0, 500)
+	}
+	return uint16(min(s, 10000)) // #nosec G115 -- capped
+}
+
+func (app *EVMD) immuneCodeScore(ctx sdk.Context, a common.Address) uint16 {
+	return ImmuneCodeFeatures(app.EVMKeeper.GetCode(ctx, app.EVMKeeper.GetCodeHash(ctx, a))).Score()
+}
+
+// ---- pending list
+
+func immunePendingKey(h int64, a common.Address) []byte {
+	return append(append([]byte{immunePendingPfx}, u64(uint64(h))...), a.Bytes()...) // #nosec G115 -- block heights
+}
+
+func immunePendingPrefix(h int64) []byte {
+	return append([]byte{immunePendingPfx}, u64(uint64(h))...) // #nosec G115 -- block heights
+}
+
+// immunePending: the contracts deployed in block h, by address.
+func (app *EVMD) immunePending(ctx sdk.Context, h int64) []common.Address {
+	var out []common.Address
+	p := immunePendingPrefix(h)
+	it := app.secRaw(ctx).Iterator(p, storetypes.PrefixEndBytes(p))
+	defer it.Close()
+	for ; it.Valid() && len(out) < immuneMaxPerBlock; it.Next() {
+		out = append(out, common.BytesToAddress(it.Key()[len(p):]))
+	}
+	return out
+}
+
+// immuneNoteDeploy puts a contract created in this block in the pending list.
+func (app *EVMD) immuneNoteDeploy(ctx sdk.Context, a common.Address) {
+	if !app.futV5(ctx, ctx.BlockHeight()) || ctx.ExecMode() != sdk.ExecModeFinalize || !app.immuneParams(ctx).Enabled {
+		return
+	}
+	if len(app.immunePending(ctx, ctx.BlockHeight())) >= immuneMaxPerBlock {
+		ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_immune_unscored", sdk.NewAttribute("contract", a.Hex())))
+		return
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(immunePendingKey(ctx.BlockHeight(), a), []byte{})
+}
+
+// immuneScore: the recorded median for a contract.
+func (app *EVMD) immuneScore(ctx sdk.Context, a common.Address) (score uint16, height int64, share uint16, ok bool) {
+	v := app.secRaw(ctx).Get(append([]byte{immuneScorePfx}, a.Bytes()...))
+	if len(v) != 12 {
+		return 0, 0, 0, false
+	}
+	return binary.BigEndian.Uint16(v), int64(binary.BigEndian.Uint64(v[2:])), binary.BigEndian.Uint16(v[10:]), true // #nosec G115 -- block heights
+}
+
+// ---- vote extension payload
+
+type zxScore struct {
+	contract common.Address
+	score    uint16
+}
+
+type zxPayload struct {
+	scores  []zxScore
+	flagged []common.Address
+}
+
+// zxSplit: the ML-DSA-44 signature part and the v5 payload of an extension.
+func zxSplit(ext []byte) (sig, payload []byte) {
+	if len(ext) >= circl.SignatureSize {
+		return ext[:circl.SignatureSize], ext[circl.SignatureSize:]
+	}
+	return nil, ext
+}
+
+func (p *zxPayload) encode() []byte {
+	if p == nil || (len(p.scores) == 0 && len(p.flagged) == 0) {
+		return nil
+	}
+	out := append([]byte("ZX1"), byte(len(p.scores)))
+	for _, s := range p.scores {
+		out = binary.BigEndian.AppendUint16(append(out, s.contract.Bytes()...), s.score)
+	}
+	out = append(out, byte(len(p.flagged)))
+	for _, b := range p.flagged {
+		out = append(out, b.Bytes()...)
+	}
+	return out
+}
+
+// zxDecode parses a payload's structure (no state).
+func zxDecode(b []byte) (*zxPayload, error) {
+	if len(b) == 0 {
+		return &zxPayload{}, nil
+	}
+	if len(b) > zxMaxPayload || len(b) < 5 || string(b[:3]) != "ZX1" {
+		return nil, errors.New("v5 payload: bad header or size")
+	}
+	p := &zxPayload{}
+	n, q := int(b[3]), 4
+	if n > immuneMaxPerBlock || len(b) < q+n*22+1 {
+		return nil, errors.New("v5 payload: scores")
+	}
+	for i := 0; i < n; i++ {
+		s := zxScore{common.BytesToAddress(b[q : q+20]), binary.BigEndian.Uint16(b[q+20:])}
+		if s.score > 10000 || (i > 0 && bytes.Compare(s.contract.Bytes(), p.scores[i-1].contract.Bytes()) <= 0) {
+			return nil, errors.New("v5 payload: score out of range or contracts not increasing")
+		}
+		p.scores = append(p.scores, s)
+		q += 22
+	}
+	m := int(b[q])
+	q++
+	if m > breakerMax || len(b) != q+m*20 {
+		return nil, errors.New("v5 payload: bridges")
+	}
+	for i := 0; i < m; i++ {
+		a := common.BytesToAddress(b[q : q+20])
+		if i > 0 && bytes.Compare(a.Bytes(), p.flagged[i-1].Bytes()) <= 0 {
+			return nil, errors.New("v5 payload: bridges not increasing")
+		}
+		p.flagged = append(p.flagged, a)
+		q += 20
+	}
+	return p, nil
+}
+
+// zxCheck validates a payload for the vote on height h against the state
+// after h-1 (the state the vote was made in).
+func (app *EVMD) zxCheck(ctx sdk.Context, h int64, b []byte) (*zxPayload, error) {
+	if len(b) == 0 {
+		return &zxPayload{}, nil
+	}
+	if !app.futV5(ctx, h) {
+		return nil, errors.New("v5 payload before the v5 height")
+	}
+	p, err := zxDecode(b)
+	if err != nil {
+		return nil, err
+	}
+	if len(p.scores) > 0 {
+		if !app.immuneParams(ctx).Enabled {
+			return nil, errors.New("v5 payload: the immune system is off")
+		}
+		st := app.secRaw(ctx)
+		for _, s := range p.scores {
+			if !st.Has(immunePendingKey(h-1, s.contract)) {
+				return nil, fmt.Errorf("v5 payload: %s was not deployed in block %d", s.contract.Hex(), h-1)
+			}
+		}
+	}
+	for _, br := range p.flagged {
+		if app.breakerConfig(ctx, br) == nil {
+			return nil, fmt.Errorf("v5 payload: %s is not a watched bridge", br.Hex())
+		}
+	}
+	return p, nil
+}
+
+// zxBuild: this validator's payload for its vote on h (state after h-1).
+func (app *EVMD) zxBuild(ctx sdk.Context, h int64) (out []byte) {
+	defer func() {
+		if r := recover(); r != nil { // never lose the vote over this
+			app.Logger().Error("ZETAPHY v5: vote payload", "panic", r)
+			out = nil
+		}
+	}()
+	if !app.futV5(ctx, h) {
+		return nil
+	}
+	p := &zxPayload{}
+	if app.immuneParams(ctx).Enabled {
+		for _, a := range app.immunePending(ctx, h-1) {
+			p.scores = append(p.scores, zxScore{a, app.immuneCodeScore(ctx, a)})
+		}
+	}
+	p.flagged = app.breakerFlags(ctx, h-1)
+	return p.encode()
+}
+
+// ---- carrying the extensions in the next block
+
+type zxEntry struct {
+	cons    []byte
+	mode    byte // 0: no signature part, 1: the one in the block's certificate, 2: inline
+	sig     []byte
+	payload []byte
+	extSig  []byte
+}
+
+func (e zxEntry) encode() []byte {
+	out := append(append([]byte{}, e.cons...), e.mode)
+	if e.mode == 2 {
+		out = append(out, e.sig...)
+	}
+	out = binary.BigEndian.AppendUint16(out, uint16(len(e.payload))) // #nosec G115 -- capped
+	out = append(append(out, e.payload...), byte(len(e.extSig)))
+	return append(out, e.extSig...)
+}
+
+func zxDecodeEntries(b []byte) ([]zxEntry, error) {
+	var out []zxEntry
+	for q := 0; q < len(b); {
+		if len(out) >= zxMaxEntries || q+21 > len(b) {
+			return nil, errors.New("ZX votes: malformed")
+		}
+		e := zxEntry{cons: b[q : q+20], mode: b[q+20]}
+		q += 21
+		switch e.mode {
+		case 0, 1:
+		case 2:
+			if q+circl.SignatureSize > len(b) {
+				return nil, errors.New("ZX votes: malformed")
+			}
+			e.sig = b[q : q+circl.SignatureSize]
+			q += circl.SignatureSize
+		default:
+			return nil, errors.New("ZX votes: mode")
+		}
+		if q+2 > len(b) {
+			return nil, errors.New("ZX votes: malformed")
+		}
+		n := int(binary.BigEndian.Uint16(b[q:]))
+		q += 2
+		if n == 0 || n > zxMaxPayload || q+n+1 > len(b) {
+			return nil, errors.New("ZX votes: payload")
+		}
+		e.payload = b[q : q+n]
+		q += n
+		k := int(b[q])
+		q++
+		if k == 0 || q+k > len(b) {
+			return nil, errors.New("ZX votes: signature")
+		}
+		e.extSig = b[q : q+k]
+		q += k
+		if len(out) > 0 && bytes.Compare(e.cons, out[len(out)-1].cons) <= 0 {
+			return nil, errors.New("ZX votes: validators not increasing")
+		}
+		out = append(out, e)
+	}
+	return out, nil
+}
+
+func zxHas(tx sdk.Tx) bool {
+	for _, m := range tx.GetMsgs() {
+		if _, ok := m.(*MsgZXVotes); ok {
+			return true
+		}
+	}
+	return false
+}
+
+func (app *EVMD) zxVotesMsg(sdk.Context, *MsgZXVotes) (gogoproto.Message, error) {
+	return &MsgPQResponse{}, nil // applied in PreBlocker (zxPreBlock)
+}
+
+// zxOf: the MsgZXVotes of a block, right after the certificate (or first).
+func (app *EVMD) zxOf(txs [][]byte) (*MsgZXVotes, int) {
+	i := 0
+	if app.pqCertOf(txs) != nil {
+		i = 1
+	}
+	if len(txs) <= i {
+		return nil, -1
+	}
+	tx, err := app.TxDecode(txs[i])
+	if err != nil || len(tx.GetMsgs()) != 1 {
+		return nil, -1
+	}
+	z, _ := tx.GetMsgs()[0].(*MsgZXVotes)
+	if z == nil {
+		return nil, -1
+	}
+	return z, i
+}
+
+func certSigs(c *MsgPQCertificate) map[string][]byte {
+	out := map[string][]byte{}
+	if c == nil {
+		return out
+	}
+	for i := 0; i+pqAttestationSize <= len(c.Attestations); i += pqAttestationSize {
+		out[string(c.Attestations[i:i+20])] = c.Attestations[i+20 : i+pqAttestationSize]
+	}
+	return out
+}
+
+// zxBuildTx: the proposer's MsgZXVotes for block height, from the extended
+// votes on height-1; cert is the certificate tx it puts first (or nil).
+func (app *EVMD) zxBuildTx(ctx sdk.Context, height int64, commit abci.ExtendedCommitInfo, cert []byte) []byte {
+	if !app.futV5(ctx, height-1) {
+		return nil
+	}
+	var c *MsgPQCertificate
+	if cert != nil {
+		c = app.pqCertOf([][]byte{cert})
+	}
+	inCert := certSigs(c)
+	var entries []zxEntry
+	for _, v := range commit.Votes {
+		if v.BlockIdFlag != cmtproto.BlockIDFlagCommit || len(v.Validator.Address) != 20 || len(v.ExtensionSignature) == 0 || len(v.ExtensionSignature) > 255 {
+			continue
+		}
+		sig, payload := zxSplit(v.VoteExtension)
+		if len(payload) == 0 {
+			continue
+		}
+		if _, err := zxDecode(payload); err != nil {
+			continue
+		}
+		e := zxEntry{cons: v.Validator.Address, payload: payload, extSig: v.ExtensionSignature}
+		switch {
+		case sig == nil:
+		case bytes.Equal(inCert[string(v.Validator.Address)], sig):
+			e.mode = 1
+		default:
+			e.mode, e.sig = 2, sig
+		}
+		entries = append(entries, e)
+	}
+	if len(entries) == 0 {
+		return nil
+	}
+	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i].cons, entries[j].cons) < 0 })
+	var raw []byte
+	for i, e := range entries {
+		if i >= zxMaxEntries || (i > 0 && bytes.Equal(e.cons, entries[i-1].cons)) {
+			continue
+		}
+		raw = append(raw, e.encode()...)
+	}
+	b := app.txConfig.NewTxBuilder()
+	if err := b.SetMsgs(&MsgZXVotes{Signer: authtypes.NewModuleAddress(pqStoreKey).String(), Height: uint64(height - 1), // #nosec G115 -- block heights
+		Round: uint64(commit.Round), Entries: raw}); err != nil { // #nosec G115 -- rounds are small
+		return nil
+	}
+	bz, err := app.txConfig.TxEncoder()(b.GetTx())
+	if err != nil {
+		return nil
+	}
+	return bz
+}
+
+// zxCheckProposal: a structurally sound MsgZXVotes, for the block before.
+func (app *EVMD) zxCheckProposal(height int64, txs [][]byte) error {
+	z, _ := app.zxOf(txs)
+	if z == nil {
+		return nil
+	}
+	if z.Height != uint64(height-1) || len(z.Entries) > zxMaxEntriesBytes { // #nosec G115 -- block heights
+		return errors.New("malformed v5 votes")
+	}
+	_, err := zxDecodeEntries(z.Entries)
+	return err
+}
+
+// zxExtSignBytes: what CometBFT signs for a vote extension.
+func zxExtSignBytes(chainID string, height int64, round int64, ext []byte) ([]byte, error) {
+	var buf bytes.Buffer
+	err := protoio.NewDelimitedWriter(&buf).WriteMsg(&cmtproto.CanonicalVoteExtension{Extension: ext, Height: height, Round: round, ChainId: chainID})
+	return buf.Bytes(), err
+}
+
+// zxPreBlock applies the extensions a block carries: immune medians and
+// breaker trips. A bad entry is skipped, never the block.
+func (app *EVMD) zxPreBlock(ctx sdk.Context, req *abci.RequestFinalizeBlock) {
+	if !app.futV5(ctx, req.Height) {
+		return
+	}
+	defer app.immunePrune(ctx, req.Height-2)
+	z, _ := app.zxOf(req.Txs)
+	if z == nil || z.Height != uint64(req.Height-1) || len(z.Entries) > zxMaxEntriesBytes { // #nosec G115 -- block heights
+		return
+	}
+	entries, err := zxDecodeEntries(z.Entries)
+	if err != nil {
+		return
+	}
+	power := map[string]int64{}
+	var total int64
+	for _, v := range req.DecidedLastCommit.Votes {
+		power[string(v.Validator.Address)] = v.Validator.Power
+		total += v.Validator.Power
+	}
+	if total <= 0 {
+		return
+	}
+	inCert := certSigs(app.pqCertOf(req.Txs))
+	type vote struct {
+		score uint16
+		power int64
+	}
+	scores := map[common.Address][]vote{}
+	flagged := map[common.Address]int64{}
+	params := app.immuneParams(ctx)
+	st := app.secRaw(ctx)
+	for _, e := range entries {
+		pw, ok := power[string(e.cons)]
+		if !ok || pw <= 0 {
+			continue
+		}
+		var ext []byte
+		switch e.mode {
+		case 1:
+			if inCert[string(e.cons)] == nil {
+				continue
+			}
+			ext = append(append([]byte{}, inCert[string(e.cons)]...), e.payload...)
+		case 2:
+			ext = append(append([]byte{}, e.sig...), e.payload...)
+		default:
+			ext = e.payload
+		}
+		if !app.zxVerifyExt(ctx, e.cons, int64(z.Height), int64(z.Round), ext, e.extSig) { // #nosec G115 -- heights and rounds
+			continue
+		}
+		p, err := zxDecode(e.payload)
+		if err != nil {
+			continue
+		}
+		if params.Enabled {
+			for _, s := range p.scores {
+				if st.Has(immunePendingKey(req.Height-2, s.contract)) {
+					scores[s.contract] = append(scores[s.contract], vote{s.score, pw})
+				}
+			}
+		}
+		for _, b := range p.flagged {
+			flagged[b] += pw
+		}
+	}
+	kv := ctx.KVStore(app.GetKey(pqStoreKey))
+	contracts := make([]common.Address, 0, len(scores))
+	for a := range scores {
+		contracts = append(contracts, a)
+	}
+	sort.Slice(contracts, func(i, j int) bool { return bytes.Compare(contracts[i].Bytes(), contracts[j].Bytes()) < 0 })
+	for _, a := range contracts {
+		vs := scores[a]
+		var sum int64
+		for _, v := range vs {
+			sum += v.power
+		}
+		if 3*sum <= 2*total {
+			ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_immune_no_quorum", sdk.NewAttribute("contract", a.Hex()),
+				sdk.NewAttribute("power_bps", fmt.Sprint(sum*10000/total))))
+			continue
+		}
+		sort.SliceStable(vs, func(i, j int) bool { return vs[i].score < vs[j].score })
+		var cum int64
+		med := vs[len(vs)-1].score
+		for _, v := range vs {
+			cum += v.power
+			if 2*cum >= sum {
+				med = v.score
+				break
+			}
+		}
+		share := uint16(sum * 10000 / total) // #nosec G115 -- at most 10000
+		val := binary.BigEndian.AppendUint16(nil, med)
+		val = append(val, u64(uint64(req.Height))...) // #nosec G115 -- block heights
+		kv.Set(append([]byte{immuneScorePfx}, a.Bytes()...), binary.BigEndian.AppendUint16(val, share))
+		ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_immune_score", sdk.NewAttribute("contract", a.Hex()),
+			sdk.NewAttribute("score_bps", fmt.Sprint(med)), sdk.NewAttribute("power_bps", fmt.Sprint(share))))
+	}
+	for _, b := range sortedAddrs(flagged) {
+		if 3*flagged[b] > 2*total {
+			app.breakerSchedulePause(ctx, b, flagged[b]*10000/total)
+		}
+	}
+}
+
+func sortedAddrs[V any](m map[common.Address]V) []common.Address {
+	out := make([]common.Address, 0, len(m))
+	for a := range m {
+		out = append(out, a)
+	}
+	sort.Slice(out, func(i, j int) bool { return bytes.Compare(out[i].Bytes(), out[j].Bytes()) < 0 })
+	return out
+}
+
+// zxVerifyExt checks a vote extension against the validator's consensus key.
+func (app *EVMD) zxVerifyExt(ctx sdk.Context, cons []byte, height, round int64, ext, sig []byte) bool {
+	pk, err := app.StakingKeeper.GetPubKeyByConsAddr(ctx, sdk.ConsAddress(cons))
+	if err != nil {
+		return false
+	}
+	cpk, err := cryptoenc.PubKeyFromProto(pk)
+	if err != nil {
+		return false
+	}
+	sb, err := zxExtSignBytes(ctx.ChainID(), height, round, ext)
+	return err == nil && cpk.VerifySignature(sb, sig)
+}
+
+// immunePrune drops pending lists up to height h.
+func (app *EVMD) immunePrune(ctx sdk.Context, h int64) {
+	if h < 0 {
+		return
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	it := st.Iterator([]byte{immunePendingPfx}, immunePendingPrefix(h+1))
+	var del [][]byte
+	for ; it.Valid() && len(del) < 1024; it.Next() {
+		del = append(del, append([]byte{}, it.Key()...))
+	}
+	_ = it.Close()
+	for _, k := range del {
+		st.Delete(k)
+	}
+}
+
+// ---- precompile 0x…0903
+
+const immuneABIJSON = `[
+ {"type":"function","name":"scoreOf","stateMutability":"view","inputs":[{"name":"who","type":"address"}],"outputs":[{"name":"score","type":"uint16"},{"name":"height","type":"uint64"},{"name":"powerBps","type":"uint16"},{"name":"known","type":"bool"}]},
+ {"type":"function","name":"isContractEnforced","stateMutability":"view","inputs":[{"name":"who","type":"address"}],"outputs":[{"name":"","type":"bool"},{"name":"","type":"uint8"}]},
+ {"type":"function","name":"isContractHeld","stateMutability":"view","inputs":[{"name":"who","type":"address"}],"outputs":[{"name":"","type":"bool"},{"name":"","type":"uint8"}]},
+ {"type":"function","name":"codeScore","stateMutability":"view","inputs":[{"name":"who","type":"address"}],"outputs":[{"name":"score","type":"uint16"}]},
+ {"type":"function","name":"immuneParams","stateMutability":"view","inputs":[],"outputs":[{"name":"enabled","type":"bool"},{"name":"enforceBps","type":"uint16"},{"name":"holdBps","type":"uint16"},{"name":"protectBps","type":"uint16"}]},
+ {"type":"function","name":"breaker","stateMutability":"view","inputs":[{"name":"bridge","type":"address"}],"outputs":[{"name":"watched","type":"bool"},{"name":"tripped","type":"bool"},{"name":"trippedAt","type":"uint64"},{"name":"lastHeight","type":"uint64"},{"name":"lastVolume","type":"uint256"},{"name":"baseline","type":"uint256"}]}
+]`
+
+// ImmuneABI is the immune precompile's ABI.
+var ImmuneABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(immuneABIJSON)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+// ThreatReasonImmune: the ThreatRegistry reason the immune views answer ("Other").
+const ThreatReasonImmune = 7
+
+type immunePrecompile struct {
+	cmn.Precompile
+	app *EVMD
+}
+
+func newImmunePrecompile(app *EVMD) *immunePrecompile {
+	return &immunePrecompile{Precompile: cmn.Precompile{
+		KvGasConfig: storetypes.KVGasConfig(), TransientKVGasConfig: storetypes.TransientGasConfig(),
+		ContractAddress: ImmunePrecompileAddress,
+	}, app: app}
+}
+
+func (*immunePrecompile) Name() string { return "zetaphy-immune" }
+
+func (p *immunePrecompile) RequiredGas(input []byte) uint64 {
+	return p.Precompile.RequiredGas(input, false)
+}
+
+func (p *immunePrecompile) Run(evm *vm.EVM, contract *vm.Contract, readonly bool) ([]byte, error) {
+	return p.RunNativeAction(evm, contract, func(ctx sdk.Context) ([]byte, error) {
+		method, args, err := cmn.SetupABI(ImmuneABI, contract, readonly, func(*abi.Method) bool { return false })
+		if err != nil {
+			return nil, err
+		}
+		if v := contract.Value(); v != nil && !v.IsZero() {
+			return nil, errors.New("the immune precompile takes no value")
+		}
+		app := p.app
+		ctx.GasMeter().ConsumeGas(2000, "zetaphy immune read")
+		params := app.immuneParams(ctx)
+		switch method.Name {
+		case "scoreOf":
+			s, h, share, ok := app.immuneScore(ctx, args[0].(common.Address))
+			return method.Outputs.Pack(s, uint64(h), share, ok) // #nosec G115 -- block heights
+		case "isContractEnforced", "isContractHeld":
+			th := params.EnforceBps
+			if method.Name == "isContractHeld" {
+				th = params.HoldBps
+			}
+			s, _, _, ok := app.immuneScore(ctx, args[0].(common.Address))
+			on := ok && th > 0 && s >= th
+			reason := uint8(0)
+			if on {
+				reason = ThreatReasonImmune
+			}
+			return method.Outputs.Pack(on, reason)
+		case "codeScore":
+			a := args[0].(common.Address)
+			code := app.EVMKeeper.GetCode(ctx, app.EVMKeeper.GetCodeHash(ctx, a))
+			ctx.GasMeter().ConsumeGas(uint64(len(code))/4, "zetaphy immune code walk") // #nosec G115 -- code size
+			return method.Outputs.Pack(ImmuneCodeFeatures(code).Score())
+		case "immuneParams":
+			return method.Outputs.Pack(params.Enabled, params.EnforceBps, params.HoldBps, params.ProtectBps)
+		case "breaker":
+			b := args[0].(common.Address)
+			st := app.breakerStatsOf(ctx, b)
+			trip := app.secRaw(ctx).Get(append([]byte{breakerTripPfx}, b.Bytes()...))
+			return method.Outputs.Pack(app.breakerConfig(ctx, b) != nil, trip != nil, readU64(trip), uint64(st.height), // #nosec G115 -- block heights
+				new(big.Int).Set(st.volume), new(big.Int).Set(st.baseline))
+		}
+		return nil, fmt.Errorf("unknown method %s", method.Name)
+	})
+}
diff --git a/evmd/zetaphy_modelat.go b/evmd/zetaphy_modelat.go
new file mode 100644
index 0000000..6789501
--- /dev/null
+++ b/evmd/zetaphy_modelat.go
@@ -0,0 +1,319 @@
+package evmd
+
+// ZETAPHY v5: the Neuro model version bound to chain height (item 35,
+// docs/future/federated.md "Node side").
+//
+// The registry is the ModelEpochs contract (zetaphy-network/contracts/
+// ModelEpochs.sol); the chain only stores where it is:
+//
+//	model-epochs   MsgSetFuture kind: {"address":"0x…"} (a contract), or
+//	               {"address":""} to remove it (no model in consensus)
+//
+// ModelVersionAt(ctx, h) reads ModelEpochs.versionAt(h) with a read-only
+// EVM call (no commit, 200,000 gas, from the "neuro" module address). Any
+// error, an unset registry or no code at it is found = false. Called while
+// processing block h, ctx holds the committed state after h-1, whose answer
+// for h is final (no tx in h or later can add, cancel or change a version
+// with activation <= h). Consensus code may only compare the hash it
+// returns; it never fetches the manifest.
+//
+// Queries, on the state after h-1 (an archive node for old heights):
+//
+//	zetaphyd q neuro model-at <h>      (the same lookup, through EthCall)
+//	zetaphy_modelAt(h)                 JSON-RPC, on the public EVM endpoint
+//	modelEpochs() on 0x…0902           the registry address, for contracts
+//
+// Browsers and runners get the same answer from eth_call versionAt(h) with
+// blockTag h-1 (zetaphy-network/src/modelepochs.js).
+
+import (
+	"bytes"
+	"context"
+	"encoding/json"
+	"errors"
+	"fmt"
+	"math/big"
+	"strconv"
+
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	"github.com/ethereum/go-ethereum/core"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/spf13/cobra"
+	"google.golang.org/grpc/metadata"
+
+	errorsmod "cosmossdk.io/errors"
+
+	"github.com/cosmos/evm/x/vm/statedb"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/client/flags"
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	grpctypes "github.com/cosmos/cosmos-sdk/types/grpc"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+)
+
+const (
+	modelAtGas    = 200_000
+	modelAtMaxRet = 4096 // versionAt's answer: 5 words + a uri of at most 256 bytes
+	modelAtMaxURI = 256
+)
+
+// ModelEpochsCaller is the "from" of the lookup: the neuro module address.
+var ModelEpochsCaller = common.BytesToAddress(authtypes.NewModuleAddress("neuro"))
+
+var modelEpochsABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(`[{"type":"function","name":"versionAt","stateMutability":"view",
+	 "inputs":[{"name":"height","type":"uint256"}],
+	 "outputs":[{"name":"found","type":"bool"},{"name":"index","type":"uint256"},{"name":"hash","type":"bytes32"},{"name":"activation","type":"uint64"},{"name":"uri","type":"string"}]}]`)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+// ModelVersion is the Neuro model version in force at a height.
+type ModelVersion struct {
+	Found      bool
+	Index      uint64
+	Hash       [32]byte
+	Activation int64
+	URI        string
+}
+
+// modelEpochsAddr: the registry governance set (ok false: none).
+func (app *EVMD) modelEpochsAddr(ctx sdk.Context) (common.Address, bool) {
+	v := app.secRaw(ctx).Get(modelEpochsKey)
+	if len(v) != 20 {
+		return common.Address{}, false
+	}
+	return common.BytesToAddress(v), true
+}
+
+// setModelEpochs: governance's "model-epochs" kind of MsgSetFuture.
+func (app *EVMD) setModelEpochs(ctx sdk.Context, data []byte) error {
+	var c struct {
+		Address string `json:"address"`
+	}
+	if err := futJSON(data, &c); err != nil {
+		return err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if c.Address == "" || (common.IsHexAddress(c.Address) && common.HexToAddress(c.Address) == (common.Address{})) {
+		st.Delete(modelEpochsKey)
+		return nil
+	}
+	if !common.IsHexAddress(c.Address) {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "model-epochs: address: a 0x address, or \"\" to remove it")
+	}
+	a := common.HexToAddress(c.Address)
+	if len(app.EVMKeeper.GetCode(ctx, app.EVMKeeper.GetCodeHash(ctx, a))) == 0 {
+		return errorsmod.Wrapf(errortypes.ErrInvalidRequest, "model-epochs: no contract at %s", a.Hex())
+	}
+	st.Set(modelEpochsKey, a.Bytes())
+	return nil
+}
+
+// modelAtDecode checks and decodes versionAt(h)'s answer. A registry that
+// answers anything else (too long, a zero hash, a version from after h, an
+// over-long uri) counts as no version.
+func modelAtDecode(ret []byte, h int64) (ModelVersion, error) {
+	if len(ret) > modelAtMaxRet {
+		return ModelVersion{}, errors.New("versionAt: answer too long")
+	}
+	out, err := modelEpochsABI.Unpack("versionAt", ret)
+	if err != nil || len(out) != 5 {
+		return ModelVersion{}, fmt.Errorf("versionAt: bad answer: %v", err)
+	}
+	found, _ := out[0].(bool)
+	idx, _ := out[1].(*big.Int)
+	hash, _ := out[2].([32]byte)
+	act, _ := out[3].(uint64)
+	uri, _ := out[4].(string)
+	if !found {
+		return ModelVersion{}, nil
+	}
+	if idx == nil || !idx.IsUint64() || hash == ([32]byte{}) || act > uint64(h) || len(uri) == 0 || len(uri) > modelAtMaxURI { // #nosec G115 -- h > 0
+		return ModelVersion{}, errors.New("versionAt: the registry's answer breaks its rules")
+	}
+	return ModelVersion{Found: true, Index: idx.Uint64(), Hash: hash, Activation: int64(act), URI: uri}, nil // #nosec G115 -- act <= h
+}
+
+func modelAtCalldata(h int64) ([]byte, error) {
+	if h < 1 {
+		return nil, errors.New("height must be at least 1")
+	}
+	return modelEpochsABI.Pack("versionAt", big.NewInt(h))
+}
+
+// ModelVersionAt returns the Neuro model version in force at height h, from
+// the registry on ctx's state (see the top of this file). err says why
+// found is false; consensus code treats any error as "no model".
+func (app *EVMD) ModelVersionAt(ctx sdk.Context, h int64) (ModelVersion, error) {
+	reg, ok := app.modelEpochsAddr(ctx)
+	if !ok {
+		return ModelVersion{}, errors.New("no ModelEpochs registry is set (governance: security-proposal model-epochs)")
+	}
+	data, err := modelAtCalldata(h)
+	if err != nil {
+		return ModelVersion{}, err
+	}
+	c, _ := ctx.CacheContext() // never written back
+	c = c.WithGasMeter(storetypes.NewInfiniteGasMeter()).WithKVGasConfig(storetypes.GasConfig{}).
+		WithTransientKVGasConfig(storetypes.GasConfig{}).WithEventManager(sdk.NewEventManager())
+	if len(app.EVMKeeper.GetCode(c, app.EVMKeeper.GetCodeHash(c, reg))) == 0 {
+		return ModelVersion{}, fmt.Errorf("no contract at the registry %s", reg.Hex())
+	}
+	var res *evmtypes.MsgEthereumTxResponse
+	func() {
+		defer func() {
+			if r := recover(); r != nil {
+				err = fmt.Errorf("versionAt: %v", r)
+			}
+		}()
+		sdb := statedb.New(c, app.EVMKeeper, statedb.NewEmptyTxConfig())
+		res, err = app.EVMKeeper.ApplyMessage(c, sdb, core.Message{
+			From: ModelEpochsCaller, To: &reg, Value: new(big.Int), GasLimit: modelAtGas, Data: data,
+			GasPrice: new(big.Int), GasFeeCap: new(big.Int), GasTipCap: new(big.Int), AccessList: ethtypes.AccessList{},
+			SkipNonceChecks: true,
+		}, nil, false, false, true)
+	}()
+	if err != nil {
+		return ModelVersion{}, err
+	}
+	if res == nil || res.Failed() {
+		return ModelVersion{}, errors.New("versionAt reverted or ran out of gas")
+	}
+	return modelAtDecode(res.Ret, h)
+}
+
+// ---- queries (outside consensus)
+
+// ModelAtResult is the answer of zetaphy_modelAt and `q neuro model-at`.
+type ModelAtResult struct {
+	Height      int64   `json:"height"`
+	StateHeight int64   `json:"stateHeight"` // the state read: height - 1
+	Registry    *string `json:"registry"`
+	Found       bool    `json:"found"`
+	Index       *uint64 `json:"index,omitempty"`
+	Hash        *string `json:"hash,omitempty"`
+	Activation  *int64  `json:"activation,omitempty"`
+	URI         *string `json:"uri,omitempty"`
+	Error       string  `json:"error,omitempty"` // why found is false
+}
+
+func (v ModelVersion) result(h int64, reg *common.Address, err error) *ModelAtResult {
+	r := &ModelAtResult{Height: h, StateHeight: h - 1, Found: v.Found}
+	if reg != nil {
+		s := reg.Hex()
+		r.Registry = &s
+	}
+	if err != nil {
+		r.Error = err.Error()
+	}
+	if v.Found {
+		hs := hexutil.Encode(v.Hash[:])
+		r.Index, r.Hash, r.Activation, r.URI = &v.Index, &hs, &v.Activation, &v.URI
+	}
+	return r
+}
+
+// modelEthCaller is the part of the EVM query service the lookup needs
+// (evmtypes.QueryClient; the keeper itself in tests).
+type modelEthCaller interface {
+	EthCall(ctx context.Context, req *evmtypes.EthCallRequest) (*evmtypes.MsgEthereumTxResponse, error)
+}
+
+// modelAtVia: the lookup for h through an EthCall service whose state is
+// the one after h-1, given the registry stored there.
+func modelAtVia(ctx context.Context, q modelEthCaller, reg []byte, h int64) *ModelAtResult {
+	if len(reg) != 20 {
+		return ModelVersion{}.result(h, nil, errors.New("no ModelEpochs registry is set"))
+	}
+	a := common.BytesToAddress(reg)
+	data, err := modelAtCalldata(h)
+	if err != nil {
+		return ModelVersion{}.result(h, &a, err)
+	}
+	gas := hexutil.Uint64(modelAtGas)
+	from, in := ModelEpochsCaller, hexutil.Bytes(data)
+	args, _ := json.Marshal(evmtypes.TransactionArgs{From: &from, To: &a, Gas: &gas, Input: &in})
+	res, err := q.EthCall(ctx, &evmtypes.EthCallRequest{Args: args, GasCap: modelAtGas})
+	if err == nil && (res == nil || res.Failed()) {
+		err = errors.New("versionAt reverted or ran out of gas (or no contract there)")
+	}
+	if err != nil {
+		return ModelVersion{}.result(h, &a, err)
+	}
+	if len(res.Ret) == 0 {
+		return ModelVersion{}.result(h, &a, fmt.Errorf("no contract at the registry %s", a.Hex()))
+	}
+	v, err := modelAtDecode(res.Ret, h)
+	return v.result(h, &a, err)
+}
+
+type ethCallClient struct{ q evmtypes.QueryClient }
+
+func (c ethCallClient) EthCall(ctx context.Context, req *evmtypes.EthCallRequest) (*evmtypes.MsgEthereumTxResponse, error) {
+	return c.q.EthCall(ctx, req)
+}
+
+// ModelAtQuery answers ModelAt{height} from a node, on the state after
+// height-1.
+func ModelAtQuery(ctx context.Context, cctx client.Context, h int64) (*ModelAtResult, error) {
+	if h < 2 {
+		return nil, errors.New("height must be at least 2 (the state after height-1 is read)")
+	}
+	cctx = cctx.WithHeight(h - 1)
+	ctx = metadata.AppendToOutgoingContext(ctx, grpctypes.GRPCBlockHeightHeader, strconv.FormatInt(h-1, 10))
+	reg, _, err := cctx.QueryStore(modelEpochsKey, pqStoreKey)
+	if err != nil {
+		return nil, fmt.Errorf("reading the registry at height %d: %w", h-1, err)
+	}
+	return modelAtVia(ctx, ethCallClient{evmtypes.NewQueryClient(cctx)}, reg, h), nil
+}
+
+// ModelAt (zetaphy_modelAt): the Neuro model version in force at height.
+func (a *ZetaphyAPI) ModelAt(ctx context.Context, height hexutil.Uint64) (*ModelAtResult, error) {
+	if uint64(height) > 1<<62 {
+		return nil, errors.New("height out of range")
+	}
+	return ModelAtQuery(ctx, a.clientCtx, int64(height)) // #nosec G115 -- checked above
+}
+
+// NeuroQueryCmd: zetaphyd q neuro model-at <height>.
+func NeuroQueryCmd() *cobra.Command {
+	cmd := &cobra.Command{Use: "neuro", Short: "Neuro on the chain (ZETAPHY v5)", RunE: client.ValidateCmd}
+	at := &cobra.Command{
+		Use:   "model-at <height>",
+		Short: "The Neuro model version in force at a height (ModelEpochs.versionAt on the state after height-1)",
+		Args:  cobra.ExactArgs(1),
+		RunE: func(cmd *cobra.Command, args []string) error {
+			h, err := strconv.ParseInt(args[0], 10, 64)
+			if err != nil {
+				return fmt.Errorf("height: %w", err)
+			}
+			cctx, err := client.GetClientQueryContext(cmd)
+			if err != nil {
+				return err
+			}
+			r, err := ModelAtQuery(cmd.Context(), cctx, h)
+			if err != nil {
+				return err
+			}
+			bz, err := json.MarshalIndent(r, "", "  ")
+			if err != nil {
+				return err
+			}
+			_, err = fmt.Fprintln(cmd.OutOrStdout(), string(bz))
+			return err
+		},
+	}
+	flags.AddQueryFlagsToCmd(at)
+	cmd.AddCommand(at)
+	return cmd
+}
diff --git a/evmd/zetaphy_pqcall.go b/evmd/zetaphy_pqcall.go
new file mode 100644
index 0000000..42d22c2
--- /dev/null
+++ b/evmd/zetaphy_pqcall.go
@@ -0,0 +1,496 @@
+package evmd
+
+// ZETAPHY post-quantum messages (zetaphy/pq/v1/tx.proto, built in code below):
+//   MsgEVMCall      any account, including an ML-DSA-44 one, calls or creates an
+//                   EVM contract as itself, or as an account it controls
+//                   through a quantum lock (as_owner); gas is paid in the
+//                   Cosmos fee
+//   MsgQuantumLock  an ECDSA account hands control to an ML-DSA-44 account;
+//                   from then on its own key is refused (zetaphy_pqguard.go)
+//   MsgPQVoteKey    a validator registers the ML-DSA-44 key that signs its
+//                   block votes (zetaphy_pqguard.go)
+
+import (
+	"bytes"
+	"compress/gzip"
+	"context"
+	"fmt"
+	"math/big"
+	"reflect"
+	"strings"
+
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/crypto"
+	"google.golang.org/grpc"
+	protov2 "google.golang.org/protobuf/proto"
+	"google.golang.org/protobuf/reflect/protodesc"
+	"google.golang.org/protobuf/reflect/protoreflect"
+	"google.golang.org/protobuf/reflect/protoregistry"
+	"google.golang.org/protobuf/types/descriptorpb"
+	"google.golang.org/protobuf/types/dynamicpb"
+
+	msgv1 "cosmossdk.io/api/cosmos/msg/v1"
+	errorsmod "cosmossdk.io/errors"
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/types/msgservice"
+
+	"github.com/cosmos/evm/x/vm/statedb"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+const (
+	pqCallFile    = "zetaphy/pq/v1/tx.proto"
+	pqCallService = "zetaphy.pq.v1.Msg"
+	// MaxEVMCallGas caps one call, like eth_call's gas cap on this chain.
+	MaxEVMCallGas = 10_000_000
+)
+
+type MsgEVMCall struct {
+	Sender   string
+	To       string
+	Value    string
+	Data     []byte
+	GasLimit uint64
+	AsOwner  string
+}
+
+type MsgEVMCallResponse struct {
+	Ret     []byte
+	GasUsed uint64
+	Created string
+}
+
+type MsgQuantumLock struct{ Signer, Owner, Controller string }
+
+type MsgPQVoteKey struct {
+	Operator       string
+	PubKey         []byte
+	Proof          []byte
+	OldKeySig      []byte
+	ValidatorOwner string
+}
+
+type MsgPQResponse struct{}
+
+// MsgSetPQEvidence is the evidence switch (governance only).
+type MsgSetPQEvidence struct {
+	Authority string
+	Enabled   uint64
+}
+
+// MsgPQCertificate is put by the proposer as the first tx of a block: the
+// ML-DSA-44 vote signatures (20-byte validator address + signature, repeated)
+// for the previous block (zetaphy_pqcert.go). It is never signed or fee-paying.
+type MsgPQCertificate struct {
+	Signer       string
+	Height       uint64
+	Attestations []byte
+}
+
+// ZETAPHY security core (zetaphy_qday.go, zetaphy_threatgate.go, zetaphy_ibchold.go).
+
+// MsgSetQDay schedules Q-day (governance only): from height on, ECDSA-signed
+// txs are refused. 0 unschedules it. reveal_delay: blocks a commit–reveal
+// migration waits (0: the default).
+type MsgSetQDay struct {
+	Authority   string
+	Height      uint64
+	RevealDelay uint64
+}
+
+// MsgQDayCommit records sha256 of a migration (qdayCommitment) before its reveal.
+type MsgQDayCommit struct {
+	Signer     string
+	Commitment []byte
+}
+
+// MsgQDayReveal migrates an account whose ECDSA key was never shown on chain
+// to an ML-DSA-44 controller, after Q-day: the signature (EIP-191, by the
+// owner's key, over qdayRevealText) and salt open a commitment at least
+// reveal_delay blocks old.
+type MsgQDayReveal struct {
+	Signer     string
+	Owner      string
+	Controller string
+	Salt       []byte
+	Signature  []byte
+}
+
+// MsgSetThreatGate sets the ThreatRegistry the chain asks (governance only).
+type MsgSetThreatGate struct {
+	Authority string
+	Registry  string
+	Enabled   uint64
+}
+
+// MsgSetIBCHold sets the large-transfer hold delay and guardian (governance only).
+type MsgSetIBCHold struct {
+	Authority    string
+	DelaySeconds uint64
+	Guardian     string
+}
+
+// MsgSetIBCHoldRule sets when an inbound transfer of a denom is held
+// (governance only); "*" is the rule for denoms without one.
+type MsgSetIBCHoldRule struct {
+	Authority string
+	Denom     string
+	MinAmount string
+	SupplyBps uint64
+}
+
+// MsgIBCHoldCancel returns a held transfer to its sender (guardian or governance).
+type MsgIBCHoldCancel struct {
+	Signer string
+	Id     uint64
+}
+
+func (m *MsgEVMCall) Reset()                    { *m = MsgEVMCall{} }
+func (m *MsgEVMCall) String() string            { return fmt.Sprintf("%+v", *m) }
+func (*MsgEVMCall) ProtoMessage()               {}
+func (*MsgEVMCall) Descriptor() ([]byte, []int) { return pqCallDescriptor, []int{0} }
+func (m *MsgEVMCall) Marshal() ([]byte, error)  { return pqMarshal(0, m) }
+func (m *MsgEVMCall) Unmarshal(b []byte) error  { return pqUnmarshal(0, b, m) }
+func (m *MsgEVMCallResponse) Reset()            { *m = MsgEVMCallResponse{} }
+func (m *MsgEVMCallResponse) String() string    { return fmt.Sprintf("%+v", *m) }
+func (*MsgEVMCallResponse) ProtoMessage()       {}
+func (*MsgEVMCallResponse) Descriptor() ([]byte, []int) {
+	return pqCallDescriptor, []int{1}
+}
+func (m *MsgEVMCallResponse) Marshal() ([]byte, error) { return pqMarshal(1, m) }
+func (m *MsgEVMCallResponse) Unmarshal(b []byte) error { return pqUnmarshal(1, b, m) }
+func (m *MsgQuantumLock) Reset()                       { *m = MsgQuantumLock{} }
+func (m *MsgQuantumLock) String() string               { return fmt.Sprintf("%+v", *m) }
+func (*MsgQuantumLock) ProtoMessage()                  {}
+func (*MsgQuantumLock) Descriptor() ([]byte, []int)    { return pqCallDescriptor, []int{2} }
+func (m *MsgQuantumLock) Marshal() ([]byte, error)     { return pqMarshal(2, m) }
+func (m *MsgQuantumLock) Unmarshal(b []byte) error     { return pqUnmarshal(2, b, m) }
+func (m *MsgPQVoteKey) Reset()                         { *m = MsgPQVoteKey{} }
+func (m *MsgPQVoteKey) String() string                 { return "MsgPQVoteKey{" + m.Operator + "}" }
+func (*MsgPQVoteKey) ProtoMessage()                    {}
+func (*MsgPQVoteKey) Descriptor() ([]byte, []int)      { return pqCallDescriptor, []int{3} }
+func (m *MsgPQVoteKey) Marshal() ([]byte, error)       { return pqMarshal(3, m) }
+func (m *MsgPQVoteKey) Unmarshal(b []byte) error       { return pqUnmarshal(3, b, m) }
+func (m *MsgPQResponse) Reset()                        {}
+func (m *MsgPQResponse) String() string                { return "{}" }
+func (*MsgPQResponse) ProtoMessage()                   {}
+func (*MsgPQResponse) Descriptor() ([]byte, []int)     { return pqCallDescriptor, []int{4} }
+func (m *MsgPQResponse) Marshal() ([]byte, error)      { return nil, nil }
+func (m *MsgPQResponse) Unmarshal(b []byte) error      { return pqUnmarshal(4, b, m) }
+func (m *MsgEVMCall) Size() int                        { return pqSize(m) }
+func (m *MsgEVMCallResponse) Size() int                { return pqSize(m) }
+func (m *MsgQuantumLock) Size() int                    { return pqSize(m) }
+func (m *MsgPQVoteKey) Size() int                      { return pqSize(m) }
+func (m *MsgPQResponse) Size() int                     { return 0 }
+func (m *MsgPQCertificate) Reset()                     { *m = MsgPQCertificate{} }
+func (m *MsgPQCertificate) String() string             { return fmt.Sprintf("MsgPQCertificate{%d}", m.Height) }
+func (*MsgPQCertificate) ProtoMessage()                {}
+func (*MsgPQCertificate) Descriptor() ([]byte, []int)  { return pqCallDescriptor, []int{5} }
+func (m *MsgPQCertificate) Marshal() ([]byte, error)   { return pqMarshal(5, m) }
+func (m *MsgPQCertificate) Unmarshal(b []byte) error   { return pqUnmarshal(5, b, m) }
+func (m *MsgPQCertificate) Size() int                  { return pqSize(m) }
+func (m *MsgSetPQEvidence) Reset()                     { *m = MsgSetPQEvidence{} }
+func (m *MsgSetPQEvidence) String() string             { return fmt.Sprintf("%+v", *m) }
+func (*MsgSetPQEvidence) ProtoMessage()                {}
+func (*MsgSetPQEvidence) Descriptor() ([]byte, []int)  { return pqCallDescriptor, []int{6} }
+func (m *MsgSetPQEvidence) Marshal() ([]byte, error)   { return pqMarshal(6, m) }
+func (m *MsgSetPQEvidence) Unmarshal(b []byte) error   { return pqUnmarshal(6, b, m) }
+func (m *MsgSetPQEvidence) Size() int                  { return pqSize(m) }
+
+func (m *MsgSetQDay) Reset()                           { *m = MsgSetQDay{} }
+func (m *MsgSetQDay) String() string                   { return fmt.Sprintf("%+v", *m) }
+func (*MsgSetQDay) ProtoMessage()                      {}
+func (*MsgSetQDay) Descriptor() ([]byte, []int)        { return pqCallDescriptor, []int{7} }
+func (m *MsgSetQDay) Marshal() ([]byte, error)         { return pqMarshal(7, m) }
+func (m *MsgSetQDay) Unmarshal(b []byte) error         { return pqUnmarshal(7, b, m) }
+func (m *MsgSetQDay) Size() int                        { return pqSize(m) }
+func (m *MsgQDayCommit) Reset()                        { *m = MsgQDayCommit{} }
+func (m *MsgQDayCommit) String() string                { return fmt.Sprintf("%+v", *m) }
+func (*MsgQDayCommit) ProtoMessage()                   {}
+func (*MsgQDayCommit) Descriptor() ([]byte, []int)     { return pqCallDescriptor, []int{8} }
+func (m *MsgQDayCommit) Marshal() ([]byte, error)      { return pqMarshal(8, m) }
+func (m *MsgQDayCommit) Unmarshal(b []byte) error      { return pqUnmarshal(8, b, m) }
+func (m *MsgQDayCommit) Size() int                     { return pqSize(m) }
+func (m *MsgQDayReveal) Reset()                        { *m = MsgQDayReveal{} }
+func (m *MsgQDayReveal) String() string                { return fmt.Sprintf("%+v", *m) }
+func (*MsgQDayReveal) ProtoMessage()                   {}
+func (*MsgQDayReveal) Descriptor() ([]byte, []int)     { return pqCallDescriptor, []int{9} }
+func (m *MsgQDayReveal) Marshal() ([]byte, error)      { return pqMarshal(9, m) }
+func (m *MsgQDayReveal) Unmarshal(b []byte) error      { return pqUnmarshal(9, b, m) }
+func (m *MsgQDayReveal) Size() int                     { return pqSize(m) }
+func (m *MsgSetThreatGate) Reset()                     { *m = MsgSetThreatGate{} }
+func (m *MsgSetThreatGate) String() string             { return fmt.Sprintf("%+v", *m) }
+func (*MsgSetThreatGate) ProtoMessage()                {}
+func (*MsgSetThreatGate) Descriptor() ([]byte, []int)  { return pqCallDescriptor, []int{10} }
+func (m *MsgSetThreatGate) Marshal() ([]byte, error)   { return pqMarshal(10, m) }
+func (m *MsgSetThreatGate) Unmarshal(b []byte) error   { return pqUnmarshal(10, b, m) }
+func (m *MsgSetThreatGate) Size() int                  { return pqSize(m) }
+func (m *MsgSetIBCHold) Reset()                        { *m = MsgSetIBCHold{} }
+func (m *MsgSetIBCHold) String() string                { return fmt.Sprintf("%+v", *m) }
+func (*MsgSetIBCHold) ProtoMessage()                   {}
+func (*MsgSetIBCHold) Descriptor() ([]byte, []int)     { return pqCallDescriptor, []int{11} }
+func (m *MsgSetIBCHold) Marshal() ([]byte, error)      { return pqMarshal(11, m) }
+func (m *MsgSetIBCHold) Unmarshal(b []byte) error      { return pqUnmarshal(11, b, m) }
+func (m *MsgSetIBCHold) Size() int                     { return pqSize(m) }
+func (m *MsgSetIBCHoldRule) Reset()                    { *m = MsgSetIBCHoldRule{} }
+func (m *MsgSetIBCHoldRule) String() string            { return fmt.Sprintf("%+v", *m) }
+func (*MsgSetIBCHoldRule) ProtoMessage()               {}
+func (*MsgSetIBCHoldRule) Descriptor() ([]byte, []int) { return pqCallDescriptor, []int{12} }
+func (m *MsgSetIBCHoldRule) Marshal() ([]byte, error)  { return pqMarshal(12, m) }
+func (m *MsgSetIBCHoldRule) Unmarshal(b []byte) error  { return pqUnmarshal(12, b, m) }
+func (m *MsgSetIBCHoldRule) Size() int                 { return pqSize(m) }
+func (m *MsgIBCHoldCancel) Reset()                     { *m = MsgIBCHoldCancel{} }
+func (m *MsgIBCHoldCancel) String() string             { return fmt.Sprintf("%+v", *m) }
+func (*MsgIBCHoldCancel) ProtoMessage()                {}
+func (*MsgIBCHoldCancel) Descriptor() ([]byte, []int)  { return pqCallDescriptor, []int{13} }
+func (m *MsgIBCHoldCancel) Marshal() ([]byte, error)   { return pqMarshal(13, m) }
+func (m *MsgIBCHoldCancel) Unmarshal(b []byte) error   { return pqUnmarshal(13, b, m) }
+func (m *MsgIBCHoldCancel) Size() int                  { return pqSize(m) }
+
+func pqSize(m interface{ Marshal() ([]byte, error) }) int { b, _ := m.Marshal(); return len(b) }
+
+// The wire format is done by Google's protobuf runtime on a dynamic message
+// built from the descriptor below; struct field n is proto field n+1.
+func pqMarshal(i int, m any) ([]byte, error) {
+	d := dynamicpb.NewMessage(pqCallFD.Messages().Get(i))
+	v := reflect.ValueOf(m).Elem()
+	for n := range v.NumField() {
+		d.Set(d.Descriptor().Fields().ByNumber(protoreflect.FieldNumber(n+1)), protoreflect.ValueOf(v.Field(n).Interface()))
+	}
+	return protov2.MarshalOptions{Deterministic: true}.Marshal(d)
+}
+
+func pqUnmarshal(i int, b []byte, m any) error {
+	d := dynamicpb.NewMessage(pqCallFD.Messages().Get(i))
+	if err := protov2.Unmarshal(b, d); err != nil {
+		return err
+	}
+	v := reflect.ValueOf(m).Elem()
+	for n := range v.NumField() {
+		v.Field(n).Set(reflect.ValueOf(d.Get(d.Descriptor().Fields().ByNumber(protoreflect.FieldNumber(n + 1))).Interface()))
+	}
+	return nil
+}
+
+var pqMsgDefs = []struct {
+	name, signer, fields string
+}{
+	{"MsgEVMCall", "sender", "sender:S to:S value:S data:B gas_limit:U as_owner:S"},
+	{"MsgEVMCallResponse", "", "ret:B gas_used:U created:S"},
+	{"MsgQuantumLock", "signer", "signer:S owner:S controller:S"},
+	{"MsgPQVoteKey", "operator", "operator:S pub_key:B proof:B old_key_sig:B validator_owner:S"},
+	{"MsgPQResponse", "", ""},
+	{"MsgPQCertificate", "signer", "signer:S height:U attestations:B"},
+	{"MsgSetPQEvidence", "authority", "authority:S enabled:U"},
+	{"MsgSetQDay", "authority", "authority:S height:U reveal_delay:U"},
+	{"MsgQDayCommit", "signer", "signer:S commitment:B"},
+	{"MsgQDayReveal", "signer", "signer:S owner:S controller:S salt:B signature:B"},
+	{"MsgSetThreatGate", "authority", "authority:S registry:S enabled:U"},
+	{"MsgSetIBCHold", "authority", "authority:S delay_seconds:U guardian:S"},
+	{"MsgSetIBCHoldRule", "authority", "authority:S denom:S min_amount:S supply_bps:U"},
+	{"MsgIBCHoldCancel", "signer", "signer:S id:U"},
+	{"MsgSetFuture", "authority", "authority:S kind:S data:B"},
+	{"MsgZXVotes", "signer", "signer:S height:U round:U entries:B"},
+}
+
+var pqMethods = [][3]string{{"EVMCall", "MsgEVMCall", "MsgEVMCallResponse"},
+	{"QuantumLock", "MsgQuantumLock", "MsgPQResponse"}, {"PQVoteKey", "MsgPQVoteKey", "MsgPQResponse"},
+	{"PQCertificate", "MsgPQCertificate", "MsgPQResponse"}, {"SetPQEvidence", "MsgSetPQEvidence", "MsgPQResponse"},
+	{"SetQDay", "MsgSetQDay", "MsgPQResponse"}, {"QDayCommit", "MsgQDayCommit", "MsgPQResponse"},
+	{"QDayReveal", "MsgQDayReveal", "MsgPQResponse"}, {"SetThreatGate", "MsgSetThreatGate", "MsgPQResponse"},
+	{"SetIBCHold", "MsgSetIBCHold", "MsgPQResponse"}, {"SetIBCHoldRule", "MsgSetIBCHoldRule", "MsgPQResponse"},
+	{"IBCHoldCancel", "MsgIBCHoldCancel", "MsgPQResponse"},
+	{"SetFuture", "MsgSetFuture", "MsgPQResponse"}, {"ZXVotes", "MsgZXVotes", "MsgPQResponse"}}
+
+var pqCallProto = func() *descriptorpb.FileDescriptorProto {
+	types := map[byte]descriptorpb.FieldDescriptorProto_Type{'S': descriptorpb.FieldDescriptorProto_TYPE_STRING,
+		'B': descriptorpb.FieldDescriptorProto_TYPE_BYTES, 'U': descriptorpb.FieldDescriptorProto_TYPE_UINT64}
+	fd := &descriptorpb.FileDescriptorProto{Name: protov2.String(pqCallFile), Package: protov2.String("zetaphy.pq.v1"),
+		Syntax: protov2.String("proto3"), Dependency: []string{"cosmos/msg/v1/msg.proto"}}
+	for _, d := range pqMsgDefs {
+		m := &descriptorpb.DescriptorProto{Name: protov2.String(d.name)}
+		if d.signer != "" {
+			m.Options = &descriptorpb.MessageOptions{}
+			protov2.SetExtension(m.Options, msgv1.E_Signer, []string{d.signer})
+		}
+		for n, f := range strings.Fields(d.fields) {
+			name, t := f[:len(f)-2], types[f[len(f)-1]]
+			m.Field = append(m.Field, &descriptorpb.FieldDescriptorProto{Name: protov2.String(name), JsonName: protov2.String(name),
+				Number: protov2.Int32(int32(n + 1)), Type: t.Enum(), Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum()})
+		}
+		fd.MessageType = append(fd.MessageType, m)
+	}
+	svc := &descriptorpb.ServiceDescriptorProto{Name: protov2.String("Msg"), Options: &descriptorpb.ServiceOptions{}}
+	protov2.SetExtension(svc.Options, msgv1.E_Service, true)
+	for _, m := range pqMethods {
+		svc.Method = append(svc.Method, &descriptorpb.MethodDescriptorProto{Name: protov2.String(m[0]),
+			InputType: protov2.String(".zetaphy.pq.v1." + m[1]), OutputType: protov2.String(".zetaphy.pq.v1." + m[2])})
+	}
+	fd.Service = []*descriptorpb.ServiceDescriptorProto{svc}
+	return fd
+}()
+
+var pqCallFD = func() protoreflect.FileDescriptor {
+	fd, err := protodesc.NewFile(pqCallProto, protoregistry.GlobalFiles)
+	if err != nil {
+		panic(err)
+	}
+	return fd
+}()
+
+// pqCallDescriptor is the gzipped form gogoproto expects.
+var pqCallDescriptor = func() []byte {
+	raw, err := protov2.MarshalOptions{Deterministic: true}.Marshal(pqCallProto)
+	if err != nil {
+		panic(err)
+	}
+	var buf bytes.Buffer
+	w := gzip.NewWriter(&buf)
+	_, _ = w.Write(raw)
+	_ = w.Close()
+	return buf.Bytes()
+}()
+
+func init() {
+	for _, m := range []gogoproto.Message{&MsgEVMCall{}, &MsgEVMCallResponse{}, &MsgQuantumLock{}, &MsgPQVoteKey{}, &MsgPQResponse{}, &MsgPQCertificate{}, &MsgSetPQEvidence{},
+		&MsgSetQDay{}, &MsgQDayCommit{}, &MsgQDayReveal{}, &MsgSetThreatGate{}, &MsgSetIBCHold{}, &MsgSetIBCHoldRule{}, &MsgIBCHoldCancel{},
+		&MsgSetFuture{}, &MsgZXVotes{}} {
+		gogoproto.RegisterType(m, "zetaphy.pq.v1."+reflect.TypeOf(m).Elem().Name())
+	}
+	gogoproto.RegisterFile(pqCallFile, pqCallDescriptor)
+}
+
+func pqMethod[T any](name string, f func(*EVMD, sdk.Context, *T) (gogoproto.Message, error)) grpc.MethodDesc {
+	return grpc.MethodDesc{MethodName: name, Handler: func(srv any, ctx context.Context, dec func(any) error, ic grpc.UnaryServerInterceptor) (any, error) {
+		in := new(T)
+		if err := dec(in); err != nil {
+			return nil, err
+		}
+		h := func(ctx context.Context, req any) (any, error) {
+			return f(srv.(*EVMD), sdk.UnwrapSDKContext(ctx), req.(*T))
+		}
+		if ic == nil {
+			return h(ctx, in)
+		}
+		return ic(ctx, in, &grpc.UnaryServerInfo{Server: srv, FullMethod: "/" + pqCallService + "/" + name}, h)
+	}}
+}
+
+var pqCallServiceDesc = grpc.ServiceDesc{
+	ServiceName: pqCallService,
+	HandlerType: (*any)(nil),
+	Methods: []grpc.MethodDesc{pqMethod("EVMCall", (*EVMD).evmCall), pqMethod("QuantumLock", (*EVMD).quantumLock),
+		pqMethod("PQVoteKey", (*EVMD).pqVoteKey), pqMethod("PQCertificate", (*EVMD).pqCertificateMsg),
+		pqMethod("SetPQEvidence", (*EVMD).pqSetEvidence),
+		pqMethod("SetQDay", (*EVMD).setQDay), pqMethod("QDayCommit", (*EVMD).qdayCommit), pqMethod("QDayReveal", (*EVMD).qdayReveal),
+		pqMethod("SetThreatGate", (*EVMD).setThreatGate), pqMethod("SetIBCHold", (*EVMD).setIBCHold),
+		pqMethod("SetIBCHoldRule", (*EVMD).setIBCHoldRule), pqMethod("IBCHoldCancel", (*EVMD).ibcHoldCancelMsg),
+		pqMethod("SetFuture", (*EVMD).setFuture), pqMethod("ZXVotes", (*EVMD).zxVotesMsg)},
+	Metadata: pqCallFile,
+}
+
+// pqAddr reads a zetaphy1... or 0x... address.
+func pqAddr(s string) (sdk.AccAddress, error) {
+	if common.IsHexAddress(s) {
+		return common.HexToAddress(s).Bytes(), nil
+	}
+	a, err := sdk.AccAddressFromBech32(s)
+	if err != nil || len(a) != 20 {
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidAddress, "%q", s)
+	}
+	return a, nil
+}
+
+// evmCall runs the call (or, with no "to", creates a contract) with msg.sender
+// = the signer, or the account it controls (as_owner), and charges the gas
+// used to the Cosmos gas meter. A revert fails the whole tx.
+func (app *EVMD) evmCall(ctx sdk.Context, m *MsgEVMCall) (gogoproto.Message, error) {
+	from, err := pqAddr(m.Sender)
+	if err != nil {
+		return nil, err
+	}
+	if m.AsOwner != "" {
+		owner, err := pqAddr(m.AsOwner)
+		if err != nil {
+			return nil, err
+		}
+		if !bytes.Equal(app.pqController(ctx, owner), from) {
+			return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "as_owner: the signer does not control this account")
+		}
+		from = owner
+	}
+	var to *common.Address
+	if m.To != "" {
+		if !common.IsHexAddress(m.To) {
+			return nil, errorsmod.Wrap(errortypes.ErrInvalidAddress, "to must be a 0x address, or empty to create a contract")
+		}
+		t := common.HexToAddress(m.To)
+		to = &t
+	}
+	// ZETAPHY threat gate (zetaphy_threatgate.go); governance's own calls are not checked.
+	if err := threatRefused(ctx); err != nil {
+		return nil, err
+	}
+	if to != nil && !isGovAddr(m.Sender) {
+		if err := app.threatCheck(ctx, common.BytesToAddress(from), *to); err != nil {
+			return nil, err
+		}
+	}
+	value := new(big.Int)
+	if m.Value != "" {
+		if _, ok := value.SetString(m.Value, 10); !ok || value.Sign() < 0 || value.BitLen() > 255 {
+			return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "value must be a whole number of azetaphy")
+		}
+	}
+	gas := min(m.GasLimit, MaxEVMCallGas, ctx.GasMeter().GasRemaining())
+	if gas < 21000 {
+		return nil, errorsmod.Wrap(errortypes.ErrOutOfGas, "gas_limit below 21000 or tx gas too low")
+	}
+	nonce, err := app.AccountKeeper.GetSequence(ctx, from)
+	if err != nil {
+		return nil, err
+	}
+	// A creation uses the current sequence and consumes it (the EVM bumps the
+	// nonce), so each creation, in any tx, gets a fresh nonce.
+	sender := common.BytesToAddress(from)
+	// As in an EVM tx: storage is priced by EVM gas, and the EVM's gas is
+	// charged to the tx's meter once, below.
+	evmCtx := ctx.WithGasMeter(storetypes.NewInfiniteGasMeter()).
+		WithKVGasConfig(storetypes.GasConfig{}).WithTransientKVGasConfig(storetypes.GasConfig{})
+	stateDB := statedb.New(evmCtx, app.EVMKeeper, statedb.NewEmptyTxConfig())
+	res, err := app.EVMKeeper.ApplyMessage(evmCtx, stateDB, core.Message{
+		From: sender, To: to, Nonce: nonce, Value: value, GasLimit: gas, Data: m.Data,
+		GasPrice: new(big.Int), GasFeeCap: new(big.Int), GasTipCap: new(big.Int), AccessList: ethtypes.AccessList{},
+	}, nil, true, false, false) // not internal: normal refund cap and minimum gas, like an EVM tx
+	if err != nil {
+		return nil, err
+	}
+	ctx.GasMeter().ConsumeGas(res.GasUsed, "zetaphy evm call")
+	if res.Failed() {
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "evm call reverted: %s", res.VmError)
+	}
+	out := &MsgEVMCallResponse{Ret: res.Ret, GasUsed: res.GasUsed}
+	if to == nil {
+		out.Created = crypto.CreateAddress(sender, nonce).Hex()
+		app.immuneNoteDeploy(ctx, common.HexToAddress(out.Created)) // ZETAPHY v5 (zetaphy_immune.go)
+	}
+	app.breakerNoteLogs(ctx, evmtypes.LogsToEthereum(res.Logs)) // ZETAPHY v5 (zetaphy_breaker.go)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_evm_call", sdk.NewAttribute("from", sender.Hex()),
+		sdk.NewAttribute("to", m.To), sdk.NewAttribute("created", out.Created), sdk.NewAttribute("value", value.String())))
+	return out, nil
+}
+
+// registerEVMCall wires the messages into the app (codec and message router).
+func (app *EVMD) registerEVMCall() {
+	app.interfaceRegistry.RegisterImplementations((*sdk.Msg)(nil), &MsgEVMCall{}, &MsgQuantumLock{}, &MsgPQVoteKey{}, &MsgPQCertificate{}, &MsgSetPQEvidence{},
+		&MsgSetQDay{}, &MsgQDayCommit{}, &MsgQDayReveal{}, &MsgSetThreatGate{}, &MsgSetIBCHold{}, &MsgSetIBCHoldRule{}, &MsgIBCHoldCancel{},
+		&MsgSetFuture{}, &MsgZXVotes{})
+	msgservice.RegisterMsgServiceDesc(app.interfaceRegistry, &pqCallServiceDesc)
+	app.MsgServiceRouter().RegisterService(&pqCallServiceDesc, app)
+}
diff --git a/evmd/zetaphy_pqcert.go b/evmd/zetaphy_pqcert.go
new file mode 100644
index 0000000..34df4b6
--- /dev/null
+++ b/evmd/zetaphy_pqcert.go
@@ -0,0 +1,400 @@
+package evmd
+
+// ZETAPHY post-quantum vote certificates.
+//
+// Validators sign each precommit with ML-DSA-44 (vote extensions,
+// zetaphy_pqguard.go). The proposer of block H+1 puts the signatures it got
+// for block H into H+1, as its first tx (MsgPQCertificate). Every node checks
+// them, in ProcessProposal and again in PreBlocker, which also runs when a
+// node catches up from peers (blocksync) without checking votes itself:
+//
+//	the validators of H with a valid ML-DSA-44 signature over (chain id, H,
+//	hash of H) must hold more than 2/3 of the power of H minus the power of
+//	validators without a registered key.
+//
+// While no key is registered the rule asks for nothing. Once validators with
+// more than 2/3 of the power have keys, a chain forged with ed25519 alone
+// (a quantum attack on CometBFT's signatures) is refused, and the
+// certificates let wallets and light clients check a block post-quantum.
+//
+// Evidence switch: CometBFT proves double-signing with ed25519 only, which a
+// quantum computer could forge to slash an honest validator. A governance
+// proposal with MsgSetPQEvidence (zetaphyd tx pq-evidence-proposal on|off)
+// turns ignoring that evidence on or off for validators with an ML-DSA-44 key.
+
+import (
+	"bytes"
+	"encoding/binary"
+	"errors"
+	"fmt"
+	"path/filepath"
+	"sort"
+
+	circl "github.com/cloudflare/circl/sign/mldsa/mldsa44"
+	abci "github.com/cometbft/cometbft/abci/types"
+	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/spf13/cobra"
+
+	"cosmossdk.io/core/comet"
+	errorsmod "cosmossdk.io/errors"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/client/flags"
+	"github.com/cosmos/cosmos-sdk/client/tx"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
+	govv1 "github.com/cosmos/cosmos-sdk/x/gov/types/v1"
+
+	"github.com/cosmos/evm/crypto/mldsa44"
+)
+
+var (
+	pqEvidenceKey  = []byte{5}
+	pqLastBlockKey = []byte{6} // height (8 bytes) || hash of the last finalized block
+)
+
+const pqAttestationSize = 20 + circl.SignatureSize
+
+func pqHasCert(tx sdk.Tx) bool {
+	for _, m := range tx.GetMsgs() {
+		if _, ok := m.(*MsgPQCertificate); ok {
+			return true
+		}
+	}
+	return false
+}
+
+// pqCertificateMsg does nothing: the certificate was checked before the block ran.
+func (app *EVMD) pqCertificateMsg(sdk.Context, *MsgPQCertificate) (gogoproto.Message, error) {
+	return &MsgPQResponse{}, nil
+}
+
+// pqCertOf returns the certificate if txs[0] is one.
+func (app *EVMD) pqCertOf(txs [][]byte) *MsgPQCertificate {
+	if len(txs) == 0 {
+		return nil
+	}
+	tx, err := app.TxDecode(txs[0])
+	if err != nil || len(tx.GetMsgs()) != 1 {
+		return nil
+	}
+	c, _ := tx.GetMsgs()[0].(*MsgPQCertificate)
+	return c
+}
+
+// pqCheckCert applies the rule above to the certificate for block height-1
+// in block height, proposed by proposer.
+func (app *EVMD) pqCheckCert(ctx sdk.Context, height int64, proposer []byte, votes []abci.VoteInfo, txs [][]byte) error {
+	_, err := app.pqVerifiedCert(ctx, height, proposer, votes, txs)
+	return err
+}
+
+// pqVerifiedCert is pqCheckCert that also returns the certificate when every
+// entry of it was verified (nil when there is none or nothing was checked).
+//
+// From the v2 activation height (zetaphy_upgrade.go) one more rule: if the
+// proposer of height was a validator of height-1 with a registered key, the
+// certificate must hold the proposer's own entry. That takes away the
+// proposer's choice to leave itself out or to send no certificate at all
+// (fallback prevrandao) while keyed power is under 1/3. It cannot halt the
+// chain: the entry is a signature over (chain id, height-1, hash of
+// height-1), which the proposer can make at proposal time even when its
+// precommit is not in the commit (pqBuildCert does), so it only needs its own
+// key. A proposer without the right key (its node exits in ExtendVote anyway)
+// loses its round and the next proposer goes on; every proposer failing
+// means every validator is keyed and without its key, which the 2/3 rule
+// already cannot pass. It does not stop the proposer from re-signing its own
+// entry: prevrandao stays biasable by the proposer (zetaphy_random.go).
+func (app *EVMD) pqVerifiedCert(ctx sdk.Context, height int64, proposer []byte, votes []abci.VoteInfo, txs [][]byte) (*MsgPQCertificate, error) {
+	last := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqLastBlockKey)
+	if len(last) != 8+32 || int64(binary.BigEndian.Uint64(last)) != height-1 { // #nosec G115 -- block heights
+		return nil, nil // nothing to certify yet (first block, or state restored without it)
+	}
+	prev, hash := height-1, last[8:]
+	if !pqExtensionsOn(ctx, prev) {
+		return nil, nil
+	}
+	var total, unregistered int64
+	keys := map[string][]byte{}
+	power := map[string]int64{}
+	for _, v := range votes {
+		a := string(v.Validator.Address)
+		total += v.Validator.Power
+		if k := app.pqVoteKeyAt(ctx, v.Validator.Address, prev); k != nil {
+			keys[a], power[a] = k, v.Validator.Power
+		} else {
+			unregistered += v.Validator.Power
+		}
+	}
+	// The certificate must be canonical: entries sorted by address, each a
+	// registered validator of the block with a valid signature. Anything else
+	// is refused, so a proposer cannot pad it or make nodes verify garbage.
+	var signed int64
+	var proposerSigned bool
+	c := app.pqCertOf(txs)
+	if c != nil {
+		if c.Height != uint64(prev) || len(c.Attestations)%pqAttestationSize != 0 || len(c.Attestations) > len(keys)*pqAttestationSize { // #nosec G115 -- block heights
+			return nil, fmt.Errorf("block %d: malformed vote certificate", prev)
+		}
+		msg := pqVoteMsg(ctx.ChainID(), prev, hash)
+		var before []byte
+		for i := 0; i < len(c.Attestations); i += pqAttestationSize {
+			a := c.Attestations[i : i+20]
+			k, ok := keys[string(a)]
+			if !ok || bytes.Compare(a, before) <= 0 || !(&mldsa44.PubKey{Key: k}).VerifySignature(msg, c.Attestations[i+20:i+pqAttestationSize]) {
+				return nil, fmt.Errorf("block %d: vote certificate entry %d is not valid", prev, i/pqAttestationSize)
+			}
+			signed += power[string(a)]
+			proposerSigned = proposerSigned || bytes.Equal(a, proposer)
+			before = a
+		}
+	}
+	need := 2*total - 3*unregistered // signed power must be > need/3
+	if need >= 0 && 3*signed <= need {
+		return nil, fmt.Errorf("block %d: ML-DSA-44 vote signatures cover %d of %d voting power (%d without a key); not enough", prev, signed, total, unregistered)
+	}
+	if _, keyed := keys[string(proposer)]; keyed && !proposerSigned && app.zetaphyV2(ctx, height) {
+		return nil, fmt.Errorf("block %d: the vote certificate lacks the proposer's own ML-DSA-44 entry", prev)
+	}
+	if c != nil && len(c.Attestations) == 0 {
+		c = nil
+	}
+	return c, nil
+}
+
+// pqBuildCert makes the certificate tx from the votes that committed block
+// height-1. From the v2 activation height the proposer adds its own entry,
+// signed now, when its precommit did not bring one.
+func (app *EVMD) pqBuildCert(ctx sdk.Context, height int64, proposer []byte, votes []abci.ExtendedVoteInfo) []byte {
+	last := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqLastBlockKey)
+	if len(last) != 8+32 || int64(binary.BigEndian.Uint64(last)) != height-1 || !pqExtensionsOn(ctx, height-1) { // #nosec G115 -- block heights
+		return nil
+	}
+	msg := pqVoteMsg(ctx.ChainID(), height-1, last[8:])
+	var entries [][]byte
+	for _, v := range votes {
+		sig, _ := zxSplit(v.VoteExtension) // ZETAPHY v5: a payload may follow the signature
+		if v.BlockIdFlag != cmtproto.BlockIDFlagCommit || len(sig) != circl.SignatureSize || len(v.Validator.Address) != 20 {
+			continue
+		}
+		// CometBFT adds late precommits without asking the app; check each one.
+		if k := app.pqVoteKeyAt(ctx, v.Validator.Address, height-1); k != nil && (&mldsa44.PubKey{Key: k}).VerifySignature(msg, sig) {
+			entries = append(entries, append(append([]byte{}, v.Validator.Address...), sig...))
+		}
+	}
+	if own := app.pqOwnEntry(ctx, height, proposer, votes, msg, entries); own != nil {
+		entries = append(entries, own)
+	}
+	if entries == nil {
+		return nil
+	}
+	sort.Slice(entries, func(i, j int) bool { return bytes.Compare(entries[i][:20], entries[j][:20]) < 0 })
+	var att []byte
+	for i, e := range entries {
+		if i > 0 && bytes.Equal(e[:20], entries[i-1][:20]) {
+			continue
+		}
+		att = append(att, e...)
+	}
+	b := app.txConfig.NewTxBuilder()
+	if err := b.SetMsgs(&MsgPQCertificate{Signer: authtypes.NewModuleAddress(pqStoreKey).String(), Height: uint64(height - 1), Attestations: att}); err != nil { // #nosec G115 -- block heights
+		return nil
+	}
+	bz, err := app.txConfig.TxEncoder()(b.GetTx())
+	if err != nil {
+		return nil
+	}
+	return bz
+}
+
+// pqOwnEntry is the proposer's own certificate entry when the rule in
+// pqVerifiedCert asks for it and the votes did not bring one: signed with
+// this node's vote key file (or .old) that matches the registered key.
+func (app *EVMD) pqOwnEntry(ctx sdk.Context, height int64, proposer []byte, votes []abci.ExtendedVoteInfo, msg []byte, entries [][]byte) []byte {
+	if len(proposer) != 20 || !app.zetaphyV2(ctx, height) {
+		return nil
+	}
+	inSet := false
+	for _, v := range votes {
+		inSet = inSet || bytes.Equal(v.Validator.Address, proposer)
+	}
+	for _, e := range entries {
+		if bytes.Equal(e[:20], proposer) {
+			return nil
+		}
+	}
+	want := app.pqVoteKeyAt(ctx, proposer, height-1)
+	if !inSet || want == nil || app.pqHome == "" {
+		return nil
+	}
+	seedFile := filepath.Join(app.pqHome, "config", pqVoteSeedFn)
+	for _, f := range []string{seedFile, seedFile + ".old"} {
+		if sk, pub, err := pqVoteSeed(f); err == nil && bytes.Equal(pub, want) {
+			if sig, err := pqSign(sk, msg); err == nil {
+				return append(append([]byte{}, proposer...), sig...)
+			}
+		}
+	}
+	app.Logger().Error("ZETAPHY: no ML-DSA vote key here matches the one registered for this validator; this node's proposals will be refused. Put the right key in " + seedFile)
+	return nil
+}
+
+// pqProposalHandlers wraps the proposal handlers: the proposer puts the
+// certificate first; everyone checks it and hands the rest on.
+func (app *EVMD) pqProposalHandlers(prepare sdk.PrepareProposalHandler, process sdk.ProcessProposalHandler) {
+	app.SetPrepareProposal(func(ctx sdk.Context, req *abci.RequestPrepareProposal) (*abci.ResponsePrepareProposal, error) {
+		cert := app.pqBuildCert(ctx, req.Height, req.ProposerAddress, req.LocalLastCommit.Votes)
+		zx := app.zxBuildTx(ctx, req.Height, req.LocalLastCommit, cert) // ZETAPHY v5 (zetaphy_immune.go)
+		var lead [][]byte
+		for _, t := range [][]byte{cert, zx} {
+			if t != nil {
+				lead = append(lead, t)
+			}
+		}
+		r := *req
+		r.MaxTxBytes -= int64(len(cert)+len(zx)) + 32
+		res, err := prepare(ctx, &r)
+		if lead == nil {
+			return res, err
+		}
+		if err != nil || res == nil { // the certificate alone keeps the chain going
+			return &abci.ResponsePrepareProposal{Txs: lead}, nil
+		}
+		res.Txs = append(lead, res.Txs...)
+		return res, nil
+	})
+	app.SetProcessProposal(func(ctx sdk.Context, req *abci.RequestProcessProposal) (*abci.ResponseProcessProposal, error) {
+		if err := app.pqCheckCert(ctx, req.Height, req.ProposerAddress, req.ProposedLastCommit.Votes, req.Txs); err != nil {
+			app.Logger().Info("ZETAPHY: rejecting proposal", "err", err)
+			return &abci.ResponseProcessProposal{Status: abci.ResponseProcessProposal_REJECT}, nil
+		}
+		if err := app.zxCheckProposal(req.Height, req.Txs); err != nil { // ZETAPHY v5
+			app.Logger().Info("ZETAPHY: rejecting proposal", "err", err)
+			return &abci.ResponseProcessProposal{Status: abci.ResponseProcessProposal_REJECT}, nil
+		}
+		skip := 0
+		if app.pqCertOf(req.Txs) != nil {
+			skip = 1
+		}
+		if z, i := app.zxOf(req.Txs); z != nil {
+			skip = i + 1
+		}
+		if skip > 0 {
+			r := *req
+			r.Txs = req.Txs[skip:]
+			return process(ctx, &r)
+		}
+		return process(ctx, req)
+	})
+}
+
+// pqPreBlock checks the certificate when the block runs (also in blocksync)
+// and records this block for the next one.
+func (app *EVMD) pqPreBlock(ctx sdk.Context, req *abci.RequestFinalizeBlock) error {
+	cert, err := app.pqVerifiedCert(ctx, req.Height, req.ProposerAddress, req.DecidedLastCommit.Votes, req.Txs)
+	if err != nil {
+		return err
+	}
+	// ZETAPHY: block.prevrandao (zetaphy_random.go), before pqLastBlockKey moves on
+	app.setPrevRandao(ctx, req.Height, cert)
+	if len(req.Hash) == 32 { // CometBFT always sends it; some test harnesses do not
+		v := binary.BigEndian.AppendUint64(nil, uint64(req.Height)) // #nosec G115 -- block heights
+		ctx.KVStore(app.GetKey(pqStoreKey)).Set(pqLastBlockKey, append(v, req.Hash...))
+	}
+	return nil
+}
+
+// ---- evidence switch
+
+type pqEvidenceList []comet.Evidence
+
+func (l pqEvidenceList) Len() int                 { return len(l) }
+func (l pqEvidenceList) Get(i int) comet.Evidence { return l[i] }
+
+type pqBlockInfo struct {
+	comet.BlockInfo
+	evidence pqEvidenceList
+}
+
+func (b pqBlockInfo) GetEvidence() comet.EvidenceList { return b.evidence }
+
+// pqFilterEvidence drops ed25519-only double-sign evidence against validators
+// with an ML-DSA-44 vote key, once governance has switched that on.
+func (app *EVMD) pqFilterEvidence(ctx sdk.Context) sdk.Context {
+	info := ctx.CometInfo()
+	if info == nil || !bytes.Equal(ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqEvidenceKey), []byte{1}) {
+		return ctx
+	}
+	ev := info.GetEvidence()
+	var keep pqEvidenceList
+	for i := 0; i < ev.Len(); i++ {
+		e := ev.Get(i)
+		if app.pqVoteKeyAt(ctx, e.Validator().Address(), ctx.BlockHeight()+1) != nil {
+			ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_evidence_ignored",
+				sdk.NewAttribute("validator", fmt.Sprintf("%X", e.Validator().Address())), sdk.NewAttribute("height", fmt.Sprint(e.Height()))))
+			continue
+		}
+		keep = append(keep, e)
+	}
+	return ctx.WithCometInfo(pqBlockInfo{info, keep})
+}
+
+// pqSetEvidence is the evidence switch; only governance can send it.
+func (app *EVMD) pqSetEvidence(ctx sdk.Context, m *MsgSetPQEvidence) (gogoproto.Message, error) {
+	if m.Authority != authtypes.NewModuleAddress(govtypes.ModuleName).String() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can switch evidence handling")
+	}
+	if m.Enabled > 1 {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "enabled: 0 or 1")
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(pqEvidenceKey, []byte{byte(m.Enabled)})
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_pq_evidence", sdk.NewAttribute("ignore_ed25519_evidence", fmt.Sprint(m.Enabled))))
+	return &MsgPQResponse{}, nil
+}
+
+// pqExtensionsOn: vote extensions (and so ML-DSA vote signatures) exist for votes on h.
+func pqExtensionsOn(ctx sdk.Context, h int64) bool {
+	cp := ctx.ConsensusParams()
+	return cp.Abci != nil && cp.Abci.VoteExtensionsEnableHeight > 0 && cp.Abci.VoteExtensionsEnableHeight <= h
+}
+
+// PQEvidenceProposalCmd: zetaphyd tx pq-evidence-proposal on|off --deposit ... --from <key>.
+func PQEvidenceProposalCmd() *cobra.Command {
+	cmd := &cobra.Command{
+		Use:   "pq-evidence-proposal on|off",
+		Short: "Propose to stop (on) or resume (off) slashing on ed25519-only double-sign evidence for validators with an ML-DSA-44 vote key",
+		Args:  cobra.ExactArgs(1),
+		RunE: func(cmd *cobra.Command, args []string) error {
+			cctx, err := client.GetClientTxContext(cmd)
+			if err != nil {
+				return err
+			}
+			on := map[string]uint64{"on": 1, "off": 0}
+			v, ok := on[args[0]]
+			if !ok {
+				return errors.New("on or off")
+			}
+			dep, err := cmd.Flags().GetString("deposit")
+			if err != nil {
+				return err
+			}
+			coins, err := sdk.ParseCoinsNormalized(dep)
+			if err != nil {
+				return err
+			}
+			title := map[uint64]string{1: "Ignore ed25519-only double-sign evidence for validators with ML-DSA-44 keys", 0: "Slash on ed25519 double-sign evidence again"}[v]
+			p, err := govv1.NewMsgSubmitProposal([]sdk.Msg{&MsgSetPQEvidence{Authority: authtypes.NewModuleAddress(govtypes.ModuleName).String(), Enabled: v}},
+				coins, cctx.GetFromAddress().String(), "", title, title, false)
+			if err != nil {
+				return err
+			}
+			return tx.GenerateOrBroadcastTxCLI(cctx, cmd.Flags(), p)
+		},
+	}
+	cmd.Flags().String("deposit", "", "initial deposit, e.g. 1000000000000000000000azetaphy")
+	flags.AddTxFlagsToCmd(cmd)
+	return cmd
+}
diff --git a/evmd/zetaphy_pqguard.go b/evmd/zetaphy_pqguard.go
new file mode 100644
index 0000000..7c6f8b6
--- /dev/null
+++ b/evmd/zetaphy_pqguard.go
@@ -0,0 +1,519 @@
+package evmd
+
+// ZETAPHY post-quantum guards.
+//
+// Quantum lock: an ECDSA (MetaMask) account hands control to an ML-DSA-44
+// account, by a MetaMask tx to PQLockAddress or by MsgQuantumLock. From then on every tx signed by the ECDSA key is refused (the ante
+// wrapper below, which also looks inside authz MsgExec and at fee grants);
+// the controller acts for it through MsgEVMCall.as_owner, so its address,
+// balance, tokens and contract roles stay where they are.
+//
+// Vote keys: CometBFT signs votes with ed25519 only. Each validator also
+// signs every precommit with ML-DSA-44 (a vote extension over chain id,
+// height and block hash), and nodes reject a precommit from a validator with
+// a registered key whose ML-DSA signature is missing or wrong. Once
+// validators with more than 2/3 of the power have keys, forging ed25519
+// cannot commit a block. Validators without a key are not checked, so they
+// can always register (no halt).
+
+import (
+	"bytes"
+	"encoding/binary"
+	"encoding/hex"
+	"encoding/json"
+	"errors"
+	"fmt"
+	"os"
+	"path/filepath"
+
+	circl "github.com/cloudflare/circl/sign/mldsa/mldsa44"
+	abci "github.com/cometbft/cometbft/abci/types"
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/spf13/cobra"
+
+	errorsmod "cosmossdk.io/errors"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/client/flags"
+	"github.com/cosmos/cosmos-sdk/client/tx"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authsigning "github.com/cosmos/cosmos-sdk/x/auth/signing"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+
+	"github.com/cosmos/evm/crypto/mldsa44"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+const (
+	pqStoreKey   = "zetaphypq"
+	pqVoteSeedFn = "pq_vote_key.seed"
+)
+
+func pqLockKey(owner []byte) []byte  { return append([]byte{1}, owner...) }
+func pqVoteKeyOf(cons []byte) []byte { return append([]byte{2}, cons...) }
+
+// A vote key entry is since (8 bytes, the block that registered it) || key ||
+// the key it replaced (if any). Votes for height h are signed in the state
+// before h, so a key registered in block s signs votes from h = s+1 on.
+func (app *EVMD) pqVoteKeyAt(ctx sdk.Context, cons []byte, h int64) []byte {
+	v := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqVoteKeyOf(cons))
+	if len(v) == mldsa44.PubKeySize { // the format before key history: registered at 0
+		v = append(make([]byte, 8), v...)
+	}
+	if len(v) < 8+mldsa44.PubKeySize {
+		return nil
+	}
+	if int64(binary.BigEndian.Uint64(v)) < h { // #nosec G115 -- block heights
+		return v[8 : 8+mldsa44.PubKeySize]
+	}
+	if len(v) == 8+2*mldsa44.PubKeySize {
+		return v[8+mldsa44.PubKeySize:]
+	}
+	return nil
+}
+
+// pqController is the ML-DSA account that controls a quantum-locked owner, or nil.
+func (app *EVMD) pqController(ctx sdk.Context, owner []byte) []byte {
+	return ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqLockKey(owner))
+}
+
+func (app *EVMD) quantumLock(ctx sdk.Context, m *MsgQuantumLock) (gogoproto.Message, error) {
+	signer, err := pqAddr(m.Signer)
+	if err != nil {
+		return nil, err
+	}
+	owner, err := pqAddr(m.Owner)
+	if err != nil {
+		return nil, err
+	}
+	ctrl, err := pqAddr(m.Controller)
+	if err != nil {
+		return nil, err
+	}
+	if acc := app.AccountKeeper.GetAccount(ctx, owner); acc != nil {
+		if _, ok := acc.GetPubKey().(*mldsa44.PubKey); ok {
+			return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "an ML-DSA-44 account is post-quantum already and cannot be locked")
+		}
+	}
+	if cur := app.pqController(ctx, owner); cur == nil && !owner.Equals(signer) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only the owner can lock its account")
+	} else if cur != nil && !bytes.Equal(cur, signer) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only the current controller can hand control over")
+	}
+	if err := app.checkPQController(ctx, owner, ctrl); err != nil {
+		return nil, err
+	}
+	app.applyQuantumLock(ctx, owner, ctrl)
+	return &MsgPQResponse{}, nil
+}
+
+// checkPQController: the controller must be another ML-DSA-44 account that
+// has already sent a tx (its key is on chain) and is not locked itself.
+func (app *EVMD) checkPQController(ctx sdk.Context, owner, ctrl sdk.AccAddress) error {
+	isPQ := false
+	if acc := app.AccountKeeper.GetAccount(ctx, ctrl); acc != nil {
+		_, isPQ = acc.GetPubKey().(*mldsa44.PubKey)
+	}
+	if !isPQ || ctrl.Equals(owner) || app.pqController(ctx, ctrl) != nil {
+		return errorsmod.Wrap(errortypes.ErrInvalidRequest, "the controller must be another ML-DSA-44 account that has already sent a transaction")
+	}
+	return nil
+}
+
+// applyQuantumLock records owner -> controller, in the zetaphypq store and
+// mirrored into EVM storage for ecrecover and the mempool.
+func (app *EVMD) applyQuantumLock(ctx sdk.Context, owner, ctrl sdk.AccAddress) {
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(pqLockKey(owner), ctrl)
+	app.ensurePQLockAccount(ctx)
+	app.EVMKeeper.SetState(ctx, PQLockAddress, common.BytesToHash(owner), common.BytesToHash(ctrl).Bytes())
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_quantum_lock", sdk.NewAttribute("owner", owner.String()), sdk.NewAttribute("controller", ctrl.String())))
+}
+
+// PQLockAddress: an EVM tx (MetaMask) to this address with no value and the
+// controller's 20-byte address as data locks the sender to that controller.
+var PQLockAddress = evmtypes.PQLockAddress
+
+type pqHooks struct{ app *EVMD }
+
+func (h pqHooks) PostTxProcessing(ctx sdk.Context, sender common.Address, msg core.Message, r *ethtypes.Receipt) error {
+	if err := threatRefused(ctx); err != nil {
+		return err // the threat gate refused this tx in the ante handler: revert it (the fee stays paid)
+	}
+	if r.Status == ethtypes.ReceiptStatusSuccessful { // ZETAPHY v5: new contracts to score, bridge outflows (never fails)
+		if msg.To == nil && r.ContractAddress != (common.Address{}) {
+			h.app.immuneNoteDeploy(ctx, r.ContractAddress)
+		}
+		h.app.breakerNoteLogs(ctx, r.Logs)
+	}
+	if msg.To == nil || *msg.To != PQLockAddress || r.Status != ethtypes.ReceiptStatusSuccessful {
+		return nil
+	}
+	if len(msg.Data) != 20 || msg.Value.Sign() != 0 {
+		return errors.New("quantum lock: send no value, and the controller's 20-byte address as data")
+	}
+	_, err := h.app.quantumLock(ctx, &MsgQuantumLock{Signer: sender.Hex(), Owner: sender.Hex(), Controller: common.BytesToAddress(msg.Data).Hex()})
+	return err
+}
+
+// pqLockAnte refuses any tx that a quantum-locked account signs (the fee
+// payer included), pays for through a fee grant, authorizes through authz,
+// or delegates code for (EIP-7702). It runs after the normal ante handler has
+// validated the tx; a refusal discards that handler's changes. Signatures
+// that contracts check go through ecrecover, which refuses locked accounts
+// too (x/vm/keeper/zetaphy_ecrecover.go).
+func (app *EVMD) pqLockAnte(next sdk.AnteHandler) sdk.AnteHandler {
+	return func(ctx sdk.Context, tx sdk.Tx, sim bool) (sdk.Context, error) {
+		if pqHasCert(tx) { // only the proposer's first tx, checked in ProcessProposal and PreBlocker
+			if len(tx.GetMsgs()) == 1 && ctx.ExecMode() == sdk.ExecModeFinalize && ctx.TxIndex() == 0 {
+				return ctx.WithGasMeter(storetypes.NewGasMeter(100_000)), nil
+			}
+			return ctx, errorsmod.Wrap(errortypes.ErrUnauthorized, "a vote certificate is only valid as the first tx of a block")
+		}
+		if zxHas(tx) { // ZETAPHY v5: the proposer's MsgZXVotes, after the certificate (zetaphy_immune.go)
+			if len(tx.GetMsgs()) == 1 && ctx.ExecMode() == sdk.ExecModeFinalize && ctx.TxIndex() <= 1 {
+				return ctx.WithGasMeter(storetypes.NewGasMeter(100_000)), nil
+			}
+			return ctx, errorsmod.Wrap(errortypes.ErrUnauthorized, "v5 votes are only valid at the start of a block")
+		}
+		newCtx, err := next(ctx, tx, sim)
+		if err != nil {
+			return newCtx, err
+		}
+		signers, err := app.pqTxSigners(tx)
+		if err != nil {
+			return newCtx, err
+		}
+		for _, s := range signers {
+			if app.pqController(ctx, s) != nil {
+				return newCtx, errorsmod.Wrapf(errortypes.ErrUnauthorized, "%s is quantum-locked: only its ML-DSA-44 controller can act for it", sdk.AccAddress(s))
+			}
+		}
+		// ZETAPHY security core (zetaphy_security.go): Q-day, then the threat gate.
+		if app.qdayActive(ctx) {
+			if err := app.qdayCheckTx(ctx, tx); err != nil {
+				return newCtx, err
+			}
+		}
+		if err := app.guardTx(newCtx, tx); err != nil { // ZETAPHY v5: protected accounts, anomaly hold (zetaphy_guard.go)
+			return newCtx, err
+		}
+		if err := app.threatGateTx(ctx, tx); err != nil {
+			if ctx.ExecMode() != sdk.ExecModeFinalize {
+				return newCtx, err // CheckTx and proposals: refused before inclusion
+			}
+			// In a block the tx stays included and pays its fee (the
+			// handler's fee and nonce changes are kept); what it would do
+			// is refused where it runs (threatRefused).
+			return newCtx.WithValue(threatRefusedKey{}, err), nil
+		}
+		return newCtx, nil
+	}
+}
+
+func (app *EVMD) pqTxSigners(tx sdk.Tx) (signers [][]byte, err error) {
+	defer func() {
+		if r := recover(); r != nil {
+			err = errorsmod.Wrapf(errortypes.ErrTxDecode, "malformed tx: %v", r)
+		}
+	}()
+	if st, ok := tx.(authsigning.SigVerifiableTx); ok { // the fee payer is one of these
+		if signers, err = st.GetSigners(); err != nil {
+			return nil, err
+		}
+	}
+	if ft, ok := tx.(sdk.FeeTx); ok && ft.FeeGranter() != nil {
+		signers = append(signers, ft.FeeGranter())
+	}
+	msgs := append([]sdk.Msg{}, tx.GetMsgs()...)
+	for i := 0; i < len(msgs); i++ {
+		if ex, ok := msgs[i].(*authz.MsgExec); ok {
+			inner, err := ex.GetMessages()
+			if err != nil {
+				return nil, err
+			}
+			msgs = append(msgs, inner...)
+		}
+		// EIP-7702: an authorization signed by a locked key, carried in someone else's tx.
+		if et, ok := msgs[i].(*evmtypes.MsgEthereumTx); ok {
+			if t := et.AsTransaction(); t != nil {
+				for _, auth := range t.SetCodeAuthorizations() {
+					if a, err := auth.Authority(); err == nil {
+						signers = append(signers, a.Bytes())
+					}
+				}
+			}
+		}
+		s, _, err := app.appCodec.GetMsgV1Signers(msgs[i])
+		if err != nil {
+			return nil, err
+		}
+		signers = append(signers, s...)
+	}
+	return signers, nil
+}
+
+func pqVoteMsg(chainID string, height int64, hash []byte) []byte {
+	return append(binary.BigEndian.AppendUint64([]byte("zetaphy/pq-vote\x00"+chainID+"\x00"), uint64(height)), hash...) // #nosec G115 -- heights are positive
+}
+
+func pqVoteKeyMsg(chainID string, cons, pub []byte) []byte {
+	return append(append([]byte("zetaphy/pq-vote-key\x00"+chainID+"\x00"), cons...), pub...)
+}
+
+func (app *EVMD) pqVoteKey(ctx sdk.Context, m *MsgPQVoteKey) (gogoproto.Message, error) {
+	op, err := pqAddr(m.Operator)
+	if err != nil {
+		return nil, err
+	}
+	if m.ValidatorOwner != "" { // the operator account is quantum-locked to the signer
+		owner, err := pqAddr(m.ValidatorOwner)
+		if err != nil {
+			return nil, err
+		}
+		if !bytes.Equal(app.pqController(ctx, owner), op) {
+			return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "validator_owner: the signer does not control this account")
+		}
+		op = owner
+	}
+	val, err := app.StakingKeeper.GetValidator(ctx, sdk.ValAddress(op))
+	if err != nil {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "the signer does not operate a validator")
+	}
+	cons, err := val.GetConsAddr()
+	if err != nil {
+		return nil, err
+	}
+	if !pqExtensionsOn(ctx, ctx.BlockHeight()+1) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "vote extensions are off on this chain")
+	}
+	if cur := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqVoteKeyOf(cons)); len(cur) >= 8 && int64(binary.BigEndian.Uint64(cur)) == ctx.BlockHeight() { // #nosec G115 -- block heights
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "the vote key already changed in this block")
+	}
+	msg := pqVoteKeyMsg(ctx.ChainID(), cons, m.PubKey)
+	if !(&mldsa44.PubKey{Key: m.PubKey}).VerifySignature(msg, m.Proof) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "proof: not signed by the new key")
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	// A jailed validator (down because its key was lost) may start over, but
+	// only through the ML-DSA controller of its quantum-locked operator: an
+	// ECDSA operator key could be forged to take the vote key over.
+	old := app.pqVoteKeyAt(ctx, cons, ctx.BlockHeight()+1)
+	reset := val.IsJailed() && m.ValidatorOwner != ""
+	if old != nil && !reset && !(&mldsa44.PubKey{Key: old}).VerifySignature(msg, m.OldKeySig) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "replacing a vote key needs a signature by the current one")
+	}
+	if len(m.PubKey) != mldsa44.PubKeySize {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "pub_key size")
+	}
+	v := binary.BigEndian.AppendUint64(nil, uint64(ctx.BlockHeight())) // #nosec G115 -- block heights
+	// The previous key is the one that signs the votes on this block: with two
+	// replacements in one block that is not the one just replaced.
+	prev := app.pqVoteKeyAt(ctx, cons, ctx.BlockHeight())
+	st.Set(pqVoteKeyOf(cons), append(append(v, m.PubKey...), prev...))
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_pq_vote_key", sdk.NewAttribute("validator", sdk.ValAddress(op).String())))
+	return &MsgPQResponse{}, nil
+}
+
+// pqVoteSeed loads <home>/config/pq_vote_key.seed (32 bytes, hex).
+func pqVoteSeed(path string) (*circl.PrivateKey, []byte, error) {
+	b, err := os.ReadFile(filepath.Clean(path))
+	if err != nil {
+		return nil, nil, err
+	}
+	var seed [circl.SeedSize]byte
+	if n, err := hex.Decode(seed[:], bytes.TrimSpace(b)); err != nil || n != len(seed) {
+		return nil, nil, fmt.Errorf("%s: want %d hex bytes", path, len(seed))
+	}
+	pk, sk := circl.NewKeyFromSeed(&seed)
+	return sk, pk.Bytes(), nil
+}
+
+func pqSign(sk *circl.PrivateKey, msg []byte) ([]byte, error) {
+	sig := make([]byte, circl.SignatureSize)
+	return sig, circl.SignTo(sk, msg, nil, false, sig)
+}
+
+// pqConsAddr is this node's validator (consensus) address.
+func pqConsAddr(home string) ([]byte, error) {
+	pv, err := os.ReadFile(filepath.Join(home, "config", "priv_validator_key.json")) // #nosec G304 -- the node's own key file
+	if err != nil {
+		return nil, err
+	}
+	var k struct{ Address string }
+	if err := json.Unmarshal(pv, &k); err != nil {
+		return nil, err
+	}
+	return hex.DecodeString(k.Address)
+}
+
+// setPQVoteHandlers signs this node's precommits and checks everyone else's.
+// The node signs with config/pq_vote_key.seed or, while a replacement is
+// being registered, config/pq_vote_key.seed.old: whichever the chain has.
+// With neither it stops instead of sending a vote the others would reject:
+// this node counts its own precommit (it does not check its own extension)
+// and may commit a block the others cannot, which stalls them for good (seen
+// on a devnet); a node that is down is ordinary downtime.
+func (app *EVMD) setPQVoteHandlers(home string) {
+	app.pqHome = home // for the proposer's own certificate entry (pqOwnEntry)
+	seedFile := filepath.Join(home, "config", pqVoteSeedFn)
+	app.SetExtendVoteHandler(func(ctx sdk.Context, req *abci.RequestExtendVote) (*abci.ResponseExtendVote, error) {
+		var want []byte
+		// ZETAPHY v5: the payload (immune scores, breaker flags) goes after the signature (zetaphy_immune.go)
+		payload := app.zxBuild(ctx, req.Height)
+		cons, err := pqConsAddr(home)
+		if err != nil { // remote signer: sign with the current seed file
+			if sk, _, err := pqVoteSeed(seedFile); err == nil {
+				sig, err := pqSign(sk, pqVoteMsg(ctx.ChainID(), req.Height, req.Hash))
+				return &abci.ResponseExtendVote{VoteExtension: append(sig, payload...)}, err
+			}
+			return &abci.ResponseExtendVote{VoteExtension: payload}, nil
+		}
+		want = app.pqVoteKeyAt(ctx, cons, req.Height)
+		for _, f := range []string{seedFile, seedFile + ".old"} {
+			sk, pub, err := pqVoteSeed(f)
+			if err == nil && (want == nil || bytes.Equal(pub, want)) {
+				sig, err := pqSign(sk, pqVoteMsg(ctx.ChainID(), req.Height, req.Hash))
+				return &abci.ResponseExtendVote{VoteExtension: append(sig, payload...)}, err
+			}
+		}
+		if want == nil {
+			return &abci.ResponseExtendVote{VoteExtension: payload}, nil
+		}
+		app.Logger().Error("ZETAPHY: no ML-DSA vote key here matches the one registered for this validator; stopping so as not to send a vote the chain rejects. Put the right key in " + seedFile)
+		os.Exit(1)
+		return nil, nil
+	})
+	app.SetVerifyVoteExtensionHandler(func(ctx sdk.Context, req *abci.RequestVerifyVoteExtension) (*abci.ResponseVerifyVoteExtension, error) {
+		if app.pqVerifyExtension(ctx, req) {
+			return &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_ACCEPT}, nil
+		}
+		return &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_REJECT}, nil
+	})
+}
+
+// pqVerifyExtension: the ML-DSA-44 signature part (when the validator has a
+// key) and the v5 payload after it (zetaphy_immune.go) are both valid.
+func (app *EVMD) pqVerifyExtension(ctx sdk.Context, req *abci.RequestVerifyVoteExtension) bool {
+	sig, payload := zxSplit(req.VoteExtension)
+	if pk := app.pqVoteKeyAt(ctx, req.ValidatorAddress, req.Height); pk != nil &&
+		!(&mldsa44.PubKey{Key: pk}).VerifySignature(pqVoteMsg(ctx.ChainID(), req.Height, req.Hash), sig) {
+		return false
+	}
+	_, err := app.zxCheck(ctx, req.Height, payload)
+	return err == nil
+}
+
+// PQVoteKeyCmd: zetaphyd tx pq-vote-key --from <operator>. Registers the
+// node's config/pq_vote_key.seed for the validator the --from key operates
+// (signed also by pq_vote_key.seed.old, if present, to replace that key).
+func PQVoteKeyCmd() *cobra.Command {
+	cmd := &cobra.Command{
+		Use:   "pq-vote-key",
+		Short: "Register this node's ML-DSA-44 vote key (config/" + pqVoteSeedFn + "); to replace one, keep the old seed as " + pqVoteSeedFn + ".old",
+		Args:  cobra.NoArgs,
+		RunE: func(cmd *cobra.Command, _ []string) error {
+			cctx, err := client.GetClientTxContext(cmd)
+			if err != nil {
+				return err
+			}
+			sk, pub, err := pqVoteSeed(filepath.Join(cctx.HomeDir, "config", pqVoteSeedFn))
+			if err != nil {
+				return err
+			}
+			cons, err := pqConsAddr(cctx.HomeDir)
+			if err != nil {
+				return err
+			}
+			msg := pqVoteKeyMsg(cctx.ChainID, cons, pub)
+			m := &MsgPQVoteKey{Operator: cctx.GetFromAddress().String(), PubKey: pub}
+			if m.Proof, err = pqSign(sk, msg); err != nil {
+				return err
+			}
+			if old, _, err := pqVoteSeed(filepath.Join(cctx.HomeDir, "config", pqVoteSeedFn+".old")); err == nil {
+				if m.OldKeySig, err = pqSign(old, msg); err != nil {
+					return err
+				}
+			}
+			return tx.GenerateOrBroadcastTxCLI(cctx, cmd.Flags(), m)
+		},
+	}
+	flags.AddTxFlagsToCmd(cmd)
+	return cmd
+}
+
+// QuantumLockCmd: zetaphyd tx quantum-lock <controller> --from <key>.
+func QuantumLockCmd() *cobra.Command {
+	cmd := &cobra.Command{
+		Use:   "quantum-lock <controller zetaphy1... or 0x...>",
+		Short: "Hand control of the --from account to an ML-DSA-44 account for good; its own key is refused afterwards",
+		Args:  cobra.ExactArgs(1),
+		RunE: func(cmd *cobra.Command, args []string) error {
+			cctx, err := client.GetClientTxContext(cmd)
+			if err != nil {
+				return err
+			}
+			from := cctx.GetFromAddress().String()
+			return tx.GenerateOrBroadcastTxCLI(cctx, cmd.Flags(), &MsgQuantumLock{Signer: from, Owner: from, Controller: args[0]})
+		},
+	}
+	flags.AddTxFlagsToCmd(cmd)
+	return cmd
+}
+
+type pqGenesisEntry struct {
+	Key   string `json:"key"`
+	Value string `json:"value"`
+}
+
+// pqExportGenesis / pqInitGenesis carry the zetaphypq store (quantum locks
+// and vote keys) through a genesis export, under app_state.zetaphypq.
+func (app *EVMD) pqExportGenesis(ctx sdk.Context) (json.RawMessage, error) {
+	out := []pqGenesisEntry{}
+	it := ctx.KVStore(app.GetKey(pqStoreKey)).Iterator(nil, nil)
+	defer it.Close()
+	for ; it.Valid(); it.Next() {
+		k, v := it.Key(), it.Value()
+		if k[0] == pqLastBlockKey[0] || k[0] == pqRandaoKey[0] { // belongs to this chain's history only
+			continue
+		}
+		if k[0] == pqActivationKey[0] && app.zetaphyV2(ctx, ctx.BlockHeight()+1) {
+			v = binary.BigEndian.AppendUint64(nil, 1) // already on: on from the new chain's start
+		}
+		if k[0] == secV3Key[0] && app.secV3Height(ctx) > 0 && app.secV3Height(ctx) <= ctx.BlockHeight()+1 {
+			v = binary.BigEndian.AppendUint64(nil, 1)
+		}
+		if k[0] == futV5Key[0] && app.futV5(ctx, ctx.BlockHeight()+1) {
+			v = binary.BigEndian.AppendUint64(nil, 1)
+		}
+		if k[0] == immunePendingPfx || k[0] == breakerPausePfx { // this chain's last blocks only
+			continue
+		}
+		if k[0] == 2 { // vote keys: the current key only, valid from the new chain's start
+			cur := app.pqVoteKeyAt(ctx, k[1:], ctx.BlockHeight()+1)
+			if cur == nil {
+				continue
+			}
+			v = append(make([]byte, 8), cur...)
+		}
+		out = append(out, pqGenesisEntry{hex.EncodeToString(k), hex.EncodeToString(v)})
+	}
+	return json.Marshal(out)
+}
+
+func (app *EVMD) pqInitGenesis(ctx sdk.Context, raw json.RawMessage) error {
+	in, err := pqParseGenesis(raw)
+	if err != nil {
+		return err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	for _, e := range in {
+		st.Set(e[0], e[1])
+	}
+	return nil
+}
diff --git a/evmd/zetaphy_qday.go b/evmd/zetaphy_qday.go
new file mode 100644
index 0000000..bb88122
--- /dev/null
+++ b/evmd/zetaphy_qday.go
@@ -0,0 +1,303 @@
+package evmd
+
+// ZETAPHY Q-day: the day ECDSA (secp256k1) stops being trusted.
+//
+// Governance schedules it (MsgSetQDay, height 0 = not scheduled). Before it
+// nothing changes. From that block on:
+//   - a Cosmos tx is accepted only if every signer's key is ML-DSA-44 (or a
+//     multisig made only of ML-DSA-44 keys);
+//   - an Ethereum tx (always ECDSA) is refused, in blocks and at submission;
+//   - ecrecover returns nothing, so contract-checked ECDSA signatures
+//     (permits, meta-transactions) prove nothing any more.
+// A migrated account (quantum lock: an ML-DSA-44 controller acts for it with
+// MsgEVMCall.as_owner, including the staking, distribution and slashing
+// precompiles for a validator operator) keeps its address, balance and
+// contract roles. An account that did not migrate before Q-day is frozen:
+// its funds stay where they are, and governance may later add a recovery
+// method. Authorizations it gave before Q-day (ERC-20 allowances, authz and
+// fee grants) keep working: they were given with a then-trusted key.
+//
+// Recovery for keys never shown on chain (no tx sent, no signature seen by
+// ecrecover): their address is a hash of the public key, which only the
+// owner knows. Two steps, both signed by the new ML-DSA-44 account:
+//  1. MsgQDayCommit: sha256 of (chain id, the ECDSA public key, the new
+//     controller, a 32-byte salt) — reveals nothing;
+//  2. after reveal_delay blocks, MsgQDayReveal: the salt and an EIP-191
+//     signature by the old key over qdayRevealText. The chain recovers the
+//     public key, checks it opens the commitment, and records the migration
+//     as pending; it becomes a quantum lock reveal_delay blocks later.
+// The reveal shows the public key. A commitment made after seeing it is too
+// young to be revealed, and while a migration is pending, a reveal opening an
+// older commitment for the same account replaces it: the oldest commitment
+// wins.
+
+import (
+	"bytes"
+	"crypto/sha256"
+	"fmt"
+	"math/big"
+
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/accounts"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/crypto"
+
+	errorsmod "cosmossdk.io/errors"
+
+	"github.com/cosmos/cosmos-sdk/crypto/keys/multisig"
+	cryptotypes "github.com/cosmos/cosmos-sdk/crypto/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	authsigning "github.com/cosmos/cosmos-sdk/x/auth/signing"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+
+	"github.com/cosmos/evm/crypto/mldsa44"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+const (
+	// QDayDefaultRevealDelay: blocks between commit and reveal, and between
+	// reveal and the lock (about an hour at 5 s blocks), unless governance sets one.
+	QDayDefaultRevealDelay = 720
+	QDayMinRevealDelay     = 2
+	QDayMaxRevealDelay     = 1_000_000
+	qdayFinalizePerBlock   = 50
+	qdayCommitDomain       = "zetaphy/qday-commit\x00"
+)
+
+// ErrQDay is the error of every Q-day refusal (codespace "zetaphy", code 20).
+var ErrQDay = errorsmod.Register("zetaphy", 20, "Q-day")
+
+func (app *EVMD) qdayParams(ctx sdk.Context) (height, delay int64) {
+	v := app.secRaw(ctx).Get(qdayKey)
+	height, delay = int64(readU64(v)), QDayDefaultRevealDelay // #nosec G115 -- block heights
+	if len(v) == 16 && readU64(v[8:]) > 0 {
+		delay = int64(readU64(v[8:])) // #nosec G115 -- bounded by QDayMaxRevealDelay
+	}
+	return height, delay
+}
+
+// qdayActive: this block is at or after Q-day.
+func (app *EVMD) qdayActive(ctx sdk.Context) bool {
+	h, _ := app.qdayParams(ctx)
+	return h > 0 && ctx.BlockHeight() >= h
+}
+
+func (app *EVMD) setQDay(ctx sdk.Context, m *MsgSetQDay) (gogoproto.Message, error) {
+	if m.Authority != govAuthority() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can schedule Q-day")
+	}
+	if m.Height != 0 && int64(m.Height) <= ctx.BlockHeight() { // #nosec G115 -- compared, not stored
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "Q-day must be a future block (now %d), or 0 to unschedule it", ctx.BlockHeight())
+	}
+	delay := m.RevealDelay
+	if delay == 0 {
+		delay = QDayDefaultRevealDelay
+	}
+	if delay < QDayMinRevealDelay || delay > QDayMaxRevealDelay {
+		return nil, errorsmod.Wrapf(errortypes.ErrInvalidRequest, "reveal_delay: %d to %d blocks", QDayMinRevealDelay, QDayMaxRevealDelay)
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(qdayKey, append(u64(m.Height), u64(delay)...))
+	app.setPQLockSlot(ctx, evmtypes.QDaySlot, m.Height)
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_qday", sdk.NewAttribute("height", fmt.Sprint(m.Height)), sdk.NewAttribute("reveal_delay", fmt.Sprint(delay))))
+	return &MsgPQResponse{}, nil
+}
+
+// QDayRevealText is what the old key signs (EIP-191 personal_sign) to move
+// its account to an ML-DSA-44 controller.
+func QDayRevealText(chainID string, owner, controller common.Address) string {
+	return "ZETAPHY Q-day migration\nChain: " + chainID + "\nAccount: " + owner.Hex() +
+		"\nNew ML-DSA-44 controller: " + controller.Hex() + "\nSign this only in the ZETAPHY wallet."
+}
+
+// QDayCommitment is sha256(domain || chain id || 0 || compressed secp256k1
+// public key (33) || controller (20) || salt (32)).
+func QDayCommitment(chainID string, pub33 []byte, controller common.Address, salt []byte) []byte {
+	h := sha256.New()
+	h.Write([]byte(qdayCommitDomain + chainID + "\x00"))
+	h.Write(pub33)
+	h.Write(controller.Bytes())
+	h.Write(salt)
+	return h.Sum(nil)
+}
+
+func qdayCommitKey(c []byte) []byte  { return append([]byte{qdayCommitPfx}, c...) }
+func qdayPendingKey(o []byte) []byte { return append([]byte{qdayPendingPfx}, o...) }
+func qdayQueueKey(final int64, owner []byte) []byte {
+	return append(append([]byte{qdayQueuePfx}, u64(uint64(final))...), owner...) // #nosec G115 -- block heights
+}
+
+func (app *EVMD) qdayCommit(ctx sdk.Context, m *MsgQDayCommit) (gogoproto.Message, error) {
+	if !app.secV3(ctx) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "the security core is not active on this chain yet")
+	}
+	if len(m.Commitment) != 32 {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "commitment: 32 bytes (sha256)")
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if st.Has(qdayCommitKey(m.Commitment)) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "this commitment is already recorded")
+	}
+	st.Set(qdayCommitKey(m.Commitment), u64(uint64(ctx.BlockHeight()))) // #nosec G115 -- block heights
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_qday_commit", sdk.NewAttribute("commitment", fmt.Sprintf("%x", m.Commitment)), sdk.NewAttribute("height", fmt.Sprint(ctx.BlockHeight()))))
+	return &MsgPQResponse{}, nil
+}
+
+// qdayPending: commit height, final height (when it becomes a lock), controller of a pending migration.
+func (app *EVMD) qdayPending(ctx sdk.Context, owner []byte) (commitH, finalH int64, ctrl []byte, ok bool) {
+	v := ctx.KVStore(app.GetKey(pqStoreKey)).Get(qdayPendingKey(owner))
+	if len(v) != 36 {
+		return 0, 0, nil, false
+	}
+	return int64(readU64(v)), int64(readU64(v[8:])), v[16:], true // #nosec G115 -- block heights
+}
+
+// qdayExposed: the account's ECDSA public key has been seen on chain (it
+// signed a Cosmos or EVM tx, or a signature ecrecover checked).
+func (app *EVMD) qdayExposed(ctx sdk.Context, owner sdk.AccAddress) bool {
+	if acc := app.AccountKeeper.GetAccount(ctx, owner); acc != nil && (acc.GetPubKey() != nil || acc.GetSequence() > 0) {
+		return true
+	}
+	return app.EVMKeeper.GetState(ctx, PQLockAddress, evmtypes.ExposedSlot(common.BytesToAddress(owner))) != (common.Hash{})
+}
+
+func (app *EVMD) qdayReveal(ctx sdk.Context, m *MsgQDayReveal) (gogoproto.Message, error) {
+	if !app.qdayActive(ctx) {
+		return nil, errorsmod.Wrap(ErrQDay, "the commit–reveal migration opens at Q-day; before it, quantum-lock the account from its own wallet")
+	}
+	_, delay := app.qdayParams(ctx)
+	owner, err := pqAddr(m.Owner)
+	if err != nil {
+		return nil, err
+	}
+	ctrl, err := pqAddr(m.Controller)
+	if err != nil {
+		return nil, err
+	}
+	if len(m.Salt) != 32 || len(m.Signature) != 65 {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "salt: 32 bytes; signature: 65 bytes (r, s, v)")
+	}
+	sig := bytes.Clone(m.Signature)
+	if sig[64] >= 27 {
+		sig[64] -= 27
+	}
+	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:64])
+	if sig[64] > 1 || !crypto.ValidateSignatureValues(sig[64], r, s, true) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "signature: not a valid secp256k1 signature")
+	}
+	ownerHex, ctrlHex := common.BytesToAddress(owner), common.BytesToAddress(ctrl)
+	pub, err := crypto.SigToPub(accounts.TextHash([]byte(QDayRevealText(ctx.ChainID(), ownerHex, ctrlHex))), sig)
+	if err != nil || crypto.PubkeyToAddress(*pub) != ownerHex {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "signature: not made by the owner's key over the migration text")
+	}
+	if app.pqController(ctx, owner) != nil {
+		return nil, errorsmod.Wrap(ErrQDay, "this account is migrated already")
+	}
+	if acc := app.AccountKeeper.GetAccount(ctx, owner); acc != nil {
+		if _, ok := acc.GetPubKey().(*mldsa44.PubKey); ok {
+			return nil, errorsmod.Wrap(ErrQDay, "an ML-DSA-44 account is post-quantum already")
+		}
+	}
+	if err := app.checkPQController(ctx, owner, ctrl); err != nil {
+		return nil, err
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	ck := qdayCommitKey(QDayCommitment(ctx.ChainID(), crypto.CompressPubkey(pub), ctrlHex, m.Salt))
+	cv := st.Get(ck)
+	if len(cv) != 8 {
+		return nil, errorsmod.Wrap(ErrQDay, "no commitment matches this reveal (commit first, from the new account)")
+	}
+	commitH := int64(readU64(cv)) // #nosec G115 -- block heights
+	if commitH+delay > ctx.BlockHeight() {
+		return nil, errorsmod.Wrapf(ErrQDay, "the commitment is too recent: reveal from block %d", commitH+delay)
+	}
+	if pc, _, _, ok := app.qdayPending(ctx, owner); ok {
+		if commitH >= pc {
+			return nil, errorsmod.Wrap(ErrQDay, "a migration of this account from an older commitment is pending")
+		}
+	} else if app.qdayExposed(ctx, owner) {
+		return nil, errorsmod.Wrap(ErrQDay, "this account's public key was used on chain before Q-day, so it cannot migrate by commit–reveal; it stays frozen unless governance decides otherwise")
+	}
+	st.Delete(ck)
+	final := ctx.BlockHeight() + delay
+	st.Set(qdayPendingKey(owner), append(append(u64(uint64(commitH)), u64(uint64(final))...), ctrl...)) // #nosec G115 -- block heights
+	st.Set(qdayQueueKey(final, owner), []byte{})
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_qday_reveal", sdk.NewAttribute("owner", owner.String()),
+		sdk.NewAttribute("controller", ctrl.String()), sdk.NewAttribute("commit_height", fmt.Sprint(commitH)), sdk.NewAttribute("final_height", fmt.Sprint(final))))
+	return &MsgPQResponse{}, nil
+}
+
+// qdayFinalize turns pending migrations whose contest window is over into
+// quantum locks.
+func (app *EVMD) qdayFinalize(ctx sdk.Context) {
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	it := st.Iterator([]byte{qdayQueuePfx}, qdayQueueKey(ctx.BlockHeight()+1, nil))
+	var done [][]byte
+	for ; it.Valid() && len(done) < qdayFinalizePerBlock; it.Next() {
+		done = append(done, bytes.Clone(it.Key()))
+	}
+	_ = it.Close()
+	for _, k := range done {
+		st.Delete(k)
+		owner := k[9:]
+		_, finalH, ctrl, ok := app.qdayPending(ctx, owner)
+		if !ok || finalH != int64(readU64(k[1:9])) { // #nosec G115 -- block heights
+			continue // replaced by a reveal from an older commitment: its own entry finalizes it
+		}
+		st.Delete(qdayPendingKey(owner))
+		if app.pqController(ctx, owner) == nil {
+			app.applyQuantumLock(ctx, owner, ctrl)
+			ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_qday_migrated", sdk.NewAttribute("owner", sdk.AccAddress(owner).String()), sdk.NewAttribute("controller", sdk.AccAddress(ctrl).String())))
+		}
+	}
+}
+
+// pqIsPQKey: an ML-DSA-44 key, or a multisig of ML-DSA-44 keys only.
+func pqIsPQKey(pk cryptotypes.PubKey) bool {
+	switch k := pk.(type) {
+	case *mldsa44.PubKey:
+		return true
+	case *multisig.LegacyAminoPubKey:
+		for _, sub := range k.GetPubKeys() {
+			if !pqIsPQKey(sub) {
+				return false
+			}
+		}
+		return len(k.GetPubKeys()) > 0
+	}
+	return false
+}
+
+// qdayCheckTx is the Q-day rule in the ante handler (after the normal
+// checks, so every signer's public key is on its account).
+func (app *EVMD) qdayCheckTx(ctx sdk.Context, tx sdk.Tx) error {
+	q, _ := app.qdayParams(ctx)
+	msgs := append([]sdk.Msg{}, tx.GetMsgs()...)
+	for i := 0; i < len(msgs); i++ {
+		switch m := msgs[i].(type) {
+		case *evmtypes.MsgEthereumTx:
+			return errorsmod.Wrapf(ErrQDay, "Q-day (block %d) has passed: Ethereum transactions are signed with ECDSA and are no longer accepted; a migrated account acts through its ML-DSA-44 controller (MsgEVMCall as_owner)", q)
+		case *authz.MsgExec:
+			inner, err := m.GetMessages()
+			if err != nil {
+				return err
+			}
+			msgs = append(msgs, inner...)
+		}
+	}
+	st, ok := tx.(authsigning.SigVerifiableTx)
+	if !ok {
+		return nil
+	}
+	signers, err := st.GetSigners()
+	if err != nil {
+		return err
+	}
+	for _, s := range signers {
+		acc := app.AccountKeeper.GetAccount(ctx, s)
+		if acc == nil || !pqIsPQKey(acc.GetPubKey()) {
+			return errorsmod.Wrapf(ErrQDay, "Q-day (block %d) has passed: %s signs with an ECDSA key, which is no longer accepted. A migrated account acts through its ML-DSA-44 controller; an account whose key was never used on chain can still migrate by commit–reveal; others stay frozen", q, sdk.AccAddress(s))
+		}
+	}
+	return nil
+}
diff --git a/evmd/zetaphy_random.go b/evmd/zetaphy_random.go
new file mode 100644
index 0000000..81a5fff
--- /dev/null
+++ b/evmd/zetaphy_random.go
@@ -0,0 +1,137 @@
+package evmd
+
+// ZETAPHY: block.prevrandao (PREVRANDAO) that a transaction sender cannot
+// predict. Upstream cosmos/evm returns a constant there.
+//
+// For block N, set in PreBlocker before any transaction of N runs:
+//
+//	certificate mode (the post-quantum vote certificate for N-1 is in N and
+//	was verified, zetaphy_pqcert.go):
+//	  sha256("zetaphy.prevrandao.v1" || 0 || chain-id || 0 || N (8 bytes) ||
+//	         0x01 || certified height N-1 (8 bytes) || attestations)
+//	fallback (no vote extensions, no registered keys, block 1, state restored):
+//	  sha256("zetaphy.prevrandao.v1" || 0 || chain-id || 0 || N (8 bytes) ||
+//	         0x00 || hash of block N-1, when known)
+//
+// The attestations are the certificate's canonical bytes: entries of
+// validator address (20) || ML-DSA-44 signature over (chain id, N-1, hash of
+// N-1), sorted by address, each verified. They are only known once the
+// validators have precommitted N-1, and need the validators' secret keys.
+//
+// What remains (see zetaphy-chain/README.md and docs/CHAIN_AUDIT_SCOPE.md):
+//   - Validators can bias it. ML-DSA is not a unique signature: a signer can
+//     make many valid signatures for the same block. The proposer of N can
+//     re-sign its own entry and choose which entries above the 2/3 threshold
+//     to include, so it can try many values within the block time and pick
+//     one. Each other signer can do the same with its own entry before it
+//     precommits. It is unpredictable for users, not unbiasable by validators.
+//   - Vote extensions travel with the precommits for N-1, so a node that
+//     watches the votes can usually compute N's value during timeout_commit,
+//     before N is proposed. Contracts must take the value of a block after
+//     the one that fixed the bet (commit first, draw in a later block).
+//   - Fallback mode is predictable by anyone once N-1 is committed; it only
+//     guarantees the value changes every block.
+//
+// Queries: the store holds the value of the last finalized block. eth_call,
+// eth_estimateGas and CheckTx run on the latest committed block N and see N's
+// value; the transaction then runs in a later block with that block's value.
+// A context for a height without a stored value (e.g. replaying a block in a
+// trace on the state before it) gets a fallback without the previous hash.
+
+import (
+	"crypto/sha256"
+	"encoding/binary"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/crypto"
+	ethparams "github.com/ethereum/go-ethereum/params"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+)
+
+var pqRandaoKey = []byte{7} // height (8 bytes) || prevrandao of that block
+
+const prevRandaoTag = "zetaphy.prevrandao.v1"
+
+// PrevRandao computes the value above. cert is nil in fallback mode; prevHash
+// may be nil there.
+func PrevRandao(chainID string, height int64, cert *MsgPQCertificate, prevHash []byte) common.Hash {
+	h := sha256.New()
+	h.Write([]byte(prevRandaoTag))
+	h.Write([]byte{0})
+	h.Write([]byte(chainID))
+	h.Write([]byte{0})
+	h.Write(binary.BigEndian.AppendUint64(nil, uint64(height))) // #nosec G115 -- block heights
+	if cert != nil {
+		h.Write([]byte{1})
+		h.Write(binary.BigEndian.AppendUint64(nil, cert.Height))
+		h.Write(cert.Attestations)
+	} else {
+		h.Write([]byte{0})
+		h.Write(prevHash)
+	}
+	return common.BytesToHash(h.Sum(nil))
+}
+
+// setPrevRandao stores block height's value; it runs in PreBlocker, after the
+// certificate was checked and before the hash of height-1 is replaced. Before
+// the v2 activation height (zetaphy_upgrade.go) it stores nothing.
+func (app *EVMD) setPrevRandao(ctx sdk.Context, height int64, cert *MsgPQCertificate) {
+	if !app.zetaphyV2(ctx, height) {
+		return
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	var prevHash []byte
+	if cert == nil {
+		if last := st.Get(pqLastBlockKey); len(last) == 8+32 && int64(binary.BigEndian.Uint64(last)) == height-1 { // #nosec G115 -- block heights
+			prevHash = last[8:]
+		}
+	}
+	r := PrevRandao(ctx.ChainID(), height, cert, prevHash)
+	st.Set(pqRandaoKey, append(binary.BigEndian.AppendUint64(nil, uint64(height)), r.Bytes()...)) // #nosec G115 -- block heights
+}
+
+// prevRandao is the EVM keeper's source of block.prevrandao. It reads the
+// store without gas, so EVM gas use does not change. Before the v2
+// activation height it is upstream's constant 0xff…ff.
+func (app *EVMD) prevRandao(ctx sdk.Context) common.Hash {
+	if !app.zetaphyV2(ctx, ctx.BlockHeight()) {
+		return common.MaxHash
+	}
+	v := ctx.MultiStore().GetKVStore(app.GetKey(pqStoreKey)).Get(pqRandaoKey)
+	if len(v) == 8+32 && int64(binary.BigEndian.Uint64(v)) == ctx.BlockHeight() { // #nosec G115 -- block heights
+		return common.BytesToHash(v[8:])
+	}
+	return PrevRandao(ctx.ChainID(), ctx.BlockHeight(), nil, nil)
+}
+
+// ensureBlockHashHistory: BLOCKHASH(n) for the last 256 blocks reads the
+// hashes cosmos/evm keeps in the storage of the EIP-2935 history contract,
+// but only while that contract exists, and `zetaphyd init` writes a genesis
+// without it, so BLOCKHASH returned 0. From the v2 activation height it is
+// installed at the start of the first block that lacks it, before the EVM
+// module records the block's hash (at the end of the block). An account
+// already at that address (e.g. someone sent coins there) keeps its balance
+// and gets the code.
+//
+// The code is geth's: get(n) reads slot n % 8191 and serves the last 8191
+// blocks. The EVM keeper writes the hash of block n to slot
+// n % HistoryServeWindow, which is 8191 by default (x/vm/types/params.go) and
+// set to 8191 by the zetaphy-v2 upgrade. Governance must not change that
+// parameter while this code is installed.
+func (app *EVMD) ensureBlockHashHistory(ctx sdk.Context) {
+	addr := ethparams.HistoryStorageAddress
+	if !app.zetaphyV2(ctx, ctx.BlockHeight()) || app.EVMKeeper.IsContract(ctx, addr) {
+		return
+	}
+	code := ethparams.HistoryStorageCode
+	hash := crypto.Keccak256(code)
+	cctx, write := ctx.CacheContext()
+	acc := sdk.AccAddress(addr.Bytes())
+	if app.AccountKeeper.GetAccount(cctx, acc) == nil {
+		app.AccountKeeper.SetAccount(cctx, app.AccountKeeper.NewAccountWithAddress(cctx, acc))
+	}
+	app.EVMKeeper.SetCodeHash(cctx, addr.Bytes(), hash)
+	app.EVMKeeper.SetCode(cctx, hash, code)
+	write()
+}
diff --git a/evmd/zetaphy_rpc.go b/evmd/zetaphy_rpc.go
new file mode 100644
index 0000000..aeeba44
--- /dev/null
+++ b/evmd/zetaphy_rpc.go
@@ -0,0 +1,528 @@
+package evmd
+
+// ZETAPHY JSON-RPC namespace "zetaphy" on the public EVM endpoint (8545),
+// so wallets can use post-quantum (ML-DSA-44) accounts without any other
+// port being open:
+//
+//	zetaphy_pqAccount(address)  account number and sequence to sign with
+//	zetaphy_sendCosmosTx(0x…)   broadcast a signed Cosmos tx (CheckTx only)
+//	zetaphy_faucet(address)     testnet only: a little ZETAPHY for newcomers
+//	zetaphy_faucetPow(address, height, nonce), zetaphy_faucetPowInfo():
+//	                            the same faucet behind a browser proof of
+//	                            work (zetaphy_faucetpow.go)
+//	zetaphy_securityStatus, zetaphy_migration, zetaphy_qdayCommitment,
+//	zetaphy_consent, zetaphy_ibcHolds: the security core (end of this file)
+//	zetaphy_modelAt(height)     v5: the Neuro model version in force at a
+//	                            height (zetaphy_modelat.go)
+//
+// The first two hold no keys: like eth_sendRawTransaction, sendCosmosTx only
+// passes on bytes the user already signed. The faucet signs with its own key
+// (<home>/config/faucet.key, a capped testnet balance) and is off without it.
+
+import (
+	"context"
+	"crypto/ecdsa"
+	"encoding/json"
+	"fmt"
+	"math/big"
+	"net"
+	"os"
+	"path/filepath"
+	"strings"
+	"sync"
+	"time"
+
+	abci "github.com/cometbft/cometbft/abci/types"
+	channeltypes "github.com/cosmos/ibc-go/v11/modules/core/04-channel/types"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/crypto"
+	gethrpc "github.com/ethereum/go-ethereum/rpc"
+	"google.golang.org/grpc/codes"
+	"google.golang.org/grpc/status"
+	"google.golang.org/protobuf/encoding/protowire"
+
+	evmrpc "github.com/cosmos/evm/rpc"
+	"github.com/cosmos/evm/rpc/backend"
+	"github.com/cosmos/evm/rpc/stream"
+	rpctypes "github.com/cosmos/evm/rpc/types"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
+	"github.com/cosmos/cosmos-sdk/server"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+)
+
+const (
+	ZetaphyNamespace = "zetaphy"
+	maxCosmosTxBytes = 64 * 1024
+)
+
+func init() {
+	if err := evmrpc.RegisterAPINamespace(ZetaphyNamespace, func(_ *server.Context, clientCtx client.Context, _ *stream.RPCStream, b backend.BackendI) []gethrpc.API {
+		return []gethrpc.API{{Namespace: ZetaphyNamespace, Version: "1.0", Service: &ZetaphyAPI{clientCtx: clientCtx, backend: b}, Public: true}}
+	}); err != nil {
+		panic(err)
+	}
+}
+
+// ZetaphyAPI is the "zetaphy" JSON-RPC service.
+type ZetaphyAPI struct {
+	clientCtx client.Context
+	backend   backend.BackendI
+}
+
+// PQAccount is what a wallet needs to sign a transaction for an account.
+type PQAccount struct {
+	Address       string  `json:"address"`
+	Hex           string  `json:"hex"`
+	ChainID       string  `json:"chainId"`
+	Denom         string  `json:"denom"`
+	Exists        bool    `json:"exists"`
+	AccountNumber *string `json:"accountNumber"`
+	Sequence      *string `json:"sequence"`
+	PubKeyType    *string `json:"pubKeyType"`
+	LockedTo      *string `json:"quantumLockedTo"`
+}
+
+func parseAccount(s string) (sdk.AccAddress, error) {
+	s = strings.TrimSpace(s)
+	if common.IsHexAddress(s) {
+		return sdk.AccAddress(common.HexToAddress(s).Bytes()), nil
+	}
+	return sdk.AccAddressFromBech32(s)
+}
+
+// PqAccount (zetaphy_pqAccount) returns the account number and sequence of
+// an account, given as zetaphy1… or 0x….
+func (a *ZetaphyAPI) PqAccount(ctx context.Context, address string) (*PQAccount, error) {
+	addr, err := parseAccount(address)
+	if err != nil {
+		return nil, fmt.Errorf("invalid address: %w", err)
+	}
+	out := &PQAccount{
+		Address: addr.String(),
+		Hex:     common.BytesToAddress(addr).Hex(),
+		ChainID: a.clientCtx.ChainID,
+		Denom:   evmtypes.GetEVMCoinDenom(),
+	}
+	if c, _, err := a.clientCtx.QueryStore(pqLockKey(addr), pqStoreKey); err == nil && len(c) == 20 {
+		locked := sdk.AccAddress(c).String()
+		out.LockedTo = &locked
+	}
+	res, err := authtypes.NewQueryClient(a.clientCtx).Account(ctx, &authtypes.QueryAccountRequest{Address: out.Address})
+	if status.Code(err) == codes.NotFound {
+		return out, nil
+	}
+	if err != nil {
+		return nil, err
+	}
+	var acc sdk.AccountI
+	if err := a.clientCtx.InterfaceRegistry.UnpackAny(res.Account, &acc); err != nil {
+		return nil, err
+	}
+	num, seq := fmt.Sprint(acc.GetAccountNumber()), fmt.Sprint(acc.GetSequence())
+	out.Exists, out.AccountNumber, out.Sequence = true, &num, &seq
+	if pk := acc.GetPubKey(); pk != nil {
+		t := pk.Type()
+		out.PubKeyType = &t
+	}
+	return out, nil
+}
+
+// CosmosTxResult is the CheckTx outcome of a broadcast.
+type CosmosTxResult struct {
+	TxHash string `json:"txHash"`
+	Code   uint32 `json:"code"`
+	Log    string `json:"log"`
+}
+
+// SendCosmosTx (zetaphy_sendCosmosTx) broadcasts signed TxRaw bytes and
+// returns the CheckTx result. EVM transactions go through eth_sendRawTransaction.
+func (a *ZetaphyAPI) SendCosmosTx(txBytes hexutil.Bytes) (*CosmosTxResult, error) {
+	if len(txBytes) == 0 || len(txBytes) > maxCosmosTxBytes {
+		return nil, fmt.Errorf("tx must be 1 to %d bytes", maxCosmosTxBytes)
+	}
+	tx, err := a.clientCtx.TxConfig.TxDecoder()(txBytes)
+	if err != nil {
+		return nil, fmt.Errorf("not a Cosmos transaction: %w", err)
+	}
+	// EVM txs go through eth_sendRawTransaction, which enforces EIP-155
+	// replay protection; they must not get around it here.
+	if ext, ok := tx.(interface{ GetExtensionOptions() []*codectypes.Any }); ok && len(ext.GetExtensionOptions()) > 0 {
+		return nil, fmt.Errorf("EVM transactions must use eth_sendRawTransaction")
+	}
+	for _, m := range tx.GetMsgs() {
+		if _, ok := m.(*evmtypes.MsgEthereumTx); ok {
+			return nil, fmt.Errorf("EVM transactions must use eth_sendRawTransaction")
+		}
+	}
+	res, err := a.clientCtx.BroadcastTxSync(txBytes)
+	if err != nil {
+		return nil, err
+	}
+	return &CosmosTxResult{TxHash: res.TxHash, Code: res.Code, Log: res.RawLog}, nil
+}
+
+// ---- faucet (testnet) ----------------------------------------------------
+
+const (
+	FaucetPerDay   = 200 // grants per UTC day, all addresses together
+	faucetCooldown = 24 * time.Hour
+)
+
+// FaucetAmount is 10 ZETAPHY: gas for many txs and a node runner's bond.
+var FaucetAmount = new(big.Int).Mul(big.NewInt(10), big.NewInt(1e18))
+
+// One faucet per process (the HTTP and WebSocket servers share it).
+var faucet struct {
+	sync.Mutex
+	key   *ecdsa.PrivateKey
+	nonce uint64 // next nonce; the node's pending count can lag a just-sent tx
+	day   int64
+	count int
+	last  map[common.Address]time.Time
+	// zetaphy_faucetPow: (address, height) pairs whose proof got a grant, by height
+	powUsed map[powUse]uint64
+}
+
+type FaucetResult struct {
+	TxHash string       `json:"txHash"`
+	Amount *hexutil.Big `json:"amount"`
+}
+
+func (a *ZetaphyAPI) faucetKey() (*ecdsa.PrivateKey, error) {
+	if faucet.key != nil {
+		return faucet.key, nil
+	}
+	raw, err := os.ReadFile(filepath.Join(a.clientCtx.HomeDir, "config", "faucet.key"))
+	if err != nil {
+		return nil, fmt.Errorf("the faucet is off on this node")
+	}
+	key, err := crypto.HexToECDSA(strings.TrimPrefix(strings.TrimSpace(string(raw)), "0x"))
+	if err != nil {
+		return nil, fmt.Errorf("the faucet key is unreadable")
+	}
+	faucet.key = key
+	return key, nil
+}
+
+// Faucet (zetaphy_faucet) sends FaucetAmount to a new address (zetaphy1… or
+// 0x…): once per address per day, FaucetPerDay times per day in all, and
+// never to an address that already holds that much.
+func (a *ZetaphyAPI) Faucet(ctx context.Context, address string) (*FaucetResult, error) {
+	addr, err := parseAccount(address)
+	if err != nil {
+		return nil, fmt.Errorf("invalid address: %w", err)
+	}
+	to := common.BytesToAddress(addr)
+	if err := faucetPeerOK(ctx); err != nil {
+		return nil, err
+	}
+	faucet.Lock()
+	defer faucet.Unlock()
+	return a.faucetGrant(ctx, to)
+}
+
+// faucetNow is the faucet's clock (tests move it).
+var faucetNow = time.Now
+
+// faucetPeerOK: the faucet answers only through this machine (rpc-guard
+// behind Caddy counts calls per IP): not over websocket, not from another
+// machine straight to 8545.
+func faucetPeerOK(ctx context.Context) error {
+	if p := gethrpc.PeerInfoFromContext(ctx); p.Transport != "http" || !loopbackPeer(p.RemoteAddr) {
+		return fmt.Errorf("the faucet answers only through this node's https address")
+	}
+	return nil
+}
+
+// faucetDay starts a new UTC day's count when the day changed (faucet locked).
+func faucetDay(now time.Time) {
+	if d := now.Unix() / 86400; d != faucet.day {
+		faucet.day, faucet.count = d, 0
+	}
+}
+
+// faucetGrant: the limits every faucet method shares (FaucetPerDay grants a
+// UTC day in all, one grant per address per faucetCooldown, nothing for an
+// address that already holds FaucetAmount), then the transfer. The caller
+// holds faucet's lock.
+func (a *ZetaphyAPI) faucetGrant(ctx context.Context, to common.Address) (*FaucetResult, error) {
+	key, err := a.faucetKey()
+	if err != nil {
+		return nil, err
+	}
+	now := faucetNow().UTC()
+	faucetDay(now)
+	if faucet.last == nil || len(faucet.last) > 100000 {
+		faucet.last = map[common.Address]time.Time{}
+	}
+	if faucet.count >= FaucetPerDay {
+		return nil, fmt.Errorf("the faucet has given out today's %d grants; try again tomorrow (UTC)", FaucetPerDay)
+	}
+	if t, ok := faucet.last[to]; ok && now.Sub(t) < faucetCooldown {
+		return nil, fmt.Errorf("this address got ZETAPHY less than a day ago")
+	}
+	if bal, err := a.backend.GetBalance(ctx, to, rpctypes.BlockNumberOrHash{BlockNumber: ptr(rpctypes.EthLatestBlockNumber)}); err == nil && bal.ToInt().Cmp(FaucetAmount) >= 0 {
+		return nil, fmt.Errorf("this address already has ZETAPHY")
+	}
+	from := crypto.PubkeyToAddress(key.PublicKey)
+	pending, err := a.backend.GetTransactionCount(ctx, from, rpctypes.EthPendingBlockNumber)
+	if err != nil {
+		return nil, err
+	}
+	nonce := max(uint64(*pending), faucet.nonce)
+	price, err := a.backend.GasPrice(ctx)
+	if err != nil {
+		return nil, err
+	}
+	gasPrice := new(big.Int).Mul(price.ToInt(), big.NewInt(2))
+	tx := ethtypes.NewTransaction(nonce, to, FaucetAmount, 21000, gasPrice, nil)
+	signed, err := ethtypes.SignTx(tx, ethtypes.LatestSignerForChainID(a.backend.ChainConfig().ChainID), key)
+	if err != nil {
+		return nil, err
+	}
+	raw, err := signed.MarshalBinary()
+	if err != nil {
+		return nil, err
+	}
+	hash, err := a.backend.SendRawTransaction(ctx, raw)
+	if err != nil {
+		faucet.nonce = 0 // ask the node again next time
+		return nil, fmt.Errorf("faucet: %w", err)
+	}
+	faucet.nonce = nonce + 1
+	faucet.count++
+	faucet.last[to] = now
+	return &FaucetResult{TxHash: hash.Hex(), Amount: (*hexutil.Big)(FaucetAmount)}, nil
+}
+
+func ptr[T any](v T) *T { return &v }
+
+func loopbackPeer(addr string) bool {
+	host, _, err := net.SplitHostPort(addr)
+	if err != nil {
+		host = addr
+	}
+	ip := net.ParseIP(host)
+	return ip != nil && ip.IsLoopback()
+}
+
+// ---- security core (zetaphy_security.go) ---------------------------------
+//
+//	zetaphy_securityStatus()             Q-day, threat gate, IBC hold settings
+//	zetaphy_migration(address)           is the account migrated / pending / exposed
+//	zetaphy_qdayCommitment(0x…32 bytes)  the block a commitment was recorded in
+//	zetaphy_consent(account, target)     until when account consented to target
+//	zetaphy_ibcHolds()                   the inbound IBC transfers waiting
+
+func (a *ZetaphyAPI) secGet(key []byte) []byte {
+	v, _, err := a.clientCtx.QueryStore(key, pqStoreKey)
+	if err != nil {
+		return nil
+	}
+	return v
+}
+
+type secPair struct{ Key, Value []byte }
+
+// secPairs: a store "subspace" query (kv.Pairs: repeated Pair{key = 1, value = 2}).
+func (a *ZetaphyAPI) secPairs(prefix []byte) []secPair {
+	res, err := a.clientCtx.QueryABCI(abci.RequestQuery{Path: "/store/" + pqStoreKey + "/subspace", Data: prefix})
+	if err != nil {
+		return nil
+	}
+	var out []secPair
+	b := res.Value
+	for len(b) > 0 {
+		num, typ, n := protowire.ConsumeTag(b)
+		if n < 0 || num != 1 || typ != protowire.BytesType {
+			return out
+		}
+		pair, m := protowire.ConsumeBytes(b[n:])
+		if m < 0 {
+			return out
+		}
+		b = b[n+m:]
+		var p secPair
+		for len(pair) > 0 {
+			f, t, k := protowire.ConsumeTag(pair)
+			if k < 0 || t != protowire.BytesType {
+				break
+			}
+			v, l := protowire.ConsumeBytes(pair[k:])
+			if l < 0 {
+				break
+			}
+			if f == 1 {
+				p.Key = v
+			} else if f == 2 {
+				p.Value = v
+			}
+			pair = pair[k+l:]
+		}
+		out = append(out, p)
+	}
+	return out
+}
+
+type SecurityStatus struct {
+	SecurityCoreFrom   uint64        `json:"securityCoreFrom"`
+	SecurityPrecompile string        `json:"securityPrecompile"`
+	QDayHeight         uint64        `json:"qdayHeight"`
+	RevealDelay        uint64        `json:"revealDelay"`
+	LatestHeight       uint64        `json:"latestHeight"`
+	QDayActive         bool          `json:"qdayActive"`
+	ThreatRegistry     string        `json:"threatRegistry"`
+	ThreatGateOn       bool          `json:"threatGateEnabled"`
+	MaxConsentSeconds  uint64        `json:"maxConsentSeconds"`
+	IBCHoldDelay       uint64        `json:"ibcHoldDelaySeconds"`
+	IBCHoldGuardian    string        `json:"ibcHoldGuardian"`
+	IBCHoldRules       []IBCHoldRule `json:"ibcHoldRules"`
+}
+
+type IBCHoldRule struct {
+	Denom     string `json:"denom"`
+	MinAmount string `json:"minAmount"`
+	SupplyBps uint64 `json:"supplyBps"`
+}
+
+// SecurityStatus (zetaphy_securityStatus).
+func (a *ZetaphyAPI) SecurityStatus(ctx context.Context) (*SecurityStatus, error) {
+	out := &SecurityStatus{SecurityPrecompile: SecurityPrecompileAddress.Hex(), MaxConsentSeconds: MaxConsentSeconds,
+		RevealDelay: QDayDefaultRevealDelay, IBCHoldDelay: IBCHoldDefaultDelay, IBCHoldRules: []IBCHoldRule{}}
+	out.SecurityCoreFrom = readU64(a.secGet(secV3Key))
+	if q := a.secGet(qdayKey); len(q) == 16 {
+		out.QDayHeight = readU64(q)
+		if d := readU64(q[8:]); d > 0 {
+			out.RevealDelay = d
+		}
+	}
+	if n, err := a.backend.BlockNumber(ctx); err == nil {
+		out.LatestHeight = uint64(n)
+	}
+	out.QDayActive = out.QDayHeight > 0 && out.LatestHeight+1 >= out.QDayHeight
+	if g := a.secGet(gateKey); len(g) == 21 {
+		out.ThreatRegistry = common.BytesToAddress(g[:20]).Hex()
+		out.ThreatGateOn = g[20] == 1
+	}
+	if h := a.secGet(holdParamsKey); len(h) >= 8 {
+		out.IBCHoldDelay = readU64(h)
+		if len(h) == 28 {
+			out.IBCHoldGuardian = sdk.AccAddress(h[8:]).String()
+		}
+	}
+	for _, p := range a.secPairs([]byte{holdRulePfx}) {
+		if len(p.Key) > 1 && len(p.Value) >= 8 {
+			min := string(p.Value[8:])
+			if min == "" {
+				min = "0"
+			}
+			out.IBCHoldRules = append(out.IBCHoldRules, IBCHoldRule{Denom: string(p.Key[1:]), MinAmount: min, SupplyBps: readU64(p.Value)})
+		}
+	}
+	return out, nil
+}
+
+type Migration struct {
+	Address           string  `json:"address"`
+	Hex               string  `json:"hex"`
+	Migrated          bool    `json:"migrated"`
+	Controller        *string `json:"controller"`
+	PendingController *string `json:"pendingController"`
+	PendingCommit     uint64  `json:"pendingCommitHeight"`
+	PendingFinal      uint64  `json:"pendingFinalHeight"`
+	PostQuantum       bool    `json:"postQuantum"`
+	PubKeyType        *string `json:"pubKeyType"`
+	Exposed           bool    `json:"exposed"`
+	CanCommitReveal   bool    `json:"canCommitReveal"`
+}
+
+// Migration (zetaphy_migration): where an account stands for Q-day.
+func (a *ZetaphyAPI) Migration(ctx context.Context, address string) (*Migration, error) {
+	acc, err := a.PqAccount(ctx, address)
+	if err != nil {
+		return nil, err
+	}
+	addr := common.HexToAddress(acc.Hex)
+	out := &Migration{Address: acc.Address, Hex: acc.Hex, PubKeyType: acc.PubKeyType, Controller: acc.LockedTo, Migrated: acc.LockedTo != nil}
+	out.PostQuantum = acc.PubKeyType != nil && *acc.PubKeyType == "mldsa44"
+	if p := a.secGet(qdayPendingKey(addr.Bytes())); len(p) == 36 {
+		c := sdk.AccAddress(p[16:]).String()
+		out.PendingController, out.PendingCommit, out.PendingFinal = &c, readU64(p), readU64(p[8:])
+	}
+	out.Exposed = acc.PubKeyType != nil || (acc.Sequence != nil && *acc.Sequence != "0")
+	if !out.Exposed {
+		if v, err := a.backend.GetStorageAt(ctx, PQLockAddress, evmtypes.ExposedSlot(addr).Hex(), rpctypes.BlockNumberOrHash{BlockNumber: ptr(rpctypes.EthLatestBlockNumber)}); err == nil {
+			out.Exposed = common.BytesToHash(v) != (common.Hash{})
+		}
+	}
+	out.CanCommitReveal = !out.Migrated && !out.PostQuantum && (!out.Exposed || out.PendingController != nil)
+	return out, nil
+}
+
+type QDayCommitmentInfo struct {
+	Found  bool   `json:"found"`
+	Height uint64 `json:"height"`
+}
+
+// QdayCommitment (zetaphy_qdayCommitment).
+func (a *ZetaphyAPI) QdayCommitment(c hexutil.Bytes) (*QDayCommitmentInfo, error) {
+	if len(c) != 32 {
+		return nil, fmt.Errorf("a commitment is 32 bytes")
+	}
+	v := a.secGet(qdayCommitKey(c))
+	return &QDayCommitmentInfo{Found: len(v) == 8, Height: readU64(v)}, nil
+}
+
+type ConsentInfo struct {
+	Until uint64 `json:"until"`
+}
+
+// Consent (zetaphy_consent): until when (unix seconds) account consented to target.
+func (a *ZetaphyAPI) Consent(account, target string) (*ConsentInfo, error) {
+	acc, err := parseAccount(account)
+	if err != nil {
+		return nil, err
+	}
+	if !common.IsHexAddress(target) {
+		return nil, fmt.Errorf("target: a 0x address")
+	}
+	return &ConsentInfo{Until: readU64(a.secGet(consentKey(common.BytesToAddress(acc), common.HexToAddress(target))))}, nil
+}
+
+type IBCHoldInfo struct {
+	ID        uint64 `json:"id"`
+	Channel   string `json:"channel"`
+	Sequence  uint64 `json:"sequence"`
+	Denom     string `json:"denom"`
+	Amount    string `json:"amount"`
+	Sender    string `json:"sender"`
+	Receiver  string `json:"receiver"`
+	HeldAt    int64  `json:"heldAt"`
+	ReleaseAt int64  `json:"releaseAt"`
+	Stuck     string `json:"stuck,omitempty"`
+}
+
+// IbcHolds (zetaphy_ibcHolds): the inbound IBC transfers waiting (at most 200).
+func (a *ZetaphyAPI) IbcHolds() ([]IBCHoldInfo, error) {
+	out := []IBCHoldInfo{}
+	for _, p := range a.secPairs([]byte{holdPfx}) {
+		var h ibcHold
+		if json.Unmarshal(p.Value, &h) != nil {
+			continue
+		}
+		var pk channeltypes.Packet
+		_ = pk.Unmarshal(h.Packet)
+		out = append(out, IBCHoldInfo{ID: h.ID, Channel: h.Channel, Sequence: pk.Sequence, Denom: h.Denom, Amount: h.Amount,
+			Sender: h.Sender, Receiver: h.Receiver, HeldAt: h.HeldAt, ReleaseAt: h.ReleaseAt, Stuck: h.Stuck})
+		if len(out) == 200 {
+			break
+		}
+	}
+	return out, nil
+}
diff --git a/evmd/zetaphy_rpcguard.go b/evmd/zetaphy_rpcguard.go
new file mode 100644
index 0000000..2835e0e
--- /dev/null
+++ b/evmd/zetaphy_rpcguard.go
@@ -0,0 +1,421 @@
+package evmd
+
+// ZETAPHY: `zetaphyd rpc-guard`, a small filter between Caddy (the public
+// https door) and the node's own RPC servers. A caller on the internet can
+// use only what wallets and the ZETAPHY apps need:
+//
+//   - CometBFT RPC (Keplr, Leap, the explorer): the methods in cometMethods,
+//     asked as GET /<method>?… or as JSON-RPC POST (batches too). No
+//     websocket, no dump_consensus_state, net_info (peer IPs),
+//     unconfirmed_txs, genesis, unsafe_*.
+//   - EVM JSON-RPC: eth_*, net_*, web3_* and zetaphy_*. txpool_*, debug_*,
+//     admin_*, personal_* and the rest stay on the machine.
+//   - zetaphy_faucet: at most faucetPerDay calls a UTC day from one IP (an
+//     IPv6 /64 counts as one), on top of the node's own faucet limits.
+//   - zetaphy_faucetPow (the faucet behind a browser proof of work, the main
+//     guard there): at most faucetPowPerDay calls a UTC day from one IP.
+//     One faucet call (either method) per request.
+//   - everyone: at most perMinute requests a minute from one IP, and
+//     maxInFlight requests at a time in all.
+//
+// The request is decoded with encoding/json, as CometBFT and the EVM
+// JSON-RPC server decode it, so the method checked here is the method they
+// run. It listens on 127.0.0.1 only, and takes the caller's IP from
+// X-Forwarded-For only on connections from 127.0.0.1 (Caddy).
+
+import (
+	"bytes"
+	"encoding/json"
+	"fmt"
+	"io"
+	"net"
+	"net/http"
+	"net/http/httputil"
+	"net/url"
+	"strings"
+	"sync"
+	"time"
+
+	"github.com/spf13/cobra"
+)
+
+// CometBFT RPC methods open to the public (all read-only, except sending a
+// signed transaction).
+var cometMethods = map[string]bool{
+	"health": true, "status": true, "abci_info": true, "abci_query": true,
+	"block": true, "block_by_hash": true, "block_results": true, "blockchain": true,
+	"commit": true, "header": true, "header_by_hash": true,
+	"validators": true, "consensus_params": true,
+	"tx": true, "tx_search": true, "block_search": true,
+	"broadcast_tx_sync": true, "broadcast_tx_async": true, "check_tx": true,
+	"num_unconfirmed_txs": true,
+}
+
+// EVM JSON-RPC namespaces open to the public.
+var evmPrefixes = []string{"eth_", "net_", "web3_", "zetaphy_"}
+
+func evmMethodOK(m string) bool {
+	for _, p := range evmPrefixes {
+		if strings.HasPrefix(m, p) && len(m) > len(p) {
+			return true
+		}
+	}
+	return false
+}
+
+const (
+	guardBodyLimit  = 1 << 20 // as CometBFT's max_body_bytes and the EVM http-body-limit
+	guardMaxBatch   = 20
+	faucetMethod    = "zetaphy_faucet"
+	faucetPowMethod = "zetaphy_faucetPow"
+)
+
+// GuardConfig: what rpc-guard forwards where, and its limits.
+type GuardConfig struct {
+	Comet           string // CometBFT RPC, e.g. http://127.0.0.1:26657
+	EVM             string // EVM JSON-RPC, e.g. http://127.0.0.1:8545
+	PerMinute       int    // requests a minute from one IP (each side)
+	FaucetPerDay    int    // zetaphy_faucet calls a UTC day from one IP
+	FaucetPowPerDay int    // zetaphy_faucetPow calls a UTC day from one IP
+	MaxInFlight     int    // requests being answered at once (each side)
+}
+
+// Guard holds the counters shared by the two filters.
+type Guard struct {
+	cfg       GuardConfig
+	comet     *url.URL
+	evm       *url.URL
+	minute    *window
+	faucet    *window
+	faucetPow *window
+	now       func() time.Time
+}
+
+// NewGuard checks the backend addresses.
+func NewGuard(cfg GuardConfig) (*Guard, error) {
+	c, err := url.Parse(cfg.Comet)
+	if err != nil || c.Host == "" {
+		return nil, fmt.Errorf("--comet: an http://host:port address")
+	}
+	e, err := url.Parse(cfg.EVM)
+	if err != nil || e.Host == "" {
+		return nil, fmt.Errorf("--evm: an http://host:port address")
+	}
+	if cfg.PerMinute < 1 || cfg.FaucetPerDay < 0 || cfg.FaucetPowPerDay < 0 || cfg.MaxInFlight < 1 {
+		return nil, fmt.Errorf("limits must be positive")
+	}
+	return &Guard{
+		cfg: cfg, comet: c, evm: e,
+		minute:    newWindow(time.Minute, 200_000),
+		faucet:    newWindow(24*time.Hour, 200_000),
+		faucetPow: newWindow(24*time.Hour, 200_000),
+		now:       time.Now,
+	}, nil
+}
+
+// window counts calls per key in fixed periods (minute, UTC day). It holds
+// at most max keys; a new key past that is refused (no reset an attacker
+// with many addresses could force).
+type window struct {
+	mu     sync.Mutex
+	period time.Duration
+	max    int
+	start  time.Time
+	n      map[string]int
+}
+
+func newWindow(period time.Duration, max int) *window {
+	return &window{period: period, max: max, n: map[string]int{}}
+}
+
+func (w *window) allow(key string, limit int, now time.Time) bool {
+	w.mu.Lock()
+	defer w.mu.Unlock()
+	if start := now.UTC().Truncate(w.period); !start.Equal(w.start) {
+		w.start, w.n = start, map[string]int{}
+	}
+	c, seen := w.n[key]
+	if c >= limit || (!seen && len(w.n) >= w.max) {
+		return false
+	}
+	w.n[key] = c + 1
+	return true
+}
+
+// ClientKey: the caller's IP as rpc-guard counts it. Behind Caddy (a
+// connection from 127.0.0.1) it is the last X-Forwarded-For entry, the one
+// Caddy itself added; an IPv6 address counts as its /64.
+func ClientKey(r *http.Request) string {
+	host, _, err := net.SplitHostPort(r.RemoteAddr)
+	if err != nil {
+		host = r.RemoteAddr
+	}
+	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
+		if xff := r.Header.Values("X-Forwarded-For"); len(xff) > 0 {
+			parts := strings.Split(xff[len(xff)-1], ",")
+			if c := net.ParseIP(strings.TrimSpace(parts[len(parts)-1])); c != nil {
+				host = c.String()
+			}
+		}
+	}
+	ip := net.ParseIP(host)
+	if ip == nil {
+		return host
+	}
+	if v4 := ip.To4(); v4 != nil {
+		return v4.String()
+	}
+	return ip.Mask(net.CIDRMask(64, 128)).String() + "/64"
+}
+
+type rpcCall struct {
+	Method string `json:"method"`
+}
+
+// rpcMethods: the method of each call in a JSON-RPC body (one call or a
+// batch), decoded the way the servers behind decode it.
+func rpcMethods(body []byte) ([]string, error) {
+	t := bytes.TrimLeft(body, " \t\r\n")
+	if len(t) > 0 && t[0] == '[' {
+		var calls []rpcCall
+		if err := json.Unmarshal(body, &calls); err != nil {
+			return nil, fmt.Errorf("invalid JSON-RPC batch")
+		}
+		if len(calls) == 0 || len(calls) > guardMaxBatch {
+			return nil, fmt.Errorf("a batch holds 1 to %d calls", guardMaxBatch)
+		}
+		out := make([]string, len(calls))
+		for i, c := range calls {
+			out[i] = c.Method
+		}
+		return out, nil
+	}
+	var c rpcCall
+	if err := json.Unmarshal(body, &c); err != nil {
+		return nil, fmt.Errorf("invalid JSON-RPC request")
+	}
+	return []string{c.Method}, nil
+}
+
+func refuse(w http.ResponseWriter, status int, msg string) {
+	w.Header().Set("Content-Type", "application/json")
+	w.WriteHeader(status)
+	b, _ := json.Marshal(map[string]any{
+		"jsonrpc": "2.0", "id": nil,
+		"error": map[string]any{"code": -32601, "message": msg},
+	})
+	_, _ = w.Write(b)
+}
+
+func proxyTo(target *url.URL) *httputil.ReverseProxy {
+	return &httputil.ReverseProxy{
+		Rewrite: func(p *httputil.ProxyRequest) {
+			p.Out.URL.Scheme, p.Out.URL.Host = target.Scheme, target.Host
+			p.Out.Host = target.Host
+			p.Out.Header.Del("X-Forwarded-For") // the backends do not need it
+		},
+		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, _ error) {
+			refuse(w, http.StatusBadGateway, "the node is not answering")
+		},
+	}
+}
+
+// readBody reads at most guardBodyLimit bytes and puts them back for the proxy.
+func readBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
+	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, guardBodyLimit))
+	if err != nil {
+		refuse(w, http.StatusRequestEntityTooLarge, "request too large")
+		return nil, false
+	}
+	r.Body = io.NopCloser(bytes.NewReader(b))
+	r.ContentLength = int64(len(b))
+	return b, true
+}
+
+// common: in-flight and per-minute limits, no websocket.
+func (g *Guard) common(sem chan struct{}, next func(http.ResponseWriter, *http.Request)) http.Handler {
+	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		if r.Header.Get("Upgrade") != "" {
+			refuse(w, http.StatusForbidden, "websocket is not open on this public RPC")
+			return
+		}
+		select {
+		case sem <- struct{}{}:
+			defer func() { <-sem }()
+		default:
+			refuse(w, http.StatusServiceUnavailable, "the node is busy; try again shortly")
+			return
+		}
+		if !g.minute.allow(ClientKey(r), g.cfg.PerMinute, g.now()) {
+			w.Header().Set("Retry-After", "60")
+			refuse(w, http.StatusTooManyRequests, "too many requests from this address; try again in a minute")
+			return
+		}
+		next(w, r)
+	})
+}
+
+// CometHandler filters CometBFT RPC requests.
+func (g *Guard) CometHandler() http.Handler {
+	px := proxyTo(g.comet)
+	return g.common(make(chan struct{}, g.cfg.MaxInFlight), func(w http.ResponseWriter, r *http.Request) {
+		name := strings.TrimPrefix(r.URL.Path, "/")
+		if name != "" {
+			// GET /<method>?… (CometBFT also takes form values by POST here)
+			if r.URL.RawPath != "" || !cometMethods[name] {
+				refuse(w, http.StatusForbidden, "method not available on this public RPC")
+				return
+			}
+			if r.Method != http.MethodGet && r.Method != http.MethodPost {
+				refuse(w, http.StatusMethodNotAllowed, "GET or POST")
+				return
+			}
+			if r.Method == http.MethodPost {
+				if _, ok := readBody(w, r); !ok {
+					return
+				}
+			}
+			r.URL.Path, r.URL.RawPath = "/"+name, ""
+			px.ServeHTTP(w, r)
+			return
+		}
+		if r.Method != http.MethodPost {
+			refuse(w, http.StatusForbidden, "method not available on this public RPC")
+			return
+		}
+		body, ok := readBody(w, r)
+		if !ok {
+			return
+		}
+		ms, err := rpcMethods(body)
+		if err != nil {
+			refuse(w, http.StatusBadRequest, err.Error())
+			return
+		}
+		for _, m := range ms {
+			if !cometMethods[m] {
+				refuse(w, http.StatusForbidden, "method not available on this public RPC: "+trimMethod(m))
+				return
+			}
+		}
+		r.URL.Path, r.URL.RawPath = "/", ""
+		px.ServeHTTP(w, r)
+	})
+}
+
+// EVMHandler filters EVM JSON-RPC requests.
+func (g *Guard) EVMHandler() http.Handler {
+	px := proxyTo(g.evm)
+	return g.common(make(chan struct{}, g.cfg.MaxInFlight), func(w http.ResponseWriter, r *http.Request) {
+		if r.Method != http.MethodPost {
+			refuse(w, http.StatusMethodNotAllowed, "JSON-RPC by POST")
+			return
+		}
+		body, ok := readBody(w, r)
+		if !ok {
+			return
+		}
+		ms, err := rpcMethods(body)
+		if err != nil {
+			refuse(w, http.StatusBadRequest, err.Error())
+			return
+		}
+		faucets, pows := 0, 0
+		for _, m := range ms {
+			if !evmMethodOK(m) {
+				refuse(w, http.StatusForbidden, "method not available on this public RPC: "+trimMethod(m))
+				return
+			}
+			switch m {
+			case faucetMethod:
+				faucets++
+			case faucetPowMethod:
+				pows++
+			}
+		}
+		if faucets+pows > 1 {
+			refuse(w, http.StatusBadRequest, "one zetaphy_faucet or zetaphy_faucetPow call per request")
+			return
+		}
+		if faucets == 1 && !g.faucet.allow(ClientKey(r), g.cfg.FaucetPerDay, g.now()) {
+			refuse(w, http.StatusTooManyRequests, fmt.Sprintf("the faucet gives at most %d grants a day to one internet address; try again tomorrow (UTC)", g.cfg.FaucetPerDay))
+			return
+		}
+		if pows == 1 && !g.faucetPow.allow(ClientKey(r), g.cfg.FaucetPowPerDay, g.now()) {
+			refuse(w, http.StatusTooManyRequests, fmt.Sprintf("the proof-of-work faucet takes at most %d claims a day from one internet address; try again tomorrow (UTC)", g.cfg.FaucetPowPerDay))
+			return
+		}
+		r.URL.Path, r.URL.RawPath = "/", ""
+		px.ServeHTTP(w, r)
+	})
+}
+
+func trimMethod(m string) string {
+	if len(m) > 64 {
+		m = m[:64]
+	}
+	return strings.Map(func(c rune) rune {
+		if c < 0x20 || c > 0x7e {
+			return '?'
+		}
+		return c
+	}, m)
+}
+
+func guardServer(addr string, h http.Handler) *http.Server {
+	return &http.Server{
+		Addr: addr, Handler: h,
+		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
+		WriteTimeout: 60 * time.Second, IdleTimeout: 120 * time.Second,
+		MaxHeaderBytes: 16 << 10,
+	}
+}
+
+func loopbackAddr(addr string) error {
+	host, _, err := net.SplitHostPort(addr)
+	if err != nil {
+		return err
+	}
+	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
+		return fmt.Errorf("%s: rpc-guard listens on 127.0.0.1 only (Caddy is the public door)", addr)
+	}
+	return nil
+}
+
+// RPCGuardCmd is `zetaphyd rpc-guard` (a service of its own; setup-node.sh
+// installs it and points Caddy at it).
+func RPCGuardCmd() *cobra.Command {
+	var cfg GuardConfig
+	var cometListen, evmListen string
+	cmd := &cobra.Command{
+		Use:   "rpc-guard",
+		Short: "Public RPC filter for Caddy: allowed methods only, per-IP limits, faucet limit per IP",
+		Args:  cobra.NoArgs,
+		RunE: func(cmd *cobra.Command, _ []string) error {
+			for _, a := range []string{cometListen, evmListen} {
+				if err := loopbackAddr(a); err != nil {
+					return err
+				}
+			}
+			g, err := NewGuard(cfg)
+			if err != nil {
+				return err
+			}
+			errc := make(chan error, 2)
+			go func() { errc <- guardServer(cometListen, g.CometHandler()).ListenAndServe() }()
+			go func() { errc <- guardServer(evmListen, g.EVMHandler()).ListenAndServe() }()
+			cmd.Printf("rpc-guard: CometBFT %s -> %s, EVM %s -> %s\n", cometListen, cfg.Comet, evmListen, cfg.EVM)
+			return <-errc
+		},
+	}
+	f := cmd.Flags()
+	f.StringVar(&cometListen, "comet-listen", "127.0.0.1:26667", "where Caddy sends /rpc/")
+	f.StringVar(&evmListen, "evm-listen", "127.0.0.1:8547", "where Caddy sends EVM JSON-RPC")
+	f.StringVar(&cfg.Comet, "comet", "http://127.0.0.1:26657", "the node's CometBFT RPC")
+	f.StringVar(&cfg.EVM, "evm", "http://127.0.0.1:8545", "the node's EVM JSON-RPC")
+	f.IntVar(&cfg.PerMinute, "per-minute", 300, "requests a minute from one IP, on each side")
+	f.IntVar(&cfg.FaucetPerDay, "faucet-per-day", 3, "zetaphy_faucet calls a UTC day from one IP")
+	f.IntVar(&cfg.FaucetPowPerDay, "faucet-pow-per-day", 10, "zetaphy_faucetPow calls a UTC day from one IP")
+	f.IntVar(&cfg.MaxInFlight, "max-in-flight", 64, "requests answered at once, on each side")
+	return cmd
+}
diff --git a/evmd/zetaphy_seccli.go b/evmd/zetaphy_seccli.go
new file mode 100644
index 0000000..3eb7f6c
--- /dev/null
+++ b/evmd/zetaphy_seccli.go
@@ -0,0 +1,180 @@
+package evmd
+
+// zetaphyd commands for the security core (gov.sh wraps the proposals):
+//
+//	tx security-proposal qday <height> [reveal-delay-blocks]
+//	tx security-proposal threat-gate <ThreatRegistry 0x…> on|off
+//	tx security-proposal ibc-hold <delay-seconds> [guardian]
+//	tx security-proposal ibc-hold-rule <denom|*> <min-amount> <supply-bps>
+//	tx qday-commit <commitment hex>
+//	tx qday-reveal <owner> <controller> <salt hex> <signature hex>
+//	tx ibc-hold-cancel <id>
+
+import (
+	"encoding/hex"
+	"fmt"
+	"os"
+	"path/filepath"
+	"strconv"
+	"strings"
+
+	"github.com/spf13/cobra"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/client/flags"
+	"github.com/cosmos/cosmos-sdk/client/tx"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	govv1 "github.com/cosmos/cosmos-sdk/x/gov/types/v1"
+)
+
+func secTxCmd(use, short string, args int, build func(from string, args []string) (sdk.Msg, error)) *cobra.Command {
+	cmd := &cobra.Command{
+		Use: use, Short: short, Args: cobra.ExactArgs(args),
+		RunE: func(cmd *cobra.Command, args []string) error {
+			cctx, err := client.GetClientTxContext(cmd)
+			if err != nil {
+				return err
+			}
+			m, err := build(cctx.GetFromAddress().String(), args)
+			if err != nil {
+				return err
+			}
+			return tx.GenerateOrBroadcastTxCLI(cctx, cmd.Flags(), m)
+		},
+	}
+	flags.AddTxFlagsToCmd(cmd)
+	return cmd
+}
+
+func secHex(s string) ([]byte, error) { return hex.DecodeString(strings.TrimPrefix(s, "0x")) }
+
+// QDayCommitCmd: zetaphyd tx qday-commit <commitment> --from <ML-DSA account>.
+func QDayCommitCmd() *cobra.Command {
+	return secTxCmd("qday-commit <commitment hex>", "Record a Q-day migration commitment (step 1 of the commit–reveal migration)", 1,
+		func(from string, a []string) (sdk.Msg, error) {
+			c, err := secHex(a[0])
+			return &MsgQDayCommit{Signer: from, Commitment: c}, err
+		})
+}
+
+// QDayRevealCmd: zetaphyd tx qday-reveal <owner> <controller> <salt> <signature> --from <ML-DSA account>.
+func QDayRevealCmd() *cobra.Command {
+	return secTxCmd("qday-reveal <owner> <controller> <salt hex> <signature hex>", "Open a Q-day migration commitment (step 2): the owner moves to the ML-DSA-44 controller", 4,
+		func(from string, a []string) (sdk.Msg, error) {
+			salt, err := secHex(a[2])
+			if err != nil {
+				return nil, err
+			}
+			sig, err := secHex(a[3])
+			return &MsgQDayReveal{Signer: from, Owner: a[0], Controller: a[1], Salt: salt, Signature: sig}, err
+		})
+}
+
+// IBCHoldCancelCmd: zetaphyd tx ibc-hold-cancel <id> --from <guardian>.
+func IBCHoldCancelCmd() *cobra.Command {
+	return secTxCmd("ibc-hold-cancel <id>", "Return a held inbound IBC transfer to its sender (the IBC hold guardian)", 1,
+		func(from string, a []string) (sdk.Msg, error) {
+			id, err := strconv.ParseUint(a[0], 10, 64)
+			return &MsgIBCHoldCancel{Signer: from, Id: id}, err
+		})
+}
+
+func secProposalMsg(args []string) (sdk.Msg, string, error) {
+	gov := govAuthority()
+	num := func(s string) (uint64, error) { return strconv.ParseUint(s, 10, 64) }
+	switch args[0] {
+	case "qday":
+		if len(args) < 2 || len(args) > 3 {
+			return nil, "", fmt.Errorf("qday <height> [reveal-delay-blocks]")
+		}
+		h, err := num(args[1])
+		if err != nil {
+			return nil, "", err
+		}
+		var d uint64
+		if len(args) == 3 {
+			if d, err = num(args[2]); err != nil {
+				return nil, "", err
+			}
+		}
+		title := fmt.Sprintf("Q-day at block %d: ECDSA-signed transactions refused from then on", h)
+		if h == 0 {
+			title = "Unschedule Q-day"
+		}
+		return &MsgSetQDay{Authority: gov, Height: h, RevealDelay: d}, title, nil
+	case "threat-gate":
+		if len(args) != 3 || (args[2] != "on" && args[2] != "off") {
+			return nil, "", fmt.Errorf("threat-gate <ThreatRegistry 0x…> on|off")
+		}
+		on := map[string]uint64{"on": 1, "off": 0}[args[2]]
+		return &MsgSetThreatGate{Authority: gov, Registry: args[1], Enabled: on}, fmt.Sprintf("Threat gate %s (registry %s)", args[2], args[1]), nil
+	case "ibc-hold":
+		if len(args) < 2 || len(args) > 3 {
+			return nil, "", fmt.Errorf("ibc-hold <delay-seconds> [guardian]")
+		}
+		d, err := num(args[1])
+		if err != nil {
+			return nil, "", err
+		}
+		g := ""
+		if len(args) == 3 {
+			g = args[2]
+		}
+		return &MsgSetIBCHold{Authority: gov, DelaySeconds: d, Guardian: g}, fmt.Sprintf("IBC large-transfer hold: %d s, guardian %q", d, g), nil
+	case "ibc-hold-rule":
+		if len(args) != 4 {
+			return nil, "", fmt.Errorf("ibc-hold-rule <denom|*> <min-amount> <supply-bps>")
+		}
+		bps, err := num(args[3])
+		if err != nil {
+			return nil, "", err
+		}
+		min := args[2]
+		if min == "0" {
+			min = ""
+		}
+		title := fmt.Sprintf("IBC hold rule for %s: from %s, or %d bps of supply", args[1], args[2], bps)
+		if args[1] == "*" {
+			title = fmt.Sprintf("IBC hold rule for other denoms: %d bps of supply, from %s", bps, args[2])
+		}
+		return &MsgSetIBCHoldRule{Authority: gov, Denom: args[1], MinAmount: min, SupplyBps: bps}, title, nil
+	case "ai-model", "immune", "breaker", "breaker-rearm", "model-epochs": // ZETAPHY v5 (zetaphy_future.go)
+		return futProposalMsg(args, func(f string) ([]byte, error) { return os.ReadFile(filepath.Clean(f)) })
+	}
+	return nil, "", fmt.Errorf("unknown proposal %q: qday, threat-gate, ibc-hold, ibc-hold-rule, ai-model, immune, breaker, breaker-rearm or model-epochs", args[0])
+}
+
+// SecurityProposalCmd: zetaphyd tx security-proposal <kind> ... --deposit ... --from <key>.
+func SecurityProposalCmd() *cobra.Command {
+	cmd := &cobra.Command{
+		Use:   "security-proposal qday|threat-gate|ibc-hold|ibc-hold-rule|ai-model|immune|breaker|breaker-rearm|model-epochs <args>",
+		Short: "Propose a ZETAPHY security-core setting (Q-day, threat gate, IBC large-transfer hold, v5: AI model, immune system, bridge breaker, Neuro model registry)",
+		Args:  cobra.RangeArgs(2, 4),
+		RunE: func(cmd *cobra.Command, args []string) error {
+			cctx, err := client.GetClientTxContext(cmd)
+			if err != nil {
+				return err
+			}
+			m, title, err := secProposalMsg(args)
+			if err != nil {
+				return err
+			}
+			dep, err := cmd.Flags().GetString("deposit")
+			if err != nil {
+				return err
+			}
+			coins, err := sdk.ParseCoinsNormalized(dep)
+			if err != nil {
+				return err
+			}
+			p, err := govv1.NewMsgSubmitProposal([]sdk.Msg{m}, coins, cctx.GetFromAddress().String(), "", title, title, false)
+			if err != nil {
+				return err
+			}
+			return tx.GenerateOrBroadcastTxCLI(cctx, cmd.Flags(), p)
+		},
+	}
+	cmd.Flags().String("deposit", "", "initial deposit, e.g. 1000000000000000000000azetaphy")
+	flags.AddTxFlagsToCmd(cmd)
+	return cmd
+}
diff --git a/evmd/zetaphy_secprecompile.go b/evmd/zetaphy_secprecompile.go
new file mode 100644
index 0000000..2e4a563
--- /dev/null
+++ b/evmd/zetaphy_secprecompile.go
@@ -0,0 +1,151 @@
+package evmd
+
+// ZETAPHY security precompile at 0x…0901 (always on from the security-core
+// height, whatever the active_static_precompiles param says), so MetaMask
+// and contracts reach the security core without a Cosmos wallet:
+//
+//	consent(address target, uint64 seconds) returns (uint64 until)
+//	    the caller accepts calling `target` although the threat gate would
+//	    refuse it, for `seconds` (at most a day; 0 withdraws). Only an account
+//	    calling directly (msg.sender == tx.origin): a contract cannot consent
+//	    for the person who called it.
+//	consentUntil(address account, address target) view returns (uint64)
+//	threatGate() view returns (address registry, bool enabled)
+//	qday() view returns (uint64 height, uint64 revealDelay, bool active)
+//	migration(address account) view returns (bool migrated, address controller,
+//	    address pendingController, uint64 finalHeight, bool exposed)
+//	cancelIBCHold(uint64 id)
+//	    the IBC hold guardian (a multisig contract, for example) returns a
+//	    held inbound transfer to its sender
+//	event Consent(address indexed account, address indexed target, uint64 until)
+
+import (
+	"bytes"
+	"errors"
+	"fmt"
+
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	cmn "github.com/cosmos/evm/precompiles/common"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+)
+
+const securityPrecompileABI = `[
+ {"type":"function","name":"consent","stateMutability":"nonpayable","inputs":[{"name":"target","type":"address"},{"name":"seconds","type":"uint64"}],"outputs":[{"name":"until","type":"uint64"}]},
+ {"type":"function","name":"consentUntil","stateMutability":"view","inputs":[{"name":"account","type":"address"},{"name":"target","type":"address"}],"outputs":[{"name":"until","type":"uint64"}]},
+ {"type":"function","name":"threatGate","stateMutability":"view","inputs":[],"outputs":[{"name":"registry","type":"address"},{"name":"enabled","type":"bool"}]},
+ {"type":"function","name":"qday","stateMutability":"view","inputs":[],"outputs":[{"name":"height","type":"uint64"},{"name":"revealDelay","type":"uint64"},{"name":"active","type":"bool"}]},
+ {"type":"function","name":"migration","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"migrated","type":"bool"},{"name":"controller","type":"address"},{"name":"pendingController","type":"address"},{"name":"finalHeight","type":"uint64"},{"name":"exposed","type":"bool"}]},
+ {"type":"function","name":"cancelIBCHold","stateMutability":"nonpayable","inputs":[{"name":"id","type":"uint64"}],"outputs":[]},
+ {"type":"event","name":"Consent","anonymous":false,"inputs":[{"name":"account","type":"address","indexed":true},{"name":"target","type":"address","indexed":true},{"name":"until","type":"uint64","indexed":false}]}
+]`
+
+// SecurityABI is the security precompile's ABI.
+var SecurityABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(securityPrecompileABI)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+type securityPrecompile struct {
+	cmn.Precompile
+	app *EVMD
+}
+
+func newSecurityPrecompile(app *EVMD) *securityPrecompile {
+	return &securityPrecompile{Precompile: cmn.Precompile{
+		KvGasConfig: storetypes.KVGasConfig(), TransientKVGasConfig: storetypes.TransientGasConfig(),
+		ContractAddress: SecurityPrecompileAddress,
+	}, app: app}
+}
+
+func (*securityPrecompile) Name() string { return "zetaphy-security" }
+
+func securityIsTx(m *abi.Method) bool { return m.Name == "consent" || m.Name == "cancelIBCHold" }
+
+func (p *securityPrecompile) RequiredGas(input []byte) uint64 {
+	if len(input) < 4 {
+		return 0
+	}
+	m, err := SecurityABI.MethodById(input[:4])
+	if err != nil {
+		return 0
+	}
+	return p.Precompile.RequiredGas(input, securityIsTx(m))
+}
+
+func (p *securityPrecompile) Run(evm *vm.EVM, contract *vm.Contract, readonly bool) ([]byte, error) {
+	return p.RunNativeAction(evm, contract, func(ctx sdk.Context) ([]byte, error) {
+		return p.execute(ctx, evm, contract, readonly)
+	})
+}
+
+func (p *securityPrecompile) execute(ctx sdk.Context, evm *vm.EVM, contract *vm.Contract, readonly bool) ([]byte, error) {
+	method, args, err := cmn.SetupABI(SecurityABI, contract, readonly, securityIsTx)
+	if err != nil {
+		return nil, err
+	}
+	if v := contract.Value(); v != nil && !v.IsZero() {
+		return nil, errors.New("the security precompile takes no value")
+	}
+	app, caller := p.app, contract.Caller()
+	switch method.Name {
+	case "consent":
+		if caller != evm.Origin {
+			return nil, errors.New("consent: only the account itself, calling directly (not through a contract)")
+		}
+		target, seconds := args[0].(common.Address), args[1].(uint64)
+		until, err := app.setConsent(ctx, caller, target, seconds)
+		if err != nil {
+			return nil, err
+		}
+		ev := SecurityABI.Events["Consent"]
+		data, err := ev.Inputs.NonIndexed().Pack(uint64(until)) // #nosec G115 -- unix seconds
+		if err != nil {
+			return nil, err
+		}
+		evm.StateDB.AddLog(&ethtypes.Log{Address: SecurityPrecompileAddress, Data: data, BlockNumber: uint64(ctx.BlockHeight()), // #nosec G115 -- block heights
+			Topics: []common.Hash{ev.ID, common.BytesToHash(caller.Bytes()), common.BytesToHash(target.Bytes())}})
+		ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_consent", sdk.NewAttribute("account", caller.Hex()),
+			sdk.NewAttribute("target", target.Hex()), sdk.NewAttribute("until", fmt.Sprint(until))))
+		return method.Outputs.Pack(uint64(until)) // #nosec G115 -- unix seconds
+	case "consentUntil":
+		return method.Outputs.Pack(uint64(app.consentUntil(ctx, args[0].(common.Address), args[1].(common.Address)))) // #nosec G115 -- unix seconds
+	case "threatGate":
+		reg, on := app.threatGate(ctx)
+		return method.Outputs.Pack(reg, on)
+	case "qday":
+		h, d := app.qdayParams(ctx)
+		return method.Outputs.Pack(uint64(h), uint64(d), app.qdayActive(ctx)) // #nosec G115 -- block heights
+	case "migration":
+		who := args[0].(common.Address)
+		ctrl := app.pqController(ctx, who.Bytes())
+		_, final, pending, _ := app.qdayPending(ctx, who.Bytes())
+		return method.Outputs.Pack(ctrl != nil, common.BytesToAddress(ctrl), common.BytesToAddress(pending),
+			uint64(final), app.qdayExposed(ctx, who.Bytes())) // #nosec G115 -- block heights
+	case "cancelIBCHold":
+		if err := app.ibcHoldCancel(ctx, caller.Bytes(), args[0].(uint64)); err != nil {
+			return nil, err
+		}
+		return method.Outputs.Pack()
+	}
+	return nil, fmt.Errorf("unknown method %s", method.Name)
+}
+
+// zetaphyPrecompile is the EVM keeper's hook for chain-defined precompiles.
+func (app *EVMD) zetaphyPrecompile(ctx sdk.Context, addr common.Address) (vm.PrecompiledContract, bool) {
+	if addr != SecurityPrecompileAddress {
+		return app.futPrecompile(ctx, addr) // ZETAPHY v5 (zetaphy_future.go)
+	}
+	if !app.secV3(ctx) {
+		return nil, false
+	}
+	return app.secPrecompile, true
+}
diff --git a/evmd/zetaphy_security.go b/evmd/zetaphy_security.go
new file mode 100644
index 0000000..069022e
--- /dev/null
+++ b/evmd/zetaphy_security.go
@@ -0,0 +1,136 @@
+package evmd
+
+// ZETAPHY security core: three protocol rules, each off until governance
+// turns it on, kept in the zetaphypq store next to the quantum locks.
+//
+//   - Q-day (zetaphy_qday.go): from a governance-set height, txs authorized
+//     only by ECDSA are refused; accounts migrate to ML-DSA-44 beforehand
+//     (quantum lock), or after it by commit–reveal if their key was never
+//     shown on chain.
+//   - Threat gate (zetaphy_threatgate.go): a tx whose target has an ENFORCED
+//     flag in the Neuro ThreatRegistry is refused unless its sender gave
+//     consent (one tx to the security precompile, valid up to a day).
+//   - IBC large-transfer hold (zetaphy_ibchold.go): inbound transfers over a
+//     governance threshold wait in the IBC layer (async acknowledgement) and
+//     are delivered after a delay, unless the guardian returns them to the
+//     sender through an error acknowledgement.
+//
+// Upgrade path: a new chain has them from block 1 (key 0x0F = 1 in
+// app_state.zetaphypq, as `zetaphyd init` writes); a running chain gets the
+// "zetaphy-v3" upgrade, which sets 0x0F to the upgrade height + 1. Below
+// that height blocks run as before (the precompile is absent and ecrecover
+// marks nothing); the governance switches themselves are new messages.
+
+import (
+	"encoding/binary"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
+	govtypes "github.com/cosmos/cosmos-sdk/x/gov/types"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+// Keys of the zetaphypq store used by the security core.
+var (
+	secV3Key       = []byte{0x0F} // height (8) from which the security core applies
+	qdayKey        = []byte{0x10} // Q-day height (8) || reveal delay in blocks (8)
+	qdayCommitPfx  = byte(0x11)   // || commitment (32) -> height of the commit (8)
+	qdayPendingPfx = byte(0x12)   // || owner (20) -> commit height (8) || final height (8) || controller (20)
+	qdayQueuePfx   = byte(0x13)   // || final height (8) || owner (20) -> {}
+	gateKey        = []byte{0x15} // registry (20) || enabled (1)
+	consentPfx     = byte(0x16)   // || account (20) || target (20) -> until, unix seconds (8)
+	holdParamsKey  = []byte{0x17} // delay seconds (8) || guardian (0 or 20)
+	holdRulePfx    = byte(0x18)   // || denom -> supply bps (8) || minimum amount (decimal)
+	holdSeqKey     = []byte{0x19} // next hold id (8)
+	holdPfx        = byte(0x1A)   // || id (8) -> ibcHold (JSON)
+	holdQueuePfx   = byte(0x1B)   // || release time (8) || id (8) -> {}
+	holdCountKey   = []byte{0x1C} // number of open holds (8)
+	holdDenomPfx   = byte(0x1D)   // || denom -> number of open holds of that denom (8)
+)
+
+// secKeyKnown: prefixes of the zetaphypq store a genesis may carry.
+func secKeyKnown(p byte) bool { return p >= 0x0F && p <= 0x1D && p != 0x14 }
+
+func u64(v uint64) []byte { return binary.BigEndian.AppendUint64(nil, v) }
+
+func readU64(b []byte) uint64 {
+	if len(b) < 8 {
+		return 0
+	}
+	return binary.BigEndian.Uint64(b)
+}
+
+// secRaw reads the zetaphypq store without gas: parameters are read inside
+// ante handlers and EVM calls, whose gas must not depend on them.
+func (app *EVMD) secRaw(ctx sdk.Context) storetypes.KVStore {
+	return ctx.MultiStore().GetKVStore(app.GetKey(pqStoreKey))
+}
+
+func govAuthority() string { return authtypes.NewModuleAddress(govtypes.ModuleName).String() }
+
+// secV3Height is the height from which the security core applies (0: never).
+func (app *EVMD) secV3Height(ctx sdk.Context) int64 {
+	return int64(readU64(app.secRaw(ctx).Get(secV3Key))) // #nosec G115 -- block heights
+}
+
+func (app *EVMD) secV3(ctx sdk.Context) bool {
+	a := app.secV3Height(ctx)
+	return a > 0 && ctx.BlockHeight() >= a
+}
+
+func (app *EVMD) setSecV3Height(ctx sdk.Context, h int64) {
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(secV3Key, u64(uint64(h))) // #nosec G115 -- block heights
+	app.setPQLockSlot(ctx, evmtypes.SecurityV3Slot, uint64(h))        // #nosec G115 -- block heights
+}
+
+// setPQLockSlot mirrors a number into the storage of PQLockAddress, where the
+// EVM (ecrecover, the mempool) reads it. The account gets nonce 1 so the EVM
+// never drops it as empty.
+func (app *EVMD) setPQLockSlot(ctx sdk.Context, slot common.Hash, v uint64) {
+	app.ensurePQLockAccount(ctx)
+	if v == 0 {
+		app.EVMKeeper.DeleteState(ctx, PQLockAddress, slot)
+		return
+	}
+	app.EVMKeeper.SetState(ctx, PQLockAddress, slot, common.BigToHash(new(big.Int).SetUint64(v)).Bytes())
+}
+
+func (app *EVMD) ensurePQLockAccount(ctx sdk.Context) {
+	if app.AccountKeeper.GetAccount(ctx, PQLockAddress.Bytes()) == nil {
+		acc := app.AccountKeeper.NewAccountWithAddress(ctx, PQLockAddress.Bytes())
+		_ = acc.SetSequence(1)
+		app.AccountKeeper.SetAccount(ctx, acc)
+	}
+}
+
+// secMirrorAfterGenesis copies the heights a genesis set in the zetaphypq
+// store into EVM storage (InitChainer; the EVM genesis ran after them).
+func (app *EVMD) secMirrorAfterGenesis(ctx sdk.Context) {
+	if h := app.secV3Height(ctx); h > 0 {
+		app.setPQLockSlot(ctx, evmtypes.SecurityV3Slot, uint64(h)) // #nosec G115 -- block heights
+	}
+	if q, _ := app.qdayParams(ctx); q > 0 {
+		app.setPQLockSlot(ctx, evmtypes.QDaySlot, uint64(q)) // #nosec G115 -- block heights
+	}
+}
+
+// secBeginBlock: Q-day migrations that finished their wait, and held IBC
+// transfers whose delay is over (both bounded per block).
+func (app *EVMD) secBeginBlock(ctx sdk.Context) {
+	if !app.secV3(ctx) {
+		return
+	}
+	app.qdayFinalize(ctx)
+	app.ibcHoldReleaseDue(ctx)
+}
+
+// isGovAddr: s (zetaphy1… or 0x…) is the governance module account.
+func isGovAddr(s string) bool {
+	a, err := pqAddr(s)
+	return err == nil && a.Equals(authtypes.NewModuleAddress(govtypes.ModuleName))
+}
diff --git a/evmd/zetaphy_threatgate.go b/evmd/zetaphy_threatgate.go
new file mode 100644
index 0000000..2092b0d
--- /dev/null
+++ b/evmd/zetaphy_threatgate.go
@@ -0,0 +1,252 @@
+package evmd
+
+// ZETAPHY threat gate: the Neuro "vaccine" at protocol level, as consent,
+// not censorship.
+//
+// Governance points the chain at the ThreatRegistry contract
+// (MsgSetThreatGate). An Ethereum tx, or a MsgEVMCall, whose target (tx.to;
+// contract creation is never checked) has an ENFORCED flag there
+// (isContractEnforced: the flag stood enforceDelay, or went through the
+// fast lane) is refused, unless its sender gave consent for that target:
+// one tx calling consent(target, seconds) on the security precompile
+// (0x…0901, zetaphy_secprecompile.go), valid for at most a day. Wallets
+// show the flag and offer that tx; anyone can still go ahead.
+//
+// What the registry already guarantees is kept: warning and held flags do
+// not count, protected keys (the protocol's own contracts) can never be
+// flagged, a cleared flag or a won appeal ends the refusal at once.
+// The chain adds: system addresses (below 0x10000: precompiles, the lock and
+// security addresses) and the registry itself are never refused, so appeals
+// and responses always go through; governance's own calls are not checked.
+//
+// A refused tx is stopped in CheckTx (and when an Ethereum tx is submitted),
+// so it does not enter the mempool. If it is refused only once in a block
+// (e.g. its consent was withdrawn or expired meanwhile), it is still
+// included and pays its fee: the ante handler keeps the fee and nonce, and
+// the refusal fails the tx where it runs (an Ethereum tx is reverted by the
+// EVM hook, with the gas it used charged; a MsgEVMCall fails in evmCall).
+//
+// Cost: at most one EVM static call per tx (isContractEnforced, a few
+// storage reads), capped at threatGateGas. Any failure of that call (no
+// code, revert, out of gas, malformed answer) counts as "not enforced": a
+// broken registry turns the gate off, never the chain.
+
+import (
+	"bytes"
+	"fmt"
+	"math/big"
+
+	gogoproto "github.com/cosmos/gogoproto/proto"
+	"github.com/ethereum/go-ethereum/accounts/abi"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+
+	errorsmod "cosmossdk.io/errors"
+
+	storetypes "github.com/cosmos/cosmos-sdk/store/v2/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+
+	"github.com/cosmos/evm/x/vm/statedb"
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+const (
+	// MaxConsentSeconds: a consent lasts at most a day.
+	MaxConsentSeconds = 86400
+	// threatGateGas caps the registry call (beyond the 21000 intrinsic gas).
+	threatGateGas = 100_000
+)
+
+// ErrThreatFlagged is the threat gate's refusal (codespace "zetaphy", code 21).
+var ErrThreatFlagged = errorsmod.Register("zetaphy", 21, "threat gate")
+
+// SecurityPrecompileAddress hosts consent and the security-core views.
+var SecurityPrecompileAddress = common.HexToAddress("0x0000000000000000000000000000000000000901")
+
+var threatRegistryABI = func() abi.ABI {
+	a, err := abi.JSON(bytes.NewReader([]byte(`[{"type":"function","name":"isContractEnforced","stateMutability":"view",
+		"inputs":[{"name":"who","type":"address"}],"outputs":[{"name":"","type":"bool"},{"name":"","type":"uint8"}]}]`)))
+	if err != nil {
+		panic(err)
+	}
+	return a
+}()
+
+// ThreatReasons are the ThreatRegistry's Reason names, by number.
+var ThreatReasons = []string{"None", "CannotSellInSimulation", "UnlimitedMint", "OwnerCanBlockTransfers",
+	"OwnerCanMoveHolderFunds", "SameNameAsKnownToken", "SweepsApprovedTokens", "Other"}
+
+func (app *EVMD) threatGate(ctx sdk.Context) (common.Address, bool) {
+	v := app.secRaw(ctx).Get(gateKey)
+	if len(v) != 21 {
+		return common.Address{}, false
+	}
+	reg := common.BytesToAddress(v[:20])
+	return reg, v[20] == 1 && reg != (common.Address{})
+}
+
+func (app *EVMD) setThreatGate(ctx sdk.Context, m *MsgSetThreatGate) (gogoproto.Message, error) {
+	if m.Authority != govAuthority() {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only governance can set the threat gate")
+	}
+	if m.Enabled > 1 || (m.Registry != "" && !common.IsHexAddress(m.Registry)) {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "registry: a 0x address; enabled: 0 or 1")
+	}
+	reg := common.HexToAddress(m.Registry)
+	immune := reg == ImmunePrecompileAddress && app.futV5(ctx, ctx.BlockHeight()) // ZETAPHY v5: the immune system's ThreatRegistry views
+	if m.Enabled == 1 && !immune && len(app.EVMKeeper.GetCode(ctx, app.EVMKeeper.GetCodeHash(ctx, reg))) == 0 {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "registry: no contract at that address")
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(gateKey, append(reg.Bytes(), byte(m.Enabled)))
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_threat_gate", sdk.NewAttribute("registry", reg.Hex()), sdk.NewAttribute("enabled", fmt.Sprint(m.Enabled))))
+	return &MsgPQResponse{}, nil
+}
+
+func consentKey(account, target common.Address) []byte {
+	return append(append([]byte{consentPfx}, account.Bytes()...), target.Bytes()...)
+}
+
+// consentUntil: until when (unix seconds) account consented to target (0: never).
+func (app *EVMD) consentUntil(ctx sdk.Context, account, target common.Address) int64 {
+	return int64(readU64(app.secRaw(ctx).Get(consentKey(account, target)))) // #nosec G115 -- unix seconds
+}
+
+// setConsent records (seconds > 0) or withdraws (0) a consent; returns its end.
+func (app *EVMD) setConsent(ctx sdk.Context, account, target common.Address, seconds uint64) (int64, error) {
+	if seconds > MaxConsentSeconds {
+		return 0, fmt.Errorf("a consent lasts at most %d seconds (a day)", MaxConsentSeconds)
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if seconds == 0 {
+		st.Delete(consentKey(account, target))
+		return 0, nil
+	}
+	until := ctx.BlockTime().Unix() + int64(seconds) // #nosec G115 -- at most a day
+	st.Set(consentKey(account, target), u64(uint64(until)))
+	return until, nil
+}
+
+func threatSystemAddress(a common.Address) bool {
+	return new(big.Int).SetBytes(a.Bytes()).Cmp(big.NewInt(0x10000)) < 0
+}
+
+// threatEnforced asks the registry, in a throw-away branch, whether target
+// has an enforced flag. Every failure answers false.
+func (app *EVMD) threatEnforced(ctx sdk.Context, registry, target common.Address) (bool, uint8) {
+	data, err := threatRegistryABI.Pack("isContractEnforced", target)
+	if err != nil {
+		return false, 0
+	}
+	c, _ := ctx.CacheContext()
+	c = c.WithGasMeter(storetypes.NewInfiniteGasMeter()).WithKVGasConfig(storetypes.GasConfig{}).
+		WithTransientKVGasConfig(storetypes.GasConfig{}).WithEventManager(sdk.NewEventManager())
+	var res *evmtypes.MsgEthereumTxResponse
+	func() {
+		defer func() { _ = recover() }()
+		sdb := statedb.New(c, app.EVMKeeper, statedb.NewEmptyTxConfig())
+		res, err = app.EVMKeeper.ApplyMessage(c, sdb, core.Message{
+			From: SecurityPrecompileAddress, To: &registry, Value: new(big.Int), GasLimit: 21000 + threatGateGas, Data: data,
+			GasPrice: new(big.Int), GasFeeCap: new(big.Int), GasTipCap: new(big.Int), AccessList: ethtypes.AccessList{},
+			SkipNonceChecks: true,
+		}, nil, false, false, true)
+	}()
+	if err != nil || res == nil || res.Failed() || len(res.Ret) != 64 {
+		return false, 0
+	}
+	out, err := threatRegistryABI.Unpack("isContractEnforced", res.Ret)
+	if err != nil || len(out) != 2 {
+		return false, 0
+	}
+	on, _ := out[0].(bool)
+	reason, _ := out[1].(uint8)
+	return on, reason
+}
+
+// threatCheck refuses a call from `from` to `to` that the gate stops.
+func (app *EVMD) threatCheck(ctx sdk.Context, from, to common.Address) error {
+	reg, on := app.threatGate(ctx)
+	if !on || !app.secV3(ctx) || threatSystemAddress(to) || to == reg {
+		return nil
+	}
+	if app.consentUntil(ctx, from, to) > ctx.BlockTime().Unix() {
+		return nil
+	}
+	enforced, reason := app.threatEnforced(ctx, reg, to)
+	if !enforced {
+		return nil
+	}
+	name := fmt.Sprint(reason)
+	if int(reason) < len(ThreatReasons) {
+		name = ThreatReasons[reason]
+	}
+	return errorsmod.Wrapf(ErrThreatFlagged, "%s has an enforced flag in the Neuro threat registry %s (reason: %s). Nothing was done. "+
+		"To go ahead anyway, first send consent(%s, seconds) to %s from %s (valid up to %d seconds), then send this again",
+		to.Hex(), reg.Hex(), name, to.Hex(), SecurityPrecompileAddress.Hex(), from.Hex(), MaxConsentSeconds)
+}
+
+// threatGateTx: the gate in the ante handler, for Ethereum txs and
+// MsgEVMCall (also inside authz). MsgEVMCall is checked again where it runs
+// (evmCall), which covers governance proposals and nested execution.
+func (app *EVMD) threatGateTx(ctx sdk.Context, tx sdk.Tx) error {
+	if _, on := app.threatGate(ctx); !on {
+		return nil
+	}
+	msgs := append([]sdk.Msg{}, tx.GetMsgs()...)
+	for i := 0; i < len(msgs) && i < 64; i++ {
+		switch m := msgs[i].(type) {
+		case *authz.MsgExec:
+			if inner, err := m.GetMessages(); err == nil {
+				msgs = append(msgs, inner...)
+			}
+		case *MsgEVMCall: // also checked where it runs; here so CheckTx refuses it at once
+			if m.To == "" || !common.IsHexAddress(m.To) || isGovAddr(m.Sender) {
+				continue
+			}
+			from := m.Sender
+			if m.AsOwner != "" {
+				from = m.AsOwner
+			}
+			a, err := pqAddr(from)
+			if err != nil {
+				continue
+			}
+			if err := app.threatCheck(ctx, common.BytesToAddress(a), common.HexToAddress(m.To)); err != nil {
+				return err
+			}
+		case *evmtypes.MsgEthereumTx:
+			t := m.AsTransaction()
+			if t == nil || t.To() == nil {
+				continue
+			}
+			if err := app.threatCheck(ctx, common.BytesToAddress(m.From), *t.To()); err != nil {
+				return err
+			}
+		}
+	}
+	return nil
+}
+
+// threatRefusedKey marks, in a block, a tx the gate refused in the ante
+// handler; threatRefused returns that refusal.
+type threatRefusedKey struct{}
+
+func threatRefused(ctx sdk.Context) error {
+	err, _ := ctx.Value(threatRefusedKey{}).(error)
+	return err
+}
+
+// threatMempoolCheck: the same rule when an EVM tx is submitted, on the
+// latest committed state, so the wallet sees the refusal at once.
+func (app *EVMD) threatMempoolCheck(from common.Address, tx *ethtypes.Transaction) error {
+	if tx.To() == nil {
+		return nil
+	}
+	ctx, err := app.CreateQueryContext(0, false)
+	if err != nil {
+		return nil
+	}
+	return app.threatCheck(ctx.WithBlockHeight(ctx.BlockHeight()+1), from, *tx.To())
+}
diff --git a/evmd/zetaphy_upgrade.go b/evmd/zetaphy_upgrade.go
new file mode 100644
index 0000000..d629c38
--- /dev/null
+++ b/evmd/zetaphy_upgrade.go
@@ -0,0 +1,170 @@
+package evmd
+
+// ZETAPHY v2 activation height.
+//
+// The dEaD burn (zetaphy_feeburn.go), the EIP-2935 history contract install
+// and block.prevrandao from the vote certificate (zetaphy_random.go), and the
+// proposer's own entry in the certificate (zetaphy_pqcert.go) change how a
+// block runs. They apply only from the height stored under key 0x08 of the
+// zetaphypq store; below it (or while it is unset) a block runs exactly as
+// before: no burn at dEaD, no install, PREVRANDAO = 0xff…ff (upstream), and
+// the old certificate rule. Replaying an existing chain with this binary
+// therefore gives the same state.
+//
+//   - New chain: `zetaphyd init` writes app_state.zetaphypq with the height 1
+//     (DefaultGenesis below), and setup-node.sh sets it again explicitly.
+//   - Existing chain: a software-upgrade proposal named "zetaphy-v2"; its
+//     handler (registerZetaphyUpgrades) sets the height to the upgrade
+//     height + 1 and the EVM history window to 8191 (EIP-2935).
+//   - Genesis export keeps it (as 1 once it is active).
+
+import (
+	"context"
+	"encoding/binary"
+	"encoding/hex"
+	"encoding/json"
+	"fmt"
+
+	gwruntime "github.com/grpc-ecosystem/grpc-gateway/runtime"
+
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/codec"
+	codectypes "github.com/cosmos/cosmos-sdk/codec/types"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	"github.com/cosmos/cosmos-sdk/types/module"
+	upgradetypes "github.com/cosmos/cosmos-sdk/x/upgrade/types"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+// ZetaphyV2UpgradeName is the software-upgrade plan name that turns the v2
+// features on for a chain that runs without them.
+const ZetaphyV2UpgradeName = "zetaphy-v2"
+
+// ZetaphyV3UpgradeName turns the security core (zetaphy_security.go) on for
+// a chain that runs without it: key 0x0F of the zetaphypq store = the
+// upgrade height + 1. Its rules themselves stay off until governance sets them.
+const ZetaphyV3UpgradeName = "zetaphy-v3"
+
+var pqActivationKey = []byte{8} // height (8 bytes) from which the v2 features apply
+
+// zetaphyV2Height is the activation height, 0 when unset (never). It reads
+// the store without gas: it also runs inside EVM calls.
+func (app *EVMD) zetaphyV2Height(ctx sdk.Context) int64 {
+	v := ctx.MultiStore().GetKVStore(app.GetKey(pqStoreKey)).Get(pqActivationKey)
+	if len(v) != 8 {
+		return 0
+	}
+	return int64(binary.BigEndian.Uint64(v)) // #nosec G115 -- block heights
+}
+
+// zetaphyV2 reports whether block h runs with the v2 features.
+func (app *EVMD) zetaphyV2(ctx sdk.Context, h int64) bool {
+	a := app.zetaphyV2Height(ctx)
+	return a > 0 && h >= a
+}
+
+func (app *EVMD) setZetaphyV2Height(ctx sdk.Context, h int64) {
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(pqActivationKey, binary.BigEndian.AppendUint64(nil, uint64(h))) // #nosec G115 -- block heights
+}
+
+// registerZetaphyUpgrades: the "zetaphy-v2" upgrade for a chain that runs a
+// binary without the v2 features. Propose it with
+// `gov.sh propose-upgrade zetaphy-v2 <H> "<summary>"`, vote it through, and
+// have every validator switch to this binary when the chain stops at H.
+// Upgrade handlers run in the upgrade module's PreBlocker, after the
+// prevrandao of block H was fixed, so the features start at H+1.
+func (app *EVMD) registerZetaphyUpgrades() {
+	app.UpgradeKeeper.SetUpgradeHandler(ZetaphyV2UpgradeName,
+		func(c context.Context, _ upgradetypes.Plan, fromVM module.VersionMap) (module.VersionMap, error) {
+			ctx := sdk.UnwrapSDKContext(c)
+			p := app.EVMKeeper.GetParams(ctx)
+			p.HistoryServeWindow = evmtypes.DefaultHistoryServeWindow // 8191, the ring of the EIP-2935 contract
+			if err := app.EVMKeeper.SetParams(ctx, p); err != nil {
+				return nil, err
+			}
+			app.setZetaphyV2Height(ctx, ctx.BlockHeight()+1)
+			ctx.Logger().Info("ZETAPHY v2 features scheduled", "from_height", ctx.BlockHeight()+1)
+			return app.zetaphyWasmMigrations(c, fromVM)
+		})
+
+	app.UpgradeKeeper.SetUpgradeHandler(ZetaphyV3UpgradeName,
+		func(c context.Context, _ upgradetypes.Plan, fromVM module.VersionMap) (module.VersionMap, error) {
+			ctx := sdk.UnwrapSDKContext(c)
+			if !app.zetaphyV2(ctx, ctx.BlockHeight()+1) { // v3 includes v2
+				p := app.EVMKeeper.GetParams(ctx)
+				p.HistoryServeWindow = evmtypes.DefaultHistoryServeWindow
+				if err := app.EVMKeeper.SetParams(ctx, p); err != nil {
+					return nil, err
+				}
+				app.setZetaphyV2Height(ctx, ctx.BlockHeight()+1)
+			}
+			app.setSecV3Height(ctx, ctx.BlockHeight()+1)
+			ctx.Logger().Info("ZETAPHY security core scheduled", "from_height", ctx.BlockHeight()+1)
+			return app.zetaphyWasmMigrations(c, fromVM)
+		})
+	app.registerZetaphyV4() // "zetaphy-v4": CosmWasm (zetaphy_cosmwasm.go)
+	app.registerZetaphyV5() // "zetaphy-v5": immune system, AI precompile, breaker, account guard (zetaphy_future.go)
+
+	info, err := app.UpgradeKeeper.ReadUpgradeInfoFromDisk()
+	if err != nil {
+		panic(err)
+	}
+	if (info.Name == ZetaphyV2UpgradeName || info.Name == ZetaphyV3UpgradeName || info.Name == ZetaphyV4UpgradeName) &&
+		!app.UpgradeKeeper.IsSkipHeight(info.Height) {
+		// Stores the running binary does not have yet go here: the wasm
+		// store (a chain started with x/wasm never runs these upgrades).
+		// pqStoreKey and ratelimittypes.StoreKey are not: a chain started
+		// with the PQ patch already has both.
+		app.SetStoreLoader(upgradetypes.UpgradeStoreLoader(info.Height, zetaphyStoreUpgrades()))
+	}
+}
+
+// ---- genesis (app_state.zetaphypq)
+
+// pqParseGenesis decodes and checks app_state.zetaphypq.
+func pqParseGenesis(raw json.RawMessage) ([][2][]byte, error) {
+	var in []pqGenesisEntry
+	if len(raw) == 0 { // a genesis from before the PQ patch has none
+		return nil, nil
+	}
+	if err := json.Unmarshal(raw, &in); err != nil {
+		return nil, err
+	}
+	out := make([][2][]byte, 0, len(in))
+	for _, e := range in {
+		k, err1 := hex.DecodeString(e.Key)
+		v, err2 := hex.DecodeString(e.Value)
+		if err1 != nil || err2 != nil || len(k) == 0 || (k[0] != 1 && k[0] != 2 && k[0] != pqEvidenceKey[0] && k[0] != pqActivationKey[0] && !secKeyKnown(k[0]) && !futKeyKnown(k[0])) {
+			return nil, fmt.Errorf("zetaphypq genesis: bad entry %q", e.Key)
+		}
+		if (k[0] == pqActivationKey[0] || k[0] == secV3Key[0] || k[0] == futV5Key[0]) && (len(k) != 1 || len(v) != 8) {
+			return nil, fmt.Errorf("zetaphypq genesis: activation height: want key %02x and 8 bytes", k[0])
+		}
+		out = append(out, [2][]byte{k, v})
+	}
+	return out, nil
+}
+
+// pqGenesisBasic makes `zetaphyd init` write app_state.zetaphypq with the v2
+// features on from block 1, and `genesis validate-genesis` check it. It is
+// only a module basic (no store or keeper of its own: InitChainer and the
+// export handle the zetaphypq store).
+type pqGenesisBasic struct{}
+
+func (pqGenesisBasic) Name() string                                                  { return pqStoreKey }
+func (pqGenesisBasic) RegisterLegacyAminoCodec(*codec.LegacyAmino)                   {}
+func (pqGenesisBasic) RegisterInterfaces(codectypes.InterfaceRegistry)               {}
+func (pqGenesisBasic) RegisterGRPCGatewayRoutes(client.Context, *gwruntime.ServeMux) {}
+
+func (pqGenesisBasic) DefaultGenesis(codec.JSONCodec) json.RawMessage {
+	one := hex.EncodeToString(binary.BigEndian.AppendUint64(nil, 1))
+	bz, _ := json.Marshal([]pqGenesisEntry{{hex.EncodeToString(pqActivationKey), one}, {hex.EncodeToString(secV3Key), one},
+		{hex.EncodeToString(futV5Key), one}}) // ZETAPHY v5 (zetaphy_future.go): its settings stay off until voted
+	return bz
+}
+
+func (pqGenesisBasic) ValidateGenesis(_ codec.JSONCodec, _ client.TxEncodingConfig, raw json.RawMessage) error {
+	_, err := pqParseGenesis(raw)
+	return err
+}
diff --git a/evmd/zetaphy_upgradeguard.go b/evmd/zetaphy_upgradeguard.go
new file mode 100644
index 0000000..3bb3a85
--- /dev/null
+++ b/evmd/zetaphy_upgradeguard.go
@@ -0,0 +1,73 @@
+package evmd
+
+// ZETAPHY: upgrades whose binary may run before the upgrade height.
+//
+// x/upgrade stops the chain when the running binary already has the handler
+// of a scheduled plan that is not due yet ("BINARY UPDATED BEFORE TRIGGER!").
+// That guard protects upgrades whose new code would change blocks before the
+// height. A ZETAPHY upgrade listed in zetaphyEarlyUpgrades does not: below its
+// height the new binary runs blocks exactly as the old one (its features are
+// gated by a height kept in state, which only the handler sets), and it adds
+// no store. For those, a validator may install the new binary any time before
+// the height; at the height the handler runs and the chain does not stop.
+//
+// The 2026-10-29 testnet halt at block 123343 (proposal 3, "zetaphy-v5") is the
+// case this covers: the release with the v5 handler was installed before the
+// vote passed, and the chain stopped one block later.
+//
+// Rules for adding a name here: the handler only sets activation heights or
+// params from the upgrade height on, every new code path is gated by them, and
+// the upgrade has no StoreUpgrades. Upgrades that add a store (zetaphy-v2..v4
+// add the wasm store) keep the SDK's guard.
+
+import (
+	"context"
+	"fmt"
+
+	"cosmossdk.io/core/appmodule"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	"github.com/cosmos/cosmos-sdk/x/upgrade"
+	upgradekeeper "github.com/cosmos/cosmos-sdk/x/upgrade/keeper"
+)
+
+var zetaphyEarlyUpgrades = map[string]bool{
+	ZetaphyV5UpgradeName: true,
+}
+
+// zetaphyUpgradeModule is x/upgrade with one change in PreBlock: a scheduled,
+// not yet due plan named in zetaphyEarlyUpgrades does not stop the chain when
+// this binary already has its handler.
+type zetaphyUpgradeModule struct {
+	upgrade.AppModule
+	k *upgradekeeper.Keeper
+}
+
+func newZetaphyUpgradeModule(m upgrade.AppModule, k *upgradekeeper.Keeper) zetaphyUpgradeModule {
+	return zetaphyUpgradeModule{AppModule: m, k: k}
+}
+
+// PreBlock keeps every other case of x/upgrade's PreBlocker: a due plan is
+// applied (or, without a handler, stops the chain with "UPGRADE NEEDED"), and
+// any other early handler still stops it.
+func (m zetaphyUpgradeModule) PreBlock(ctx context.Context) (appmodule.ResponsePreBlock, error) {
+	sdkCtx := sdk.UnwrapSDKContext(ctx)
+	plan, err := m.k.GetUpgradePlan(ctx)
+	if err != nil || !zetaphyEarlyUpgrades[plan.Name] || plan.ShouldExecute(sdkCtx.HeaderInfo().Height) || !m.k.HasHandler(plan.Name) {
+		return m.AppModule.PreBlock(ctx)
+	}
+	// The check x/upgrade runs once per process: the last applied upgrade must
+	// have its handler in this binary.
+	if !m.k.DowngradeVerified() {
+		m.k.SetDowngradeVerified(true)
+		last, _, err := m.k.GetLastCompletedUpgrade(ctx)
+		if err != nil {
+			return nil, err
+		}
+		if last != "" && !m.k.HasHandler(last) {
+			return nil, fmt.Errorf("upgrade handler is missing for %s upgrade plan", last)
+		}
+	}
+	sdkCtx.Logger().Debug("ZETAPHY: binary with the handler of a scheduled upgrade, before its height (allowed)", "upgrade", plan.Name, "height", plan.Height)
+	return &sdk.ResponsePreBlock{ConsensusParamsChanged: false}, nil
+}
diff --git a/go.mod b/go.mod
index 777e52d..c4797ba 100644
--- a/go.mod
+++ b/go.mod
@@ -119,6 +119,7 @@ require (
 	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
 	github.com/cespare/xxhash/v2 v2.3.0 // indirect
 	github.com/chzyer/readline v1.5.1 // indirect
+	github.com/cloudflare/circl v1.6.3 // indirect
 	github.com/cloudwego/base64x v0.1.6 // indirect
 	github.com/cncf/xds/go v0.0.0-20260202195803-dba9d589def2 // indirect
 	github.com/cockroachdb/errors v1.13.0 // indirect
diff --git a/go.sum b/go.sum
index 11f8f59..bbea7b7 100644
--- a/go.sum
+++ b/go.sum
@@ -215,6 +215,8 @@ github.com/circonus-labs/circonus-gometrics v2.3.1+incompatible/go.mod h1:nmEj6D
 github.com/circonus-labs/circonusllhist v0.1.3/go.mod h1:kMXHVDlOchFAehlya5ePtbp5jckzBHf4XRpQvBOLI+I=
 github.com/clbanning/x2j v0.0.0-20191024224557-825249438eec/go.mod h1:jMjuTZXRI4dUb/I5gc9Hdhagfvm9+RyrPryS/auMzxE=
 github.com/client9/misspell v0.3.4/go.mod h1:qj6jICC3Q7zFZvVWo7KLAzC3yx5G7kyvSDkc90ppPyw=
+github.com/cloudflare/circl v1.6.3 h1:9GPOhQGF9MCYUeXyMYlqTR6a5gTrgR/fBLXvUgtVcg8=
+github.com/cloudflare/circl v1.6.3/go.mod h1:2eXP6Qfat4O/Yhh8BznvKnJ+uzEoTQ6jVKJRn81BiS4=
 github.com/cloudwego/base64x v0.1.6 h1:t11wG9AECkCDk5fMSoxmufanudBtJ+/HemLstXDLI2M=
 github.com/cloudwego/base64x v0.1.6/go.mod h1:OFcloc187FXDaYHvrNIjxSe8ncn0OOM8gEHfghB2IPU=
 github.com/cncf/udpa/go v0.0.0-20191209042840-269d4d468f6f/go.mod h1:M8M6+tZqaGXZJjfX53e64911xZQV5JYwmTeXPW+k8Sc=
diff --git a/mempool/mempool.go b/mempool/mempool.go
index 74c2f89..22fc803 100644
--- a/mempool/mempool.go
+++ b/mempool/mempool.go
@@ -113,6 +113,9 @@ type Mempool struct {
 	/** Keepers **/
 	vmKeeper VMKeeperI
 
+	// ZETAPHY: the app's extra check on EVM txs at submission (zetaphy_lock.go)
+	zetaphyCheck func(common.Address, *ethtypes.Transaction) error
+
 	/** Mempools **/
 	txPool                   *txpool.TxPool
 	legacyTxPool             *legacypool.LegacyPool
@@ -333,6 +336,9 @@ func (m *Mempool) insert(tx sdk.Tx) (<-chan error, error) {
 	switch {
 	case err == nil:
 		ethTx := ethMsg.AsTransaction()
+		if ethTx == nil {
+			return nil, errors.New("empty ethereum transaction")
+		}
 
 		// Reject txs below base fee up-front, which can never be included.
 		if baseFee := m.blockchain.CurrentBlock().BaseFee; baseFee != nil && ethTx.GasFeeCapIntCmp(baseFee) < 0 {
@@ -341,6 +347,9 @@ func (m *Mempool) insert(tx sdk.Tx) (<-chan error, error) {
 				ethTx.GasFeeCap(), baseFee,
 			)
 		}
+		if err := m.pqLockCheck(ethTx); err != nil { // ZETAPHY
+			return nil, err
+		}
 
 		// we push the tx onto the evm insert queue so the tx will be inserted
 		// at a later point. We get back a subscription that the insert queue
diff --git a/mempool/mempool_handlers.go b/mempool/mempool_handlers.go
index 2484d04..cfc6fbb 100644
--- a/mempool/mempool_handlers.go
+++ b/mempool/mempool_handlers.go
@@ -11,6 +11,7 @@ import (
 	errorsmod "cosmossdk.io/errors"
 
 	sdk "github.com/cosmos/cosmos-sdk/types"
+	sdkerrors "github.com/cosmos/cosmos-sdk/types/errors"
 )
 
 const (
@@ -77,7 +78,10 @@ func (m *Mempool) NewCheckTxHandler(txDecoder sdk.TxDecoder, timeout time.Durati
 
 		tx, err := txDecoder(req.GetTx())
 		if err != nil {
-			return nil, fmt.Errorf("decoding tx: %w", err)
+			// ZETAPHY: answer with an error code. Returning a Go error makes
+			// CometBFT's AppMempool drop the request without calling the RPC
+			// callback, so broadcast_tx_sync and REST would hang forever.
+			return ErrAsCheckTxResponse(errorsmod.Wrap(sdkerrors.ErrTxDecode, err.Error())), nil
 		}
 
 		err = m.Insert(ctx, tx)
diff --git a/mempool/recheck_pool.go b/mempool/recheck_pool.go
index 5a38319..508ebac 100644
--- a/mempool/recheck_pool.go
+++ b/mempool/recheck_pool.go
@@ -176,6 +176,13 @@ func (m *RecheckMempool) Close() error {
 // Insert adds a transaction to the pool after running the ante handler.
 // This is the main entry point for new cosmos transactions.
 func (m *RecheckMempool) Insert(_ context.Context, tx sdk.Tx) (err error) {
+	// ZETAPHY: this runs outside baseapp's panic recovery; a malformed tx must
+	// be an error, not a crash of the node.
+	defer func() {
+		if r := recover(); r != nil {
+			err = fmt.Errorf("invalid transaction: %v", r)
+		}
+	}()
 	// Reserve addresses to prevent conflicts with EVM pool
 	addrs, err := m.reserveTx(tx)
 	if err != nil {
@@ -183,6 +190,9 @@ func (m *RecheckMempool) Insert(_ context.Context, tx sdk.Tx) (err error) {
 	}
 
 	defer func() {
+		if r := recover(); r != nil {
+			err = fmt.Errorf("invalid transaction: %v", r)
+		}
 		if err == nil {
 			return
 		}
diff --git a/mempool/zetaphy_lock.go b/mempool/zetaphy_lock.go
new file mode 100644
index 0000000..81015e1
--- /dev/null
+++ b/mempool/zetaphy_lock.go
@@ -0,0 +1,46 @@
+package mempool
+
+import (
+	"fmt"
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+// pqLockCheck (ZETAPHY) refuses, at submission, an EVM tx sent by a
+// quantum-locked account or carrying its EIP-7702 authorization, and every
+// ECDSA-signed EVM tx once Q-day is reached, so the wallet gets an error
+// instead of a tx that stays pending. The ante handler refuses them as well.
+// The app's extra check (SetZetaphyCheck: the threat gate) runs last.
+func (m *Mempool) pqLockCheck(tx *ethtypes.Transaction) error {
+	st, err := m.blockchain.StateAt(m.blockchain.CurrentBlock().Hash())
+	if err != nil || st == nil {
+		return nil
+	}
+	if next := new(big.Int).Add(m.blockchain.CurrentBlock().Number, big.NewInt(1)); evmtypes.QDayReached(st.GetState, next) {
+		return fmt.Errorf("Q-day (block %s) has passed: ECDSA-signed transactions are no longer accepted; a migrated account acts through its ML-DSA-44 controller", st.GetState(evmtypes.PQLockAddress, evmtypes.QDaySlot).Big())
+	}
+	from, err := ethtypes.Sender(ethtypes.LatestSignerForChainID(tx.ChainId()), tx)
+	if err == nil && evmtypes.PQLocked(st.GetState, from) {
+		return fmt.Errorf("%s is quantum-locked: only its ML-DSA-44 controller can act for it", from.Hex())
+	}
+	for _, a := range tx.SetCodeAuthorizations() {
+		if au, err := a.Authority(); err == nil && evmtypes.PQLocked(st.GetState, au) {
+			return fmt.Errorf("authorization signed by %s, which is quantum-locked", au.Hex())
+		}
+	}
+	if m.zetaphyCheck != nil && err == nil {
+		return m.zetaphyCheck(from, tx)
+	}
+	return nil
+}
+
+// SetZetaphyCheck (ZETAPHY) sets a check every EVM tx passes at submission,
+// after the quantum-lock and Q-day checks (the app's threat gate). It must
+// only read state; the ante handler applies the same rule in blocks.
+func (m *Mempool) SetZetaphyCheck(f func(from common.Address, tx *ethtypes.Transaction) error) {
+	m.zetaphyCheck = f
+}
diff --git a/precompiles/mldsa/mldsa.go b/precompiles/mldsa/mldsa.go
new file mode 100644
index 0000000..a291984
--- /dev/null
+++ b/precompiles/mldsa/mldsa.go
@@ -0,0 +1,98 @@
+// Package mldsa adds post-quantum signature verification to the EVM:
+// ML-DSA (FIPS 204, the NIST standard formerly called CRYSTALS-Dilithium).
+// ZETAPHY stage 5: smart wallets can require a signature that a quantum
+// computer cannot forge, alongside (or instead of) secp256k1 ECDSA.
+//
+// Input:  1 byte  parameter set: 44 (ML-DSA-44) or 65 (ML-DSA-65)
+//
+//	32 bytes message (usually a hash the wallet signed)
+//	public key  (1312 bytes for 44, 1952 for 65)
+//	signature   (2420 bytes for 44, 3309 for 65)
+//
+// Output: 32 bytes ending in 0x01 when the signature is valid; empty
+//
+//	otherwise (the same convention as the P256 precompile, RIP-7212).
+//
+// Pure ML-DSA with an empty context string, as FIPS 204 section 5.2.
+package mldsa
+
+import (
+	"github.com/cloudflare/circl/sign/mldsa/mldsa44"
+	"github.com/cloudflare/circl/sign/mldsa/mldsa65"
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	evmtypes "github.com/cosmos/evm/x/vm/types"
+)
+
+var _ vm.PrecompiledContract = &Precompile{}
+
+const (
+	// Gas per verification. Verifying takes roughly the time of a few
+	// ECDSA recoveries; the large input already pays calldata gas.
+	VerifyGas44 uint64 = 30_000
+	VerifyGas65 uint64 = 45_000
+	// InvalidInputGas is charged when the input has no valid shape.
+	InvalidInputGas uint64 = 3_000
+
+	Variant44 byte = 44
+	Variant65 byte = 65
+)
+
+type Precompile struct{}
+
+func (Precompile) Name() string { return "mldsa" }
+
+func (Precompile) Address() common.Address {
+	return common.HexToAddress(evmtypes.MLDSAPrecompileAddress)
+}
+
+func (Precompile) RequiredGas(input []byte) uint64 {
+	if len(input) > 0 {
+		switch input[0] {
+		case Variant44:
+			return VerifyGas44
+		case Variant65:
+			return VerifyGas65
+		}
+	}
+	return InvalidInputGas
+}
+
+var valid = common.LeftPadBytes([]byte{1}, 32)
+
+func (p *Precompile) Run(_ *vm.EVM, contract *vm.Contract, _ bool) ([]byte, error) {
+	if Verify(contract.Input) {
+		return valid, nil
+	}
+	return nil, nil
+}
+
+// Verify checks one packed input as described in the package comment.
+func Verify(in []byte) bool {
+	if len(in) < 33 {
+		return false
+	}
+	variant, msg, rest := in[0], in[1:33], in[33:]
+	switch variant {
+	case Variant44:
+		if len(rest) != mldsa44.PublicKeySize+mldsa44.SignatureSize {
+			return false
+		}
+		var pk mldsa44.PublicKey
+		if pk.UnmarshalBinary(rest[:mldsa44.PublicKeySize]) != nil {
+			return false
+		}
+		return mldsa44.Verify(&pk, msg, nil, rest[mldsa44.PublicKeySize:])
+	case Variant65:
+		if len(rest) != mldsa65.PublicKeySize+mldsa65.SignatureSize {
+			return false
+		}
+		var pk mldsa65.PublicKey
+		if pk.UnmarshalBinary(rest[:mldsa65.PublicKeySize]) != nil {
+			return false
+		}
+		return mldsa65.Verify(&pk, msg, nil, rest[mldsa65.PublicKeySize:])
+	}
+	return false
+}
diff --git a/precompiles/types/defaults.go b/precompiles/types/defaults.go
index cd68986..f192838 100644
--- a/precompiles/types/defaults.go
+++ b/precompiles/types/defaults.go
@@ -79,6 +79,7 @@ func DefaultStaticPrecompiles(
 	precompiles := NewStaticPrecompiles().
 		WithPraguePrecompiles().
 		WithP256Precompile().
+		WithMLDSAPrecompile().
 		WithBech32Precompile().
 		WithStakingPrecompile(stakingKeeper, bankKeeper, opts...).
 		WithDistributionPrecompile(distributionKeeper, stakingKeeper, bankKeeper, opts...).
diff --git a/precompiles/types/static_precompiles.go b/precompiles/types/static_precompiles.go
index 7f19b35..ec74b76 100644
--- a/precompiles/types/static_precompiles.go
+++ b/precompiles/types/static_precompiles.go
@@ -15,6 +15,7 @@ import (
 	govprecompile "github.com/cosmos/evm/precompiles/gov"
 	ics02precompile "github.com/cosmos/evm/precompiles/ics02"
 	ics20precompile "github.com/cosmos/evm/precompiles/ics20"
+	"github.com/cosmos/evm/precompiles/mldsa"
 	"github.com/cosmos/evm/precompiles/p256"
 	slashingprecompile "github.com/cosmos/evm/precompiles/slashing"
 	stakingprecompile "github.com/cosmos/evm/precompiles/staking"
@@ -46,6 +47,12 @@ func (s StaticPrecompiles) WithP256Precompile() StaticPrecompiles {
 	return s
 }
 
+func (s StaticPrecompiles) WithMLDSAPrecompile() StaticPrecompiles {
+	mldsaPrecompile := &mldsa.Precompile{}
+	s[mldsaPrecompile.Address()] = mldsaPrecompile
+	return s
+}
+
 func (s StaticPrecompiles) WithBech32Precompile() StaticPrecompiles {
 	bech32Precompile, err := bech32.NewPrecompile(bech32PrecompileBaseGas)
 	if err != nil {
diff --git a/x/vm/keeper/abci.go b/x/vm/keeper/abci.go
index 1f241fa..a4cda86 100644
--- a/x/vm/keeper/abci.go
+++ b/x/vm/keeper/abci.go
@@ -34,7 +34,9 @@ func (k *Keeper) BeginBlock(ctx sdk.Context) (err error) {
 		})
 	}
 
-	k.SetHeaderHash(ctx)
+	// ZETAPHY: the block's hash is recorded at the end of the block (below),
+	// not here, as EIP-2935 does: while block N runs, slot N % 8191 must
+	// still hold block N-8191, which the history contract serves.
 	return nil
 }
 
@@ -46,6 +48,7 @@ func (k *Keeper) EndBlock(ctx sdk.Context) (err error) {
 	defer func() { evmtrace.EndSpanErr(span, err) }()
 
 	k.CollectTxBloom(ctx)
+	k.SetHeaderHash(ctx) // ZETAPHY: moved from BeginBlock
 
 	return nil
 }
diff --git a/x/vm/keeper/keeper.go b/x/vm/keeper/keeper.go
index 6b7b956..fc7430b 100644
--- a/x/vm/keeper/keeper.go
+++ b/x/vm/keeper/keeper.go
@@ -86,6 +86,12 @@ type Keeper struct {
 	// virtualFeeCollection enabling will use "Virtual" methods from the bank module to accumulate
 	// fees to the fee collector module in the endBlocker instead of using regular sends during tx execution.
 	virtualFeeCollection bool
+
+	// ZETAPHY: supplies block.prevrandao (zetaphy_random.go); nil keeps the
+	// upstream constant.
+	randomFn func(sdk.Context) common.Hash
+	// ZETAPHY: chain-defined precompiles (SetZetaphyPrecompiles)
+	zetaphyPrecompile func(sdk.Context, common.Address) (vm.PrecompiledContract, bool)
 }
 
 // NewKeeper generates new evm module keeper
diff --git a/x/vm/keeper/precompiles.go b/x/vm/keeper/precompiles.go
index ee26a8e..d65c670 100644
--- a/x/vm/keeper/precompiles.go
+++ b/x/vm/keeper/precompiles.go
@@ -27,11 +27,23 @@ func (k *Keeper) GetPrecompileInstance(
 		attribute.String("address", address.Hex()),
 	))
 	defer func() { evmtrace.EndSpanErr(span, err) }()
+	// ZETAPHY: ecrecover that refuses quantum-locked accounts (zetaphy_ecrecover.go).
+	if address == ecrecoverAddress {
+		return &Precompiles{Map: map[common.Address]vm.PrecompiledContract{address: pqEcrecover{}}, Addresses: []common.Address{address}}, true, nil
+	}
+	if k.zetaphyPrecompile != nil { // ZETAPHY: e.g. the security precompile at 0x…0901
+		if p, ok := k.zetaphyPrecompile(ctx, address); ok {
+			return &Precompiles{Map: map[common.Address]vm.PrecompiledContract{address: p}, Addresses: []common.Address{address}}, true, nil
+		}
+	}
 	params := k.GetParams(ctx)
 	// Get the precompile from the static precompiles
 	if precompile, found, err := k.GetStaticPrecompileInstance(&params, address); err != nil {
 		return nil, false, err
 	} else if found {
+		if address == p256Address { // ZETAPHY: P256VERIFY answers nothing from Q-day on (zetaphy_ecrecover.go)
+			precompile = pqP256{precompile}
+		}
 		addressMap := make(map[common.Address]vm.PrecompiledContract)
 		addressMap[address] = precompile
 		return &Precompiles{
diff --git a/x/vm/keeper/state_transition.go b/x/vm/keeper/state_transition.go
index 0c160b4..b6815dc 100644
--- a/x/vm/keeper/state_transition.go
+++ b/x/vm/keeper/state_transition.go
@@ -60,7 +60,7 @@ func (k *Keeper) NewEVMWithOverridePrecompiles(
 		Time:        uint64(ctx.BlockHeader().Time.Unix()), //#nosec G115 -- int overflow is not a concern here
 		Difficulty:  big.NewInt(0),                         // unused. Only required in PoW context
 		BaseFee:     cfg.BaseFee,
-		Random:      &common.MaxHash, // need to be different than nil to signal it is after the merge and pick up the right opcodes
+		Random:      k.prevRandao(ctx), // ZETAPHY (zetaphy_random.go); never nil, so the post-merge opcodes apply
 	}
 
 	ethCfg := types.GetEthChainConfig()
@@ -422,6 +422,10 @@ func (k *Keeper) ApplyMessageWithConfig(ctx sdk.Context, stateDB *statedb.StateD
 				precompiles[address] = precompile
 			}
 		}
+		precompiles[ecrecoverAddress] = pqEcrecover{} // ZETAPHY
+		if p, ok := precompiles[p256Address]; ok {
+			precompiles[p256Address] = pqP256{p} // ZETAPHY
+		}
 		if err := overrides.Apply(stateDB, precompiles); err != nil {
 			return nil, errorsmod.Wrap(err, "failed to apply state override")
 		}
diff --git a/x/vm/keeper/zetaphy_ecrecover.go b/x/vm/keeper/zetaphy_ecrecover.go
new file mode 100644
index 0000000..bc95e2e
--- /dev/null
+++ b/x/vm/keeper/zetaphy_ecrecover.go
@@ -0,0 +1,70 @@
+package keeper
+
+import (
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/tracing"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	"github.com/cosmos/evm/x/vm/types"
+)
+
+// ZETAPHY: an ECDSA account handed to an ML-DSA-44 controller (quantum lock,
+// evmd/zetaphy_pqguard.go) is marked in the storage of types.PQLockAddress. Contracts check ECDSA signatures with
+// ecrecover (0x01), so permits, Permit2 and meta-transactions signed by a
+// locked account are treated as invalid signatures: ecrecover returns nothing.
+//
+// Security core (evmd/zetaphy_qday.go):
+//   - from the Q-day height on, ecrecover returns nothing for every
+//     signature: an ECDSA signature no longer proves anything; the same for
+//     P256VERIFY (0x…0100, secp256r1, also ECDSA), which then answers
+//     "invalid" (empty output, as RIP-7212 does for a bad signature);
+//   - before it, a successful recovery of an account that holds funds but
+//     never sent a transaction marks it "exposed" (its public key is now on
+//     chain), so it cannot use the commit–reveal migration meant for keys
+//     never shown. Accounts without funds are not marked: no state for
+//     random signatures.
+
+var (
+	ecrecoverAddress = common.BytesToAddress([]byte{1})
+	p256Address      = common.HexToAddress(types.P256PrecompileAddress)
+	gethEcrecover    = vm.PrecompiledContractsPrague[ecrecoverAddress]
+)
+
+type pqEcrecover struct{}
+
+func (pqEcrecover) Address() common.Address         { return ecrecoverAddress }
+func (pqEcrecover) RequiredGas(input []byte) uint64 { return gethEcrecover.RequiredGas(input) }
+func (pqEcrecover) Name() string                    { return gethEcrecover.Name() }
+func (pqEcrecover) Run(evm *vm.EVM, c *vm.Contract, ro bool) ([]byte, error) {
+	if types.QDayReached(evm.StateDB.GetState, evm.Context.BlockNumber) {
+		return nil, nil
+	}
+	out, err := gethEcrecover.Run(evm, c, ro)
+	if err != nil || len(out) != 32 {
+		return out, err
+	}
+	who := common.BytesToAddress(out)
+	if types.PQLocked(evm.StateDB.GetState, who) {
+		return nil, nil
+	}
+	// Solidity's ecrecover is a STATICCALL (ro): the mark is the chain's own
+	// bookkeeping, invisible to contracts, so it is written regardless.
+	if types.SecurityV3(evm.StateDB.GetState, evm.Context.BlockNumber) && evm.StateDB.GetNonce(who) == 0 &&
+		evm.StateDB.GetBalance(who).Sign() > 0 && evm.StateDB.GetState(types.PQLockAddress, types.ExposedSlot(who)) == (common.Hash{}) {
+		if evm.StateDB.GetNonce(types.PQLockAddress) == 0 { // never dropped as an empty account
+			evm.StateDB.SetNonce(types.PQLockAddress, 1, tracing.NonceChangeUnspecified)
+		}
+		evm.StateDB.SetState(types.PQLockAddress, types.ExposedSlot(who), common.Hash{31: 1})
+	}
+	return out, nil
+}
+
+// pqP256 wraps the P256VERIFY precompile: from Q-day on it answers nothing.
+type pqP256 struct{ vm.PrecompiledContract }
+
+func (p pqP256) Run(evm *vm.EVM, c *vm.Contract, ro bool) ([]byte, error) {
+	if types.QDayReached(evm.StateDB.GetState, evm.Context.BlockNumber) {
+		return nil, nil
+	}
+	return p.PrecompiledContract.Run(evm, c, ro)
+}
diff --git a/x/vm/keeper/zetaphy_random.go b/x/vm/keeper/zetaphy_random.go
new file mode 100644
index 0000000..6e1f2de
--- /dev/null
+++ b/x/vm/keeper/zetaphy_random.go
@@ -0,0 +1,38 @@
+package keeper
+
+import (
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+)
+
+// ZETAPHY: block.prevrandao (the PREVRANDAO opcode, the block context's
+// Random) comes from the app, which derives it each block from the
+// post-quantum vote certificate (evmd/zetaphy_random.go). Upstream cosmos/evm
+// sets it to a constant (0xff…ff), which any contract can predict.
+
+// SetRandomFn sets the function that gives block.prevrandao for a context.
+// It must be deterministic: every node runs it in DeliverTx.
+func (k *Keeper) SetRandomFn(f func(sdk.Context) common.Hash) *Keeper {
+	k.randomFn = f
+	return k
+}
+
+// prevRandao is never nil: a nil Random would switch the EVM to pre-merge
+// opcodes (DIFFICULTY instead of PREVRANDAO).
+func (k *Keeper) prevRandao(ctx sdk.Context) *common.Hash {
+	if k.randomFn == nil {
+		return &common.MaxHash
+	}
+	h := k.randomFn(ctx)
+	return &h
+}
+
+// SetZetaphyPrecompiles (ZETAPHY) sets chain-defined precompiles that are on
+// regardless of the active_static_precompiles param; f decides from which
+// height each applies (e.g. the security precompile at 0x…0901, evmd).
+func (k *Keeper) SetZetaphyPrecompiles(f func(sdk.Context, common.Address) (vm.PrecompiledContract, bool)) *Keeper {
+	k.zetaphyPrecompile = f
+	return k
+}
diff --git a/x/vm/types/params.go b/x/vm/types/params.go
index 0a9fd86..ec754ec 100644
--- a/x/vm/types/params.go
+++ b/x/vm/types/params.go
@@ -48,7 +48,11 @@ var (
 	}
 )
 
-const DefaultHistoryServeWindow = 8192 // same as EIP-2935
+// DefaultHistoryServeWindow is EIP-2935's HISTORY_SERVE_WINDOW: the history
+// contract (params.HistoryStorageCode) reads slot n % 8191, so the keeper
+// must write block n's hash to that slot. ZETAPHY: upstream had 8192, which
+// made direct calls to the contract return wrong hashes past block 8191.
+const DefaultHistoryServeWindow = 8191
 
 // NewParams creates a new Params instance
 func NewParams(
diff --git a/x/vm/types/precompiles.go b/x/vm/types/precompiles.go
index a7e058a..e64b909 100644
--- a/x/vm/types/precompiles.go
+++ b/x/vm/types/precompiles.go
@@ -3,6 +3,8 @@ package types
 const (
 	P256PrecompileAddress   = "0x0000000000000000000000000000000000000100"
 	Bech32PrecompileAddress = "0x0000000000000000000000000000000000000400"
+	// MLDSAPrecompileAddress: post-quantum ML-DSA (FIPS 204) verification (ZETAPHY).
+	MLDSAPrecompileAddress = "0x0000000000000000000000000000000000000900"
 )
 
 const (
@@ -31,4 +33,5 @@ var AvailableStaticPrecompiles = []string{
 	GovPrecompileAddress,
 	SlashingPrecompileAddress,
 	ICS02PrecompileAddress,
+	MLDSAPrecompileAddress, // 0x…0900, last: the list must stay sorted
 }
diff --git a/x/vm/types/zetaphy.go b/x/vm/types/zetaphy.go
new file mode 100644
index 0000000..b6fb932
--- /dev/null
+++ b/x/vm/types/zetaphy.go
@@ -0,0 +1,51 @@
+package types
+
+import (
+	"math/big"
+
+	"github.com/ethereum/go-ethereum/common"
+)
+
+// PQLockAddress (ZETAPHY): an EVM tx to it, with the controller's address as
+// data, quantum-locks the sender; its storage marks locked accounts (key =
+// account, value = controller). It has no code, so only the chain writes there.
+var PQLockAddress = common.HexToAddress("0x0000000000000000000000000000000000005051")
+
+// Other slots of PQLockAddress (ZETAPHY security core, evmd/zetaphy_qday.go).
+// A lock slot is the account's 20 bytes left-padded with zeros, so a slot
+// whose first byte is not zero never collides with one.
+var (
+	// QDaySlot holds the Q-day height (0: not scheduled). From that block on,
+	// ecrecover answers nothing and ECDSA-signed EVM txs are refused.
+	QDaySlot = common.Hash{0x02}
+	// SecurityV3Slot holds the height from which the security-core EVM rules
+	// (exposure marks, the 0x…0901 precompile) apply.
+	SecurityV3Slot = common.Hash{0x03}
+)
+
+// ExposedSlot marks an account whose ECDSA public key was seen on chain by
+// ecrecover (a permit, a meta-transaction): it cannot use the commit–reveal
+// Q-day migration, which is only for keys never shown.
+func ExposedSlot(account common.Address) common.Hash {
+	h := common.BytesToHash(account.Bytes())
+	h[0] = 0x01
+	return h
+}
+
+// PQLocked reports whether a StateDB marks the account as quantum-locked.
+func PQLocked(get func(common.Address, common.Hash) common.Hash, account common.Address) bool {
+	return get(PQLockAddress, common.BytesToHash(account.Bytes())) != (common.Hash{})
+}
+
+// QDayReached reports whether block number n is at or after the Q-day height
+// stored in the StateDB.
+func QDayReached(get func(common.Address, common.Hash) common.Hash, n *big.Int) bool {
+	q := get(PQLockAddress, QDaySlot).Big()
+	return q.Sign() > 0 && n != nil && n.Cmp(q) >= 0
+}
+
+// SecurityV3 reports whether block number n runs the security-core EVM rules.
+func SecurityV3(get func(common.Address, common.Hash) common.Hash, n *big.Int) bool {
+	a := get(PQLockAddress, SecurityV3Slot).Big()
+	return a.Sign() > 0 && n != nil && n.Cmp(a) >= 0
+}
ZETAPHY_PQ_PATCH
: <<'ZETAPHY_PREINSTALLS'
[{"name":"Create2","address":"0x4e59b44847b379578588920ca78fbf26c0b4956c","code":"0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"},
{"name":"Multicall3","address":"0xcA11bde05977b3631167028862bE2a173976CA11","code":"0x6080604052600436106100f35760003560e01c80634d2301cc1161008a578063a8b0574e11610059578063a8b0574e1461025a578063bce38bd714610275578063c3077fa914610288578063ee82ac5e1461029b57600080fd5b80634d2301cc146101ec57806372425d9d1461022157806382ad56cb1461023457806386d516e81461024757600080fd5b80633408e470116100c65780633408e47014610191578063399542e9146101a45780633e64a696146101c657806342cbb15c146101d957600080fd5b80630f28c97d146100f8578063174dea711461011a578063252dba421461013a57806327e86d6e1461015b575b600080fd5b34801561010457600080fd5b50425b6040519081526020015b60405180910390f35b61012d610128366004610a85565b6102ba565b6040516101119190610bbe565b61014d610148366004610a85565b6104ef565b604051610111929190610bd8565b34801561016757600080fd5b50437fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0140610107565b34801561019d57600080fd5b5046610107565b6101b76101b2366004610c60565b610690565b60405161011193929190610cba565b3480156101d257600080fd5b5048610107565b3480156101e557600080fd5b5043610107565b3480156101f857600080fd5b50610107610207366004610ce2565b73ffffffffffffffffffffffffffffffffffffffff163190565b34801561022d57600080fd5b5044610107565b61012d610242366004610a85565b6106ab565b34801561025357600080fd5b5045610107565b34801561026657600080fd5b50604051418152602001610111565b61012d610283366004610c60565b61085a565b6101b7610296366004610a85565b610a1a565b3480156102a757600080fd5b506101076102b6366004610d18565b4090565b60606000828067ffffffffffffffff8111156102d8576102d8610d31565b60405190808252806020026020018201604052801561031e57816020015b6040805180820190915260008152606060208201528152602001906001900390816102f65790505b5092503660005b8281101561047757600085828151811061034157610341610d60565b6020026020010151905087878381811061035d5761035d610d60565b905060200281019061036f9190610d8f565b6040810135958601959093506103886020850185610ce2565b73ffffffffffffffffffffffffffffffffffffffff16816103ac6060870187610dcd565b6040516103ba929190610e32565b60006040518083038185875af1925050503d80600081146103f7576040519150601f19603f3d011682016040523d82523d6000602084013e6103fc565b606091505b50602080850191909152901515808452908501351761046d577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260846000fd5b5050600101610325565b508234146104e6576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601a60248201527f4d756c746963616c6c333a2076616c7565206d69736d6174636800000000000060448201526064015b60405180910390fd5b50505092915050565b436060828067ffffffffffffffff81111561050c5761050c610d31565b60405190808252806020026020018201604052801561053f57816020015b606081526020019060019003908161052a5790505b5091503660005b8281101561068657600087878381811061056257610562610d60565b90506020028101906105749190610e42565b92506105836020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166105a66020850185610dcd565b6040516105b4929190610e32565b6000604051808303816000865af19150503d80600081146105f1576040519150601f19603f3d011682016040523d82523d6000602084013e6105f6565b606091505b5086848151811061060957610609610d60565b602090810291909101015290508061067d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b50600101610546565b5050509250929050565b43804060606106a086868661085a565b905093509350939050565b6060818067ffffffffffffffff8111156106c7576106c7610d31565b60405190808252806020026020018201604052801561070d57816020015b6040805180820190915260008152606060208201528152602001906001900390816106e55790505b5091503660005b828110156104e657600084828151811061073057610730610d60565b6020026020010151905086868381811061074c5761074c610d60565b905060200281019061075e9190610e76565b925061076d6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166107906040850185610dcd565b60405161079e929190610e32565b6000604051808303816000865af19150503d80600081146107db576040519150601f19603f3d011682016040523d82523d6000602084013e6107e0565b606091505b506020808401919091529015158083529084013517610851577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260646000fd5b50600101610714565b6060818067ffffffffffffffff81111561087657610876610d31565b6040519080825280602002602001820160405280156108bc57816020015b6040805180820190915260008152606060208201528152602001906001900390816108945790505b5091503660005b82811015610a105760008482815181106108df576108df610d60565b602002602001015190508686838181106108fb576108fb610d60565b905060200281019061090d9190610e42565b925061091c6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff1661093f6020850185610dcd565b60405161094d929190610e32565b6000604051808303816000865af19150503d806000811461098a576040519150601f19603f3d011682016040523d82523d6000602084013e61098f565b606091505b506020830152151581528715610a07578051610a07576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b506001016108c3565b5050509392505050565b6000806060610a2b60018686610690565b919790965090945092505050565b60008083601f840112610a4b57600080fd5b50813567ffffffffffffffff811115610a6357600080fd5b6020830191508360208260051b8501011115610a7e57600080fd5b9250929050565b60008060208385031215610a9857600080fd5b823567ffffffffffffffff811115610aaf57600080fd5b610abb85828601610a39565b90969095509350505050565b6000815180845260005b81811015610aed57602081850181015186830182015201610ad1565b81811115610aff576000602083870101525b50601f017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0169290920160200192915050565b600082825180855260208086019550808260051b84010181860160005b84811015610bb1578583037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe001895281518051151584528401516040858501819052610b9d81860183610ac7565b9a86019a9450505090830190600101610b4f565b5090979650505050505050565b602081526000610bd16020830184610b32565b9392505050565b600060408201848352602060408185015281855180845260608601915060608160051b870101935082870160005b82811015610c52577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa0888703018452610c40868351610ac7565b95509284019290840190600101610c06565b509398975050505050505050565b600080600060408486031215610c7557600080fd5b83358015158114610c8557600080fd5b9250602084013567ffffffffffffffff811115610ca157600080fd5b610cad86828701610a39565b9497909650939450505050565b838152826020820152606060408201526000610cd96060830184610b32565b95945050505050565b600060208284031215610cf457600080fd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610bd157600080fd5b600060208284031215610d2a57600080fd5b5035919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81833603018112610dc357600080fd5b9190910192915050565b60008083357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe1843603018112610e0257600080fd5b83018035915067ffffffffffffffff821115610e1d57600080fd5b602001915036819003821315610a7e57600080fd5b8183823760009101908152919050565b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc1833603018112610dc357600080fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa1833603018112610dc357600080fdfea2646970667358221220bb2b5c71a328032f97c676ae39a1ec2148d3e5d6f73d95e9b17910152d61f16264736f6c634300080c0033"},
{"name":"Permit2","address":"0x000000000022D473030F116dDEE9F6B43aC78BA3","code":"0x6040608081526004908136101561001557600080fd5b600090813560e01c80630d58b1db1461126c578063137c29fe146110755780632a2d80d114610db75780632b67b57014610bde57806330f28b7a14610ade5780633644e51514610a9d57806336c7851614610a285780633ff9dcb1146109a85780634fe02b441461093f57806365d9723c146107ac57806387517c451461067a578063927da105146105c3578063cc53287f146104a3578063edd9444b1461033a5763fe8ec1a7146100c657600080fd5b346103365760c07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff833581811161033257610114903690860161164b565b60243582811161032e5761012b903690870161161a565b6101336114e6565b9160843585811161032a5761014b9036908a016115c1565b98909560a43590811161032657610164913691016115c1565b969095815190610173826113ff565b606b82527f5065726d697442617463685769746e6573735472616e7366657246726f6d285460208301527f6f6b656e5065726d697373696f6e735b5d207065726d69747465642c61646472838301527f657373207370656e6465722c75696e74323536206e6f6e63652c75696e74323560608301527f3620646561646c696e652c000000000000000000000000000000000000000000608083015282519a8b9181610222602085018096611f93565b918237018a8152039961025b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe09b8c8101835282611437565b5190209085515161026b81611ebb565b908a5b8181106102f95750506102f6999a6102ed9183516102a081610294602082018095611f66565b03848101835282611437565b519020602089810151858b015195519182019687526040820192909252336060820152608081019190915260a081019390935260643560c08401528260e081015b03908101835282611437565b51902093611cf7565b80f35b8061031161030b610321938c5161175e565b51612054565b61031b828661175e565b52611f0a565b61026e565b8880fd5b8780fd5b8480fd5b8380fd5b5080fd5b5091346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103365767ffffffffffffffff9080358281116103325761038b903690830161164b565b60243583811161032e576103a2903690840161161a565b9390926103ad6114e6565b9160643590811161049f576103c4913691016115c1565b949093835151976103d489611ebb565b98885b81811061047d5750506102f697988151610425816103f9602082018095611f66565b037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe08101835282611437565b5190206020860151828701519083519260208401947ffcf35f5ac6a2c28868dc44c302166470266239195f02b0ee408334829333b7668652840152336060840152608083015260a082015260a081526102ed8161141b565b808b61031b8261049461030b61049a968d5161175e565b9261175e565b6103d7565b8680fd5b5082346105bf57602090817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126103325780359067ffffffffffffffff821161032e576104f49136910161161a565b929091845b848110610504578580f35b8061051a610515600193888861196c565b61197c565b61052f84610529848a8a61196c565b0161197c565b3389528385528589209173ffffffffffffffffffffffffffffffffffffffff80911692838b528652868a20911690818a5285528589207fffffffffffffffffffffffff000000000000000000000000000000000000000081541690558551918252848201527f89b1add15eff56b3dfe299ad94e01f2b52fbcb80ae1a3baea6ae8c04cb2b98a4853392a2016104f9565b8280fd5b50346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610676816105ff6114a0565b936106086114c3565b6106106114e6565b73ffffffffffffffffffffffffffffffffffffffff968716835260016020908152848420928816845291825283832090871683528152919020549251938316845260a083901c65ffffffffffff169084015260d09190911c604083015281906060820190565b0390f35b50346103365760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336576106b26114a0565b906106bb6114c3565b916106c46114e6565b65ffffffffffff926064358481169081810361032a5779ffffffffffff0000000000000000000000000000000000000000947fda9fa7c1b00402c17d0161b249b1ab8bbec047c5a52207b9c112deffd817036b94338a5260016020527fffffffffffff0000000000000000000000000000000000000000000000000000858b209873ffffffffffffffffffffffffffffffffffffffff809416998a8d5260205283878d209b169a8b8d52602052868c209486156000146107a457504216925b8454921697889360a01b16911617179055815193845260208401523392a480f35b905092610783565b5082346105bf5760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576107e56114a0565b906107ee6114c3565b9265ffffffffffff604435818116939084810361032a57338852602091600183528489209673ffffffffffffffffffffffffffffffffffffffff80911697888b528452858a20981697888a5283528489205460d01c93848711156109175761ffff9085840316116108f05750907f55eb90d810e1700b35a8e7e25395ff7f2b2259abd7415ca2284dfb1c246418f393929133895260018252838920878a528252838920888a5282528389209079ffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffff000000000000000000000000000000000000000000000000000083549260d01b16911617905582519485528401523392a480f35b84517f24d35a26000000000000000000000000000000000000000000000000000000008152fd5b5084517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b503461033657807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610336578060209273ffffffffffffffffffffffffffffffffffffffff61098f6114a0565b1681528084528181206024358252845220549051908152f35b5082346105bf57817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf577f3704902f963766a4e561bbaab6e6cdc1b1dd12f6e9e99648da8843b3f46b918d90359160243533855284602052818520848652602052818520818154179055815193845260208401523392a280f35b8234610a9a5760807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc360112610a9a57610a606114a0565b610a686114c3565b610a706114e6565b6064359173ffffffffffffffffffffffffffffffffffffffff8316830361032e576102f6936117a1565b80fd5b503461033657817ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657602090610ad7611b1e565b9051908152f35b508290346105bf576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf57610b1a3661152a565b90807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c36011261033257610b4c611478565b9160e43567ffffffffffffffff8111610bda576102f694610b6f913691016115c1565b939092610b7c8351612054565b6020840151828501519083519260208401947f939c21a48a8dbe3a9a2404a1d46691e4d39f6583d6ec6b35714604c986d801068652840152336060840152608083015260a082015260a08152610bd18161141b565b51902091611c25565b8580fd5b509134610336576101007ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033657610c186114a0565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc360160c08112610332576080855191610c51836113e3565b1261033257845190610c6282611398565b73ffffffffffffffffffffffffffffffffffffffff91602435838116810361049f578152604435838116810361049f57602082015265ffffffffffff606435818116810361032a5788830152608435908116810361049f576060820152815260a435938285168503610bda576020820194855260c4359087830182815260e43567ffffffffffffffff811161032657610cfe90369084016115c1565b929093804211610d88575050918591610d786102f6999a610d7e95610d238851611fbe565b90898c511690519083519260208401947ff3841cd1ff0085026a6327b620b67997ce40f282c88a8e905a7a5626e310f3d086528401526060830152608082015260808152610d70816113ff565b519020611bd9565b916120c7565b519251169161199d565b602492508a51917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b5091346103365760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc93818536011261033257610df36114a0565b9260249081359267ffffffffffffffff9788851161032a578590853603011261049f578051978589018981108282111761104a578252848301358181116103265785019036602383011215610326578382013591610e50836115ef565b90610e5d85519283611437565b838252602093878584019160071b83010191368311611046578801905b828210610fe9575050508a526044610e93868801611509565b96838c01978852013594838b0191868352604435908111610fe557610ebb90369087016115c1565b959096804211610fba575050508998995151610ed681611ebb565b908b5b818110610f9757505092889492610d7892610f6497958351610f02816103f98682018095611f66565b5190209073ffffffffffffffffffffffffffffffffffffffff9a8b8b51169151928551948501957faf1b0d30d2cab0380e68f0689007e3254993c596f2fdd0aaa7f4d04f794408638752850152830152608082015260808152610d70816113ff565b51169082515192845b848110610f78578580f35b80610f918585610f8b600195875161175e565b5161199d565b01610f6d565b80610311610fac8e9f9e93610fb2945161175e565b51611fbe565b9b9a9b610ed9565b8551917fcd21db4f000000000000000000000000000000000000000000000000000000008352820152fd5b8a80fd5b6080823603126110465785608091885161100281611398565b61100b85611509565b8152611018838601611509565b838201526110278a8601611607565b8a8201528d611037818701611607565b90820152815201910190610e7a565b8c80fd5b84896041867f4e487b7100000000000000000000000000000000000000000000000000000000835252fd5b5082346105bf576101407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126105bf576110b03661152a565b91807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7c360112610332576110e2611478565b67ffffffffffffffff93906101043585811161049f5761110590369086016115c1565b90936101243596871161032a57611125610bd1966102f6983691016115c1565b969095825190611134826113ff565b606482527f5065726d69745769746e6573735472616e7366657246726f6d28546f6b656e5060208301527f65726d697373696f6e73207065726d69747465642c6164647265737320737065848301527f6e6465722c75696e74323536206e6f6e63652c75696e7432353620646561646c60608301527f696e652c0000000000000000000000000000000000000000000000000000000060808301528351948591816111e3602085018096611f93565b918237018b8152039361121c7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe095868101835282611437565b5190209261122a8651612054565b6020878101518589015195519182019687526040820192909252336060820152608081019190915260a081019390935260e43560c08401528260e081016102e1565b5082346105bf576020807ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc36011261033257813567ffffffffffffffff92838211610bda5736602383011215610bda5781013592831161032e576024906007368386831b8401011161049f57865b8581106112e5578780f35b80821b83019060807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc83360301126103265761139288876001946060835161132c81611398565b611368608461133c8d8601611509565b9485845261134c60448201611509565b809785015261135d60648201611509565b809885015201611509565b918291015273ffffffffffffffffffffffffffffffffffffffff80808093169516931691166117a1565b016112da565b6080810190811067ffffffffffffffff8211176113b457604052565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6060810190811067ffffffffffffffff8211176113b457604052565b60a0810190811067ffffffffffffffff8211176113b457604052565b60c0810190811067ffffffffffffffff8211176113b457604052565b90601f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0910116810190811067ffffffffffffffff8211176113b457604052565b60c4359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b600080fd5b6004359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6024359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b6044359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b359073ffffffffffffffffffffffffffffffffffffffff8216820361149b57565b7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc01906080821261149b576040805190611563826113e3565b8082941261149b57805181810181811067ffffffffffffffff8211176113b457825260043573ffffffffffffffffffffffffffffffffffffffff8116810361149b578152602435602082015282526044356020830152606435910152565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020838186019501011161149b57565b67ffffffffffffffff81116113b45760051b60200190565b359065ffffffffffff8216820361149b57565b9181601f8401121561149b5782359167ffffffffffffffff831161149b576020808501948460061b01011161149b57565b91909160608184031261149b576040805191611666836113e3565b8294813567ffffffffffffffff9081811161149b57830182601f8201121561149b578035611693816115ef565b926116a087519485611437565b818452602094858086019360061b8501019381851161149b579086899897969594939201925b8484106116e3575050505050855280820135908501520135910152565b90919293949596978483031261149b578851908982019082821085831117611730578a928992845261171487611509565b81528287013583820152815201930191908897969594936116c6565b602460007f4e487b710000000000000000000000000000000000000000000000000000000081526041600452fd5b80518210156117725760209160051b010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b92919273ffffffffffffffffffffffffffffffffffffffff604060008284168152600160205282828220961695868252602052818120338252602052209485549565ffffffffffff8760a01c16804211611884575082871696838803611812575b5050611810955016926118b5565b565b878484161160001461184f57602488604051907ff96fb0710000000000000000000000000000000000000000000000000000000082526004820152fd5b7fffffffffffffffffffffffff000000000000000000000000000000000000000084846118109a031691161790553880611802565b602490604051907fd81b2f2e0000000000000000000000000000000000000000000000000000000082526004820152fd5b9060006064926020958295604051947f23b872dd0000000000000000000000000000000000000000000000000000000086526004860152602485015260448401525af13d15601f3d116001600051141617161561190e57565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601460248201527f5452414e534645525f46524f4d5f4641494c45440000000000000000000000006044820152fd5b91908110156117725760061b0190565b3573ffffffffffffffffffffffffffffffffffffffff8116810361149b5790565b9065ffffffffffff908160608401511673ffffffffffffffffffffffffffffffffffffffff908185511694826020820151169280866040809401511695169560009187835260016020528383208984526020528383209916988983526020528282209184835460d01c03611af5579185611ace94927fc6a377bfc4eb120024a8ac08eef205be16b817020812c73223e81d1bdb9708ec98979694508715600014611ad35779ffffffffffff00000000000000000000000000000000000000009042165b60a01b167fffffffffffff00000000000000000000000000000000000000000000000000006001860160d01b1617179055519384938491604091949373ffffffffffffffffffffffffffffffffffffffff606085019616845265ffffffffffff809216602085015216910152565b0390a4565b5079ffffffffffff000000000000000000000000000000000000000087611a60565b600484517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b467f000000000000000000000000000000000000000000000000000000000000000103611b69577f866a5aba21966af95d6c7ab78eb2b2fc913915c28be3b9aa07cc04ff903e3f2890565b60405160208101907f8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a86682527f9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a604082015246606082015230608082015260808152611bd3816113ff565b51902090565b611be1611b1e565b906040519060208201927f190100000000000000000000000000000000000000000000000000000000000084526022830152604282015260428152611bd381611398565b9192909360a435936040840151804211611cc65750602084510151808611611c955750918591610d78611c6594611c60602088015186611e47565b611bd9565b73ffffffffffffffffffffffffffffffffffffffff809151511692608435918216820361149b57611810936118b5565b602490604051907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b602490604051907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b959093958051519560409283830151804211611e175750848803611dee57611d2e918691610d7860209b611c608d88015186611e47565b60005b868110611d42575050505050505050565b611d4d81835161175e565b5188611d5a83878a61196c565b01359089810151808311611dbe575091818888886001968596611d84575b50505050505001611d31565b611db395611dad9273ffffffffffffffffffffffffffffffffffffffff6105159351169561196c565b916118b5565b803888888883611d78565b6024908651907f3728b83d0000000000000000000000000000000000000000000000000000000082526004820152fd5b600484517fff633a38000000000000000000000000000000000000000000000000000000008152fd5b6024908551907fcd21db4f0000000000000000000000000000000000000000000000000000000082526004820152fd5b9073ffffffffffffffffffffffffffffffffffffffff600160ff83161b9216600052600060205260406000209060081c6000526020526040600020818154188091551615611e9157565b60046040517f756688fe000000000000000000000000000000000000000000000000000000008152fd5b90611ec5826115ef565b611ed26040519182611437565b8281527fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0611f0082946115ef565b0190602036910137565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8114611f375760010190565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b805160208092019160005b828110611f7f575050505090565b835185529381019392810192600101611f71565b9081519160005b838110611fab575050016000815290565b8060208092840101518185015201611f9a565b60405160208101917f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b3678835273ffffffffffffffffffffffffffffffffffffffff8082511660408401526020820151166060830152606065ffffffffffff9182604082015116608085015201511660a082015260a0815260c0810181811067ffffffffffffffff8211176113b45760405251902090565b6040516020808201927f618358ac3db8dc274f0cd8829da7e234bd48cd73c4a740aede1adec9846d06a1845273ffffffffffffffffffffffffffffffffffffffff81511660408401520151606082015260608152611bd381611398565b919082604091031261149b576020823592013590565b6000843b61222e5750604182036121ac576120e4828201826120b1565b939092604010156117725760209360009360ff6040608095013560f81c5b60405194855216868401526040830152606082015282805260015afa156121a05773ffffffffffffffffffffffffffffffffffffffff806000511691821561217657160361214c57565b60046040517f815e1d64000000000000000000000000000000000000000000000000000000008152fd5b60046040517f8baa579f000000000000000000000000000000000000000000000000000000008152fd5b6040513d6000823e3d90fd5b60408203612204576121c0918101906120b1565b91601b7f7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84169360ff1c019060ff8211611f375760209360009360ff608094612102565b60046040517f4be6321b000000000000000000000000000000000000000000000000000000008152fd5b929391601f928173ffffffffffffffffffffffffffffffffffffffff60646020957fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0604051988997889687947f1626ba7e000000000000000000000000000000000000000000000000000000009e8f8752600487015260406024870152816044870152868601378b85828601015201168101030192165afa9081156123a857829161232a575b507fffffffff000000000000000000000000000000000000000000000000000000009150160361230057565b60046040517fb0669cbc000000000000000000000000000000000000000000000000000000008152fd5b90506020813d82116123a0575b8161234460209383611437565b810103126103365751907fffffffff0000000000000000000000000000000000000000000000000000000082168203610a9a57507fffffffff0000000000000000000000000000000000000000000000000000000090386122d4565b3d9150612337565b6040513d84823e3d90fdfea164736f6c6343000811000a"},
{"name":"Safe singleton factory","address":"0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7","code":"0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"}]
ZETAPHY_PREINSTALLS
