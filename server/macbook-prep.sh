#!/usr/bin/env bash
# Prepare a MacBook running Ubuntu to act as an always-on server.
#
# A laptop is not a server out of the box. Left alone it will close-lid-suspend,
# throttle its Wi-Fi to save power, and cook its own battery. Each of those
# presents as "the VPN randomly stops working", which is miserable to debug from
# the far side of a tunnel.
#
# Run this on the SERVER before (or after) install.sh. It is idempotent.

set -euo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
say()  { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$*"; }
die()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root:  sudo $0"

say "Preparing this laptop to run headless"

# ---------------------------------------------------------------- lid switch
# The big one. Closing the lid suspends the machine and every tunnel dies.
say "Ignoring the lid switch"
install -d -m 755 /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/99-yanvpn-server.conf <<'EOF'
# Run as a server: closing the lid must not suspend anything.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
IdleAction=ignore
EOF
ok "lid close, suspend key, and idle timeout all disabled"

# ------------------------------------------------------------------- sleeping
say "Masking sleep targets"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
ok "suspend/hibernate cannot be entered even if something requests it"

# --------------------------------------------------------------- wifi powersave
# Broadcom cards on Apple hardware park the radio aggressively. The tunnel stays
# "up" while packets quietly stall for seconds at a time.
say "Disabling Wi-Fi power management"
WIFI=$(ip -o link show | awk -F': ' '/wl/{print $2; exit}')
if [[ -n ${WIFI:-} ]]; then
  if [[ -d /etc/NetworkManager ]]; then
    install -d -m 755 /etc/NetworkManager/conf.d
    printf '[connection]\nwifi.powersave = 2\n' >/etc/NetworkManager/conf.d/99-yanvpn-nopowersave.conf
    ok "NetworkManager: wifi.powersave = 2 (off)"
  fi
  # Apply immediately too, in case NetworkManager isn't managing this link.
  iw dev "$WIFI" set power_save off 2>/dev/null && ok "${WIFI}: power_save off now" \
    || info "${WIFI}: could not set power_save directly (NetworkManager will handle it on reconnect)"

  # A boot-time oneshot races NetworkManager: it can run before NM associates,
  # after which NM re-applies its own powersave. A dispatcher script instead
  # fires on every "up" event, so it also survives Wi-Fi reconnects -- which is
  # exactly when a laptop server drops off the network.
  cat >/etc/NetworkManager/dispatcher.d/99-yanvpn-powersave <<'DISP'
#!/bin/sh
# yanvpn: keep Wi-Fi power saving off. Broadcom cards on Apple hardware park the
# radio hard enough to stall a tunnel for seconds at a time.
IFACE="$1"; ACTION="$2"
case "$ACTION" in
  up|dhcp4-change|dhcp6-change) ;;
  *) exit 0 ;;
esac
case "$IFACE" in
  wl*) iw dev "$IFACE" set power_save off 2>/dev/null ;;
esac
exit 0
DISP
  # Dispatcher refuses to run scripts that are group/world writable.
  chown root:root /etc/NetworkManager/dispatcher.d/99-yanvpn-powersave
  chmod 755 /etc/NetworkManager/dispatcher.d/99-yanvpn-powersave
  ok "dispatcher installed — re-applied on every connect"

  # Also pin it on the connection profile itself (2 = disable powersave), since
  # a per-connection value overrides the global default.
  for c in $(nmcli -t -f NAME connection show 2>/dev/null); do
    nmcli connection modify "$c" 802-11-wireless.powersave 2 >/dev/null 2>&1 || true
  done
  ok "connection profiles pinned to powersave=disable"

  # Remove the older racy unit if a previous run installed it.
  if systemctl list-unit-files yanvpn-wifi-powersave.service >/dev/null 2>&1; then
    systemctl disable --now yanvpn-wifi-powersave >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/yanvpn-wifi-powersave.service
    systemctl daemon-reload
  fi
else
  info "No Wi-Fi interface found — skipping"
fi

# ------------------------------------------------------------------- ethernet
say "Checking the network path"
ETH=$(ip -o link show | awk -F': ' '/en|eth/{print $2; exit}')
if [[ -n ${ETH:-} ]] && ip link show "$ETH" 2>/dev/null | grep -q 'state UP'; then
  ok "Wired connection active on ${ETH} — best case"
else
  warn "Running over Wi-Fi."
  info "A 2017 MacBook Pro has no Ethernet port, but a USB-C dongle is ~\$15 and"
  info "removes an entire category of intermittent failure. Worth it for a box"
  info "you intend to leave running."
fi

# -------------------------------------------------------------------- thermals
say "Thermals"
if apt-cache show mbpfan >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mbpfan >/dev/null 2>&1 \
    && systemctl enable --now mbpfan >/dev/null 2>&1 \
    && ok "mbpfan installed — fans respond to temperature under Linux" \
    || info "mbpfan install failed; not critical"
else
  info "mbpfan not available in your repos — skipping"
fi
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  t=$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))
  info "Current CPU temperature: ${t}°C"
fi
info "Closed-lid operation traps heat. Prop the lid open a few millimetres, or"
info "stand the machine on its side, if it runs hot."

# --------------------------------------------------------------------- battery
say "Battery"
BAT=/sys/class/power_supply/BAT0
if [[ -d $BAT ]]; then
  full=$(cat "$BAT/energy_full" 2>/dev/null || echo 0)
  design=$(cat "$BAT/energy_full_design" 2>/dev/null || echo 0)
  if (( design > 0 )); then
    info "Health: $(( full * 100 / design ))% of design capacity"
  fi
  warn "Left plugged in at 100% for months, this battery will swell."
  info "A 2017 MacBook Pro exposes no charge-limit control under Linux, so there"
  info "is nothing to configure — just check on it every few months. A swelling"
  info "battery deforms the case and is a genuine fire risk."
else
  info "No battery detected."
fi

# Deliberately NOT restarting systemd-logind. It would apply the lid settings
# immediately, but it also severs the session/seat bookkeeping GNOME relies on,
# leaving the desktop unable to log in until reboot. logind config only takes
# effect on restart, so a reboot is the honest way to apply it.
cat <<EOF

${BOLD}Done — but reboot to apply.${RST}

The lid and idle settings live in systemd-logind, which only reads them at
start. Restarting logind on a running desktop breaks GNOME login until reboot,
so this script does not do that.

    sudo reboot

${BOLD}Then verify${RST} by closing the lid and, from another machine:

    ping $(hostname -I | awk '{print $1}')

If it keeps replying, you're set.

EOF
