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

set -euo pipefail

# ---- Fixed parameters (decided 19 Oct 2026) --------------------------------
CHAIN_ID="zetaphy-testnet-1"
EVM_CHAIN_ID=77390                 # free in ethereum-lists/chains as of 19 Oct 2026
DENOM="azetaphy"                   # 1 ZETAPHY = 10^18 azetaphy
MONIKER="${MONIKER:-zetaphy-validator-0}"
COSMOS_EVM_TAG="v0.7.3"
COSMOS_EVM_COMMIT="c3ae9067a7eadcdea55a5192226916deb44c71c4"
GO_VERSION="1.25.9"                # what cosmos/evm v0.7.3 go.mod requires
# IBC rate limits: ibc-apps rate-limiting, ported to ibc-go v11 by the patch below.
RATELIMIT_MOD="github.com/cosmos/ibc-apps/modules/rate-limiting/v10@v10.7.0"
RATELIMIT_SUM="h1:5X2o/xT1x1fltUrkhvDCOpFaRJK5/1M36/SCh873VOc="

NODE_USER="zetaphy"
NODE_HOME="/home/${NODE_USER}/.zetaphy"          # chain data + config (no keys)
KEYS_DIR="/home/${NODE_USER}/.zetaphy-genesis-keys" # genesis keys, kept out of the node's home
BIN="/usr/local/bin/zetaphyd"
LOG="/var/log/zetaphy-setup.log"

# Test hooks (leave unset on Oracle): ZETAPHYD_BIN=<prebuilt evmd>, NO_SYSTEMD=1
ZETAPHYD_BIN="${ZETAPHYD_BIN:-}"
NO_SYSTEMD="${NO_SYSTEMD:-}"

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

# bash setup-node.sh --become-validator <ZETAPHY>: on a synced node that
# joined with JOIN=, stake that much from its "validator" key (the faucet
# gives 10) and become a validator.
if [ "${1:-}" = "--become-validator" ]; then
  amt=${2:?amount of ZETAPHY to stake}
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
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  need=""
  for p in git jq curl make gcc; do command -v "$p" >/dev/null || need=1; done
  if [ -n "$need" ]; then apt-get update -y && apt-get install -y git jq curl build-essential ca-certificates; fi
fi

step "2/8 swap (small machines need it to compile)"
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$mem_kb" -lt 6000000 ] && ! swapon --show | grep -q . && [ -z "$NO_SYSTEMD" ]; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

step "3/8 user"
id "$NODE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$NODE_USER"
as_node() { su -s /bin/bash "$NODE_USER" -c "$*"; }

step "4/8 build zetaphyd"
if [ -n "$ZETAPHYD_BIN" ]; then
  install -m 755 "$ZETAPHYD_BIN" "$BIN"
elif [ ! -x "$BIN" ] || [ -n "${FORCE_BUILD:-}" ]; then
  # Any Go >= 1.21 can fetch the exact toolchain the source asks for (GOTOOLCHAIN),
  # verified against Go's checksum database. Ubuntu 24.04's golang-go is 1.22.
  GO=$(command -v go || true)
  [ -z "$GO" ] && [ -x /usr/local/go/bin/go ] && GO=/usr/local/go/bin/go
  if [ -z "$GO" ]; then apt-get install -y golang-go && GO=$(command -v go); fi
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
  install -m 644 "$0" /tmp/zetaphy-setup-node.sh
  as_node "cd '$src' && $goenv bash /tmp/zetaphy-setup-node.sh --patch-source '$src'"
  as_node "cd '$src' && $goenv make install"
  install -m 755 "/home/${NODE_USER}/go/bin/evmd" "$BIN"
fi
"$BIN" version

# Runs the chain binary as the node user with the right home.
z() { su -s /bin/bash "$NODE_USER" -c "$BIN $*"; }
K="--keyring-backend test --keyring-dir $KEYS_DIR"

if [ ! -f "$NODE_HOME/config/genesis.json" ]; then
  step "5/8 keys and genesis"
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
  # Testnet: short votes so upgrade proposals can be tried quickly.
  jqg '.app_state.gov.params.voting_period="600s" | .app_state.gov.params.expedited_voting_period="300s" | .app_state.gov.params.max_deposit_period="600s"'

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
# A joined node dials the node it joined.
if [ -f "$NODE_HOME/config/seed-peer" ]; then
  peer=$(tr -cd 'a-f0-9@.:' < "$NODE_HOME/config/seed-peer")
  as_node "sed -i -E 's/^persistent_peers = .*/persistent_peers = \"$peer\"/' '$C'"
