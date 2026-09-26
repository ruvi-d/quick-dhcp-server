#!/usr/bin/env bash
# Watches one interface for carrier down->up transitions and restarts the
# DHCP container when the link comes back. Launched (and killed) by
# setup-routing.sh; not meant to be run standalone long-term.
set -euo pipefail

IFACE="$1"
COMPOSE_DIR="$2"

up=1
# -o (oneline): without it each event spans two lines, and the second
# ("link/ether ...") never contains LOWER_UP, so every event -- even an
# unrelated flag change like tcpdump toggling PROMISC -- looked like a
# down->up bounce and restarted the container.
ip -o monitor link dev "$IFACE" 2>/dev/null | while read -r line; do
  if [[ "$line" == *"LOWER_UP"* ]]; then
    if [[ $up -eq 0 ]]; then
      echo "$(date -Is) [link-watch] ${IFACE} link restored, restarting dhcp-server"
      sleep 2   # debounce: let the link settle before bouncing the container
      ( cd "$COMPOSE_DIR" && docker compose restart dhcp-server ) || true
    fi
    up=1
  else
    if [[ $up -eq 1 ]]; then
      echo "$(date -Is) [link-watch] ${IFACE} link down"
    fi
    up=0
  fi
done
