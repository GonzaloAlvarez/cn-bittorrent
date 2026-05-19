# cn-bittorrent

Torrent core (qbittorrent + prowlarr + sonarr + radarr + lidarr + readarr)
running on **kaiser.lan**, with **all public-internet egress forced
through `infra.lan`'s Mullvad WireGuard tunnel** via a Tailscale
exit-node sidecar — kill-switch by construction.

| Layer | URL |
|---|---|
| LAN (cn-home Traefik) | `https://torrent.kaiser.lan`, `https://sonarr.kaiser.lan`, `radarr.…`, `prowlarr.…`, `lidarr.…`, `readarr.…` |
| Tailnet (VPS traefik-lab via Consul catalog) | `https://torrent.lab.gn.al`, `https://sonarr.lab.gn.al`, `radarr.…`, `prowlarr.…`, `lidarr.…`, `readarr.…` |

## Architecture

```
ts-torrent (tag:vpn-client, --exit-node=infra-mullvad)
└── iptables OUTPUT DROP except tailscale0 + mark 0x80000/0xff0000 + lo + ESTABLISHED
    network_mode: service:ts-torrent
    ├── qbittorrent       (UI :8080)
    ├── sonarr            (UI :8989)
    ├── radarr            (UI :7878)
    ├── prowlarr          (UI :9696)
    ├── lidarr            (UI :8686)
    ├── readarr           (UI :8787)
    ├── consul-register   (6 entries → VPS Consul → traefik-lab routes by Host)
    ├── promtail          (log push → VPS Loki)
    └── node-exporter

mount-precheck         (verifies /home/gonzalo/docker/data/nfs/torrent exists before anything starts)
ts-torrent-watchdog    (recreates dependents on ts-torrent restart — netns drift fix)
watchtower             (nightly --cleanup + SMTP notify)
```

## Egress path

```
qbittorrent (and the *arr suite) → tailscale0 → infra-mullvad (100.64.0.17)
  → wg0 → Mullvad WireGuard endpoint → public internet
```

If `infra-mullvad` (or `wg-mullvad` inside cn-infra) is down: packets
are dropped (fail-closed) at the route layer; the iptables policy
seals the startup window before tailscaled applies `--exit-node`.

## Operation

After day-one, **always go through systemd**, not `docker compose`
directly:

```sh
sudo systemctl status   docker-compose@cn-bittorrent
sudo systemctl restart  docker-compose@cn-bittorrent
sudo systemctl stop     docker-compose@cn-bittorrent
```

For per-service tweaks during dev (won't survive next systemctl restart):

```sh
docker compose -p cn-bittorrent up -d --force-recreate <service>
docker compose -p cn-bittorrent logs <service> --tail 100
```

## First-time setup

```sh
ssh kaiser.lan
cd ~ && git clone git@github.com:GonzaloAlvarez/cn-bittorrent.git
cd ~/cn-bittorrent
cp .env.example .env
$EDITOR .env              # fill TORRENT_AUTHKEY + SMTP_*
./setup.sh                # see script header for what it does
```

`setup.sh` is idempotent — re-run after editing `.env` or after first
boot generated `qBittorrent.conf` (it pins host-header validation on
re-run).

## Verification — the egress-leak drill

Below is the **load-bearing** test that proves the kill-switch holds.
Full drill (5 layers) lives in the planning doc; this README pins the
single most important one — the fail-closed proof.

```sh
# Public IP from inside qbittorrent must be Mullvad, not your ISP
docker compose -p cn-bittorrent exec qbittorrent curl -sf https://am.i.mullvad.net/json | jq .
# Expect: "mullvad_exit_ip": true

# Same drill for each *arr (they share the netns)
for svc in sonarr radarr prowlarr lidarr readarr; do
  docker compose -p cn-bittorrent exec $svc curl -sf https://am.i.mullvad.net/json | jq -r '.ip + " mullvad=" + (.mullvad_exit_ip|tostring)'
done
# Expect: same Mullvad IP for all six, mullvad=true for all six

# Fail-closed: stop wg-mullvad on infra.lan, public egress MUST fail
ssh infra.lan 'docker stop cn-infra-wg-mullvad' && sleep 8
docker compose -p cn-bittorrent exec qbittorrent curl --max-time 8 -sf https://ifconfig.me; echo "exit=$?"
# Expect: empty output, non-zero exit. NEVER your home IP.
ssh infra.lan 'docker start cn-infra-wg-mullvad'
```

If qb returns your home IP at any point: STOP. Diagnose
`iptables -L OUTPUT -nv` inside `ts-torrent` and `tailscale status` —
the kill-switch is broken.

## Maintenance notes

- **Mullvad does NOT forward inbound ports** (discontinued 2023-07).
  Bittorrent runs leech-only — no incoming peer connections. Trackers
  see the Mullvad IP as your endpoint; the listen port is unreachable.
- **`infra-mullvad` is a SPOF for the stack.** If cn-infra goes down
  for maintenance, stop cn-bittorrent first: `sudo systemctl stop
  docker-compose@cn-bittorrent`.
- **Restart order on reboot is enforced by systemd**: the unit
  `Requires=` + `RequiresMountsFor=` block startup until the
  `home-gonzalo-docker-data-nfs.mount` is active. If raidnas is offline
  at boot, the stack waits.
- **Adding a new path mapping?** Both `qbittorrent` (mounted at
  `/data/torrents`) and the *arr suite (mounted at `/data/torrent`)
  see the same NFS subtree — preserved from the legacy paths so
  migrated config databases keep working. If you add a new media root
  on NFS, expose it under either mount and update both *arr and qb.