fi
# Public: EVM JSON-RPC 8545 (read + send signed txs) and P2P 26656.
# Local only: CometBFT RPC 26657, REST 1317, gRPC 9090 (defaults).
as_node "python3 - '$A' <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
sec = re.search(r'(?ms)^\[json-rpc\].*?(?=^\[|\Z)', s).group(0)
new = re.sub(r'(?m)^enable = .*', 'enable = true', sec)
new = re.sub(r'(?m)^address = .*', 'address = \"0.0.0.0:8545\"', new)
new = re.sub(r'(?m)^ws-address = .*', 'ws-address = \"127.0.0.1:8546\"', new)
new = re.sub(r'(?m)^api = .*', 'api = \"eth,net,web3,txpool,zetaphy\"', new)
# The port is public: keep one caller from tying the node up.
limits = {
    'allow-insecure-unlock': 'false',         # no account unlocking over RPC
    'gas-cap': '10000000',                    # eth_call / estimateGas gas ceiling
    'evm-timeout': '\"3s\"',                  # eth_call wall-clock ceiling
    'logs-cap': '2000',                       # eth_getLogs results per call
    'block-range-cap': '2000',                # eth_getLogs block span per call
    'max-open-connections': '200',            # 0 meant unlimited
    'batch-request-limit': '50',
    'batch-response-max-size': '5000000',
    'http-body-limit': '1048576',             # 1 MB requests
}
for k, v in limits.items():
    new = re.sub(r'(?m)^' + re.escape(k) + r' = .*', k + ' = ' + v, new)
open(p, 'w').write(s.replace(sec, new))
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
  systemctl enable --now zetaphyd
else
  as_node "nohup $START > /home/$NODE_USER/zetaphyd.log 2>&1 &"
fi

# The genesis validator registers its vote key once the chain runs.
if [ -z "$JOIN" ] && [ ! -f "$V.registered" ]; then
  for _ in $(seq 1 60); do
    [ "$(z status --home "$NODE_HOME" 2>/dev/null | jq -r '.sync_info.latest_block_height // 0')" -ge 2 ] && break; sleep 2
  done
  z tx pq-vote-key --from validator $K --home "$NODE_HOME" --chain-id "$CHAIN_ID" --gas 600000 \
    --gas-prices "1000000000$DENOM" -y -o json | grep -q '"code":0' && as_node "touch '$V.registered'" || echo "vote key not registered yet; run setup-node.sh again"
fi

step "8/8 firewall and https"
# Oracle's Ubuntu images reject everything except SSH in iptables; open the public ports.
if command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  for port in 8545 26656 80 443; do
    iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -I INPUT 5 -p tcp --dport $port -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save || true
fi

