#!/usr/bin/env bash
# yanvpn health check and self-heal. Installed as /usr/local/sbin/yanvpn-health
# and run every 5 minutes by yanvpn-health.timer.
#
# Why this exists: systemd's notion of "active" does not mean "working" here.
# wg-quick and awg-quick are Type=oneshot with RemainAfterExit=yes, so if the
# userspace amneziawg-go daemon dies, the unit still reports active while the
# tunnel is gone. Same story for a DDNS record that silently drifts. Every check
# below tests the thing itself, not systemd's opinion of it.
#
#   yanvpn-health           quiet; logs to the journal, exits non-zero if unhealthy
#   yanvpn-health -v        verbose, for running by hand
#   yanvpn-health -n        check only, never restart anything

set -uo pipefail

VERBOSE=no; NOACT=no
for a in "$@"; do
  case $a in
    -v|--verbose) VERBOSE=yes ;;
    -n|--dry-run) NOACT=yes ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

CONF=/etc/yanvpn/config
[[ -r $CONF ]] || { echo "yanvpn is not installed"; exit 2; }
# shellcheck source=/dev/null
source "$CONF"
: "${WG_IF:=wg0}" "${AWG_IF:=awg0}" "${WG_NET4:=10.66.66}" "${AWG_NET4:=10.66.67}"
: "${REALITY_PORT:=443}" "${ENDPOINT:=}"

FAILED=0; HEALED=0

log()  { logger -t yanvpn-health -- "$*"; [[ $VERBOSE == yes ]] && printf '  %s\n' "$*"; }
okay() { [[ $VERBOSE == yes ]] && printf '  \e[32m✓\e[0m %s\n' "$*"; return 0; }
bad()  { FAILED=$((FAILED+1)); log "UNHEALTHY: $*"; [[ $VERBOSE == yes ]] && printf '  \e[31m✗\e[0m %s\n' "$*"; return 0; }

# Bring a unit back. Deliberately NOT 'systemctl restart': wg-quick and
# awg-quick are oneshots, and when the interface has vanished underneath them
# their ExecStop fails, which can abort the restart and leave the unit failed
# instead of running. Stop, clear the failure, remove any half-dead link, start.
heal() {
  local unit=$1 why=$2
  if [[ $NOACT == yes ]]; then
    log "would repair ${unit} (${why})"
    return 0
  fi
  HEALED=$((HEALED+1))
  log "repairing ${unit} (${why})"
  systemctl stop "$unit" 2>/dev/null || true
  systemctl reset-failed "$unit" 2>/dev/null || true
  # A stale interface makes the next 'up' fail with "File exists".
  if [[ $unit == *-quick@* ]]; then
    local iface=${unit##*@}
    ip link show "$iface" >/dev/null 2>&1 && ip link del "$iface" 2>/dev/null || true
  fi
  systemctl start "$unit" 2>/dev/null || log "WARNING: ${unit} would not start"
  sleep 3
}

# Run a check, and retry once after a short pause before believing a failure.
# A single blip at a 5-minute cadence is far more likely to be noise than a
# genuine outage, and restarting on noise is its own failure mode.
confirm() {
  "$@" && return 0
  sleep 2
  "$@"
}

# ------------------------------------------------------------------ WireGuard
check_wg()  { ip link show "$WG_IF"  >/dev/null 2>&1 && wg  show "$WG_IF"  >/dev/null 2>&1; }
check_awg() { ip link show "$AWG_IF" >/dev/null 2>&1 && awg show "$AWG_IF" >/dev/null 2>&1; }

if confirm check_wg; then okay "WireGuard ${WG_IF} up"
else bad "${WG_IF} interface missing or unresponsive"; heal "wg-quick@${WG_IF}" "interface down"
     confirm check_wg && log "recovered ${WG_IF}"; fi

if command -v awg >/dev/null && [[ -f /etc/amnezia/amneziawg/${AWG_IF}.conf ]]; then
  if confirm check_awg; then okay "AmneziaWG ${AWG_IF} up"
  else bad "${AWG_IF} interface missing (userspace daemon may have died)"
       heal "awg-quick@${AWG_IF}" "interface down"
       confirm check_awg && log "recovered ${AWG_IF}"; fi
fi

# -------------------------------------------------------------------- REALITY
if [[ -f /etc/sing-box/config.json ]]; then
  check_sb() {
    systemctl is-active --quiet sing-box \
      && ss -tln 2>/dev/null | grep -qE ":${REALITY_PORT}([[:space:]]|$)"
  }
  if confirm check_sb; then okay "REALITY listening on tcp/${REALITY_PORT}"
  else bad "sing-box not listening on tcp/${REALITY_PORT}"
       heal sing-box "not listening"
       confirm check_sb && log "recovered sing-box"; fi
fi

# ------------------------------------------------------------------ tunnel DNS
# Listening is not answering, so ask it a real question when dig is available.
check_dns() {
  if command -v dig >/dev/null; then
    dig +short +time=2 +tries=1 "@${WG_NET4}.1" example.com >/dev/null 2>&1
  else
    ss -uln 2>/dev/null | grep -q "${WG_NET4}.1:53"
  fi
}
if confirm check_dns; then okay "tunnel DNS answering on ${WG_NET4}.1"
else bad "dnsmasq not answering on ${WG_NET4}.1"; heal dnsmasq "not answering"
     confirm check_dns && log "recovered dnsmasq"; fi

# ------------------------------------------------------------------------ DDNS
# The published record drifting away from the real address is the single most
# likely way this whole thing silently stops working from outside.
if [[ -r /etc/yanvpn/duckdns.env && -n $ENDPOINT ]]; then
  PUB=$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null)
  if [[ -z $PUB ]]; then
    okay "skipping DDNS check (no outbound internet right now)"
  else
    REC=$(dig +short +time=3 +tries=1 @1.1.1.1 "$ENDPOINT" A 2>/dev/null | tail -1)
    if [[ $REC == "$PUB" ]]; then
      okay "DDNS ${ENDPOINT} -> ${PUB}"
    else
      bad "DDNS drift: ${ENDPOINT} says '${REC:-<none>}' but we are ${PUB}"
      if [[ $NOACT == no ]] && [[ -x /usr/local/sbin/yanvpn-ddns ]]; then
        HEALED=$((HEALED+1)); log "forcing a DDNS update"
        /usr/local/sbin/yanvpn-ddns >/dev/null 2>&1 && log "DDNS updated"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------- report
if [[ $VERBOSE == yes ]]; then
  printf '\n  %d check(s) failed, %d repair(s) attempted\n' "$FAILED" "$HEALED"
fi
[[ $FAILED -eq 0 ]] && exit 0
log "health check finished with ${FAILED} failure(s), ${HEALED} repair(s)"
exit 1
