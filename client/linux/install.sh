#!/usr/bin/env bash
# yanvpn Linux client installer.
#
#   sudo ./install.sh /path/to/laptop/
#
# where laptop/ is the directory produced by 'vpnctl add laptop' on the server:
#
#   scp -r root@your-server:/etc/yanvpn/clients/laptop .
#   sudo ./client/linux/install.sh laptop/
#
# Installs whichever transports the server offered.

set -euo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 $*"
SRC=${1:-}
[[ -n $SRC ]] || die "Usage: sudo $0 <client-directory>"
[[ -d $SRC ]] || die "$SRC is not a directory. Copy the whole client directory from the server."
SRC=${SRC%/}
[[ -r $SRC/wg.conf ]] || die "$SRC/wg.conf not found — is this a yanvpn client directory?"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IF=yanvpn

say "Installing yanvpn client"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# ------------------------------------------------------------------ WireGuard
apt-get install -y -qq wireguard wireguard-tools curl jq iputils-ping >/dev/null
# wg-quick needs resolvconf to apply the tunnel's DNS setting. Without it the
# 'DNS =' line is silently ignored and you keep using the local network's
# filtered resolver, which is the whole thing we're avoiding.
command -v resolvconf >/dev/null || command -v resolvectl >/dev/null \
  || apt-get install -y -qq resolvconf >/dev/null
install -d -m 700 /etc/wireguard
install -m 600 "$SRC/wg.conf" "/etc/wireguard/${IF}.conf"
ok "WireGuard      /etc/wireguard/${IF}.conf"

# ------------------------------------------------------------------ AmneziaWG
if [[ -r $SRC/awg.conf ]]; then
  # shellcheck source=../../common/amneziawg-setup.sh
  source "$SCRIPT_DIR/../../common/amneziawg-setup.sh"
  ensure_amneziawg
  install -d -m 700 /etc/amnezia/amneziawg
  install -m 600 "$SRC/awg.conf" "/etc/amnezia/amneziawg/${IF}.conf"
  ok "AmneziaWG      /etc/amnezia/amneziawg/${IF}.conf"
fi

