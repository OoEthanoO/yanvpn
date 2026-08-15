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
2. **AmneziaVPN also fails** → try changing its `Endpoint` port between `443`,
   `53`, and `51821`. If none work, the network is dropping all UDP.
3. **All UDP dead** → use the REALITY app. It's TCP/443 and looks like an
   ordinary HTTPS connection.
4. **REALITY fails too** → check the server clock (`timedatectl` on the server).
   REALITY performs a real TLS 1.3 handshake, and clock skew breaks it in a way
   that looks exactly like censorship.

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
