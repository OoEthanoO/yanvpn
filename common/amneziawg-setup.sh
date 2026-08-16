#!/usr/bin/env bash
# Acquire AmneziaWG on Debian/Ubuntu, however that has to happen.
#
# Sourced by both server/install-amnezia.sh and client/linux/install.sh. Both
# provide say/ok/warn/info/die before sourcing this.
#
# The Amnezia PPA lags new Ubuntu releases by months — on 26.04 "resolute" it
# publishes nothing at all — and the DKMS kernel module frequently fails to
# build against recent kernels. So this tries, in order:
#
#   1. packages already installed
#   2. the PPA, but only if it actually publishes for this codename
#   3. building amneziawg-tools + amneziawg-go from source
#
# and then falls back from the kernel module to the userspace daemon if needed.
#
# Sets AWG_USERSPACE=yes|no.

ppa_publishes_for() {
  curl -fsS --max-time 10 -o /dev/null \
    "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/$1/Release" 2>/dev/null
}

awg_build_from_source() {
  say "Building amneziawg from source"
  apt-get install -y -qq build-essential git golang-go libmnl-dev pkg-config >/dev/null

  local tmp; tmp=$(mktemp -d)

  git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools "$tmp/tools" \
    || { rm -rf "$tmp"; die "Could not clone amneziawg-tools."; }
  if ! make -C "$tmp/tools/src" -j"$(nproc)" >/dev/null 2>&1; then
    make -C "$tmp/tools/src" || true      # re-run noisily so the error is visible
    rm -rf "$tmp"; die "amneziawg-tools failed to build."
  fi
  make -C "$tmp/tools/src" install >/dev/null || { rm -rf "$tmp"; die "amneziawg-tools install failed."; }
  ok "amneziawg-tools built (awg, awg-quick)"

  # A source build gives no kernel module, so the userspace daemon is mandatory.
  git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go "$tmp/go" \
    || { rm -rf "$tmp"; die "Could not clone amneziawg-go."; }
  if ! ( cd "$tmp/go" && make >/dev/null 2>&1 ); then
    ( cd "$tmp/go" && make ) || true
    rm -rf "$tmp"; die "amneziawg-go failed to build."
  fi
  install -m 755 "$tmp/go/amneziawg-go" /usr/local/bin/amneziawg-go
  ok "amneziawg-go built (userspace implementation)"
  rm -rf "$tmp"
}

ensure_amneziawg() {
  export DEBIAN_FRONTEND=noninteractive
  local codename; codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")

  if command -v awg >/dev/null && command -v awg-quick >/dev/null; then
    ok "amneziawg already installed"
  elif [[ -n $codename ]] && ppa_publishes_for "$codename"; then
    ok "PPA publishes for ${codename} — installing packages"
    apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || true
    apt-get update -qq
    apt-get install -y -qq amneziawg amneziawg-tools >/dev/null 2>&1 || true
    command -v awg >/dev/null || awg_build_from_source
  else
    info "PPA has no packages for '${codename:-unknown}' — building from source"
    awg_build_from_source
  fi
  command -v awg >/dev/null || die "amneziawg tools are still missing."

  # ---------------------------------------------------- kernel or userspace
  # AWG_USERSPACE is this function's return channel: install-amnezia.sh reads it
  # to report which implementation is in use. shellcheck cannot see across that.
  # shellcheck disable=SC2034
  AWG_USERSPACE=no
  if modprobe amneziawg 2>/dev/null && lsmod | grep -q '^amneziawg'; then
    ok "kernel module loaded (fast path)"
  else
    command -v amneziawg-go >/dev/null || awg_build_from_source
    command -v amneziawg-go >/dev/null || die "No kernel module and no amneziawg-go."
    # shellcheck disable=SC2034
    AWG_USERSPACE=yes
    warn "No kernel module for $(uname -r) — using userspace amneziawg-go"
    info "Costs throughput; obfuscation and correctness are unaffected."

    # awg-quick reads WG_QUICK_USERSPACE_IMPLEMENTATION from its own environment,
    # and sudo scrubs the environment. A shim earlier on PATH makes an
    # interactive 'sudo awg-quick up' behave like the systemd service.
    local real; real=$(command -v awg-quick)
    if [[ $real != /usr/local/bin/awg-quick ]]; then
      cat >/usr/local/bin/awg-quick <<EOF
#!/bin/sh
# yanvpn shim: no amneziawg kernel module here, so force the userspace daemon.
export WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
export WG_SUDO=1
exec ${real} "\$@"
EOF
      chmod 755 /usr/local/bin/awg-quick
      ok "shim: /usr/local/bin/awg-quick -> ${real}"
    fi
  fi

  # ------------------------------------------------------------ systemd unit
  # A source build installs no unit file, so 'systemctl enable awg-quick@awg0'
  # would fail. Provide one if it's missing.
  if ! systemctl cat 'awg-quick@.service' >/dev/null 2>&1; then
    local q=/usr/local/bin/awg-quick
    [[ -x $q ]] || q=$(command -v awg-quick)
    cat >/etc/systemd/system/awg-quick@.service <<EOF
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${q} up %i
ExecStop=${q} down %i
ExecReload=/bin/bash -c 'exec $(command -v awg) syncconf %i <(exec ${q} strip %i)'
Environment=WG_ENDPOINT_RESOLUTION_RETRIES=infinity
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
Environment=WG_SUDO=1

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "installed awg-quick@.service"
  fi

  # awg-quick's config search path differs between builds; make sure the one we
  # write to is the one it reads.
  install -d -m 700 /etc/amnezia/amneziawg
}
