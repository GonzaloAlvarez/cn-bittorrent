#!/usr/bin/env bash
# cn-bittorrent — one-shot host setup on kaiser.lan.
#
# Idempotent: safe to re-run. Performs, in order:
#   1. fstab normalize: nfs4+vers=3 → nfs+nfsvers=3 (backup first)
#   2. remount the NFS share with the normalized options
#   3. copy step-ca root CA into ./certs/
#   4. rsync legacy *arr + qbittorrent config dirs from
#      ~/docker/docker-compose-nas/ (preserves API keys + indexer state)
#   5. clear <UrlBase> from each *arr config.xml (subdomain routing
#      means root-of-host, not path prefix)
#   6. pin qbittorrent WebUI host-header validation so torrent.kaiser.lan
#      and torrent.lab.gn.al are both accepted
#   7. install /etc/systemd/system/docker-compose@cn-bittorrent.service
#   8. systemctl enable --now docker-compose@cn-bittorrent.service
#   9. print status

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LEGACY_DIR="$HOME/docker/docker-compose-nas"
NFS_MOUNTPOINT="/home/gonzalo/docker/data/nfs"

# Sanity: we run on kaiser, with sudo.
if [ "$(hostname -s)" != "kaiser" ]; then
  echo "ERROR: this script must run on kaiser.lan (hostname is '$(hostname -s)')" >&2
  exit 1
fi
if ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo (fstab edit + systemd install). You may be prompted."
fi

# ─── 1. fstab normalization ──────────────────────────────────────────
TARGET_LINE="raidnas.lan:/volume1/data  $NFS_MOUNTPOINT  nfs  rw,nfsvers=3,relatime,hard,rsize=8192,wsize=8192,_netdev  0 0"
CURRENT_LINE=$(grep -E "^raidnas\.lan:/volume1/data" /etc/fstab || true)

if [ -z "$CURRENT_LINE" ]; then
  echo "ERROR: no raidnas line in /etc/fstab — refusing to add one automatically" >&2
  exit 1
fi
if [ "$CURRENT_LINE" = "$TARGET_LINE" ]; then
  echo "[1/9] fstab already normalized"
else
  ts=$(date +%s)
  echo "[1/9] backing up /etc/fstab → /etc/fstab.pre-cn-bittorrent.$ts"
  sudo cp /etc/fstab "/etc/fstab.pre-cn-bittorrent.$ts"
  # Use a delimiter pipes won't appear in (we use | by default but
  # the path has /; with the full target as a single-line literal,
  # sed handles it fine).
  sudo sed -i "s|^raidnas\.lan:/volume1/data.*\$|$TARGET_LINE|" /etc/fstab
  echo "[1/9] new fstab line:"
  grep raidnas /etc/fstab | sed 's/^/      /'
fi

# ─── 2. remount NFS so the new options take effect ────────────────────
echo "[2/9] reloading systemd + remounting NFS"
sudo systemctl daemon-reload
sudo systemctl restart home-gonzalo-docker-data-nfs.mount
sleep 1
ACTUAL_TYPE=$(stat -f -c '%T' "$NFS_MOUNTPOINT")
if [ "$ACTUAL_TYPE" != "nfs" ]; then
  echo "ERROR: $NFS_MOUNTPOINT type is '$ACTUAL_TYPE', expected 'nfs'" >&2
  exit 1
fi
echo "      mounted: $(mount | grep raidnas | head -1)"

# ─── 3. step-ca root CA ───────────────────────────────────────────────
if [ ! -f "$REPO_DIR/certs/root_ca.crt" ]; then
  echo "[3/9] fetching step-ca root CA"
  curl -sfo "$REPO_DIR/certs/root_ca.crt" http://pki.lan/cert/ca.crt
else
  echo "[3/9] step-ca root CA already in place"
fi

# ─── 4. rsync legacy config dirs ──────────────────────────────────────
if [ -d "$LEGACY_DIR" ]; then
  echo "[4/9] rsync'ing legacy config dirs from $LEGACY_DIR"
  for svc_pair in "sonarr:sonarr" "radarr:radarr" "prowlarr:prowlarr" "lidarr:lidarr" "readerr:readarr" "qbittorrent:qbittorrent"; do
    src="${svc_pair%%:*}"; dst="${svc_pair##*:}"
    if [ -d "$LEGACY_DIR/$src" ] && [ ! -d "$REPO_DIR/$dst" ]; then
      echo "      $src → $dst"
      rsync -a "$LEGACY_DIR/$src/" "$REPO_DIR/$dst/"
    elif [ -d "$REPO_DIR/$dst" ]; then
      echo "      $dst already present, skipping"
    fi
  done
else
  echo "[4/9] no legacy dir at $LEGACY_DIR — starting fresh (you'll re-create indexers manually)"
fi