ip=$(curl -fsS -m 5 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')
# HTTPS in front of 8545, for pages served over https (the web wallet): Caddy
# from Ubuntu's archive gets a free Let's Encrypt certificate for
# <ip>.sslip.io, a free DNS name that points at the IP. Not fatal if it fails.
host="${ip//./-}.sslip.io"
# It also publishes what another machine needs to JOIN this chain.
pub=/var/lib/zetaphy-public
mkdir -p $pub && install -m 644 "$NODE_HOME/config/genesis.json" $pub/ && install -m 644 "$0" $pub/setup-node.sh
echo "$(z comet show-node-id --home "$NODE_HOME")@$ip:26656" > $pub/peer
if [ -z "$NO_SYSTEMD" ] && [ -d /run/systemd/system ] && [[ "$ip" =~ ^[0-9.]+$ ]]; then
  { apt-get install -y caddy >/dev/null && printf '%s {\n\thandle_path /zetaphy/* {\n\t\troot * %s\n\t\tfile_server\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:8545\n\t}\n}\n' "$host" $pub > /etc/caddy/Caddyfile \
    && systemctl restart caddy; } || echo "https setup failed; the RPC still works over http"
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
  MetaMask RPC URL:    http://$ip:8545
  HTTPS RPC (wallet):  https://$host  (needs ports 80 and 443 open)
  Others join with:    JOIN=$host in setup-node.sh, then --become-validator 9
  Currency symbol:     ZETAPHY
  Genesis keys:        $KEYS_DIR (testnet only; MNEMONICS-KEEP-SECRET.txt)
  Back up:             $NODE_HOME/config/priv_validator_key.json and pq_vote_key.seed
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
index 204345c..7496dcb 100644
--- a/evmd/app.go
+++ b/evmd/app.go
@@ -36,6 +36,10 @@ import (
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
@@ -179,6 +183,8 @@ type EVMD struct {
 	IBCKeeper      *ibckeeper.Keeper // IBC Keeper must be a pointer in the app, so we can SetRouter on it correctly
 	TransferKeeper *transferkeeper.Keeper
 	CallbackKeeper ibccallbackskeeper.ContractKeeper
+	// ZETAPHY: per-denom, per-channel IBC flow limits set by governance
+	RateLimitKeeper *ratelimitkeeper.Keeper
 
 	// Cosmos EVM keepers
 	FeeMarketKeeper feemarketkeeper.Keeper
@@ -238,9 +244,10 @@ func NewExampleApp(
 		govtypes.StoreKey, consensusparamtypes.StoreKey,
 		upgradetypes.StoreKey, feegrant.StoreKey, evidencetypes.StoreKey, authzkeeper.StoreKey,
 		// ibc keys
-		ibcexported.StoreKey, ibctransfertypes.StoreKey,
+		ibcexported.StoreKey, ibctransfertypes.StoreKey, ratelimittypes.StoreKey,
 		// Cosmos EVM store keys
 		evmtypes.StoreKey, feemarkettypes.StoreKey, erc20types.StoreKey,
+		pqStoreKey, // ZETAPHY: quantum locks and validator vote keys
 	)
 	oKeys := storetypes.NewObjectStoreKeys(banktypes.ObjectStoreKey, evmtypes.ObjectKey)
 
@@ -530,9 +537,29 @@ func NewExampleApp(
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
+
 	var transferStackV2 ibcapi.IBCModule
 	transferStackV2 = transferv2.NewIBCModule(app.TransferKeeper)
 	transferStackV2 = erc20v2.NewIBCMiddleware(transferStackV2, app.Erc20Keeper)
+	rateLimitV2 := ratelimitv2.NewIBCMiddleware(*app.RateLimitKeeper, transferStackV2)
+	transferStackV2 = &rateLimitV2
 
 	// Create static IBC router, add transfer route, then set and seal it
 	ibcRouter := porttypes.NewRouter()
@@ -579,6 +606,7 @@ func NewExampleApp(
 		ibc.NewAppModule(app.IBCKeeper),
 		ibctm.NewAppModule(tmLightClientModule),
 		transferModule,
+		ratelimit.NewAppModule(appCodec, *app.RateLimitKeeper),
 		// Cosmos EVM modules
 		vmModule,
 		feemarket.NewAppModule(app.FeeMarketKeeper),
@@ -618,7 +646,7 @@ func NewExampleApp(
 		minttypes.ModuleName,
 
 		// IBC modules
-		ibcexported.ModuleName, ibctransfertypes.ModuleName,
+		ibcexported.ModuleName, ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 
 		// Cosmos EVM BeginBlockers
 		erc20types.ModuleName, feemarkettypes.ModuleName,
@@ -645,7 +673,7 @@ func NewExampleApp(
 		evmtypes.ModuleName, erc20types.ModuleName, feemarkettypes.ModuleName,
 
 		// no-ops
-		ibcexported.ModuleName, ibctransfertypes.ModuleName,
+		ibcexported.ModuleName, ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 		distrtypes.ModuleName,
 		slashingtypes.ModuleName, minttypes.ModuleName,
 		genutiltypes.ModuleName, evidencetypes.ModuleName, authz.ModuleName,
@@ -670,7 +698,7 @@ func NewExampleApp(
 		feemarkettypes.ModuleName,
 		erc20types.ModuleName,
 
-		ibctransfertypes.ModuleName,
+		ibctransfertypes.ModuleName, ratelimittypes.ModuleName,
 		genutiltypes.ModuleName, evidencetypes.ModuleName, authz.ModuleName,
 		feegrant.ModuleName, upgradetypes.ModuleName, vestingtypes.ModuleName,
 	}
@@ -684,6 +712,9 @@ func NewExampleApp(
 	if err = app.ModuleManager.RegisterServices(app.configurator); err != nil {
 		panic(fmt.Sprintf("failed to register services in module manager: %s", err.Error()))
 	}
+	app.registerEVMCall()                // ZETAPHY: post-quantum messages (zetaphy_pqcall.go)
+	app.setPQVoteHandlers(homePath)      // ZETAPHY: ML-DSA-44 vote signatures (zetaphy_pqguard.go)
+	app.EVMKeeper.SetHooks(pqHooks{app}) // ZETAPHY: quantum lock from MetaMask
 
 	// RegisterUpgradeHandlers is used for registering any on-chain upgrades.
 	// Make sure it's called after `app.ModuleManager` and `app.configurator` are set.
@@ -812,7 +843,7 @@ func (app *EVMD) setAnteHandler(txConfig client.TxConfig, maxGasWanted uint64) {
 		panic(err)
 	}
 
-	app.SetAnteHandler(evmante.NewAnteHandler(options))
+	app.SetAnteHandler(app.pqLockAnte(evmante.NewAnteHandler(options))) // ZETAPHY: quantum locks
 }
 
 func (app *EVMD) onPendingTx(hash common.Hash) {
@@ -842,7 +873,16 @@ func (app *EVMD) Name() string { return app.BaseApp.Name() }
 
 // BeginBlocker application updates every begin block
 func (app *EVMD) BeginBlocker(ctx sdk.Context) (sdk.BeginBlock, error) {
-	return app.ModuleManager.BeginBlock(ctx)
+	// ZETAPHY: burn before distribution pays validators. The module manager
+	// replaces the event manager, so keep the burn's events and add them.
+	em := sdk.NewEventManager()
+	app.burnFees(ctx.WithEventManager(em))
+	bb, err := app.ModuleManager.BeginBlock(ctx)
+	if err != nil {
+		return bb, err
+	}
+	bb.Events = append(em.ABCIEvents(), bb.Events...)
+	return bb, nil
 }
 
 // EndBlocker application updates every end block
diff --git a/evmd/cmd/evmd/cmd/root.go b/evmd/cmd/evmd/cmd/root.go
index 4da3349..4731e81 100644
--- a/evmd/cmd/evmd/cmd/root.go
+++ b/evmd/cmd/evmd/cmd/root.go
@@ -249,6 +249,7 @@ func txCommand() *cobra.Command {
 		authcmd.GetEncodeCommand(),
 		authcmd.GetDecodeCommand(),
 		authcmd.GetSimulateCmd(),
+		evmd.PQVoteKeyCmd(), evmd.QuantumLockCmd(), // ZETAPHY
 	)
 
 	cmd.PersistentFlags().String(flags.FlagChainID, "", "The network chain ID")
diff --git a/evmd/go.mod b/evmd/go.mod
index e503386..dc04366 100644
--- a/evmd/go.mod
+++ b/evmd/go.mod
@@ -88,6 +88,7 @@ require (
 	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
 	github.com/cespare/xxhash/v2 v2.3.0 // indirect
 	github.com/chzyer/readline v1.5.1 // indirect
+	github.com/cloudflare/circl v1.6.3 // indirect
 	github.com/cloudwego/base64x v0.1.6 // indirect
 	github.com/cncf/xds/go v0.0.0-20260202195803-dba9d589def2 // indirect
 	github.com/cockroachdb/errors v1.13.0 // indirect
diff --git a/evmd/go.sum b/evmd/go.sum
index 92d6f82..4ce53b3 100644
--- a/evmd/go.sum
+++ b/evmd/go.sum
@@ -220,6 +220,8 @@ github.com/circonus-labs/circonus-gometrics v2.3.1+incompatible/go.mod h1:nmEj6D
 github.com/circonus-labs/circonusllhist v0.1.3/go.mod h1:kMXHVDlOchFAehlya5ePtbp5jckzBHf4XRpQvBOLI+I=
 github.com/clbanning/x2j v0.0.0-20191024224557-825249438eec/go.mod h1:jMjuTZXRI4dUb/I5gc9Hdhagfvm9+RyrPryS/auMzxE=
 github.com/client9/misspell v0.3.4/go.mod h1:qj6jICC3Q7zFZvVWo7KLAzC3yx5G7kyvSDkc90ppPyw=
+github.com/cloudflare/circl v1.6.3 h1:9GPOhQGF9MCYUeXyMYlqTR6a5gTrgR/fBLXvUgtVcg8=
+github.com/cloudflare/circl v1.6.3/go.mod h1:2eXP6Qfat4O/Yhh8BznvKnJ+uzEoTQ6jVKJRn81BiS4=
 github.com/cloudwego/base64x v0.1.6 h1:t11wG9AECkCDk5fMSoxmufanudBtJ+/HemLstXDLI2M=
 github.com/cloudwego/base64x v0.1.6/go.mod h1:OFcloc187FXDaYHvrNIjxSe8ncn0OOM8gEHfghB2IPU=
 github.com/cncf/udpa/go v0.0.0-20191209042840-269d4d468f6f/go.mod h1:M8M6+tZqaGXZJjfX53e64911xZQV5JYwmTeXPW+k8Sc=
diff --git a/evmd/zetaphy_feeburn.go b/evmd/zetaphy_feeburn.go
new file mode 100644
index 0000000..96d0ea8
--- /dev/null
+++ b/evmd/zetaphy_feeburn.go
@@ -0,0 +1,43 @@
+package evmd
+
+import (
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
diff --git a/evmd/zetaphy_pqcall.go b/evmd/zetaphy_pqcall.go
new file mode 100644
index 0000000..131c042
--- /dev/null
+++ b/evmd/zetaphy_pqcall.go
@@ -0,0 +1,322 @@
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
+
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/types/msgservice"
+
+	"github.com/cosmos/evm/x/vm/statedb"
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
+	Operator  string
+	PubKey    []byte
+	Proof     []byte
+	OldKeySig []byte
+}
+
+type MsgPQResponse struct{}
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
+	{"MsgPQVoteKey", "operator", "operator:S pub_key:B proof:B old_key_sig:B"},
+	{"MsgPQResponse", "", ""},
+}
+
+var pqMethods = [][3]string{{"EVMCall", "MsgEVMCall", "MsgEVMCallResponse"},
+	{"QuantumLock", "MsgQuantumLock", "MsgPQResponse"}, {"PQVoteKey", "MsgPQVoteKey", "MsgPQResponse"}}
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
+	for _, m := range []gogoproto.Message{&MsgEVMCall{}, &MsgEVMCallResponse{}, &MsgQuantumLock{}, &MsgPQVoteKey{}, &MsgPQResponse{}} {
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
+		pqMethod("PQVoteKey", (*EVMD).pqVoteKey)},
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
+	sender := common.BytesToAddress(from)
+	stateDB := statedb.New(ctx, app.EVMKeeper, statedb.NewEmptyTxConfig())
+	res, err := app.EVMKeeper.ApplyMessage(ctx, stateDB, core.Message{
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
+		// The create bumped the EVM nonce, which is the account sequence the
+		// ante handler already bumped for this tx: undo the second bump.
+		if m.AsOwner == "" {
+			acc := app.AccountKeeper.GetAccount(ctx, from)
+			if err := acc.SetSequence(nonce); err != nil {
+				return nil, err
+			}
+			app.AccountKeeper.SetAccount(ctx, acc)
+		}
+	}
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_evm_call", sdk.NewAttribute("from", sender.Hex()),
+		sdk.NewAttribute("to", m.To), sdk.NewAttribute("created", out.Created), sdk.NewAttribute("value", value.String())))
+	return out, nil
+}
+
+// registerEVMCall wires the messages into the app (codec and message router).
+func (app *EVMD) registerEVMCall() {
+	app.interfaceRegistry.RegisterImplementations((*sdk.Msg)(nil), &MsgEVMCall{}, &MsgQuantumLock{}, &MsgPQVoteKey{})
+	msgservice.RegisterMsgServiceDesc(app.interfaceRegistry, &pqCallServiceDesc)
+	app.MsgServiceRouter().RegisterService(&pqCallServiceDesc, app)
+}
diff --git a/evmd/zetaphy_pqguard.go b/evmd/zetaphy_pqguard.go
new file mode 100644
index 0000000..10fc455
--- /dev/null
+++ b/evmd/zetaphy_pqguard.go
@@ -0,0 +1,323 @@
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
+	"github.com/cosmos/cosmos-sdk/client"
+	"github.com/cosmos/cosmos-sdk/client/flags"
+	"github.com/cosmos/cosmos-sdk/client/tx"
+	sdk "github.com/cosmos/cosmos-sdk/types"
+	errortypes "github.com/cosmos/cosmos-sdk/types/errors"
+	"github.com/cosmos/cosmos-sdk/x/authz"
+
+	"github.com/cosmos/evm/crypto/mldsa44"
+	evmkeeper "github.com/cosmos/evm/x/vm/keeper"
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
+	if cur := app.pqController(ctx, owner); cur == nil && !owner.Equals(signer) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only the owner can lock its account")
+	} else if cur != nil && !bytes.Equal(cur, signer) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "only the current controller can hand control over")
+	}
+	isPQ := false
+	if acc := app.AccountKeeper.GetAccount(ctx, ctrl); acc != nil {
+		_, isPQ = acc.GetPubKey().(*mldsa44.PubKey)
+	}
+	if !isPQ || ctrl.Equals(owner) || app.pqController(ctx, ctrl) != nil {
+		return nil, errorsmod.Wrap(errortypes.ErrInvalidRequest, "the controller must be another ML-DSA-44 account that has already sent a transaction")
+	}
+	ctx.KVStore(app.GetKey(pqStoreKey)).Set(pqLockKey(owner), ctrl)
+	// Mirror into EVM storage for ecrecover; the account gets nonce 1 so the
+	// EVM never drops it as empty.
+	if app.AccountKeeper.GetAccount(ctx, PQLockAddress.Bytes()) == nil {
+		acc := app.AccountKeeper.NewAccountWithAddress(ctx, PQLockAddress.Bytes())
+		if err := acc.SetSequence(1); err != nil {
+			return nil, err
+		}
+		app.AccountKeeper.SetAccount(ctx, acc)
+	}
+	app.EVMKeeper.SetState(ctx, PQLockAddress, common.BytesToHash(owner), common.BytesToHash(ctrl).Bytes())
+	ctx.EventManager().EmitEvent(sdk.NewEvent("zetaphy_quantum_lock", sdk.NewAttribute("owner", owner.String()), sdk.NewAttribute("controller", ctrl.String())))
+	return &MsgPQResponse{}, nil
+}
+
+// PQLockAddress: an EVM tx (MetaMask) to this address with no value and the
+// controller's 20-byte address as data locks the sender to that controller.
+var PQLockAddress = evmkeeper.PQLockAddress
+
+type pqHooks struct{ app *EVMD }
+
+func (h pqHooks) PostTxProcessing(ctx sdk.Context, sender common.Address, msg core.Message, r *ethtypes.Receipt) error {
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
+// pqLockAnte refuses any tx that a quantum-locked account signs, pays for
+// through a fee grant, authorizes through authz, or delegates code for
+// (EIP-7702). Signatures that contracts check go through ecrecover, which
+// refuses locked accounts too (x/vm/keeper/zetaphy_ecrecover.go).
+func (app *EVMD) pqLockAnte(next sdk.AnteHandler) sdk.AnteHandler {
+	return func(ctx sdk.Context, tx sdk.Tx, sim bool) (sdk.Context, error) {
+		var signers [][]byte
+		if ft, ok := tx.(sdk.FeeTx); ok && ft.FeeGranter() != nil {
+			signers = append(signers, ft.FeeGranter())
+		}
+		msgs := append([]sdk.Msg{}, tx.GetMsgs()...)
+		for i := 0; i < len(msgs); i++ {
+			if ex, ok := msgs[i].(*authz.MsgExec); ok {
+				inner, err := ex.GetMessages()
+				if err != nil {
+					return ctx, err
+				}
+				msgs = append(msgs, inner...)
+			}
+			// EIP-7702: an authorization signed by a locked key, carried in someone else's tx.
+			if et, ok := msgs[i].(*evmtypes.MsgEthereumTx); ok {
+				for _, auth := range et.AsTransaction().SetCodeAuthorizations() {
+					if a, err := auth.Authority(); err == nil {
+						signers = append(signers, a.Bytes())
+					}
+				}
+			}
+			s, _, err := app.appCodec.GetMsgV1Signers(msgs[i])
+			if err != nil {
+				return ctx, err
+			}
+			signers = append(signers, s...)
+		}
+		for _, s := range signers {
+			if app.pqController(ctx, s) != nil {
+				return ctx, errorsmod.Wrapf(errortypes.ErrUnauthorized, "%s is quantum-locked: only its ML-DSA-44 controller can act for it", sdk.AccAddress(s))
+			}
+		}
+		return next(ctx, tx, sim)
+	}
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
+	val, err := app.StakingKeeper.GetValidator(ctx, sdk.ValAddress(op))
+	if err != nil {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "the signer does not operate a validator")
+	}
+	cons, err := val.GetConsAddr()
+	if err != nil {
+		return nil, err
+	}
+	msg := pqVoteKeyMsg(ctx.ChainID(), cons, m.PubKey)
+	if !(&mldsa44.PubKey{Key: m.PubKey}).VerifySignature(msg, m.Proof) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "proof: not signed by the new key")
+	}
+	st := ctx.KVStore(app.GetKey(pqStoreKey))
+	if old := st.Get(pqVoteKeyOf(cons)); old != nil && !(&mldsa44.PubKey{Key: old}).VerifySignature(msg, m.OldKeySig) {
+		return nil, errorsmod.Wrap(errortypes.ErrUnauthorized, "replacing a vote key needs a signature by the current one")
+	}
+	st.Set(pqVoteKeyOf(cons), m.PubKey)
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
+// With neither it stops instead of sending a vote the others would reject
+// (a rejected precommit can stall the chain; a missing one is just downtime).
+func (app *EVMD) setPQVoteHandlers(home string) {
+	seedFile := filepath.Join(home, "config", pqVoteSeedFn)
+	app.SetExtendVoteHandler(func(ctx sdk.Context, req *abci.RequestExtendVote) (*abci.ResponseExtendVote, error) {
+		cons, err := pqConsAddr(home)
+		if err != nil {
+			return nil, err
+		}
+		want := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqVoteKeyOf(cons))
+		for _, f := range []string{seedFile, seedFile + ".old"} {
+			sk, pub, err := pqVoteSeed(f)
+			if err == nil && (want == nil || bytes.Equal(pub, want)) {
+				sig, err := pqSign(sk, pqVoteMsg(ctx.ChainID(), req.Height, req.Hash))
+				return &abci.ResponseExtendVote{VoteExtension: sig}, err
+			}
+		}
+		if want == nil {
+			return &abci.ResponseExtendVote{}, nil
+		}
+		app.Logger().Error("ZETAPHY: no ML-DSA vote key here matches the one registered for this validator; stopping so as not to send a vote the chain rejects. Put the right key in " + seedFile)
+		os.Exit(1)
+		return nil, nil
+	})
+	app.SetVerifyVoteExtensionHandler(func(ctx sdk.Context, req *abci.RequestVerifyVoteExtension) (*abci.ResponseVerifyVoteExtension, error) {
+		ok := true
+		if pk := ctx.KVStore(app.GetKey(pqStoreKey)).Get(pqVoteKeyOf(req.ValidatorAddress)); pk != nil {
+			ok = (&mldsa44.PubKey{Key: pk}).VerifySignature(pqVoteMsg(ctx.ChainID(), req.Height, req.Hash), req.VoteExtension)
+		}
+		if ok {
+			return &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_ACCEPT}, nil
+		}
+		return &abci.ResponseVerifyVoteExtension{Status: abci.ResponseVerifyVoteExtension_REJECT}, nil
+	})
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
diff --git a/evmd/zetaphy_rpc.go b/evmd/zetaphy_rpc.go
new file mode 100644
index 0000000..7dfa1b1
--- /dev/null
+++ b/evmd/zetaphy_rpc.go
@@ -0,0 +1,261 @@
+package evmd
+
+// ZETAPHY JSON-RPC namespace "zetaphy" on the public EVM endpoint (8545),
+// so wallets can use post-quantum (ML-DSA-44) accounts without any other
+// port being open:
+//
+//	zetaphy_pqAccount(address)  account number and sequence to sign with
+//	zetaphy_sendCosmosTx(0x…)   broadcast a signed Cosmos tx (CheckTx only)
+//	zetaphy_faucet(address)     testnet only: a little ZETAPHY for newcomers
+//
+// The first two hold no keys: like eth_sendRawTransaction, sendCosmosTx only
+// passes on bytes the user already signed. The faucet signs with its own key
+// (<home>/config/faucet.key, a capped testnet balance) and is off without it.
+
+import (
+	"context"
+	"crypto/ecdsa"
+	"fmt"
+	"math/big"
+	"os"
+	"path/filepath"
+	"strings"
+	"sync"
+	"time"
+
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/common/hexutil"
+	ethtypes "github.com/ethereum/go-ethereum/core/types"
+	"github.com/ethereum/go-ethereum/crypto"
+	gethrpc "github.com/ethereum/go-ethereum/rpc"
+	"google.golang.org/grpc/codes"
+	"google.golang.org/grpc/status"
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
+	faucet.Lock()
+	defer faucet.Unlock()
+	key, err := a.faucetKey()
+	if err != nil {
+		return nil, err
+	}
+	now := time.Now().UTC()
+	if d := now.Unix() / 86400; d != faucet.day {
+		faucet.day, faucet.count = d, 0
+	}
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
diff --git a/x/vm/keeper/precompiles.go b/x/vm/keeper/precompiles.go
index ee26a8e..bd19281 100644
--- a/x/vm/keeper/precompiles.go
+++ b/x/vm/keeper/precompiles.go
@@ -27,6 +27,10 @@ func (k *Keeper) GetPrecompileInstance(
 		attribute.String("address", address.Hex()),
 	))
 	defer func() { evmtrace.EndSpanErr(span, err) }()
