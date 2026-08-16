#!/usr/bin/env bash
# Apply this checkout to a running yanvpn server. Run on the SERVER as root.
#
#   sudo ./server/update.sh          install anything that changed, then regenerate
#   sudo ./server/update.sh -n       show what would change, touch nothing
#
# This is deliberately narrow. It installs the management tooling and rebuilds
# generated configuration from the client registry. It does NOT install packages,
# mint keys, or re-run the installers -- those are one-time setup, and quietly
# re-running them is how a working deployment gets surprised.
#
# Existing clients are unaffected: their keys live in /etc/yanvpn and every
# protocol config is regenerated from them, so nothing needs re-issuing.

set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

DRY=no
[[ ${1:-} == -n || ${1:-} == --dry-run ]] && DRY=yes

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"
[[ -r /etc/yanvpn/config ]] || die "yanvpn is not installed here. Run server/install.sh first."

CHANGED=0

# Install src at dst if the contents differ. Returns 0 if it changed anything.
sync_file() {
  local src=$1 dst=$2 mode=$3 label=$4
  [[ -r $src ]] || { warn "missing from checkout: $src"; return 1; }
  if [[ -r $dst ]] && cmp -s "$src" "$dst"; then
    info "$label already current"
    return 1
  fi
  CHANGED=$((CHANGED+1))
  if [[ $DRY == yes ]]; then
    warn "would update $label ($dst)"
    return 0
  fi
  install -m "$mode" "$src" "$dst"
  ok "updated $label"
  return 0
}

say "Updating yanvpn from $(cd "$SCRIPT_DIR/.." && pwd)"
if command -v git >/dev/null && git -C "$SCRIPT_DIR/.." rev-parse --short HEAD >/dev/null 2>&1; then
  info "checkout at $(git -C "$SCRIPT_DIR/.." rev-parse --short HEAD)$(
        git -C "$SCRIPT_DIR/.." diff --quiet 2>/dev/null || echo ' (with local edits)')"
fi

# ------------------------------------------------------------------ tooling
sync_file "$SCRIPT_DIR/lib.sh"  /etc/yanvpn/lib.sh        644 "lib.sh"
sync_file "$SCRIPT_DIR/vpnctl"  /usr/local/sbin/vpnctl    755 "vpnctl"

# Only touch the health check if it was actually installed; installing it is
# install-health.sh's job, not this script's.
if [[ -e /usr/local/sbin/yanvpn-health ]]; then
  sync_file "$SCRIPT_DIR/health.sh" /usr/local/sbin/yanvpn-health 755 "yanvpn-health"
else
  info "health check not installed — run server/install-health.sh to add it"
fi

# --------------------------------------------------------------- regenerate
# Generation logic lives in lib.sh, so a lib.sh change means the live configs
# were produced by older code and should be rebuilt.
if [[ $DRY == yes ]]; then
  echo
  if (( CHANGED )); then warn "${CHANGED} file(s) would change; configs would then be regenerated"
  else ok "everything already current — nothing to do"; fi
  exit 0
fi

echo
if (( CHANGED )); then
  say "Regenerating configuration from the client registry"
  if vpnctl regen; then
    ok "all transports rebuilt and reloaded"
  else
    die "regen failed — the previous configs are still in place, nothing was torn down."
  fi
else
  ok "everything already current — nothing to regenerate"
fi

# ------------------------------------------------------------------- verify
echo
say "Verifying"
if [[ -x /usr/local/sbin/yanvpn-health ]]; then
  /usr/local/sbin/yanvpn-health -v
else
  # WG_IF is not in this script's scope; read it from the live config.
  wg_if=$(grep -oP '(?<=^WG_IF=).*' /etc/yanvpn/config 2>/dev/null | tr -d '"')
  for u in "wg-quick@${wg_if:-wg0}" sing-box dnsmasq; do
    systemctl list-unit-files "${u}.service" >/dev/null 2>&1 \
      && printf '  %-22s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
  done
fi

cat <<EOF

${BOLD}Done.${RST} Clients are unaffected — their keys live in /etc/yanvpn and every
protocol config is regenerated from them, so nothing needs re-issuing and no
QR codes need re-scanning.

EOF