# ─── 5. clear UrlBase in migrated *arr configs ───────────────────────
echo "[5/9] clearing UrlBase in *arr config.xml (subdomain routing)"
for svc in sonarr radarr prowlarr lidarr readarr; do
  f="$REPO_DIR/$svc/config.xml"
  if [ -f "$f" ]; then
    if grep -q '<UrlBase>[^<]\+</UrlBase>' "$f"; then
      sudo sed -i 's|<UrlBase>[^<]*</UrlBase>|<UrlBase></UrlBase>|' "$f"
      echo "      $svc: UrlBase cleared"
    else
      echo "      $svc: UrlBase already empty (or missing)"
    fi
  fi
done

# ─── 6. pin qbittorrent reverse-proxy + host-header config ───────────
echo "[6/9] pinning qbittorrent WebUI for Traefik (host validation + reverse proxy)"
QBCONF="$REPO_DIR/qbittorrent/qBittorrent/qBittorrent.conf"

# Helper: set "WebUI\Key=Value" in qBittorrent.conf, idempotent.
qb_set() {
  local key="$1" val="$2"
  if grep -q "^WebUI\\\\${key}=" "$QBCONF"; then
    sudo sed -i "s|^WebUI\\\\${key}=.*|WebUI\\\\${key}=${val}|" "$QBCONF"
  else
    echo "WebUI\\${key}=${val}" | sudo tee -a "$QBCONF" >/dev/null
  fi
}

if [ -f "$QBCONF" ]; then
  # qb v5 only stores ONE hostname in ServerDomains — even though its
  # parser splits on ';', qb rewrites the config on startup keeping
  # only the first entry. Since we need to serve TWO hostnames
  # (torrent.kaiser.lan + torrent.lab.gn.al) and Traefik upstream
  # already validates Host (cn-home for LAN, traefik-lab for tailnet),
  # the cleanest fix is to disable qb's own host-header check.
  # qb still gets the Host header for cookies/redirects via the
  # reverse-proxy support below.
  qb_set HostHeaderValidation       false
  # Traefik is the only thing fronting qb; trust the docker-bridge
  # subnets so X-Forwarded-For / X-Forwarded-Host are honored.
  qb_set ReverseProxySupportEnabled true
  qb_set TrustedReverseProxiesList  '172.16.0.0/12'
  # Whitelist just the VPS tailnet IP for unauth access so Glance's
  # monitor probe from home.lab.gn.al gets 200 instead of 401. qb has
  # no unauth health endpoint and the tailnet ACL already gates
  # tag:infra exclusively to the qb UI port, so this doesn't broaden
  # the attack surface — only the VPS sees an unauth qb.
  qb_set AuthSubnetWhitelistEnabled true
  # 100.64.0.1/32 = VPS infra-vps for Glance monitor probe.
  qb_set AuthSubnetWhitelist        '100.64.0.1/32'
  # Bypass auth for 127.0.0.1 so the qbittorrent-exporter sidecar
  # (running in the same netns) can read /api/v2/* without credentials.
  # qb's LocalHostAuth=false is the documented localhost-bypass flag —
  # AuthSubnetWhitelist treats 127.0.0.1 separately and doesn't actually
  # cover it.
  qb_set LocalHostAuth              false
  echo "      $QBCONF pinned"
else
  echo "      qBittorrent.conf not yet present (first start will create it; re-run this script after)"
fi

# ─── 6b. extract *arr API keys for exportarr ─────────────────────────
# Each *arr writes its API key into config.xml under <ApiKey>. exportarr
# needs them as env vars. Read them and write to .env idempotently —
# user never has to touch these manually. .env is gitignored.
echo "[6b/9] extracting *arr API keys into .env"
ENV_FILE="$REPO_DIR/.env"
extract_apikey() {
  local svc="$1" envvar="$2"
  local cfg="$REPO_DIR/$svc/config.xml"
  if [ -f "$cfg" ]; then
    local key
    key=$(grep -oE '<ApiKey>[a-f0-9]{32}</ApiKey>' "$cfg" | sed 's/<[^>]*>//g' | head -1)
    if [ -n "$key" ]; then
      if grep -q "^${envvar}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${envvar}=.*|${envvar}=${key}|" "$ENV_FILE"
      else
        echo "${envvar}=${key}" >> "$ENV_FILE"
      fi
      echo "      ${svc}: ${envvar} set"
    else
      echo "      ${svc}: no ApiKey in config.xml (service hasn't fully booted yet?)"
    fi
  else
    echo "      ${svc}: config.xml missing"
  fi
}
extract_apikey sonarr   SONARR_API_KEY
extract_apikey radarr   RADARR_API_KEY
extract_apikey prowlarr PROWLARR_API_KEY
extract_apikey lidarr   LIDARR_API_KEY
extract_apikey readarr  READARR_API_KEY

# ─── 7. install systemd unit ─────────────────────────────────────────
UNIT_SRC="$REPO_DIR/systemd/docker-compose@cn-bittorrent.service"
UNIT_DST="/etc/systemd/system/docker-compose@cn-bittorrent.service"
if [ ! -f "$UNIT_DST" ] || ! sudo cmp -s "$UNIT_SRC" "$UNIT_DST"; then
  echo "[7/9] installing $UNIT_DST"
  sudo cp "$UNIT_SRC" "$UNIT_DST"
  sudo systemctl daemon-reload
