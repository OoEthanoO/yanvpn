#!/usr/bin/env bash
# Dynamic DNS for yanvpn, via DuckDNS (free, no card, 5 subdomains).
#
# Home ISPs rotate your public IP without warning. When that happens every
# client silently stops connecting and the failure looks exactly like a
# firewall problem. A DDNS name keeps a stable address pointed at your house.
#
# Before running: create a free account at https://www.duckdns.org, add a
# subdomain (e.g. "yanvpn"), and copy your token from the top of that page.

set -euo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; DIM=$'\e[2m'; RST=$'\e[0m'
ok()  { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
die() { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"

printf '%s==>%s DuckDNS setup\n\n' "$BOLD" "$RST"
printf '  Subdomain %s(just the name, not .duckdns.org)%s: ' "$DIM" "$RST"
read -r SUB </dev/tty
printf '  Token: '
read -r TOKEN </dev/tty
[[ -n $SUB && -n $TOKEN ]] || die "Both fields are required."

install -d -m 700 /etc/yanvpn
cat >/etc/yanvpn/duckdns.env <<EOF
DUCKDNS_SUB=${SUB}
DUCKDNS_TOKEN=${TOKEN}
EOF
chmod 600 /etc/yanvpn/duckdns.env

cat >/usr/local/sbin/yanvpn-ddns <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/yanvpn/duckdns.env
resp=$(curl -fsS --max-time 20 \
  "https://www.duckdns.org/update?domains=${DUCKDNS_SUB}&token=${DUCKDNS_TOKEN}&ip=")
[[ $resp == OK ]] || { echo "duckdns update failed: $resp" >&2; exit 1; }
echo "duckdns: ${DUCKDNS_SUB}.duckdns.org updated"
EOF
chmod 755 /usr/local/sbin/yanvpn-ddns

cat >/etc/systemd/system/yanvpn-ddns.service <<'EOF'
[Unit]
Description=Update DuckDNS record for yanvpn
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/yanvpn-ddns
EOF

cat >/etc/systemd/system/yanvpn-ddns.timer <<'EOF'
[Unit]
Description=Refresh yanvpn DuckDNS record every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now yanvpn-ddns.timer >/dev/null
/usr/local/sbin/yanvpn-ddns
ok "Timer active — refreshing every 5 minutes."

if [[ -r /etc/yanvpn/config ]] && command -v vpnctl >/dev/null; then
  vpnctl endpoint "${SUB}.duckdns.org"
fi

cat <<EOF

${BOLD}Done.${RST} Your server is now reachable at ${BOLD}${SUB}.duckdns.org${RST}
regardless of what your ISP does to your IP.

Existing clients still hold the old endpoint. Re-issue them:

    sudo vpnctl qr phone       # rescan on iOS
    sudo vpnctl show laptop    # copy to the laptop

EOF
