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
# Installs whichever transports the server offered. For REALITY alone:
#
#   sudo ./install.sh --reality-only            # paste the vless:// link when asked
#   sudo ./install.sh --reality-only laptop/    # or take it from a client directory
#
# The link is what 'vpnctl show laptop reality' prints on either server.

set -euo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ------------------------------------------------------------ REALITY profile
# Every R_* value lands in the sing-box config or a download URL, so each is
# held to what a yanvpn server actually produces.
REALITY_ERR=""
reality_ok() {
  local hex='[0-9A-Fa-f]'
  REALITY_ERR=""
  if ! [[ ${R_UUID:-} =~ ^$hex{8}(-$hex{4}){3}-$hex{12}$ ]]; then
    REALITY_ERR="the UUID is missing or malformed"
  elif ! [[ ${R_HOST:-} =~ ^[A-Za-z0-9.:-]+$ ]]; then
    REALITY_ERR="the server address is missing or malformed"
  elif ! [[ ${R_PORT:-} =~ ^[0-9]{1,5}$ ]] || (( 10#$R_PORT < 1 || 10#$R_PORT > 65535 )); then
    REALITY_ERR="the port is missing or malformed"
  elif ! [[ ${R_SNI:-} =~ ^[A-Za-z0-9.-]+$ ]]; then
    REALITY_ERR="the mask site (sni) is missing or malformed"
  elif ! [[ ${R_PBK:-} =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    REALITY_ERR="the public key (pbk) is missing or malformed"
  elif ! [[ ${R_SID:-} =~ ^($hex$hex){0,8}$ ]]; then
    REALITY_ERR="the short id (sid) is malformed"
  elif ! [[ ${R_SBVER:-} =~ ^([0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*)?$ ]]; then
    REALITY_ERR="the sing-box version is malformed"
  fi
  [[ -z $REALITY_ERR ]] || return 1
  R_PORT=$((10#$R_PORT))
}

# Both servers write the same vless:// link to reality.url and print it for
# 'vpnctl show <client> reality', so it is the one thing every deployment can
# hand this client. Parsed into the R_* values reality.env carries.
parse_reality_url() {
  local url=${1//[$'\r\n\t ']/} rest query kv security="" type=""
  local -a pairs
  R_UUID=""; R_HOST=""; R_PORT=""; R_SNI=""; R_PBK=""; R_SID=""
  REALITY_ERR="not a vless:// link"
  [[ $url == vless://*@* ]] || return 1
  rest=${url#vless://}; rest=${rest%%#*}
  R_UUID=${rest%%@*}; rest=${rest#*@}
  query=""; [[ $rest == *\?* ]] && query=${rest#*\?}
  rest=${rest%%\?*}
  if [[ $rest == \[*\]:* ]]; then            # [IPv6]:port
    R_HOST=${rest%%]*}; R_HOST=${R_HOST#\[}; R_PORT=${rest##*]:}
  else
    R_HOST=${rest%:*}; R_PORT=${rest##*:}
  fi
  IFS='&' read -ra pairs <<<"$query"
  for kv in "${pairs[@]}"; do
    case $kv in
      security=*) security=${kv#*=} ;;
      type=*)     type=${kv#*=} ;;
      sni=*)      R_SNI=${kv#*=} ;;
      pbk=*)      R_PBK=${kv#*=} ;;
      sid=*)      R_SID=${kv#*=} ;;
    esac
  done
  # A Caddy-fronted Windows server hands out VLESS over WebSocket+TLS under the
  # same scheme. That is not REALITY, and this client cannot dial it.
  if [[ $security != reality || ${type:-tcp} != tcp ]]; then
    REALITY_ERR="security=${security:-none} type=${type:-tcp} is not a REALITY link"
    return 1
  fi
  reality_ok
}

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0 $*"
USAGE="Usage: sudo $0 [--reality-only] [<client-directory> | <reality.url>]"
ONLY=""; SRC=""
while (( $# )); do
  case $1 in
    --reality-only) ONLY=reality ;;
    -h|--help)      printf '%s\n' "$USAGE"; exit 0 ;;
    # sudo logs its full command line, so a link given here is already on disk.
    vless://*)      die "Don't pass the link as an argument: sudo logs it. Run with --reality-only and paste it when asked." ;;
    -*)             die "Unknown option: $1"$'\n'"$USAGE" ;;
    *)              [[ -z $SRC ]] || die "$USAGE"; SRC=${1%/} ;;
  esac
  shift
done

HAVE_REALITY=yes
if [[ -z $SRC ]]; then
  [[ $ONLY == reality ]] || die "$USAGE"
  # Hidden, because it is a credential and terminals get shared and recorded.
  [[ -t 0 ]] && printf 'Paste the REALITY link from the server (input is hidden): ' >&2
  link=""; IFS= read -rs link || true
  [[ -t 0 ]] && echo >&2
  parse_reality_url "$link" || die "That is not a usable REALITY link: ${REALITY_ERR}."
  unset link
elif [[ -f $SRC ]]; then
  ONLY=reality        # a lone file can only be a reality.url
  parse_reality_url "$(head -n1 "$SRC")" || die "$SRC: ${REALITY_ERR}."
elif [[ -d $SRC ]]; then
  [[ $ONLY == reality || -r $SRC/wg.conf ]] \
    || die "$SRC/wg.conf not found — is this a yanvpn client directory?"
  if [[ -r $SRC/reality.env ]]; then
    # shellcheck source=/dev/null
    source "$SRC/reality.env"
    reality_ok || die "$SRC/reality.env: ${REALITY_ERR}."
  elif [[ -r $SRC/reality.url ]]; then
    # A Windows server writes no reality.env: just the link, and its sing-box
    # version alongside so both ends can still run the same build.
    parse_reality_url "$(head -n1 "$SRC/reality.url")" || die "$SRC/reality.url: ${REALITY_ERR}."
    [[ -r $SRC/sing-box-version.txt ]] && R_SBVER=$(tr -d '[:space:]' <"$SRC/sing-box-version.txt")
    reality_ok || die "$SRC/sing-box-version.txt: ${REALITY_ERR}."
  else
    [[ $ONLY != reality ]] || die "$SRC has no REALITY profile (reality.env or reality.url)."
    HAVE_REALITY=no
  fi
else
  die "$SRC not found. Pass the client directory copied from the server, or its reality.url."
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
IF=yanvpn

say "Installing yanvpn client${ONLY:+ (REALITY only)}"
export DEBIAN_FRONTEND=noninteractive
if [[ $ONLY == reality ]]; then
  # curl and jq are all REALITY needs from apt, and are usually there already.
  command -v curl >/dev/null && command -v jq >/dev/null \
    || { apt-get update -qq && apt-get install -y -qq curl jq >/dev/null; }
else
  apt-get update -qq
fi

# ------------------------------------------------------------------ WireGuard
if [[ $ONLY != reality ]]; then
  apt-get install -y -qq wireguard wireguard-tools curl jq iputils-ping >/dev/null
  # wg-quick needs resolvconf to apply the tunnel's DNS setting. Without it the
  # 'DNS =' line is silently ignored and you keep using the local network's
  # filtered resolver, which is the whole thing we're avoiding.
  command -v resolvconf >/dev/null || command -v resolvectl >/dev/null \
    || apt-get install -y -qq resolvconf >/dev/null
  install -d -m 700 /etc/wireguard
  install -m 600 "$SRC/wg.conf" "/etc/wireguard/${IF}.conf"
  ok "WireGuard      /etc/wireguard/${IF}.conf"
fi

# ------------------------------------------------------------------ AmneziaWG
if [[ $ONLY != reality && -r $SRC/awg.conf ]]; then
  # shellcheck source=../../common/amneziawg-setup.sh
  source "$SCRIPT_DIR/../../common/amneziawg-setup.sh"
  ensure_amneziawg
  install -d -m 700 /etc/amnezia/amneziawg
  install -m 600 "$SRC/awg.conf" "/etc/amnezia/amneziawg/${IF}.conf"
  ok "AmneziaWG      /etc/amnezia/amneziawg/${IF}.conf"
fi

# -------------------------------------------------------------------- REALITY
if [[ $HAVE_REALITY == yes ]]; then
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
    [[ $ONLY == reality ]] && die "Cannot configure REALITY."
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

# ----------------------------------------------------------------- transports
# 'yanvpn up' tries every transport it finds a config for, so a REALITY-only
# install has to say so -- or a WireGuard config left by an earlier full install
# would still be tried first.
CLIENT_CONF=/etc/yanvpn-client.conf
[[ -f $CLIENT_CONF ]] && sed -i '/^TRANSPORTS=/d' "$CLIENT_CONF"
[[ $ONLY == reality ]] && echo 'TRANSPORTS="reality"' >>"$CLIENT_CONF"

# -------------------------------------------------------------------- watch
# Two things go wrong after a successful connect, and nothing used to notice
# either: the server's address rotates (WireGuard resolves a hostname exactly
# once), and the transport dies (failover only ran at 'yanvpn up' time, so a
# dead tunnel stayed dead however long you sat there).
#
# The watcher no-ops unless you asked to be connected, so it is cheap to leave
# enabled and will not resurrect a tunnel you deliberately took down.
systemctl disable --now yanvpn-reresolve.timer >/dev/null 2>&1 || true
rm -f /etc/systemd/system/yanvpn-reresolve.{service,timer}

cat >/etc/systemd/system/yanvpn-watch.service <<'EOF'
[Unit]
Description=Keep the yanvpn tunnel alive and pointed at the right address

[Service]
Type=oneshot
ExecStart=/usr/local/bin/yanvpn watch
EOF

cat >/etc/systemd/system/yanvpn-watch.timer <<'EOF'
[Unit]
Description=Check the yanvpn tunnel every 2 minutes

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
systemctl enable --now yanvpn-watch.timer >/dev/null 2>&1 || true
ok "CLI            /usr/local/bin/yanvpn"
ok "watch          every 2 min: re-resolves, and fails over if the tunnel dies"

if [[ $ONLY == reality ]]; then
  cat <<EOF

${BOLD}Done.${RST}

    sudo yanvpn up        connect over REALITY (TCP ${R_PORT})
    sudo yanvpn status    check
    sudo yanvpn down      disconnect

If 'up' fails, 'sudo yanvpn doctor' says whether this network or the server is
to blame.

EOF
else
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
fi
