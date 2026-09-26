# quick-dhcp-server

A throwaway DHCP server for a direct Ethernet link (or a switch hanging off
one), with NAT out through the host's normal internet uplink. Useful when you
need to plug one or more devices straight into a laptop/PC port and get them
online without touching your real network/router.

`dnsmasq` runs in a container and serves DHCP only on the link interface;
`setup-routing.sh` configures the host side (static IP, NAT, firewall rules)
and drives the container.

## How it works

- `setup-routing.sh` assigns a static IP to the link interface, enables IP
  forwarding, and adds iptables NAT/FORWARD rules so devices' traffic goes
  out through the host's auto-detected default route (uplink). If firewalld
  is running (e.g. Fedora), the link interface is moved into the `trusted`
  zone for the session (runtime only) and restored on `stop` -- otherwise
  firewalld silently rejects the devices' DHCP requests.
- `dnsmasq.conf.template` is rendered into a gitignored `dnsmasq.conf` with
  the interface and IP range substituted in, then baked into the container
  image via `Dockerfile` / `docker-compose.yml`.
- `link-watch.sh` watches the link interface for carrier down->up
  transitions (e.g. the device gets unplugged/replugged) and restarts the
  container so DHCP starts serving again.

## Requirements

- Linux with `iptables`, `ip`, and root access
- Docker and Docker Compose

## Usage

```sh
sudo ./setup-routing.sh [iface] start   # configure IP + NAT, start the DHCP container
sudo ./setup-routing.sh stop            # undo everything, stop the DHCP container
sudo ./setup-routing.sh restart         # stop, then start again on the same iface
```

`iface` defaults to `DEFAULT_LINK_IFACE` in `setup-routing.sh` if omitted.
`stop`/`restart` don't take an iface — they reuse whatever interface the last
`start` recorded.

## Configuration

Edit the network config block at the top of `setup-routing.sh`
(`LINK_IP`, `CLIENT_IP_START`, `CLIENT_IP_END`, `LINK_PREFIX`, `NETMASK`,
`LINK_NET`) to move or resize the served range. Everything else (iptables
rules, `dnsmasq.conf`) is generated from these values. `CLIENT_IP_START` and
`CLIENT_IP_END` bound the pool dnsmasq hands out, so widen them to serve more
than one device at a time; if they're set to the same address, only a single
device can be served at once.

## License

MIT — see [LICENSE](LICENSE).
