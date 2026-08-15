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

# Re-running to pick up updater fixes must not require re-entering the token.
if [[ -r /etc/yanvpn/duckdns.env ]]; then
  # shellcheck source=/dev/null
  source /etc/yanvpn/duckdns.env
  SUB=${DUCKDNS_SUB:-}; TOKEN=${DUCKDNS_TOKEN:-}
fi
if [[ -n ${SUB:-} && -n ${TOKEN:-} ]]; then
  ok "reusing existing credentials for ${SUB}.duckdns.org"
else
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
fi

cat >/usr/local/sbin/yanvpn-ddns <<'EOF'
#!/usr/bin/env bash
# Push the current public IP to DuckDNS.
#
# An IP change and a brief outage arrive together: the WAN drops, comes back
# with a new address, and DNS is unreliable for a few seconds either side. That
# is exactly when this must not give up -- an updater that fails once and waits
# for the next timer tick leaves the hostname pointing at an address that now
# belongs to a stranger. So: retry with backoff, and only report failure after
# genuinely exhausting the attempts.
set -uo pipefail
source /etc/yanvpn/duckdns.env

for attempt in 1 2 3 4 5; do
  resp=$(curl -fsS --max-time 20 \
    "https://www.duckdns.org/update?domains=${DUCKDNS_SUB}&token=${DUCKDNS_TOKEN}&ip=" 2>/dev/null) || resp=""
  if [[ $resp == OK ]]; then
    echo "duckdns: ${DUCKDNS_SUB}.duckdns.org -> $(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || echo '?')"
    exit 0
  fi
  echo "duckdns: attempt ${attempt} failed (${resp:-no response}); retrying" >&2
  sleep $(( attempt * 5 ))
done
echo "duckdns: giving up after 5 attempts" >&2
exit 1
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
# Fire on a fixed wall-clock cadence rather than relative to the last run, so a
# failed attempt cannot delay the next one.
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now yanvpn-ddns.timer >/dev/null
/usr/local/sbin/yanvpn-ddns
ok "Timer active — refreshing every 5 minutes."

PREV_ENDPOINT=$(grep -oP '(?<=^ENDPOINT=).*' /etc/yanvpn/config 2>/dev/null | tr -d '"')
if [[ -r /etc/yanvpn/config ]] && command -v vpnctl >/dev/null; then
  vpnctl endpoint "${SUB}.duckdns.org"
fi

cat <<EOF

${BOLD}Done.${RST} Your server is now reachable at ${BOLD}${SUB}.duckdns.org${RST}
regardless of what your ISP does to your IP.

EOF

# Only nag about re-issuing when the hostname actually changed. A new IP behind
# an unchanged hostname is exactly what DDNS exists to absorb -- clients dial the
# name, so they need nothing.
if [[ ${PREV_ENDPOINT:-} != "${SUB}.duckdns.org" ]]; then
  cat <<EOF
Your endpoint changed from ${PREV_ENDPOINT:-<unset>}, so existing clients must be
re-issued:

    sudo vpnctl qr phone       # rescan on iOS
    sudo vpnctl show laptop    # copy to the laptop

EOF
else
  cat <<EOF
Clients need no changes — they dial the hostname, and only the address behind it
moved. That is what DDNS is for.

EOF
fi
