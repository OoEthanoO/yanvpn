#!/usr/bin/env bash
# yanvpn preflight — run this on the HOME SERVER before install.sh
#
# Answers the question you don't know yet: can the outside world actually
# reach this machine? If you are behind CGNAT, no amount of port forwarding
# will help and you need a different design (see README, "Behind CGNAT").

set -uo pipefail

BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'

ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
info() { printf '  %s·%s %s\n' "$DIM" "$RST" "$*"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RST"; }

need() { command -v "$1" >/dev/null 2>&1; }

is_private_v4() {
  local ip=$1
  [[ $ip =~ ^10\. ]] && return 0
  [[ $ip =~ ^192\.168\. ]] && return 0
  [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
  return 1
}

is_cgnat_v4() {
  # 100.64.0.0/10  ->  100.64.x.x through 100.127.x.x
  [[ $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

printf '%s\n' "${BOLD}yanvpn preflight${RST}"

# ---------------------------------------------------------------- interfaces
head_ "1. Network interface"

WAN_IF=$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')
LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')

if [[ -z ${WAN_IF:-} ]]; then
  bad "No default route found. This machine has no internet path."
  exit 1
fi
ok "Default interface: ${BOLD}${WAN_IF}${RST}"
ok "Local address:     ${BOLD}${LOCAL_IP}${RST}"

if is_private_v4 "$LOCAL_IP"; then
  info "That's a private LAN address, so you will need a port forward on your router."
  NEEDS_FORWARD=yes
else
  ok "This machine holds a public address directly — no router forward needed."
  NEEDS_FORWARD=no
fi

# ------------------------------------------------------------------ public IP
head_ "2. Public IP as the internet sees it"

PUBLIC_IP=""
for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
  PUBLIC_IP=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')
  [[ -n $PUBLIC_IP ]] && break
done

if [[ -z $PUBLIC_IP ]]; then
  bad "Could not determine public IP (no outbound HTTPS?). Re-run when online."
  exit 1
fi
ok "Public IP: ${BOLD}${PUBLIC_IP}${RST}"

# ---------------------------------------------------------------- CGNAT check
head_ "3. Carrier-grade NAT check"

CGNAT_VERDICT="clear"

if is_cgnat_v4 "$PUBLIC_IP"; then
  bad "Your 'public' IP is in 100.64.0.0/10 — that is textbook CGNAT."
  CGNAT_VERDICT="cgnat"
elif is_private_v4 "$PUBLIC_IP"; then
  bad "Your 'public' IP is private. You are behind another layer of NAT."
  CGNAT_VERDICT="cgnat"
else
  ok "Public IP is a normal routable address (not in the CGNAT range)."

  # Second opinion: if the first hop past your router is CGNAT space, the ISP
  # is NATing you even though the far-end IP looks clean.
  if need traceroute; then
    info "Tracing first 4 hops to look for carrier NAT..."
    HOPS=$(traceroute -n -w 2 -q 1 -m 4 1.1.1.1 2>/dev/null | tail -n +2 | awk '{print $2}')
    while read -r hop; do
      [[ -z $hop || $hop == "*" ]] && continue
      if is_cgnat_v4 "$hop"; then
        warn "Hop ${hop} is in CGNAT space — your ISP is likely NATing you."
        CGNAT_VERDICT="suspect"
      fi
    done <<< "$HOPS"
    [[ $CGNAT_VERDICT == "clear" ]] && ok "No carrier-NAT hops seen in the first 4."
  else
    info "traceroute not installed; skipping the deeper check."
    info "Install it for a better answer:  sudo apt install -y traceroute"
  fi
fi

# ------------------------------------------------------- router WAN IP compare
head_ "4. Does your router agree?"

if [[ $NEEDS_FORWARD == yes ]]; then
  GW=$(ip route show default | awk '/^default/{print $3; exit}')
  info "Your router is at ${BOLD}${GW}${RST}"
  info "Open http://${GW} and find its ${BOLD}WAN / Internet IP${RST}."
  echo
  info "  If it shows ${BOLD}${PUBLIC_IP}${RST}      -> you are NOT behind CGNAT. Port forwarding will work."
  info "  If it shows something else       -> you ARE behind CGNAT. See README."
  echo
  info "This is the one check that can't be automated — routers have no standard API."
else
  ok "No router in the path; nothing to cross-check."
fi

# ------------------------------------------------------------- what to do next
head_ "5. Verdict"

case $CGNAT_VERDICT in
  cgnat)
    bad "Direct inbound connections will NOT work from this house."
    echo
    info "Your options, cheapest first:"
    info "  a) Call your ISP and ask for a public IPv4 address. Often free, sometimes \$5/mo."
    info "  b) Rent a \$4/mo VPS with a public IP and relay through it."
    info "  c) Use IPv6 if your ISP provides it (CGNAT is IPv4-only)."
    echo
    info "Check for usable IPv6 right now:"
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
      V6=$(ip -6 addr show scope global | awk '/inet6/{print $2; exit}')
      ok "  You have a global IPv6 address: ${BOLD}${V6}${RST}"
      info "  If your phone's carrier also does IPv6, an IPv6-only tunnel is viable."
    else
      bad "  No global IPv6 on this machine either."
    fi
    ;;
  suspect)
    warn "Inconclusive. Confirm with the router WAN IP check in step 4 before installing."
    ;;
  clear)
    ok "Looks good. You have a routable public IP."
    echo
    if [[ $NEEDS_FORWARD == yes ]]; then
      info "Next: forward these ${BOLD}UDP${RST} ports on your router to ${BOLD}${LOCAL_IP}${RST}:"
      info "    51820  (primary)"
      info "      443  (disguises the tunnel as QUIC/HTTP3 — this is the one that beats firewalls)"
      info "       53  (last-resort fallback; almost nothing blocks DNS ports)"
      echo
      info "Also give this machine a ${BOLD}static DHCP lease${RST} in the router so ${LOCAL_IP} never moves."
    fi
    echo
    info "Then run:  sudo ./server/install.sh"
    ;;
esac

# --------------------------------------------------------------- dynamic IP
head_ "6. Is your public IP stable?"
info "Most home ISPs rotate your IP every few days or on router reboot."
info "If yours does, clients will silently stop connecting."
info "Fix it after install with:  sudo ./server/install-ddns.sh"
echo
