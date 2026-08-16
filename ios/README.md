# iOS client

Nothing to install from this repo — iOS uses off-the-shelf apps. But each
transport needs a *different* app, because the official WireGuard app speaks
only plain WireGuard.

| Transport | App | Cost | Use it when |
| --- | --- | --- | --- |
| WireGuard | **WireGuard** | free | Home, cellular, any permissive network. Fastest. |
| AmneziaWG | **AmneziaVPN** | free | The network blocks WireGuard but allows UDP. |
| VLESS + REALITY | **sing-box**, **Streisand**, or **V2Box** | free | Everything else fails, or all UDP is blocked. |

Install at least AmneziaVPN and one REALITY app before you go anywhere you
expect trouble — you can't download them from behind the block.

## Setup

On the server, `sudo vpnctl add phone` prints a labelled QR code per transport.
Scan each into its matching app:

- **WireGuard** — tap **+** → *Create from QR code*
- **AmneziaVPN** — tap **+** → *Scan QR code* (it reads the same config format
  plus the obfuscation parameters)
- **sing-box / Streisand / V2Box** — import from QR, or paste the `vless://`
  link from `sudo vpnctl show phone reality`

To reprint one later: `sudo vpnctl qr phone awg`.

Verify each works by visiting a "what's my IP" site — it should show your home IP.

## Turn on On-Demand (WireGuard and AmneziaVPN)

Without it you'll forget to connect on exactly the networks where you need it.

Tap the tunnel → **Edit** → **On-Demand**:

- **Wi-Fi** — on
- **Cellular** — off (your carrier isn't filtering you, and it saves battery)
- **Excluded SSIDs** — your home network, and anywhere else you trust

The phone then connects itself on any untrusted Wi-Fi and stays off at home.

## If it won't connect

Each app shows a **last handshake** time. No handshake means packets aren't
reaching your server. Work down the ladder:

1. **WireGuard fails, AmneziaVPN works** → expected. That network fingerprints
   WireGuard. Use AmneziaVPN there and enable On-Demand for it.

   Note that plain WireGuard also fails everywhere if your router only forwards
   443, which is the recommended minimal setup. In that case its profile works
   at home and nowhere else, by design — consider deleting it from the phone so
   you don't reach for it and assume something is broken.
2. **AmneziaVPN also fails** → it can only use a port your router actually
   forwards. With the recommended single TCP/UDP 443 rule there is nothing else
   to try, so this means the network is dropping UDP. If you forwarded extra
   ports, change the `Endpoint` port to one of them.
3. **All UDP dead** → use the REALITY app. It's TCP/443 and looks like an
   ordinary HTTPS connection.
4. **REALITY fails too** → check three things, in order:
   - **The server clock.** `timedatectl` on the server. REALITY does a real
     TLS 1.3 handshake and embeds a timestamp; skew breaks authentication in a
     way indistinguishable from censorship.
   - **TLS interception.** If every site on that network shows an unfamiliar
     certificate authority, the network is MITMing all HTTPS and REALITY cannot
     work there — it expects the mask site's genuine certificate.
   - **DNS.** `dig +short @1.1.1.1 <your-ddns-name>` should match your home IP.

If nothing works anywhere, test from cellular first. A failure there means the
problem is at home — port forwards or a changed IP — not the network you're on.

## Notes

- QR codes and `vless://` links contain your private key or UUID. Don't
  photograph them, don't paste them into chat, and clear your terminal
  scrollback afterward.
- `sudo vpnctl remove phone` revokes the device across all three transports
  immediately — do this if you lose it.
- Running AmneziaVPN or a REALITY client costs a little more battery than plain
  WireGuard. Keep plain WireGuard as your home/cellular profile.