else
  echo "[7/9] systemd unit already in place"
fi

# ─── 8. enable + start ───────────────────────────────────────────────
echo "[8/9] enabling + starting docker-compose@cn-bittorrent"
sudo systemctl enable --now docker-compose@cn-bittorrent.service

# ─── 8b. configure qbittorrent save/temp paths via WebUI API ─────────
# qb must save completed downloads under the SAME NFS subtree the *arr
# suite imports from, at the IDENTICAL container path (/data/torrent), so
# Radarr/Sonarr hardlink-import without a RemotePathMapping. Done over the
# API (LocalHostAuth=false → no creds from 127.0.0.1) so it survives even
# when qb rewrites its own conf on shutdown.
echo "[8b/9] configuring qbittorrent download paths"
# NOTE: qb's LocalHostAuth bypass only covers TRUE localhost inside its netns;
# a curl from the host's published port hop is NOT 127.0.0.1 to qb and gets a
# 403. So drive the API via `docker exec` into the qb container.
QBX="docker exec cn-bittorrent-qbittorrent-1 curl -fsS"
qb_ready=0
for i in $(seq 1 30); do
  if $QBX -o /dev/null "http://127.0.0.1:8080/api/v2/app/version" 2>/dev/null; then qb_ready=1; break; fi
  sleep 2
done
if [ "$qb_ready" = 1 ]; then
  $QBX -X POST "http://127.0.0.1:8080/api/v2/app/setPreferences" \
    --data-urlencode 'json={"save_path":"/data/torrent/downloads","temp_path_enabled":true,"temp_path":"/data/torrent/incomplete"}' \
    && echo "      save_path=/data/torrent/downloads, temp_path=/data/torrent/incomplete"
  # Point the radarr/sonarr categories at the downloads dir (create-or-edit).
  for cat in movies tv-sonarr radarr; do
    $QBX -X POST "http://127.0.0.1:8080/api/v2/torrents/editCategory" \
      --data "category=${cat}" --data-urlencode "savePath=/data/torrent/downloads" 2>/dev/null \
    || $QBX -X POST "http://127.0.0.1:8080/api/v2/torrents/createCategory" \
      --data "category=${cat}" --data-urlencode "savePath=/data/torrent/downloads" 2>/dev/null || true
  done
  echo "      categories pinned to /data/torrent/downloads"
else
  echo "      qb WebUI not reachable yet — re-run setup.sh once qb is up"
fi

# ─── 8c. normalize Prowlarr application URLs to 127.0.0.1 ─────────────
# All *arr apps share ts-arr's netns, so Prowlarr must reach them on
# localhost with NO UrlBase path prefix. Legacy configs carried stale
# docker-DNS hostnames (radarr:7878/radarr, readerr:8787, …) that don't
# resolve here → "applications unavailable". Rewrite baseUrl + prowlarrUrl.
echo "[8c/9] normalizing Prowlarr application URLs"
PK=$(grep -oE '<ApiKey>[a-f0-9]{32}</ApiKey>' "$REPO_DIR/prowlarr/config.xml" 2>/dev/null | sed 's/<[^>]*>//g' | head -1)
if [ -n "$PK" ] && command -v python3 >/dev/null 2>&1 && curl -fsS -o /dev/null -H "X-Api-Key: $PK" "http://127.0.0.1:9696/api/v1/health" 2>/dev/null; then
  python3 - "$PK" <<'PY'
import json,sys,urllib.request
key=sys.argv[1]; base="http://127.0.0.1:9696/api/v1"
ports={"Radarr":7878,"Sonarr":8989,"Lidarr":8686,"Readarr":8787}
def req(path,method="GET",data=None):
    r=urllib.request.Request(base+path,data=json.dumps(data).encode() if data else None,
        headers={"X-Api-Key":key,"Content-Type":"application/json"},method=method)
    return urllib.request.urlopen(r,timeout=15)
apps=json.load(req("/applications"))
for a in apps:
    impl=a.get("implementationName") or a.get("name")
    port=ports.get(impl)
    if not port: continue
    for f in a["fields"]:
        if f["name"]=="baseUrl": f["value"]=f"http://127.0.0.1:{port}"
        if f["name"]=="prowlarrUrl": f["value"]="http://127.0.0.1:9696"
    req(f"/applications/{a['id']}","PUT",a); print(f"      {impl}: baseUrl -> http://127.0.0.1:{port}")
PY
else
  echo "      skipped (no api key / python3 / prowlarr not up)"
fi

# ─── 9. status ───────────────────────────────────────────────────────
echo "[9/9] status:"
sudo systemctl status docker-compose@cn-bittorrent.service --no-pager -l | head -15
echo
docker compose -p cn-bittorrent ps

echo
echo "Done. Verify with the §10 drill (README.md → \"Verification\")."
