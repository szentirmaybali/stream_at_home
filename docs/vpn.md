# Optional: routing torrents through a VPN

qBittorrent can be moved behind a WireGuard tunnel with [gluetun](https://github.com/qdm12/gluetun). It is **optional and off by default**, so the stack still comes up with a plain `./install.sh` and no subscription.

Only qBittorrent is tunnelled. Jellyfin, Immich, Sonarr, Radarr and Prowlarr stay on the normal network — they do not need a VPN, and you want them reachable on the LAN.

```text
        LAN                          VPN tunnel
         │                              ▲
   ┌─────▼──────┐                       │
   │  gluetun   │  wg0 ─────────────────┘
   │  (netns)   │  iptables: only wg0 leaves
   └─────┬──────┘
         │ shared network namespace
   ┌─────▼──────┐
   │qBittorrent │  8080 published on gluetun
   └────────────┘
```

## How it works

- `gluetun` holds the tunnel, the WireGuard interface and the firewall. If the tunnel drops, its iptables rules drop the traffic — torrent traffic never falls back to your home IP. This is the actual kill switch; a SOCKS5 proxy in qBittorrent does not have one.
- `qbittorrent` runs with `network_mode: "service:gluetun"`, so it shares that network namespace and cannot bypass the tunnel.
- The WebUI port is published on `gluetun` instead of qBittorrent.
- gluetun carries a network alias `qbittorrent`, so `http://qbittorrent:8080` inside the stack still works and the Sonarr/Radarr download client settings do not change.

## Requirements

| | |
|---|---|
| Docker Compose | **2.24 or newer** — the overlay uses `!reset` |
| Kernel | `/dev/net/tun` (`sudo modprobe tun` if missing) |
| Provider | one that allows **P2P** and gives you a WireGuard config file |

### Free tiers do not work

This is the honest part: free plans exclude exactly the feature you need.

- **ProtonVPN Free** — no P2P at all; torrent traffic is blocked or throttled on free servers.
- **Windscribe Free** — P2P moved to paid plans.
- No reputable provider offers free P2P with a WireGuard config, and free VPNs are a bad place to send your traffic anyway. A cheap paid plan is the realistic option.

If you only want to **test the plumbing**, any WireGuard endpoint works — including a WireGuard server on your own VPS, configured with `VPN_SERVICE_PROVIDER=custom`. That proves the kill switch and the routing, but it only hides traffic from your ISP: the VPS IP still leads back to you.

## Providers

| Provider | WireGuard | P2P on the plan | Port forwarding in gluetun |
|---|---|---|---|
| ProtonVPN | yes | paid plans only | yes (native) |
| PIA | yes | yes | yes (native) |
| PrivateVPN | yes | yes | yes (native) |
| AirVPN | yes | yes | manual, on the provider side |
| Mullvad | yes | yes | no (removed in 2023) |
| Windscribe | yes | paid plans only | no |
| NordVPN | yes | yes | no |

Port forwarding matters for **seeding**: without it, peers cannot connect to you, so upload is slow and private-tracker ratios suffer. Downloads work either way.

## Setup

### 1. Get a WireGuard config

In your provider's account page, generate a WireGuard configuration. You get a file like this:

```ini
[Interface]
PrivateKey = <your private key>
Address    = 10.2.0.2/32
DNS        = 10.2.0.1

[Peer]
PublicKey  = <server public key>
Endpoint   = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
```

Map it to `.env`:

| WireGuard config | `.env` |
|---|---|
| `PrivateKey` (Interface) | `WIREGUARD_PRIVATE_KEY` |
| `Address` (Interface) | `WIREGUARD_ADDRESSES` |
| `PublicKey` (Peer) | `WIREGUARD_PUBLIC_KEY` — only for `custom` |
| `Endpoint` IP | `VPN_ENDPOINT_IP` — only for `custom` |
| `Endpoint` port | `VPN_ENDPOINT_PORT` — only for `custom` |

Known providers (ProtonVPN, PIA, …) already ship the server list and the public keys, so there you only need `VPN_SERVICE_PROVIDER`, `WIREGUARD_PRIVATE_KEY` and optionally `VPN_SERVER_COUNTRIES`.

### 2. Fill in `.env`

```bash
VPN_ENABLED=true
VPN_SERVICE_PROVIDER=custom        # or protonvpn, private internet access, ...
WIREGUARD_PRIVATE_KEY=...
WIREGUARD_ADDRESSES=10.2.0.2/32
WIREGUARD_PUBLIC_KEY=...
VPN_ENDPOINT_IP=203.0.113.10
VPN_ENDPOINT_PORT=51820
```

The file is already `chmod 600` and gitignored, so the key stays local.

### 3. Start it

```bash
./install.sh
```

The installer detects `VPN_ENABLED=true`, validates the values, checks `/dev/net/tun` and the Compose version, and adds the overlay automatically. Without the installer:

```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
```

`VPN_ENABLED` is only read by `install.sh`; the overlay file is what actually does the work, so the two commands above are equivalent.

## Verify

```bash
# 1. The tunnel is up and has an IP
docker exec gluetun wget -qO- https://ipinfo.io/ip

# 2. qBittorrent sees the same IP (proves the traffic is tunnelled)
docker exec qbittorrent wget -qO- https://ipinfo.io/ip

# 3. The kill switch: while gluetun is unhealthy, qBittorrent has no
#    working route at all — it must never answer with your ISP IP
docker stop gluetun
docker exec qbittorrent wget -qO- --timeout=5 https://ipinfo.io/ip   # fails, expected
docker start gluetun

# 4. Sonarr can still reach the WebUI by name
docker exec sonarr wget -qO- --spider http://qbittorrent:8080
```

Step 3 is the important one: a failure there is the correct result. If it prints your real IP, stop the stack and fix the firewall before downloading anything.

## Port forwarding (seeding)

With ProtonVPN, PIA or PrivateVPN, gluetun asks the provider for a port and logs it:

```bash
# .env
VPN_PORT_FORWARDING=on
```

```bash
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
docker logs gluetun 2>&1 | grep -i "port forwarded"
```

Then set that port in qBittorrent: **Options → Connection → Listening port**, and disable "Use UPnP / NAT-PMP port mapping from my router".

The provider can change the port at any time. gluetun exposes `VPN_PORT_FORWARDING_UP_COMMAND` for updating qBittorrent through its API when that happens — worth adding once the rest works.

Do **not** publish `6881` on the host any more: incoming peers arrive through the tunnel, and the host port would just be noise.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `service "qbittorrent" refers to undefined network` or a `!reset` parse error | Compose older than 2.24 | upgrade the Compose plugin |
| `conflicting options: port publishing and the container type network mode` | `ports:` was not reset | the overlay must keep `ports: !reset []` |
| WebUI unreachable from the LAN, but works via `docker exec` | gluetun firewall | keep `FIREWALL_INPUT_PORTS=8080` |
| Sonarr cannot reach `qbittorrent:8080` | alias missing after a manual `docker run` | recreate: `docker compose … up -d --force-recreate qbittorrent` |
| qBittorrent has no network at all | gluetun is unhealthy (bad key, blocked endpoint) | `docker logs gluetun`, then fix the WireGuard values |
| Handshake works, transfers stall | MTU | add `WIREGUARD_MTU=1420` (or `1280`) to the gluetun environment |
| qBittorrent loses connectivity after a gluetun restart | the shared namespace was recreated | the overlay sets `depends_on: restart: true`; keep it |

## Turning it off

```bash
# .env
VPN_ENABLED=false
```

```bash
docker compose -f docker-compose.yml up -d --remove-orphans
```

Without the overlay, qBittorrent returns to the bridge network and publishes `8080` and `6881` itself, exactly as before. The WebUI URL and the *arr settings stay valid in both modes.
