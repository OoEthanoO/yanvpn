#!/usr/bin/env bash
# Install the yanvpn health check and its timer. Run on the SERVER as root.
# Safe to re-run; it only rewrites the script and units.

set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'
say() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()  { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
die() { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
[[ -r /etc/yanvpn/config ]] || die "yanvpn is not installed on this machine."

say "Installing yanvpn health check"

# dig makes the DNS checks meaningful; without it they degrade to "is it bound".
command -v dig >/dev/null || {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsutils >/dev/null 2>&1 || true
}

install -m 755 "$SCRIPT_DIR/health.sh" /usr/local/sbin/yanvpn-health
ok "/usr/local/sbin/yanvpn-health"

cat >/etc/systemd/system/yanvpn-health.service <<'EOF'
[Unit]
Description=yanvpn health check and self-heal
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/yanvpn-health
# A failing check is information, not a unit failure -- the script has already
# tried to repair whatever it found and logged it.
SuccessExitStatus=0 1
EOF

cat >/etc/systemd/system/yanvpn-health.timer <<'EOF'
[Unit]
Description=Run the yanvpn health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
# Without this, a machine that was asleep or off never catches up.
Persistent=true
# Keep it off the same instant as every other 5-minute timer on the box.
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now yanvpn-health.timer >/dev/null
ok "yanvpn-health.timer active — every 5 minutes"

echo
say "Running it once now"
/usr/local/sbin/yanvpn-health -v || true

cat <<EOF

${BOLD}Installed.${RST}

  yanvpn-health -v      run it by hand, verbose
  yanvpn-health -n      check only, never restart anything
  journalctl -t yanvpn-health --since today

It verifies the things systemd cannot: that the WireGuard and AmneziaWG
interfaces actually exist (a dead userspace daemon leaves the unit reporting
"active"), that sing-box is really listening, that tunnel DNS answers a real
query, and that your DDNS record still matches your public IP. Anything broken
is restarted, and a drifted DDNS record is re-pushed.

EOF
