# yanvpn

A personal VPN: one always-on server in your house, an iOS phone and a Linux
laptop as clients. Built for a network that filters DNS, firewalls outbound
traffic, **and blocks WireGuard**.

## Why WireGuard alone isn't enough

WireGuard is trivial to fingerprint. Every handshake initiation begins with the
byte `0x01` followed by three zero bytes, and the packet is always exactly 148
bytes long. One DPI rule catches that on any port, which is why moving
WireGuard to 443 doesn't help — the giveaway is the *content*, not the port.

So yanvpn installs three transports and falls back between them:

| Transport | Wire | How it hides | Cost |
| --- | --- | --- | --- |
| **WireGuard** | UDP 51820 | Nothing. Fastest. | Blocked wherever DPI looks; LAN-only unless you forward its port. |
| **AmneziaWG** | UDP 443 | WireGuard fork: the four fixed header bytes become random per-deployment values, and junk packets pad the handshake so the size signature dies too. Same crypto, same speed. | Still UDP. Dies if all UDP is dropped. |
| **VLESS + REALITY** | TCP 443 | Proxies the real TLS handshake to a genuine public site, so a middlebox sees that site's **real certificate** with a valid chain. Active probes get handed the real site. | TCP: lower throughput, head-of-line blocking on lossy links. |

`yanvpn up` tries them fastest-first and remembers what worked.
`yanvpn doctor` probes all of them and tells you what the network actually blocks.

**DNS filtering** is solved separately and by construction: clients resolve via
an address that exists only inside the tunnel, answered by `dnsmasq` at your
house. The local resolver never sees a query.

## Setup

### 1. Check you're reachable — on the server

Copy this repo to the server machine, then **on the server**:

```bash
cd ~/yanvpn && ./server/preflight.sh
```

Run it on the server itself, not the laptop — the LAN address it reports is the
one your router needs to forward to, and it differs per machine.

If you already ran it from another machine in the same house, the CGNAT verdict
carries over — that's a property of the house, not the machine — but you still
need this machine's LAN address, which is what the router forwards to.

### 2. Forward ports on your router

To the **server's** LAN address from step 1, and give that machine a **static
DHCP lease** so it never moves:

| Protocol | Port | For |
| --- | --- | --- |
| **TCP/UDP** | **443** | REALITY (TCP) and AmneziaWG (UDP) |

One rule, one port, two protocols — that is the whole external footprint. If
your router's form separates TCP and UDP, make it two rules; both are needed.

You can also forward UDP 51820 (plain WireGuard) and UDP 53 (a fallback for
captive portals), but neither is required, and an open port 53 attracts
DNS-amplification scanners permanently. Start with 443 only and add the others
only if `yanvpn doctor` shows you need them.

### 3. Install, on the server

If the server is a laptop, prepare it first — closing the lid otherwise
suspends the machine and takes every tunnel with it:

```bash
sudo ./server/macbook-prep.sh
```

Then:

```bash
sudo ./server/install.sh
sudo ./server/install-amnezia.sh
sudo ./server/install-reality.sh
```

Order matters — the first writes the config and registry the other two extend.

`install-amnezia.sh` mints a random obfuscation profile (header magic values,
junk packet counts) unique to your install, so no two yanvpn deployments look
alike to a classifier. It also hands UDP 443/53 over from WireGuard to
AmneziaWG, since on any network where those ports mattered, the obfuscated
transport is the one with a chance.

`install-reality.sh` picks a mask site by testing candidates for TLS 1.3 + HTTP/2
support, then generates keys and pins the client to the same sing-box build so
both ends agree on the config schema.

### 4. Create clients

```bash
sudo vpnctl add phone
sudo vpnctl add laptop
```

One command produces configs for **every** installed transport and prints a QR
code for each. iOS needs a different app per transport — see
[ios/README.md](ios/README.md).

For the laptop, copy the whole directory:

```bash
scp -r root@your-server:/etc/yanvpn/clients/laptop .
sudo ./client/linux/install.sh laptop/
```

### 5. Pin down a stable address

```bash
sudo ./server/install-ddns.sh
```

