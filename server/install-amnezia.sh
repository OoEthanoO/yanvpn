#!/usr/bin/env bash
# AmneziaWG — obfuscated WireGuard. Run on the HOME SERVER as root, after install.sh.
#
# Why this exists: plain WireGuard is trivial to fingerprint. Every handshake
# initiation begins with the byte 0x01 followed by three zero bytes, and the
# packet is always exactly 148 bytes long. One DPI rule catches it on any port.
#
# AmneziaWG is a WireGuard fork that (a) replaces those four fixed header bytes
# with random per-deployment magic values, and (b) sends a burst of junk packets
# ahead of the real handshake so the size signature doesn't match either.
# Cryptography and speed are unchanged -- only the wire format moves.
#
# It is still UDP. If the network drops all UDP, use install-reality.sh instead.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
load_config

AWG_IF=${AWG_IF:-awg0}
AWG_PORT=${AWG_PORT:-51821}
AWG_NET4=${AWG_NET4:-10.66.67}

say "AmneziaWG install"

# ------------------------------------------------------------------- packages
# shellcheck source=../common/amneziawg-setup.sh
source "$SCRIPT_DIR/../common/amneziawg-setup.sh"
ensure_amneziawg
USERSPACE=$AWG_USERSPACE

# --------------------------------------------------------------- obfuscation
say "Generating obfuscation profile"

# These values are the shared secret of the disguise: they must match exactly
# on every client. They are generated once, per deployment, so two yanvpn
# installs never look alike to a traffic classifier.
# NB: 'read a b c d < <(... | tr)' assigns correctly but returns 1 at EOF
# without a trailing newline, which set -e turns into a fatal error. mapfile
# has no such trap.
mapfile -t _H < <(shuf -i 5-2147483647 -n 4)
H1=${_H[0]}; H2=${_H[1]}; H3=${_H[2]}; H4=${_H[3]}
JC=$(shuf -i 4-12 -n 1)          # junk packets sent before the real handshake
JMIN=50                          # junk packet size floor
JMAX=1000                        #                  ceiling
S1=$(shuf -i 15-150 -n 1)        # bytes of junk prepended to the init packet
S2=$(shuf -i 15-150 -n 1)        #                              response packet
# AmneziaWG requires S1 + 56 != S2, otherwise the padded init and response
# packets end up the same length and become distinguishable again.
while (( S1 + 56 == S2 )); do S2=$(shuf -i 15-150 -n 1); done

_priv=$(awg genkey)
_pub=$(printf '%s' "$_priv" | awg pubkey)

set_env AWG_PRIV "$_priv"
set_env AWG_PUB  "$_pub"
for kv in "AWG_JC=$JC" "AWG_JMIN=$JMIN" "AWG_JMAX=$JMAX" "AWG_S1=$S1" "AWG_S2=$S2" \
          "AWG_H1=$H1" "AWG_H2=$H2" "AWG_H3=$H3" "AWG_H4=$H4"; do
  set_env "${kv%%=*}" "${kv#*=}"
done
ok "headers H1-H4 randomised, ${JC} junk packets per handshake"

# ------------------------------------------------------------- port handover
# Hand the camouflage ports (443/53) to AmneziaWG. Plain WireGuard keeps only
# its own port: on any network where 443/53 mattered, the obfuscated transport
# is the one that stands a chance.
say "Reassigning camouflage ports to AmneziaWG"
set_cfg AWG_IF        "$AWG_IF"
set_cfg AWG_PORT      "$AWG_PORT"
set_cfg AWG_NET4      "$AWG_NET4"
set_cfg AWG_ALT_PORTS "443 53"
set_cfg WG_ALT_PORTS  ""
ok "UDP 443, 53 -> ${AWG_IF};  ${WG_IF} keeps ${WG_PORT}"

# ------------------------------------------------------------------- generate
# Bring wg0 down while its config still describes the rules it installed, so
# PostDown can actually remove them. Regenerating first would strand them.
if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
  systemctl stop "wg-quick@${WG_IF}"
fi
load_config
flush_yanvpn_redirects        # belt and braces: clear any orphans from before
regen_awg
regen_wg
ok "/etc/amnezia/amneziawg/${AWG_IF}.conf"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${AWG_PORT}/udp" >/dev/null
  ufw route allow in on "$AWG_IF" >/dev/null 2>&1 || true
fi

say "Starting ${AWG_IF}"
systemctl enable "awg-quick@${AWG_IF}" >/dev/null 2>&1
systemctl restart "awg-quick@${AWG_IF}"
systemctl start "wg-quick@${WG_IF}"
sleep 1
systemctl is-active --quiet "awg-quick@${AWG_IF}" || {
  journalctl -u "awg-quick@${AWG_IF}" -n 30 --no-pager; die "awg-quick@${AWG_IF} failed to start."; }
ok "awg-quick@${AWG_IF} running, enabled at boot"

cat <<EOF

${BOLD}AmneziaWG is up.${RST}

  Port       UDP ${AWG_PORT}, also reachable on 443 and 53
  Subnet     ${AWG_NET4}.0/24
  Mode       $([[ $USERSPACE == yes ]] && echo "userspace (amneziawg-go)" || echo "kernel module")

Re-issue your clients so they pick up the AmneziaWG profile:

  sudo vpnctl add phone     # or 'vpnctl qr phone awg' if it already exists

${BOLD}iOS:${RST} the official WireGuard app cannot speak this protocol. Install
${BOLD}AmneziaVPN${RST} from the App Store and scan the awg QR code instead.

EOF
