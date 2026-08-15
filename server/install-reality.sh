#!/usr/bin/env bash
# VLESS + REALITY over TCP/443. Run on the HOME SERVER as root, after install.sh.
#
# This is the transport that survives when everything else is blocked.
#
# Ordinary TLS tunnels are detectable because their certificate is either
# self-signed or issued to a domain nobody else visits. REALITY sidesteps that:
# during the handshake your server proxies the real TLS negotiation to a genuine
# public site, so the certificate a middlebox observes is that site's actual
# certificate, with a valid chain. If a censor actively probes your address, it
# is transparently handed the real site and sees nothing unusual.
#
# Cost: TCP, so throughput is lower than WireGuard, and head-of-line blocking
# hurts on lossy links.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
load_config

REALITY_PORT=${REALITY_PORT:-443}

say "VLESS + REALITY install"

# ------------------------------------------------------------------- sing-box
say "Installing sing-box"
apt-get install -y -qq curl jq openssl ca-certificates >/dev/null

case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  armv7l)  ARCH=armv7 ;;
  *)       die "Unsupported architecture: $(uname -m)" ;;
esac

VER=${SINGBOX_VERSION:-$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
       | jq -r '.tag_name' | sed 's/^v//')}
[[ -n $VER && $VER != null ]] || die "Could not determine the latest sing-box release. Set SINGBOX_VERSION=x.y.z."