Your home IP will change eventually, and when it does the failure looks
identical to a firewall block. Don't skip this.

## Daily use

```bash
sudo yanvpn up        # WireGuard -> AmneziaWG -> REALITY, fastest that works
sudo yanvpn status
sudo yanvpn down
sudo yanvpn doctor    # run this on the network giving you trouble
```

`doctor` is the useful one. It probes each transport on each port and then
interprets the result: whether they're fingerprinting WireGuard specifically,
dropping all UDP, or the server is simply unreachable.

## Managing clients

```bash
sudo vpnctl list                 # who exists, last handshake per transport
sudo vpnctl add tablet
sudo vpnctl remove tablet        # revokes on all three at once
sudo vpnctl qr phone awg         # reprint one transport's QR
sudo vpnctl show laptop reality  # print the vless:// link
sudo vpnctl status               # which transports are up
sudo vpnctl regen                # rebuild every config from the registry
sudo vpnctl backup               # save keys + registry before you need them
sudo vpnctl restore <file>       # rebuild a dead server from that backup
```

## Updating a running server

Pull, then apply — in that order, and always with git:

```bash
ssh you@server 'cd ~/yanvpn && git pull'
ssh you@server -t 'cd ~/yanvpn && sudo ./server/update.sh -n'   # what would change
ssh you@server -t 'cd ~/yanvpn && sudo ./server/update.sh'      # do it
```

Do **not** rsync a working tree over the server's checkout. Git will keep
reporting the old commit while the files are something else, so `update.sh`
can only tell you which commit it *thinks* it is installing. It warns when it
detects this, but the fix is to not create the situation.

Installs the management tooling and rebuilds every generated config from the
client registry. Deliberately narrow: it does not install packages, mint keys,
or re-run the installers — that is one-time setup, and quietly re-running it is
how a working deployment gets surprised. Clients are unaffected, because their
keys live in `/etc/yanvpn` and all protocol configs are regenerated from them.

## Keeping it healthy

```bash
sudo ./server/install-health.sh
```

Installs a check that runs every 5 minutes and repairs what it finds. It exists
because systemd's "active" does not mean "working" here: `wg-quick` and
`awg-quick` are oneshots with `RemainAfterExit`, so a dead userspace
`amneziawg-go` leaves the unit reporting active while the tunnel is gone. It
verifies the interfaces really exist, that sing-box is really listening, that
tunnel DNS answers a real query, and that the DDNS record still matches your
public IP — re-pushing it if it has drifted.

```bash
sudo yanvpn-health -v      # run by hand
sudo yanvpn-health -n      # check only, change nothing
journalctl -t yanvpn-health --since today
```

## Back up before you need to

```bash
sudo vpnctl backup /root/yanvpn-backup.tar.gz
```

`/etc/yanvpn` holds the only irreplaceable state: server keys, the obfuscation
profile, and every client's keys. Everything else is regenerated. Copy that file
somewhere off the server — a backup that dies with the disk is not a backup.
Restoring keeps existing clients working, so nobody re-scans a QR code.

`/etc/yanvpn/clients/<name>/meta` is the single source of truth. Every protocol
config is *regenerated* from it rather than edited in place, so adding a
transport later needs only `vpnctl regen` — no re-issuing clients.

## When it won't connect

Run `sudo yanvpn doctor` **on the failing network**, then read its verdict.

Before blaming the firewall, prove the server works: connect from your phone's
cellular hotspot. If that fails too, the problem is at home.

**Testing from inside your own house usually fails, and that's normal.** Dialing
your public IP from the same LAN the server is on requires the router to support
hairpin NAT, and many don't — including, commonly, for UDP only. A router that
hairpins TCP but not UDP will let REALITY through while every UDP transport
fails, which looks exactly like a broken port forward.

Distinguish the two with a control: send a probe to the server's **LAN** address
and the same probe to your **public** address, and capture on the server.

```bash
sudo tcpdump -ni <wan-if> -l udp > /tmp/c.txt 2>&1 &
echo -n test > /dev/udp/<server-lan-ip>/443     # control
echo -n test > /dev/udp/<public-ip>/443         # through the forward
```

