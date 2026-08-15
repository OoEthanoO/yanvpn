#!/usr/bin/env bash
# VLESS + REALITY over TCP/443. Run on the HOME SERVER as root, after install.sh.
#
# This is the transport that survives when everything else is blocked.
#
# Ordinary TLS tunnels are detectable because their certificate is either
# self-signed or issued to a domain nobody else visits. REALITY sidesteps that:
# during the handshake your server proxies the real TLS negotiation to a genuine
# public site (Microsoft, Apple, ...), so the certificate a middlebox observes is
# that site's actual certificate, with a valid chain. If a censor actively probes
# your address, it is transparently handed the real site and sees nothing unusual.
#
# The result is indistinguishable from an HTTPS connection to a major website
# without also blocking that website. Cost: TCP, so throughput is lower than
# WireGuard, and head-of-line blocking hurts on lossy links.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
load_config

REALITY_PORT=${REALITY_PORT:-443}

say "VLESS + REALITY install"

# ------------------------------------------------------------------- the mask
# The site we borrow. It must support TLS 1.3 and HTTP/2, must not be blocked on
# the network you're bypassing, and should be somewhere plausible for you to
# connect to constantly.
CANDIDATES=${CANDIDATES:-"www.microsoft.com www.apple.com www.cloudflare.com dl.google.com"}

check_dest() {
  local host=$1
  timeout 10 openssl s_client -connect "${host}:443" -servername "$host" \
      -tls1_3 -alpn h2 </dev/null 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

if [[ -n ${REALITY_SNI:-} ]]; then
  SNI=$REALITY_SNI
  ok "Using configured mask site: $SNI"
else
  say "Choosing a mask site"
  SNI=""
  for c in $CANDIDATES; do
    printf '  testing %-22s' "$c"
    if check_dest "$c"; then printf '%sTLS1.3 + h2 ok%s\n' "$GRN" "$RST"; SNI=$c; break
    else printf '%sunsuitable%s\n' "$YEL" "$RST"; fi
  done
  [[ -n $SNI ]] || die "No candidate site supports TLS1.3+h2 from here. Set REALITY_SNI=<host> and re-run."
  ok "Masking as ${BOLD}${SNI}${RST}"
fi

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

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/sb.tgz" \
  "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz" \
  || die "Download failed for sing-box ${VER} (${ARCH})."
tar -xzf "$tmp/sb.tgz" -C "$tmp"
install -m 755 "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
ok "sing-box $(sing-box version | awk 'NR==1{print $3}')"

# --------------------------------------------------------------------- keys
say "Generating REALITY keys"
kp=$(sing-box generate reality-keypair)
R_PRIV=$(awk -F': *' '/PrivateKey/{print $2}' <<<"$kp")
R_PUB=$(awk -F': *' '/PublicKey/{print $2}' <<<"$kp")
[[ -n $R_PRIV && -n $R_PUB ]] || die "Could not parse the REALITY keypair from sing-box."
R_SID=$(openssl rand -hex 8)

set_env REALITY_PRIV "$R_PRIV"
set_env REALITY_PUB  "$R_PUB"
set_env REALITY_SID  "$R_SID"
set_cfg REALITY_SNI  "$SNI"
set_cfg REALITY_PORT "$REALITY_PORT"
# Pin the client to the same build, so both ends agree on the config schema.
set_cfg SINGBOX_VERSION "$VER"
ok "public key $R_PUB"

# ----------------------------------------------------------------- accurate time
# REALITY performs a real TLS 1.3 handshake; a skewed clock breaks it in ways
# that look exactly like censorship.
if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  warn "System clock is not NTP-synchronised — enabling timesyncd"
  timedatectl set-ntp true 2>/dev/null || apt-get install -y -qq systemd-timesyncd >/dev/null
fi

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
sleep 1
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

  sudo vpnctl add phone       # or: vpnctl qr phone reality

${BOLD}iOS:${RST} install ${BOLD}sing-box${RST}, ${BOLD}Streisand${RST}, or ${BOLD}V2Box${RST} (all free) and scan the
reality QR code. The official WireGuard app cannot speak this protocol.

EOF