if ! command -v sing-box >/dev/null || [[ $(sing-box version | awk 'NR==1{print $3}') != "$VER" ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/sb.tgz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz" \
    || die "Download failed for sing-box ${VER} (${ARCH})."
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
fi
ok "sing-box $(sing-box version | awk 'NR==1{print $3}')"

# ----------------------------------------------------------------- accurate time
# REALITY performs a real TLS 1.3 handshake and embeds a timestamp; a skewed
# clock breaks authentication in a way that looks exactly like censorship.
if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  warn "System clock is not NTP-synchronised — enabling timesyncd"
  timedatectl set-ntp true 2>/dev/null || apt-get install -y -qq systemd-timesyncd >/dev/null
fi

# --------------------------------------------------------------------- keys
say "Generating REALITY keys"
if [[ -n ${REALITY_PRIV:-} && -n ${REALITY_PUB:-} && -n ${REALITY_SID:-} ]]; then
  R_PRIV=$REALITY_PRIV; R_PUB=$REALITY_PUB; R_SID=$REALITY_SID
  ok "reusing existing keys (clients keep working)"
else
  kp=$(sing-box generate reality-keypair)
  R_PRIV=$(awk -F': *' '/PrivateKey/{print $2}' <<<"$kp")
  R_PUB=$(awk -F': *' '/PublicKey/{print $2}' <<<"$kp")
  [[ -n $R_PRIV && -n $R_PUB ]] || die "Could not parse the REALITY keypair from sing-box."
  R_SID=$(openssl rand -hex 8)
  ok "public key $R_PUB"
fi

# ------------------------------------------------------------------- the mask
# The site we borrow. TLS 1.3 + HTTP/2 support is necessary but NOT sufficient:
# some major sites complete an ordinary TLS handshake yet cannot serve as a
# REALITY handshake target at all (www.microsoft.com is one). The only test
# worth trusting is a real REALITY handshake, so stand up a throwaway
# server/client pair on loopback per candidate and require traffic to flow.
CANDIDATES=${CANDIDATES:-"www.apple.com dl.google.com addons.mozilla.org www.cloudflare.com www.lovelive-anime.jp"}

verify_mask_site() {
  local host=$1 sport=45443 cport=11443 uuid rc=1 sp cp out
  uuid=$(cat /proc/sys/kernel/random/uuid)
  local sc; sc=$(mktemp); local cc; cc=$(mktemp)

  jq -n --arg priv "$R_PRIV" --arg sid "$R_SID" --arg sni "$host" \
        --arg uuid "$uuid" --argjson p "$sport" '
  { log:{level:"error"},
    inbounds:[{type:"vless",tag:"in",listen:"127.0.0.1",listen_port:$p,
               users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],
               tls:{enabled:true,server_name:$sni,
                    reality:{enabled:true,handshake:{server:$sni,server_port:443},
                             private_key:$priv,short_id:[$sid]}}}],
    outbounds:[{type:"direct",tag:"direct"}] }' >"$sc"

  jq -n --arg uuid "$uuid" --arg pbk "$R_PUB" --arg sid "$R_SID" --arg sni "$host" \
        --argjson sp "$sport" --argjson cp "$cport" '
  { log:{level:"error"},
    inbounds:[{type:"socks",tag:"in",listen:"127.0.0.1",listen_port:$cp}],
    outbounds:[{type:"vless",tag:"proxy",server:"127.0.0.1",server_port:$sp,uuid:$uuid,
                flow:"xtls-rprx-vision",
                tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
                     reality:{enabled:true,public_key:$pbk,short_id:$sid}}}] }' >"$cc"

  sing-box run -c "$sc" >/dev/null 2>&1 & sp=$!
  sing-box run -c "$cc" >/dev/null 2>&1 & cp=$!
  sleep 3
  out=$(curl -4 -s --max-time 8 --socks5-hostname "127.0.0.1:${cport}" https://api.ipify.org 2>/dev/null)
  [[ -n $out ]] && rc=0
  kill "$sp" "$cp" 2>/dev/null || true
  wait "$sp" "$cp" 2>/dev/null || true
  rm -f "$sc" "$cc"
  return $rc
}

if [[ -n ${REALITY_SNI_FORCE:-} ]]; then
  SNI=$REALITY_SNI_FORCE
  ok "Using forced mask site: $SNI"
else
  say "Choosing a mask site"
  info "testing each candidate with a real REALITY handshake, not just TLS"
  SNI=""
  for c in $CANDIDATES; do
    printf '  %-24s' "$c"
    if ! timeout 12 openssl s_client -connect "${c}:443" -servername "$c" \
           -tls1_3 -alpn h2 </dev/null 2>/dev/null | grep -q 'ALPN protocol: h2'; then
      printf '%sno TLS1.3+h2%s\n' "$YEL" "$RST"; continue
    fi
    if verify_mask_site "$c"; then
      printf '%sREALITY handshake ok%s\n' "$GRN" "$RST"; SNI=$c; break
    fi
    printf '%sTLS fine, but REALITY fails%s\n' "$YEL" "$RST"
  done
  [[ -n $SNI ]] || die "No candidate works as a REALITY mask. Set REALITY_SNI_FORCE=<host> and re-run."
  ok "Masking as ${BOLD}${SNI}${RST}"
fi

set_env REALITY_PRIV "$R_PRIV"
set_env REALITY_PUB  "$R_PUB"
set_env REALITY_SID  "$R_SID"
set_cfg REALITY_SNI  "$SNI"
set_cfg REALITY_PORT "$REALITY_PORT"
# Pin the client to the same build, so both ends agree on the config schema.
set_cfg SINGBOX_VERSION "$VER"

# ------------------------------------------------------------------- service
cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box (yanvpn REALITY transport)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
install -d -m 755 /var/lib/sing-box /etc/sing-box
systemctl daemon-reload

load_config
regen_reality
sing-box check -c "$SB_CONF" || die "Generated config failed validation (sing-box ${VER} schema mismatch)."
ok "config validated"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${REALITY_PORT}/tcp" >/dev/null
  ok "ufw: ${REALITY_PORT}/tcp"
fi

systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || {
  journalctl -u sing-box -n 30 --no-pager; die "sing-box failed to start."; }
ok "sing-box running, enabled at boot"

cat <<EOF

${BOLD}REALITY is up.${RST}

  Listening  TCP ${REALITY_PORT}
  Masking as ${SNI}
  Public key ${R_PUB}
  Short ID   ${R_SID}

${BOLD}Forward TCP ${REALITY_PORT} on your router to this machine${RST} — that is a
separate rule from the UDP ones, and it is the step people forget.

Then re-issue clients to pick up the REALITY profile:

  sudo vpnctl regen && sudo vpnctl qr phone reality

${BOLD}iOS:${RST} install ${BOLD}sing-box${RST}, ${BOLD}Streisand${RST}, or ${BOLD}V2Box${RST} (all free) and scan the
reality QR code. The official WireGuard app cannot speak this protocol.

EOF
