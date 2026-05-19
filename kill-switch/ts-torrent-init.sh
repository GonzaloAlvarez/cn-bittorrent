#!/bin/sh
# ts-torrent init — installs an OUTPUT-DROP kill-switch BEFORE starting
# tailscaled, so that during the brief startup window (where the
# container's default route is still the docker-bridge gateway →
# kaiser → ISP) qbittorrent and the *arr suite can't leak even a
# single packet to the public internet via the home WAN.
#
# Allow list:
#   - mark 0x80000/0xff0000  : tailscaled's own control + WG packets
#                              (TS_BYPASS_MARK; set by tailscaled itself)
#   - -o tailscale0           : the exit-node-bound traffic from apps
#   - -o lo                   : intra-netns loopback (inter-service)
#   - ctstate ESTABLISHED,RELATED : reverse path for inbound published
#                              ports (so cn-home traefik on kaiser host
#                              can reach qb/*arr UIs via docker-proxy)
#
# Final fallthrough: default policy DROP on OUTPUT (v4 + v6).
#
# Reference: Tailscale uses fwmark 0x80000/0xff0000 by default for its
# bypass packets; verifiable via `iptables-save | grep mark` after
# tailscaled is running.

set -eu

echo "[kill-switch] installing iptables OUTPUT default-deny"

for cmd in iptables ip6tables; do
  $cmd -P OUTPUT DROP
  $cmd -F OUTPUT
  $cmd -A OUTPUT -m mark --mark 0x80000/0xff0000 -j ACCEPT
  $cmd -A OUTPUT -o tailscale0 -j ACCEPT
  $cmd -A OUTPUT -o lo -j ACCEPT
  $cmd -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

echo "[kill-switch] rules:"
iptables -L OUTPUT -nv --line-numbers
echo "[kill-switch] handing off to tailscaled"

exec /usr/local/bin/containerboot
