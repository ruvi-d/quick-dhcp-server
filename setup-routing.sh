#!/usr/bin/env bash
# Sets up (and tears down) temporary host-side routing for a direct
# ethernet link to an embedded device on $LINK_IFACE, so it can reach the
# internet through the host's normal uplink (auto-detected default route).
#
# Usage:
#   sudo ./setup-routing.sh [iface] start   # configure IP + NAT, start the DHCP container
#   sudo ./setup-routing.sh stop            # undo everything, stop the DHCP container
#   sudo ./setup-routing.sh restart         # stop, then start again on the same iface
#
# [iface] defaults to DEFAULT_LINK_IFACE below if omitted. `stop`/`restart`
# never take an iface -- they reuse whatever interface the last `start`
# recorded in $STATE_FILE.

set -euo pipefail

DEFAULT_LINK_IFACE="enp9s0u1u4u2u4"
LINK_IP="10.0.0.1"
LINK_NET="10.0.0.0/24"
LINK_PREFIX=24
STATE_FILE="/run/dhcp-docker-p2p.state"
COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (needs to touch interfaces/iptables)." >&2
  exit 1
fi

uplink_iface() {
  ip route show default | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}'
}

start() {
  LINK_IFACE="${1:-$DEFAULT_LINK_IFACE}"

  local uplink
  uplink="$(uplink_iface)"
  if [[ -z "$uplink" || "$uplink" == "$LINK_IFACE" ]]; then
    echo "Could not determine a distinct internet-facing uplink interface (got: '${uplink:-none}')." >&2
    exit 1
  fi
  echo "Using '$LINK_IFACE' as the device link and '$uplink' as the internet uplink."

  # Stop NetworkManager from touching this link (auto-connect/DHCP-client
  # races can silently rewrite or drop the static IP we're about to set).
  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "$LINK_IFACE" managed no 2>/dev/null || true
  fi

  echo "Assigning ${LINK_IP}/${LINK_PREFIX} to ${LINK_IFACE}..."
  ip addr replace "${LINK_IP}/${LINK_PREFIX}" dev "$LINK_IFACE"
  ip link set "$LINK_IFACE" up

  local prev_forward
  prev_forward="$(cat /proc/sys/net/ipv4/ip_forward)"
  echo "ip_forward=1 uplink=${uplink}" > "$STATE_FILE"
  echo "prev_ip_forward=${prev_forward}" >> "$STATE_FILE"
  echo "link_iface=${LINK_IFACE}" >> "$STATE_FILE"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # NAT the embedded device's traffic out through the uplink.
  iptables -t nat -C POSTROUTING -s "$LINK_NET" -o "$uplink" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$LINK_NET" -o "$uplink" -j MASQUERADE

  iptables -C FORWARD -i "$LINK_IFACE" -o "$uplink" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$LINK_IFACE" -o "$uplink" -j ACCEPT

  iptables -C FORWARD -i "$uplink" -o "$LINK_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$uplink" -o "$LINK_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT

  # Host firewalls (ufw etc.) commonly default INPUT to DROP, which silently
  # swallows the device's DHCP broadcasts before dnsmasq's socket ever sees
  # them. Insert at the very top of INPUT so it wins regardless of whatever
  # else the firewall does with this traffic.
  iptables -C INPUT -i "$LINK_IFACE" -p udp --dport 67 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -i "$LINK_IFACE" -p udp --dport 67 -j ACCEPT

  echo "Writing dnsmasq.conf for interface '${LINK_IFACE}'..."
  sed "s/@LINK_IFACE@/${LINK_IFACE}/g" "$COMPOSE_DIR/dnsmasq.conf.template" > "$COMPOSE_DIR/dnsmasq.conf"

  echo "Starting DHCP server container..."
  ( cd "$COMPOSE_DIR" && docker compose up -d --build )

  echo "Done. Embedded device should get ${LINK_IP%.*}.2 via DHCP and reach the internet through ${uplink}."
}

stop() {
  if [[ -f "$STATE_FILE" ]]; then
    LINK_IFACE="$(grep -oP '(?<=link_iface=).*' "$STATE_FILE" || echo "$DEFAULT_LINK_IFACE")"
  else
    LINK_IFACE="$DEFAULT_LINK_IFACE"
  fi

  echo "Stopping DHCP server container..."
  ( cd "$COMPOSE_DIR" && docker compose down ) || true

  local uplink=""
  if [[ -f "$STATE_FILE" ]]; then
    uplink="$(grep -oP '(?<=uplink=).*' "$STATE_FILE" || true)"
  fi
  if [[ -z "$uplink" ]]; then
    uplink="$(uplink_iface)"
  fi

  if [[ -n "$uplink" ]]; then
    echo "Removing NAT/forward rules for uplink '${uplink}'..."
    iptables -t nat -D POSTROUTING -s "$LINK_NET" -o "$uplink" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$LINK_IFACE" -o "$uplink" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$uplink" -o "$LINK_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  fi

  iptables -D INPUT -i "$LINK_IFACE" -p udp --dport 67 -j ACCEPT 2>/dev/null || true

  if [[ -f "$STATE_FILE" ]]; then
    local prev_forward
    prev_forward="$(grep -oP '(?<=prev_ip_forward=).*' "$STATE_FILE" || echo 0)"
    sysctl -w net.ipv4.ip_forward="$prev_forward" >/dev/null
    rm -f "$STATE_FILE"
  fi

  echo "Removing ${LINK_IP}/${LINK_PREFIX} from ${LINK_IFACE}..."
  ip addr del "${LINK_IP}/${LINK_PREFIX}" dev "$LINK_IFACE" 2>/dev/null || true

  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "$LINK_IFACE" managed yes 2>/dev/null || true
  fi

  echo "Done."
}

restart() {
  local iface
  if [[ -f "$STATE_FILE" ]]; then
    iface="$(grep -oP '(?<=link_iface=).*' "$STATE_FILE" || echo "$DEFAULT_LINK_IFACE")"
  else
    iface="$DEFAULT_LINK_IFACE"
  fi
  stop
  start "$iface"
}

IFACE_ARG=""
ACTION="start"

case "${1:-}" in
  start|stop|restart|"")
    ACTION="${1:-start}"
    ;;
  *)
    IFACE_ARG="$1"
    ACTION="${2:-start}"
    ;;
esac

case "$ACTION" in
  start) start "$IFACE_ARG" ;;
  stop) stop ;;
  restart) restart ;;
  *) echo "Usage: $0 [iface] start | stop | restart" >&2; exit 1 ;;
esac
