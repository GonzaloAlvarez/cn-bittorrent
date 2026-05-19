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

install_rules() {
  cmd=$1
  $cmd -P OUTPUT DROP
  $cmd -F OUTPUT
  $cmd -A OUTPUT -m mark --mark 0x80000/0xff0000 -j ACCEPT
  $cmd -A OUTPUT -o tailscale0 -j ACCEPT
  $cmd -A OUTPUT -o lo -j ACCEPT
  $cmd -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

echo "[kill-switch] installing iptables (v4) OUTPUT default-deny"
install_rules iptables

echo "[kill-switch] installing ip6tables OUTPUT default-deny (best effort)"
if install_rules ip6tables 2>&1; then
  echo "[kill-switch] ip6tables OK"
else
  # No IPv6 stack / nf6 module on this host — disable IPv6 in this
  # netns instead, so apps can't try to use it and leak that way.
  echo "[kill-switch] ip6tables unavailable; disabling IPv6 in this netns"
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 || true
fi

echo "[kill-switch] active rules:"
iptables -L OUTPUT -nv --line-numbers
echo "[kill-switch] handing off to tailscaled"

exec /usr/local/bin/containerboot
