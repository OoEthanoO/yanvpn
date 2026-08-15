#!/usr/bin/env bash
# yanvpn base installer — plain WireGuard. Run on the HOME SERVER as root.
#
# This is the fast path, for networks that don't inspect your traffic. If the
# network you care about blocks WireGuard, install this anyway (it is the
# foundation the others build on), then add obfuscation:
#
#     sudo ./server/install-amnezia.sh    # obfuscated WireGuard, still UDP
#     sudo ./server/install-reality.sh    # TLS camouflage over TCP/443

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"

WG_IF=${WG_IF:-wg0}
WG_PORT=${WG_PORT:-51820}
WG_NET4=${WG_NET4:-10.66.66}
WG_ALT_PORTS=${WG_ALT_PORTS:-"443 53"}

say "yanvpn base install (WireGuard)"

[[ -f /etc/wireguard/${WG_IF}.conf ]] && die "/etc/wireguard/${WG_IF}.conf exists. Move it aside first."

WAN_IF=$(ip route show default | awk '/^default/{print $5; exit}')
[[ -n $WAN_IF ]] || die "No default route — cannot find the internet-facing interface."
ok "Internet-facing interface: $WAN_IF"

if [[ -z ${ENDPOINT:-} ]]; then
  PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  echo
  printf '  Hostname or IP that clients will connect to\n'
  [[ -n $PUBLIC_IP ]] && printf '  %s(currently %s — fine for now, install-ddns.sh makes it stable)%s\n' "$DIM" "$PUBLIC_IP" "$RST"
  printf '  Endpoint [%s]: ' "${PUBLIC_IP:-required}"
  read -r ENDPOINT </dev/tty
  ENDPOINT=${ENDPOINT:-$PUBLIC_IP}
fi
[[ -n $ENDPOINT ]] || die "An endpoint is required."

say "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools qrencode dnsmasq iptables curl jq >/dev/null
ok "wireguard, qrencode, dnsmasq, jq"

say "Enabling IP forwarding"
printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' >/etc/sysctl.d/99-yanvpn.conf
sysctl -q --system
ok "net.ipv4.ip_forward = 1"

say "Generating server keys"
install -d -m 700 /etc/wireguard "$YANVPN_DIR" "$CLIENTS"
umask 077
_priv=$(wg genkey)
_pub=$(printf '%s' "$_priv" | wg pubkey)

cat >"$CONFIG" <<EOF
WG_IF="${WG_IF}"
WG_PORT="${WG_PORT}"
WG_NET4="${WG_NET4}"
WG_ALT_PORTS="${WG_ALT_PORTS}"
WAN_IF="${WAN_IF}"
ENDPOINT="${ENDPOINT}"
CLIENT_MTU="1380"
EOF
chmod 600 "$CONFIG"
set_env WG_PRIV "$_priv"
set_env WG_PUB  "$_pub"
ok "Server public key: $_pub"

say "Configuring tunnel DNS"
# This is what defeats DNS filtering: clients are told to resolve via
# ${WG_NET4}.1, an address that exists only inside the tunnel. Every lookup is
# encrypted and answered from your house, so the local resolver sees nothing.
# bind-dynamic lets dnsmasq start before the tunnel interfaces exist.
cat >/etc/dnsmasq.d/yanvpn.conf <<EOF
interface=${WG_IF}
interface=awg0
bind-dynamic
listen-address=${WG_NET4}.1
listen-address=10.66.67.1

# Never read /etc/resolv.conf — on Ubuntu it points at systemd-resolved,
# which would create a resolution loop.
no-resolv
server=1.1.1.1
server=9.9.9.9

local-service
domain-needed
bogus-priv
cache-size=1000
EOF
systemctl enable --now dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq
ok "dnsmasq answering inside the tunnel only"

say "Generating ${WG_IF}"
load_config
regen_wg
ok "/etc/wireguard/${WG_IF}.conf"

install -m 755 "$SCRIPT_DIR/vpnctl" /usr/local/sbin/vpnctl
install -m 644 "$SCRIPT_DIR/lib.sh" "$YANVPN_DIR/lib.sh"
ok "/usr/local/sbin/vpnctl"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  say "Opening ports in ufw"
  ufw allow "${WG_PORT}/udp" >/dev/null
  for p in $WG_ALT_PORTS; do ufw allow "${p}/udp" >/dev/null; done
  ufw route allow in on "$WG_IF" >/dev/null 2>&1 || true
  ok "ufw: ${WG_PORT} ${WG_ALT_PORTS} (udp)"
fi

say "Starting WireGuard"
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1
systemctl restart "wg-quick@${WG_IF}"
sleep 1
systemctl is-active --quiet "wg-quick@${WG_IF}" || {
  journalctl -u "wg-quick@${WG_IF}" -n 30 --no-pager; die "wg-quick@${WG_IF} failed to start."; }
ok "wg-quick@${WG_IF} running, enabled at boot"

cat <<EOF

${BOLD}Base server is up.${RST}

  Endpoint   ${ENDPOINT}
  WireGuard  UDP ${WG_PORT} (also reachable on ${WG_ALT_PORTS// /, })

${BOLD}Because your target network blocks WireGuard, keep going:${RST}

  sudo ./server/install-amnezia.sh    obfuscated WireGuard — fast, still UDP
  sudo ./server/install-reality.sh    TLS camouflage on TCP/443 — nearly unblockable

Then create clients once, and get configs for every transport at the same time:

  sudo vpnctl add phone
  sudo vpnctl add laptop

EOF
