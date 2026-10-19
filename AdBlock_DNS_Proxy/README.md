# Ad-blocking, DNS & Proxy

Block ads network-wide and put every app behind a clean URL.

| App | What it does | Platform | Status |
| --- | --- | --- | --- |
| **Pi-hole** (+ optional Unbound) | Network-wide ad blocker and DNS server | Ubuntu / Debian: [`linux/pihole.sh`](linux/pihole.sh) | 🧪 Beta |
| AdGuard Home | Ad blocker with DoH/DoT and per-client rules | | Planned |
| Nginx Proxy Manager | Reverse proxy with a GUI and Let's Encrypt | | Planned |
| Caddy | Reverse proxy with automatic HTTPS | | Planned |

## Pi-hole (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/linux/pihole.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`, so the installer can ask you questions.

Installs **Pi-hole v6** in Docker on the host network, so the query log shows each device's real IP. It's blocking from the first minute: no setup wizard, no lists to add by hand.

### Port 53 first

A DNS server needs port 53, and on Ubuntu `systemd-resolved` already holds it. The installer checks what's listening before it touches anything:

- **systemd-resolved:** turns off only its DNS stub (one drop-in file) and points `/etc/resolv.conf` at the real resolvers, so the host keeps working. Uninstalling puts it back exactly as it was.
- **dnsmasq, bind9, unbound, another DNS container:** shows you what it found and asks before stopping it.
- **Anything it can't identify safely** (libvirt's dnsmasq, for example): it stops and tells you, instead of breaking it.

The admin page and Unbound ports are checked too. If port 80 is taken (CasaOS, a web server), it offers the next free one, such as 8080.

### What it asks while installing

Every question has a sensible default (press Enter), and each one has a flag for unattended installs.

| Question | Choices (default **bold**) | Flag |
| --- | --- | --- |
| Admin password | **generate one**, or type your own | `--password` |
| Blocklists | Light · **Balanced** (HaGeZi Pro + Threat Intel) · Aggressive · Classic (StevenBlack) | `--blocklists` |
| Extra blocklists | Smart TV telemetry · Phone & PC telemetry · DNS bypass (DoH/VPN/proxy) · Gambling · Adult | `--extras` |
| Allowlists | **Shopping & affiliate links** · Link shorteners | `--allowlists` |
| Blocklist updates | **Daily** · Weekly (systemd timer) | `--refresh` |
| Upstream DNS | **Unbound** (your own recursive resolver) · Cloudflare · Quad9 · Google · your own IPs | `--upstream` |
| Who can use it | **Local network only** · Any network (Tailscale, WireGuard, other subnets) | `--dns-access` |
| Device names | **Ask your router** (detected, editable) · Off | `--device-names`, `--router`, `--local-domain` |

**DNSSEC** is always on: Unbound validates when you pick it, otherwise Pi-hole does. `--no-dnssec` turns it off for public upstreams.

Nothing is tied to one network: the router, subnet, local domain and VPN interfaces are all detected on the machine it runs on. If it finds Tailscale and you allow any network, it prints the steps to make Pi-hole your tailnet's DNS.

### How the pieces connect

```
your devices ──DNS──▶ Pi-hole :53 ──▶ Unbound 127.0.0.1:5335 ──▶ root servers → .com → example.com
                         │                (or Cloudflare / Quad9 / Google)
                         ├── blocklists (HaGeZi), refreshed daily
                         └── reverse lookups ──▶ your router  (device names in the log)
```

With Unbound, no DNS company sees your lookups: it asks the authoritative servers directly and checks DNSSEC. Unbound only listens on `127.0.0.1`, so it's reachable by Pi-hole alone.

### When it finishes

It runs checks and shows the results: ads blocked, normal sites resolve, answers on the LAN IP, admin login works, Unbound answers, DNSSEC rejects a forged domain, allowlists loaded, device names resolve, refresh timer active.

Then point your devices at it: set the server's IP as the **DNS server in your router's DHCP settings** (every device picks it up), or on one device at a time.

- **Admin page:** `http://<server-ip>/admin` (or the port it picked)
- **Password:** shown at the end, saved in `/opt/sudohomelab/pihole/credentials.txt` (root only)
- **Logs:** `/var/log/sudohomelab/pihole-*.log`
- **Re-running is safe:** it reads your saved choices, changes only what you changed, and removes only the lists it added itself.

### Unattended install

```bash
curl -fsSL <url> | sudo bash -s -- --blocklists=balanced --upstream=unbound --yes
```

All options: `sudo bash pihole.sh --help`. Also `--lists=URL,URL` (your own blocklists), `--web-port`, `--install-dir`, `--dry-run`.

### Uninstall

```bash
# Remove Pi-hole and Unbound, give port 53 back (keeps settings)
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall
# ...and delete settings, lists and query history
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge
```

> Before uninstalling, point your router's DNS back to something else, or devices lose name resolution until it's changed.

Tested on Ubuntu 26.04 (with CasaOS already on port 80): fresh install, every menu choice, switching options on re-run, and uninstall.

## Coming next

A **Private DNS Stack**: ad blocker + Unbound + a reverse proxy, so every app gets a name like `jellyfin.home`. AdGuard Home and the Proxmox / TrueNAS versions of the Pi-hole installer are planned.
