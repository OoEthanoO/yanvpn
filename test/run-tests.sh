#!/usr/bin/env bash
# yanvpn test suite.
#
#   ./test/run-tests.sh
#
# Runs unprivileged and offline. Every path that generates configuration is
# exercised against a throwaway tree, because the bugs that actually cost time
# on this project were all in generation and all invisible to `bash -n`:
# a multi-word value written unquoted, a `read` that returns 1 at EOF under
# `set -e`, peers built from the wrong transport's keys, iptables rules stranded
# by regenerating before tearing down, and a sing-box config that validated but
# would not start.
#
# Tests needing sing-box are skipped when it is absent rather than failing.

set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'

PASS=0; FAIL=0; SKIP=0
# Namespaced on purpose: lib.sh defines ok/warn/info/die, and sourcing it inside
# a fixture would otherwise replace the harness's reporters -- passes would
# still print but stop being counted, quietly hiding how little ran.
group()  { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }
t_pass() { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
t_fail() { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$RED" "$RST" "$1"
           [[ -n ${2:-} ]] && printf '      %s\n' "$2"; }
t_skip() { SKIP=$((SKIP+1)); printf '  %s–%s %s %s(skipped: %s)%s\n' "$YEL" "$RST" "$1" "$DIM" "$2" "$RST"; }

eq()       { [[ $2 == "$3" ]] && t_pass "$1" || t_fail "$1" "expected '$3', got '$2'"; }
contains() { [[ $2 == *"$3"* ]] && t_pass "$1" || t_fail "$1" "missing '$3'"; }
absent()   { [[ $2 != *"$3"* ]] && t_pass "$1" || t_fail "$1" "should not contain '$3'"; }
succeeds() { if "${@:2}" >/dev/null 2>&1; then t_pass "$1"; else t_fail "$1" "command failed: ${*:2}"; fi; }
fails()    { if "${@:2}" >/dev/null 2>&1; then t_fail "$1" "should have failed: ${*:2}"; else t_pass "$1"; fi; }
# Run a command in a subshell. Anything under test that calls die() would
# otherwise exit(1) the harness itself, ending the run mid-group -- which reads
# as "the suite passed everything before this" rather than "the suite stopped".
sub() { ( "$@" ); }

# A throwaway /etc tree with one server and two clients.
make_fixture() {
  local T=$1
  rm -rf "$T"; mkdir -p "$T/etc/yanvpn/clients" "$T/wg" "$T/awg" "$T/sb"
  export YANVPN_DIR="$T/etc/yanvpn" WG_DIR="$T/wg" AWG_DIR="$T/awg" SB_DIR="$T/sb"
  # lib.sh derives CONFIG/SERVER_ENV/CLIENTS at source time, so it has to be
  # re-sourced once the fixture's paths are in the environment.
  # shellcheck source=/dev/null
  source "$REPO/server/lib.sh"
  touch "$YANVPN_DIR/config"
  # Build config only through set_cfg/set_env, exactly as the installers do, so
  # the suite covers how values are written and not just how they are read.
  set_cfg WG_IF wg0;   set_cfg WG_PORT 51820; set_cfg WG_NET4 10.66.66
  set_cfg WAN_IF eth0; set_cfg ENDPOINT vpn.example.org; set_cfg CLIENT_MTU 1380
  set_cfg WG_ALT_PORTS "443 53"
  set_env WG_PRIV SRV_WG_PRIV; set_env WG_PUB SRV_WG_PUB
  local n h
  for n in alpha beta; do
    h=$([[ $n == alpha ]] && echo 2 || echo 3)
    mkdir -p "$YANVPN_DIR/clients/$n"
    cat >"$YANVPN_DIR/clients/$n/meta" <<EOF
CL_NAME=$n
CL_HOST=$h
CL_WG_PRIV=${n}_WGPRIV
CL_WG_PUB=${n}_WGPUB
CL_WG_PSK=${n}_WGPSK
CL_AWG_PRIV=${n}_AWGPRIV
CL_AWG_PUB=${n}_AWGPUB
CL_AWG_PSK=${n}_AWGPSK
CL_UUID=$([[ $n == alpha ]] && echo "$T_UUID_ALPHA" || echo "$T_UUID_BETA")
EOF
  done
}

enable_amnezia() {
  set_cfg AWG_IF awg0; set_cfg AWG_PORT 51821; set_cfg AWG_NET4 10.66.67
  set_cfg AWG_ALT_PORTS "443 53"; set_cfg WG_ALT_PORTS ""
  set_env AWG_PRIV SRV_AWG_PRIV; set_env AWG_PUB SRV_AWG_PUB
  local kv
  for kv in AWG_JC=9 AWG_JMIN=50 AWG_JMAX=1000 AWG_S1=124 AWG_S2=113 \
            AWG_H1=1732916892 AWG_H2=1105905578 AWG_H3=1605792636 AWG_H4=1629572532; do
    set_env "${kv%%=*}" "${kv#*=}"
  done
}

enable_reality() {
  set_env REALITY_PRIV "$T_PRIV"; set_env REALITY_PUB "$T_PUB"
  set_env REALITY_SID abcdef0123456789
  set_cfg REALITY_SNI www.example.com; set_cfg REALITY_PORT 443
}

# Structurally valid throwaway values. sing-box validates key encoding and UUID
# shape at load, so placeholder strings make its own checks unusable as tests.
# These are generated test keys and belong to no deployment.
T_PRIV="YGXsP6PT8KTbP3DBGInobQvCYPeH4x825gat1at4j0w"
T_PUB="i-zP5EA56KkvFgBjZ6eHbEpXxDDgXnhtmhtHisGT-E4"
T_UUID_ALPHA="11111111-2222-3333-4444-555555555555"
T_UUID_BETA="66666666-7777-8888-9999-000000000000"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------- syntax
group "Syntax"
for f in "$REPO"/server/*.sh "$REPO"/server/vpnctl "$REPO"/common/*.sh \
         "$REPO"/client/linux/install.sh "$REPO"/client/linux/yanvpn "$REPO"/test/run-tests.sh; do
  [[ -e $f ]] || continue
  succeeds "parses: ${f#"$REPO"/}" bash -n "$f"
done

# ------------------------------------------------------------------- shellcheck
group "Lint"
if command -v shellcheck >/dev/null; then
  SC_FILES=("$REPO"/server/*.sh "$REPO"/server/vpnctl "$REPO"/common/*.sh
            "$REPO"/client/linux/install.sh "$REPO"/client/linux/yanvpn "$REPO"/test/run-tests.sh)
  errs=$(shellcheck -S error -f gcc "${SC_FILES[@]}" 2>/dev/null | grep -c ': error:')
  eq "no shellcheck errors" "$errs" "0"
  # Kept at zero. The few unavoidable cases carry explicit disable directives
  # explaining why, so a new warning is a failure rather than something that
  # blends quietly into a tolerated baseline.
  warns=$(shellcheck -S warning -f gcc "${SC_FILES[@]}" 2>/dev/null | grep -c ': warning:')
  if [[ $warns -le 0 ]]; then t_pass "shellcheck is clean"
  else t_fail "shellcheck is clean" "$warns warning(s); this codebase keeps it at zero"; fi
else
  t_skip "shellcheck" "not installed"
fi

# ------------------------------------------------------------ config round-trip
group "Config values survive a write/read round-trip"
# shellcheck source=/dev/null
source "$REPO/server/lib.sh"
make_fixture "$TMP/a"
if load_config 2>/dev/null; then t_pass "generated config sources cleanly"
else t_fail "generated config sources cleanly" "load_config errored"; fi
# The original bug: WG_ALT_PORTS="443 53" written unquoted made `source` try to
# run `53` as a command.
eq "multi-word value survives quoting" "${WG_ALT_PORTS:-}" "443 53"
eq "scalar value survives"             "${WG_PORT:-}"      "51820"
set_cfg WG_ALT_PORTS ""; load_config
eq "value can be cleared"              "${WG_ALT_PORTS:-}" ""

# ------------------------------------------------------------- host allocation
group "Address allocation"
make_fixture "$TMP/b"; load_config
eq "next free octet after .2 and .3" "$(next_host_octet)" "4"
rm -rf "$YANVPN_DIR/clients/alpha"
eq "frees an octet when a client is removed" "$(next_host_octet)" "2"

# ------------------------------------------------------------ peer generation
group "WireGuard config generation"
make_fixture "$TMP/c"; load_config; regen_wg
WGC=$(cat "$WG_DIR/wg0.conf")
eq       "one [Peer] per client" "$(grep -c '^\[Peer\]' "$WG_DIR/wg0.conf")" "2"
contains "server private key present"  "$WGC" "PrivateKey = SRV_WG_PRIV"
contains "client public key present"   "$WGC" "alpha_WGPUB"
contains "preshared key present"       "$WGC" "alpha_WGPSK"
contains "address from the wg subnet"  "$WGC" "AllowedIPs   = 10.66.66.2/32"
contains "alt-port redirect emitted"   "$WGC" "--dport 443 -j REDIRECT --to-ports 51820"
absent   "no AmneziaWG keys leak in"   "$WGC" "AWGPUB"

group "AmneziaWG config generation"
make_fixture "$TMP/d"; enable_amnezia; load_config; regen_awg; regen_wg
AWGC=$(cat "$AWG_DIR/awg0.conf")
contains "obfuscation profile written" "$AWGC" "Jc  = 9"
contains "header magic written"        "$AWGC" "H1  = 1732916892"
# Peers must use the AmneziaWG keypair, not the WireGuard one. Getting this
# wrong produces a config that looks right and never handshakes.
contains "peers use the awg keys"      "$AWGC" "alpha_AWGPUB"
absent   "peers do not use wg keys"    "$AWGC" "alpha_WGPUB"
contains "address from the awg subnet" "$AWGC" "10.66.67.2/32"
contains "camouflage ports redirect to awg" "$AWGC" "--dport 443 -j REDIRECT --to-ports 51821"
# The handover: once AmneziaWG owns 443/53, plain WireGuard must stop claiming
# them, or stale rules shadow the new ones.
absent   "wireguard released the camouflage ports" "$(cat "$WG_DIR/wg0.conf")" "REDIRECT --to-ports 51820"

# ------------------------------------------------------------ reality server
group "REALITY server config"
if command -v jq >/dev/null; then
  make_fixture "$TMP/e"; enable_amnezia; enable_reality; load_config; regen_reality
  succeeds "emits valid JSON" jq -e . "$SB_DIR/config.json"
  eq "one user per client" "$(jq '.inbounds[0].users|length' "$SB_DIR/config.json")" "2"
  eq "mask site propagated" "$(jq -r '.inbounds[0].tls.server_name' "$SB_DIR/config.json")" "www.example.com"
  eq "handshake target matches SNI" \
     "$(jq -r '.inbounds[0].tls.reality.handshake.server' "$SB_DIR/config.json")" "www.example.com"
  if command -v sing-box >/dev/null; then
    succeeds "sing-box accepts the server config" sing-box check -c "$SB_DIR/config.json"
  else t_skip "sing-box accepts the server config" "sing-box not installed"; fi
else t_skip "REALITY server config" "jq not installed"; fi

# ------------------------------------------------------------ client artifacts
group "Client artifacts"
make_fixture "$TMP/f"; enable_amnezia; enable_reality; load_config
eval "$(sed -n '/^gen_wg_conf()/,/^}/p;/^gen_awg_conf()/,/^}/p;/^gen_reality_url()/,/^}/p;/^gen_reality_env()/,/^}/p' "$REPO/server/vpnctl")"
load_client alpha
CW=$(gen_wg_conf); CA=$(gen_awg_conf); CU=$(gen_reality_url)
contains "client wg.conf uses its own private key" "$CW" "PrivateKey = alpha_WGPRIV"
contains "client wg.conf points at the endpoint"   "$CW" "Endpoint     = vpn.example.org:51820"
contains "client wg.conf blackholes IPv6"          "$CW" "::/0"
contains "client awg.conf carries the profile"     "$CA" "S1  = 124"
contains "client awg.conf uses the camouflage port" "$CA" "vpn.example.org:443"
contains "reality url carries the uuid"  "$CU" "$T_UUID_ALPHA"
contains "reality url carries the pubkey" "$CU" "pbk=$T_PUB"
contains "reality url carries the sni"   "$CU" "sni=www.example.com"
contains "reality url uses vision flow"  "$CU" "flow=xtls-rprx-vision"

# ------------------------------------------------------------- name validation
group "Client name validation"
valid_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$ ]]; }
for n in phone laptop-work my_pad a A1; do succeeds "accepts '$n'" valid_name "$n"; done
for n in "" "-lead" "a b" "../etc/passwd" 'x;rm -rf /' '$(id)' "a/b" "$(printf 'a%.0s' {1..40})"; do
  fails "rejects '${n:0:18}'" valid_name "$n"
done

# ----------------------------------------------------------- backup / restore
group "Backup and restore"
make_fixture "$TMP/g"; enable_amnezia; enable_reality; load_config
eval "$(sed -n '/^cmd_backup()/,/^}/p' "$REPO/server/vpnctl")"
BK="$TMP/backup.tar.gz"
cmd_backup "$BK" >/dev/null 2>&1
succeeds "backup archive created" test -s "$BK"
contains "archive holds the config"  "$(tar -tzf "$BK")" "yanvpn/config"
contains "archive holds server keys" "$(tar -tzf "$BK")" "yanvpn/server.env"
contains "archive holds client meta" "$(tar -tzf "$BK")" "yanvpn/clients/alpha/meta"
eq "backup is not world-readable" "$(stat -c '%a' "$BK")" "600"
# Wipe and restore, then confirm the regenerated peer carries the original keys.
rm -rf "$YANVPN_DIR"
tar -C "$(dirname "$YANVPN_DIR")" -xzf "$BK"
load_config; regen_wg
contains "restored peer keeps its key" "$(cat "$WG_DIR/wg0.conf")" "alpha_WGPUB"
eq "restored client count" "$(client_names | wc -l)" "2"

# ------------------------------------------------------------- restore itself
group "Restore"
# cmd_backup was covered above, but cmd_restore had never actually been run --
# only its tar mechanics by hand. A disaster-recovery path nobody has executed
# is a hope, not a plan.
make_fixture "$TMP/r"; enable_amnezia; enable_reality; load_config
eval "$(sed -n '/^gen_wg_conf()/,/^}/p;/^gen_awg_conf()/,/^}/p;/^gen_reality_url()/,/^}/p;/^gen_reality_env()/,/^}/p;/^write_client_files()/,/^}/p;/^cmd_regen()/,/^}/p;/^cmd_backup()/,/^}/p;/^cmd_restore()/,/^}/p' "$REPO/server/vpnctl")"
RBK="$TMP/restore.tar.gz"
cmd_backup "$RBK" >/dev/null 2>&1

# Refuses things that are not a yanvpn backup, rather than unpacking them over
# live state.
echo "not a backup" | gzip >"$TMP/bogus.tar.gz"
fails "rejects a non-yanvpn archive" sub cmd_restore "$TMP/bogus.tar.gz"
fails "rejects a missing file"       sub cmd_restore "$TMP/does-not-exist.tar.gz"
fails "rejects no argument"          sub cmd_restore

# A real restore over existing state.
ORIG_UUID=$(grep -oP '(?<=^CL_UUID=).*' "$YANVPN_DIR/clients/alpha/meta")
rm -rf "$YANVPN_DIR/clients/beta"          # simulate divergence from the backup
if sub cmd_restore "$RBK" >/dev/null 2>&1; then t_pass "restore completes"
else t_fail "restore completes"; fi
eq "both clients came back"      "$(client_names | wc -l)" "2"
eq "keys are the originals"      "$(grep -oP '(?<=^CL_UUID=).*' "$YANVPN_DIR/clients/alpha/meta")" "$ORIG_UUID"
contains "peers regenerated from restored keys" "$(cat "$WG_DIR/wg0.conf")" "alpha_WGPUB"
contains "awg peers regenerated too"            "$(cat "$AWG_DIR/awg0.conf")" "alpha_AWGPUB"
# Displaced state is preserved rather than destroyed, so a mistaken restore is
# recoverable.
if compgen -G "${YANVPN_DIR}.replaced-*" >/dev/null; then t_pass "prior state moved aside, not deleted"
else t_fail "prior state moved aside, not deleted"; fi

# ------------------------------------------------------- sing-box client shapes
group "sing-box client config shapes"
if command -v jq >/dev/null; then
  R_UUID=$T_UUID_ALPHA R_HOST=vpn.example.org R_PORT=443 R_SNI=www.example.com \
  R_PBK=$T_PUB R_SID=abcdef0123456789
  export R_UUID R_HOST R_PORT R_SNI R_PBK R_SID
  eval "$(sed -n '/^  emit_conf()/,/^  }$/p' "$REPO/client/linux/install.sh")"
  for v in modern typed-action legacy-action legacy-plain; do
    out=$(emit_conf "$v" 2>/dev/null)
    if jq -e . >/dev/null 2>&1 <<<"$out"; then t_pass "variant '$v' emits valid JSON"
    else t_fail "variant '$v' emits valid JSON"; fi
  done
  M=$(emit_conf modern)
  # Vision cannot relay UDP, so a udp resolver behind the proxy fails every
  # lookup. This is the bug that made REALITY appear to hang.
  eq "modern uses a TCP remote resolver" \
     "$(jq -r '.dns.servers[]|select(.tag=="remote")|.type' <<<"$M")" "tcp"
  eq "modern bootstraps with the system resolver" \
     "$(jq -r '.dns.servers[]|select(.tag=="local")|.type' <<<"$M")" "local"
  contains "modern sets a default domain resolver" "$M" "default_domain_resolver"
  if command -v sing-box >/dev/null; then
    echo "$M" >"$TMP/m.json"
    succeeds "sing-box accepts the modern client config" sing-box check -c "$TMP/m.json"
    # `check` validates schema only; the DNS/outbound graph is wired at start.
    jq '.inbounds=[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":11099}]' \
      "$TMP/m.json" >"$TMP/ms.json"
    if [[ -z $(timeout 5 sing-box run -c "$TMP/ms.json" 2>&1 | head -2) ]]; then
      t_pass "modern client config actually starts"
    else t_fail "modern client config actually starts" "$(timeout 5 sing-box run -c "$TMP/ms.json" 2>&1 | head -1)"; fi
  else t_skip "sing-box validation" "sing-box not installed"; fi
else t_skip "sing-box client shapes" "jq not installed"; fi

# ------------------------------------------------------------- client helpers
group "Client port selection"
mkdir -p "$TMP/cl"
printf '[Peer]\nEndpoint     = vpn.example.org:51820\n' >"$TMP/cl/wg.conf"
printf '[Peer]\nEndpoint     = vpn.example.org:443\n'   >"$TMP/cl/awg.conf"
conf_for() { [[ $1 == wg ]] && echo "$TMP/cl/wg.conf" || echo "$TMP/cl/awg.conf"; }
endpoint_port() { awk '/^\s*Endpoint/{split($3,a,":"); print a[2]; exit}' "$(conf_for "$1")"; }
eval "$(sed -n '/^ports_for()/,/^}/p' "$REPO/client/linux/yanvpn")"
eq "wg port derived from its config"  "$(WG_PORTS='' ports_for wg)"  "51820"
eq "awg port derived from its config" "$(AWG_PORTS='' ports_for awg)" "443"
eq "site-local override wins" "$(WG_PORTS='1 2 3' ports_for wg)" "1 2 3"

# ------------------------------------------------------- transport ordering
group "Transport ordering"
# A corrupted state file must never yield an empty or bogus order: cmd_up would
# then match no case branch and report "nothing got through" without trying.
# Both are read by transport_order, which is eval'd in below.
# shellcheck disable=SC2034
STATE=/nonexistent
# shellcheck disable=SC2034
load_state() { LAST=${FAKE_LAST:-}; }
eval "$(sed -n '/^transport_order()/,/^}/p' "$REPO/client/linux/yanvpn")"
eq "no state falls back to full order"   "$(FAKE_LAST=""        transport_order | tr '\n' ' ')" "wg awg reality "
eq "known transport leads"               "$(FAKE_LAST="awg"     transport_order | tr '\n' ' ')" "awg wg reality "
eq "reality leads when it worked last"   "$(FAKE_LAST="reality" transport_order | tr '\n' ' ')" "reality wg awg "
eq "garbage state falls back safely"     "$(FAKE_LAST="GARBAGE" transport_order | tr '\n' ' ')" "wg awg reality "
eq "multi-word garbage falls back too"   "$(FAKE_LAST="wg awg"  transport_order | tr '\n' ' ')" "wg awg reality "
eq "explicit transport wins"             "$(transport_order awg | tr '\n' ' ')" "awg "
unset -f load_state

# ------------------------------------------------------ endpoint re-resolution
group "Endpoint re-resolution"
# WireGuard resolves an endpoint hostname once. If the server's address rotates
# -- which this deployment saw happen within an hour -- a live tunnel keeps
# sending to the dead one, and it reads as the network blocking you.
eval "$(sed -n '/^needs_reresolve()/,/^}/p' "$REPO/client/linux/yanvpn")"
succeeds "re-points when the address moved"   needs_reresolve vpn.example.org 1.2.3.4 5.6.7.8
fails    "leaves an unchanged address alone"  needs_reresolve vpn.example.org 1.2.3.4 1.2.3.4
fails    "skips a literal IPv4 endpoint"      needs_reresolve 203.0.113.9 203.0.113.9 203.0.113.9
# Acting on a failed lookup would break a tunnel that is currently working.
fails    "does nothing when resolution fails" needs_reresolve vpn.example.org 1.2.3.4 ""
fails    "does nothing with no current peer"  needs_reresolve vpn.example.org "" 5.6.7.8
fails    "skips a literal IP even if it moved" needs_reresolve 203.0.113.9 203.0.113.9 198.51.100.4

# ------------------------------------------------------------- tunnel watchdog
group "Tunnel watchdog"
eval "$(sed -n '/^handshake_is_stale()/,/^}/p;/^should_reconnect()/,/^}/p' "$REPO/client/linux/yanvpn")"
# Read by handshake_is_stale, which is eval'd in above.
# shellcheck disable=SC2034
HANDSHAKE_DEAD_AFTER=300
NOW=1000000
# PersistentKeepalive refreshes a working handshake every couple of minutes,
# so anything older than five is dead rather than merely quiet.
fails    "a fresh handshake is not stale"     handshake_is_stale $((NOW - 30))  "$NOW"
fails    "two minutes old is still fine"      handshake_is_stale $((NOW - 120)) "$NOW"
succeeds "ten minutes old is stale"           handshake_is_stale $((NOW - 600)) "$NOW"
succeeds "never handshook counts as stale"    handshake_is_stale 0 "$NOW"
succeeds "empty handshake counts as stale"    handshake_is_stale "" "$NOW"
# Reconnecting on a single stale reading would tear down tunnels that are
# simply waking up from suspend.
fails    "one strike does not reconnect"      should_reconnect 1
succeeds "two strikes reconnects"             should_reconnect 2
succeeds "more strikes still reconnects"      should_reconnect 5

# Intent is what stops a watchdog resurrecting a tunnel you took down.
group "Connection intent"
ST="$TMP/state"
save_state() { printf 'LAST=%s\nLAST_PORT=%s\nWANTED=%s\n' "$1" "${2:-}" "${3:-yes}" >"$ST"; }
# LAST/LAST_PORT mirror the real load_state; only WANTED is asserted on here.
# shellcheck disable=SC2034,SC1090
load_state() { LAST=; LAST_PORT=; WANTED=; [[ -r $ST ]] && source "$ST"; : "${WANTED:=no}"; }
save_state awg 443
load_state; eq "connecting records intent"  "$WANTED" "yes"
save_state awg 443 no
load_state; eq "disconnecting clears it"    "$WANTED" "no"
rm -f "$ST"; load_state
eq "absent state means not wanted"          "$WANTED" "no"
unset -f save_state load_state

# --------------------------------------------------------------- health checks
group "Health check"
HT="$TMP/health"; mkdir -p "$HT/etc/yanvpn"
printf 'WG_IF="wg0"\nAWG_IF="awg0"\nWG_NET4="10.66.66"\nREALITY_PORT="443"\nENDPOINT=""\n' \
  >"$HT/etc/yanvpn/config"
sed "s#^CONF=/etc/yanvpn/config#CONF=$HT/etc/yanvpn/config#; \
     s#/etc/amnezia/amneziawg/#$HT/none/#; s#/etc/sing-box/config.json#$HT/none.json#; \
     s#/etc/yanvpn/duckdns.env#$HT/none.env#" "$REPO/server/health.sh" >"$HT/h.sh"
HOUT=$(bash "$HT/h.sh" -v -n 2>&1); HRC=$?
eq       "reports unhealthy when nothing is up" "$HRC" "1"
contains "names the missing interface" "$HOUT" "wg0 interface missing"
absent   "dry-run changes nothing"     "$HOUT" "repairing "
contains "dry-run says what it would do" "$HOUT" "would repair"

# ---------------------------------------------------------------------- report
printf '\n%s%d passed, %d failed, %d skipped%s\n' \
  "$BOLD" "$PASS" "$FAIL" "$SKIP" "$RST"
[[ $FAIL -eq 0 ]] || exit 1