If the control arrives and the public one doesn't, it's hairpin, not your rules.
UDP forwards then can only be confirmed from a phone on cellular.

To test at home, dial the server directly instead:

```bash
sudo yanvpn pin <server-LAN-ip>
```

Then `sudo yanvpn pin <your-public-ip-or-ddns-name>` to switch back before you
leave. The real test is always from cellular.

Common causes, in the order they actually occur:

1. **Public IP changed** — step 5.
2. **Port forward missing.** TCP 443 for REALITY is its own rule.
3. **Endpoint hostname filtered** — `sudo yanvpn pin <your.home.ip>` skips DNS.
4. **Large transfers stall, pings fine** — MTU. Drop `MTU` in the client conf
   from 1380 to 1280.
5. **REALITY fails, others work** — check the server clock. REALITY does a real
   TLS 1.3 handshake and clock skew breaks it in a way that looks like censorship.

### If even REALITY is blocked

You're on a network that permits only authenticated HTTP through a corporate
proxy. Nothing here will help; that needs a proxy-aware transport, and at that
point you should be asking whether you're meant to be bypassing it at all.

### Behind CGNAT

If `preflight.sh` on the server reports CGNAT, your ISP shares one public IP
across customers and nothing can be forwarded to you. Ask your ISP for a public
IPv4 address (often free), use IPv6 if they provide it, or relay through a cheap
VPS.

## Tests

```bash
./test/run-tests.sh
```

Unprivileged and offline. It builds a throwaway `/etc` tree and exercises every
path that generates configuration, because every bug that actually cost time on
this project was in generation and invisible to `bash -n`: a multi-word value
written unquoted, a `read` returning 1 at EOF under `set -e`, peers built from
the wrong transport's keys, and a sing-box config that passed `check` but would
not start. The suite is mutation-tested — reintroducing each of those bugs makes
it fail.

## Layout

```
common/
  amneziawg-setup.sh  acquires AmneziaWG (PPA or source build), used by both ends
server/
  lib.sh              shared state + config generation for all transports
  preflight.sh        reachability + CGNAT detection
  macbook-prep.sh     lid/sleep/Wi-Fi-powersave fixes for a laptop server
  health.sh           what runs every 5 minutes; verifies and self-heals
  install-health.sh   installs health.sh plus its timer
  update.sh           apply this checkout to an already-running server
  install.sh          base: WireGuard, NAT, tunnel DNS
  install-amnezia.sh  AmneziaWG obfuscation
  install-reality.sh  VLESS + REALITY via sing-box
  install-ddns.sh     DuckDNS on a systemd timer
  vpnctl              client management across all transports
client/linux/
  install.sh          installs whichever transports the server offered
  yanvpn              connect / doctor / fallback
ios/README.md         which app per transport
```

### A note on AmneziaWG packaging

The Amnezia PPA lags new Ubuntu releases — on 26.04 "resolute" it publishes
nothing. `common/amneziawg-setup.sh` checks whether the PPA actually has your
codename and builds `amneziawg-tools` + `amneziawg-go` from source when it
doesn't. A source build has no kernel module, so it also installs a userspace
shim and a systemd unit that the packages would otherwise have provided.

## Notes

- Each client gets a separate keypair **and** preshared key per WireGuard-family
  transport, plus its own UUID for REALITY. Nothing is shared between clients.
- Private keys live on the server under `/etc/yanvpn/clients/` (0600) so configs
  can be reissued. Delete a client directory's key files once installed if you'd
  rather not keep them; `vpnctl regen` will then no longer rebuild that client.
- `vpnctl remove` revokes across all three transports and applies immediately.
- The tunnel is IPv4-only, but client configs route `::/0` into it anyway, to
  blackhole IPv6 so a dual-stack network can't leak around the VPN.
- Traffic exits from your home IP and is visible to your home ISP. This is a
  bypass and a private exit, not anonymity.
- Obfuscation hides *what protocol* you're speaking, not *that you're sending
  traffic*. A network operator can still see a steady encrypted flow to one
  address. Check the acceptable-use policy of whatever network you're on.