+	// ZETAPHY: ecrecover that refuses quantum-locked accounts (zetaphy_ecrecover.go).
+	if address == ecrecoverAddress {
+		return &Precompiles{Map: map[common.Address]vm.PrecompiledContract{address: pqEcrecover{}}, Addresses: []common.Address{address}}, true, nil
+	}
 	params := k.GetParams(ctx)
 	// Get the precompile from the static precompiles
 	if precompile, found, err := k.GetStaticPrecompileInstance(&params, address); err != nil {
diff --git a/x/vm/keeper/zetaphy_ecrecover.go b/x/vm/keeper/zetaphy_ecrecover.go
new file mode 100644
index 0000000..04743d3
--- /dev/null
+++ b/x/vm/keeper/zetaphy_ecrecover.go
@@ -0,0 +1,33 @@
+package keeper
+
+import (
+	"github.com/ethereum/go-ethereum/common"
+	"github.com/ethereum/go-ethereum/core/vm"
+)
+
+// ZETAPHY: an ECDSA account handed to an ML-DSA-44 controller (quantum lock,
+// evmd/zetaphy_pqguard.go) is marked in the storage of PQLockAddress (key =
+// the account, value = its controller). Contracts check ECDSA signatures with
+// ecrecover (0x01), so permits, Permit2 and meta-transactions signed by a
+// locked account are treated as invalid signatures: ecrecover returns nothing.
+
+// PQLockAddress has no code; only the quantum lock writes its storage.
+var PQLockAddress = common.HexToAddress("0x0000000000000000000000000000000000005051")
+
+var (
+	ecrecoverAddress = common.BytesToAddress([]byte{1})
+	gethEcrecover    = vm.PrecompiledContractsPrague[ecrecoverAddress]
+)
+
+type pqEcrecover struct{}
+
+func (pqEcrecover) Address() common.Address         { return ecrecoverAddress }
+func (pqEcrecover) RequiredGas(input []byte) uint64 { return gethEcrecover.RequiredGas(input) }
+func (pqEcrecover) Name() string                    { return gethEcrecover.Name() }
+func (pqEcrecover) Run(evm *vm.EVM, c *vm.Contract, ro bool) ([]byte, error) {
+	out, err := gethEcrecover.Run(evm, c, ro)
+	if err == nil && len(out) == 32 && evm.StateDB.GetState(PQLockAddress, common.BytesToHash(out)) != (common.Hash{}) {
+		return nil, nil
+	}
+	return out, err
+}
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
ZETAPHY_PQ_PATCH