# -------------------------------------------------------------------- REALITY
if [[ -r $SRC/reality.env ]]; then
  # shellcheck source=/dev/null
  source "$SRC/reality.env"

  if ! command -v sing-box >/dev/null; then
    case $(uname -m) in
      x86_64)  ARCH=amd64 ;;
      aarch64) ARCH=arm64 ;;
      armv7l)  ARCH=armv7 ;;
      *)       die "Unsupported architecture for sing-box: $(uname -m)" ;;
    esac
    VER=${R_SBVER:-}
    [[ -n $VER ]] || VER=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
                            | jq -r '.tag_name' | sed 's/^v//')
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/sb.tgz" \
      "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz" \
      || die "Could not download sing-box ${VER}."
    tar -xzf "$tmp/sb.tgz" -C "$tmp"
    install -m 755 "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
  fi
  ok "sing-box       $(sing-box version | awk 'NR==1{print $3}')"

  install -d -m 755 /etc/sing-box

  # sing-box changes its DNS/routing schema across releases and hard-fails on
  # anything deprecated, so emit each known-good shape newest-first and keep the
  # first that validates. Collect every error, because when all of them fail the
  # last one is rarely the informative one.
  emit_conf() {
    local variant=$1 dns route
    case $variant in
      # 1.12+: typed DNS servers, rule actions, and a mandatory domain resolver.
      modern)
        # remote resolver must be TCP: xtls-rprx-vision cannot relay UDP, so a
        # udp server behind the proxy fails every query. "local" (type local)
        # uses the system resolver to bootstrap, and avoids detouring to an
        # empty direct outbound, which sing-box rejects at startup.
        dns='{"servers":[{"tag":"remote","type":"tcp","server":"1.1.1.1","detour":"proxy"},
                         {"tag":"local","type":"local"}],
              "final":"remote","strategy":"ipv4_only"}'
        # QUIC is UDP, which Vision also cannot carry. Rejecting it makes
        # browsers fall back to TCP immediately instead of stalling first.
        route='{"rules":[{"action":"sniff"},
                         {"protocol":"dns","action":"hijack-dns"},
                         {"network":"udp","port":443,"action":"reject"},
                         {"ip_is_private":true,"outbound":"direct"}],
                "final":"proxy","auto_detect_interface":true,
                "default_domain_resolver":"local"}' ;;
      # 1.11: rule actions exist, default_domain_resolver does not.
      typed-action)
        dns='{"servers":[{"tag":"remote","type":"udp","server":"1.1.1.1","detour":"proxy"},
                         {"tag":"local","type":"udp","server":"1.1.1.1"}],
              "final":"remote","strategy":"ipv4_only"}'
        route='{"rules":[{"action":"sniff"},
                         {"protocol":"dns","action":"hijack-dns"},
                         {"ip_is_private":true,"outbound":"direct"}],
                "final":"proxy","auto_detect_interface":true}' ;;
      # <=1.11 with the old string-form DNS servers.
      legacy-action)
        dns='{"servers":[{"tag":"remote","address":"1.1.1.1","detour":"proxy"},
                         {"tag":"local","address":"1.1.1.1"}],
              "final":"remote","strategy":"ipv4_only"}'
        route='{"rules":[{"action":"sniff"},
                         {"protocol":"dns","action":"hijack-dns"},
                         {"ip_is_private":true,"outbound":"direct"}],
                "final":"proxy","auto_detect_interface":true}' ;;
      # <=1.10: no rule actions; DNS handled by a dedicated outbound.
      legacy-plain)
        dns='{"servers":[{"tag":"remote","address":"1.1.1.1","detour":"proxy"},
                         {"tag":"local","address":"1.1.1.1"}],
              "final":"remote","strategy":"ipv4_only"}'
        route='{"rules":[{"protocol":"dns","outbound":"dns-out"},
                         {"ip_is_private":true,"outbound":"direct"}],
                "final":"proxy","auto_detect_interface":true}' ;;
    esac
    local extra='[]'
    [[ $variant == legacy-plain ]] && extra='[{"type":"dns","tag":"dns-out"}]'

    jq -n --argjson dns "$dns" --argjson route "$route" --argjson extra "$extra" \
          --arg host "$R_HOST" --argjson port "$R_PORT" --arg uuid "$R_UUID" \
          --arg sni "$R_SNI" --arg pbk "$R_PBK" --arg sid "$R_SID" '
    {
      log: { level: "warn" },
      dns: $dns,
      inbounds: [{
        type: "tun", tag: "tun-in",
        address: ["172.19.0.1/30"],
        auto_route: true, strict_route: true, stack: "system"
      }],
      outbounds: ([{
        type: "vless", tag: "proxy",
        server: $host, server_port: $port, uuid: $uuid,
        flow: "xtls-rprx-vision",
        tls: {
          enabled: true, server_name: $sni,
          utls: { enabled: true, fingerprint: "chrome" },
          reality: { enabled: true, public_key: $pbk, short_id: $sid }
        }
      }, { type: "direct", tag: "direct" }] + $extra),
      route: $route
    }'
  }

  # 'sing-box check' validates schema only; things like "detour to an empty
  # direct outbound" are raised when the service graph is assembled at start.
  # Run the config for real, with tun swapped for a throwaway socks listener so
  # the routing table is never touched.
  smoke_test() {
    local t; t=$(mktemp)
    jq '.inbounds=[{"type":"socks","tag":"smoke","listen":"127.0.0.1","listen_port":11081}]' \
      "$1" >"$t" 2>/dev/null || { rm -f "$t"; return 1; }
    local out; out=$(timeout 5 sing-box run -c "$t" 2>&1 | head -2)
    rm -f "$t"
    [[ -z $out ]] && return 0
    printf '%s' "$out"; return 1
  }

  picked=""; errs=""
  for variant in modern typed-action legacy-action legacy-plain; do
    emit_conf "$variant" >/etc/sing-box/yanvpn.json 2>/dev/null || continue
    if ! err=$(sing-box check -c /etc/sing-box/yanvpn.json 2>&1); then
      errs+="  [${variant}] check: $(echo "$err" | grep -oP '(?<=\]).*' | head -1 | cut -c1-130)"$'\n'
      continue
    fi
    if ! err=$(smoke_test /etc/sing-box/yanvpn.json); then
      errs+="  [${variant}] start: $(echo "$err" | grep -oP '(?<=\]).*' | head -1 | cut -c1-130)"$'\n'
      continue
    fi
    picked=$variant; break
  done
  if [[ -z $picked ]]; then
    printf '\n%sEvery sing-box config shape was rejected by %s:%s\n%s\n' \
      "$RED" "$(sing-box version | awk 'NR==1{print $3}')" "$RST" "$errs"
    die "Cannot configure REALITY. WireGuard and AmneziaWG are installed and usable."
  fi
  chmod 600 /etc/sing-box/yanvpn.json
  ok "REALITY        /etc/sing-box/yanvpn.json (schema: ${picked})"

  # Started on demand by 'yanvpn up', not at boot — it takes the default route.
  cat >/etc/systemd/system/yanvpn-singbox.service <<'EOF'
[Unit]
Description=yanvpn REALITY transport (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 755 /var/lib/sing-box
  systemctl daemon-reload
  systemctl disable yanvpn-singbox >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- reresolve
# WireGuard resolves an endpoint hostname once and never again, so a server
# whose address rotates leaves a live tunnel pointed at nothing. The timer
# no-ops when no WireGuard-family tunnel is up, so it is cheap to leave on.
cat >/etc/systemd/system/yanvpn-reresolve.service <<'EOF'
[Unit]
Description=Re-point a live yanvpn tunnel at its endpoint's current address

[Service]
Type=oneshot
ExecStart=/usr/local/bin/yanvpn reresolve
EOF

cat >/etc/systemd/system/yanvpn-reresolve.timer <<'EOF'
[Unit]
Description=Check every 2 minutes whether the yanvpn endpoint has moved

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
RandomizedDelaySec=15

[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------------------ CLI
install -m 755 "$SCRIPT_DIR/yanvpn" /usr/local/bin/yanvpn
install -d -m 700 /var/lib/yanvpn
systemctl daemon-reload
systemctl enable --now yanvpn-reresolve.timer >/dev/null 2>&1 || true
ok "CLI            /usr/local/bin/yanvpn"
ok "reresolve      every 2 min, no-ops unless a tunnel is up"

cat <<EOF

${BOLD}Done.${RST}

    sudo yanvpn up        connect — tries WireGuard, then AmneziaWG, then REALITY
    sudo yanvpn status    check
    sudo yanvpn down      disconnect

${BOLD}First thing to run on the restricted network:${RST}

    sudo yanvpn doctor

It probes every transport and port and tells you what that network is actually
blocking, instead of leaving you to guess.

EOF
