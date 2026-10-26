# Ad-blocking, DNS & Proxy

Block ads network-wide and put every app behind a clean URL.

| App | What it does | Platform | Status |
| --- | --- | --- | --- |
| **Private DNS Stack:** Pi-hole + Unbound + Nginx Proxy Manager | Ad blocking, private DNS, and names like `https://jellyfin.home` for your apps | Ubuntu / Debian: [`linux/pihole.sh`](linux/pihole.sh)<br>Proxmox VE 8 / 9: [`proxmox/pihole.sh`](proxmox/pihole.sh)<br>TrueNAS SCALE 24.10+: [`truenas/pihole.sh`](truenas/pihole.sh) | 🧪 Beta |
| AdGuard Home | Ad blocker with DoH/DoT and per-client rules | | Planned |
| Caddy | Reverse proxy with automatic HTTPS | | Planned |

## Private DNS Stack (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/linux/pihole.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`, so the script can ask you questions.

Run it and pick what to do:

```
  What would you like to do?
    1) Install        Pi-hole + Unbound + Nginx Proxy Manager, then pick your settings
    2) List domains   the app names and the address each one points to
    3) Add domain     an app's address + a name, e.g. 192.168.1.50:8096 → jellyfin.home
    4) Delete domain  remove an app name (the app itself isn't touched)
    5) Uninstall      remove everything (asks whether to keep the settings)
    6) Quit           close the menu
```

After each action, press Enter to go back to the menu, or `q` to quit.

Or skip the menu with an action:

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --install
sudo bash -c "$(curl -fsSL <url>)" _ --list
sudo bash -c "$(curl -fsSL <url>)" _ --add=jellyfin=192.168.1.50:8096
sudo bash -c "$(curl -fsSL <url>)" _ --delete=jellyfin
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall          # keeps settings
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge  # deletes them too
```

### What gets installed

| Piece | Job |
| --- | --- |
| **Pi-hole v6** | Every device asks it for addresses. Blocks ads and trackers, and answers the app names. Runs on the host network, so the query log shows each device's real IP. |
| **Unbound** | Looks up real websites by asking the internet's root servers directly, so no DNS company sees your browsing. Validates DNSSEC. Only Pi-hole can reach it (`127.0.0.1`). |
| **Nginx Proxy Manager** | Gets a request for `jellyfin.home` and passes it to the right app and port, over HTTPS. Its admin page is on port 81. |

```
you open https://jellyfin.home
   │
   ▼
Pi-hole: "that's one of ours" → this server's IP
   │
   ▼
Nginx Proxy Manager :443  "jellyfin.home → 192.168.1.50:8096"
   │
   ▼
Jellyfin

any other site → Pi-hole (ads blocked) → Unbound → root servers (private, DNSSEC-checked)
```

### App names (domains)

**Add domain** asks for the address you use now and a name:

```
  ? App address (IP:port, host:port or http(s)://…) [] 192.168.1.50:8096
  ? Name (becomes <name>.home) [jellyfin]
  ✓ 192.168.1.50:8096 answers (http)
  ✓ Adding https://jellyfin.home → http://192.168.1.50:8096
  ✓ jellyfin.home → 192.168.1.10 (Pi-hole answers it)
  ✓ https://jellyfin.home opens (HTTP 200, trusted certificate)
```

- It checks that the address answers, works out whether the app speaks HTTP or HTTPS (Proxmox on 8006 and Portainer on 9443 do HTTPS), and suggests a name for well-known ports.
- Websockets are on, so live pages (Home Assistant, the *arr apps, Jellyfin) keep working.
- `localhost:PORT` means an app on this same machine. Any address on your network works too: a NAS, Proxmox, your router.
- `pihole.<ending>` and `proxy.<ending>` are created at install.
- Names you add in the proxy's own admin page get their DNS record the next time you run the script.

**List domains** shows every name and where it points. Your IPs and ports keep working as before; the names are an extra way in.

### Certificates

Chosen at install:

- **This machine's own (default):** the script creates a small certificate authority that can only vouch for `*.<your ending>` (a name constraint), so trusting it on a device can't be misused for any other site. Each device downloads it once from `http://proxy.<ending>/ca.crt` and installs it; after that there are no browser warnings. The fingerprint is shown at the end of the install.
- **Let's Encrypt:** with your own domain (say `home.example.com`) on Cloudflare, give an API token ("Edit zone DNS") and it gets one wildcard certificate, `*.home.example.com`, trusted everywhere. It uses the DNS challenge, so no port is opened to the internet.

### Over Tailscale (or WireGuard, ZeroTier)

The same names work away from home. Pi-hole answers each network with the matching address: a device at home gets the LAN IP, a device on Tailscale gets the server's Tailscale IP. Nothing is tied to one tailnet; the script finds the VPN addresses on whatever machine it runs on.

1. At install, choose **Any network** for "Who should be able to use this Pi-hole?" (the default when a VPN is found).
2. In the Tailscale admin console → **DNS** → **Add nameserver** → **Custom** → the server's Tailscale IP (the script prints it):
   - **Just the names:** turn on **Restrict to domain** with your ending (e.g. `home`). That's split DNS.
   - **Ad blocking on all your devices too:** leave it unrestricted and turn on **Override DNS servers**.
3. On the server itself: `sudo tailscale set --accept-dns=false`, so it keeps using its own DNS.

Installed the VPN after Pi-hole? Run **Install** again and the names pick up the new address.

### Port 53 and other ports

A DNS server needs port 53, and on Ubuntu `systemd-resolved` already holds it. The installer checks what's listening before it touches anything:

- **systemd-resolved:** turns off only its DNS stub (one drop-in file) and points `/etc/resolv.conf` at the real resolvers, so the host keeps working. Uninstalling puts it back exactly as it was.
- **dnsmasq, bind9, unbound, another DNS container:** shows you what it found and asks before stopping it.
- **Anything it can't identify safely** (libvirt's dnsmasq, for example): it stops and tells you, instead of breaking it.

The proxy needs 80 and 443, so Pi-hole's own admin page moves to **8080**. If 80 is taken (CasaOS, a web server), it offers another port: names still work with `https://`, only plain `http://name` needs the port. If 443 is taken, names need the port (`https://name:8443`), so freeing 443 is better.

### What it asks while installing

Every question has a default (press Enter), and each one has a flag for unattended installs.

| Question | Choices (default **bold**) | Flag |
| --- | --- | --- |
| Admin password (Pi-hole + proxy) | **generate one**, or type your own | `--password` |
| Blocklists | Light · **Balanced** (HaGeZi Pro + Threat Intel) · Aggressive · Classic (StevenBlack) | `--blocklists` |
| Extra blocklists | Smart TV telemetry · Phone & PC telemetry · DNS bypass (DoH/VPN/proxy) · Gambling · Adult | `--extras` |
| Allowlists | **Shopping & affiliate links** · Link shorteners | `--allowlists` |
| Blocklist updates | **Daily** · Weekly (systemd timer) | `--refresh` |
| Upstream DNS | **Unbound** · Cloudflare · Quad9 · Google · your own IPs | `--upstream` |
| Who can use it | **Local network only** (**Any network** when a VPN is found) | `--dns-access` |
| Device names | **Ask your router** (detected, editable) · Off | `--device-names`, `--router`, `--local-domain` |
| Names for your apps | **Local names** (`<app>.home`, or `lan`, `home.arpa`…) · your own domain | `--domain` |
| Certificates | **This machine's own** · Let's Encrypt via Cloudflare | `--cert`, `--cloudflare-token`, `--email` |

**DNSSEC** is always on: Unbound validates when you pick it, otherwise Pi-hole does. `--no-dnssec` turns it off for public upstreams.

### When it finishes

It checks that everything works: ads blocked, sites resolve, answers on the LAN IP, both admin logins work, Unbound and DNSSEC, allowlists, device names, the refresh timer, `https://pihole.<ending>` through the proxy with a trusted certificate, the certificate download, and, over each VPN, the name answering with the VPN address.

Then point your devices at it: set the server's IP as the **DNS server in your router's DHCP settings**, so every device picks it up.

- **Pi-hole:** `https://pihole.home` (or `http://<server-ip>:8080/admin`)
- **Proxy admin:** `https://proxy.home` (or `http://<server-ip>:81`), login `admin@home`
- **Password:** shown at the end, saved in `/opt/sudohomelab/pihole/credentials.txt` (root only)
- **Logs:** `/var/log/sudohomelab/pihole-*.log`
- **Re-running Install is safe:** it reads your saved choices, changes only what you changed, renews certificates that are close to expiring, and keeps your app names. Changing the ending (say `home` → `lan`) moves every name over.

### Unattended install

```bash
curl -fsSL <url> | sudo bash -s -- --install --domain=home --yes
```

All options: `sudo bash pihole.sh --help`. Also `--lists=URL,URL` (your own blocklists), `--web-port`, `--install-dir`, `--dry-run`.

> Before uninstalling, point your router's DNS back to something else, or devices lose name resolution until it's changed.

Tested on Ubuntu 26.04, with CasaOS already on port 80 and Tailscale on the same machine. See the test notes in the commit history.

## Proxmox VE 8 / 9

Run in the Proxmox host shell (root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/proxmox/pihole.sh)"
```

Same menu. Install creates one small unprivileged Debian container (`pihole`, tag `sudohomelab-dns`, 2 cores, 1 GB RAM, 8 GB disk) and runs the Ubuntu/Debian installer inside it, so the questions, blocklists, checks and app names are the same. Before that it asks:

- **A fixed address.** Your devices use it as their DNS server, so it must never change. It suggests a free one in the host's network (`.53` first) and checks that nothing answers on the address you type. Pick one outside your router's DHCP range, or reserve it there. `dhcp` works too, but then reserve the address in the router.
- **Where the disk lives** (when there's more than one storage).
- **Tailscale (optional).** The container gets `/dev/net/tun`, Tailscale is installed in it, and it joins your tailnet as `pihole`, with an auth key (`tskey-auth-…`) or a login link. It runs with `--accept-dns=false`, so Tailscale never takes over the container's own DNS. Then answer **Any network** in the Pi-hole questions, so it answers over Tailscale too.

The settings live on the host in `/opt/sudohomelab/pihole` (mounted into the container), so **Uninstall** can delete the container and keep them: Install again later brings the same address, password, lists and app names back. List / Add / Delete run inside the container for you. Re-running Install updates the container in place, and saying yes to Tailscale on a re-run adds it to an existing container.

```bash
bash -c "$(curl -fsSL <url>)" _ --install --ip=192.168.1.53/24 --yes
bash -c "$(curl -fsSL <url>)" _ --install --tailscale --tailscale-key-file=/root/ts.key --yes
bash -c "$(curl -fsSL <url>)" _ --add=jellyfin=192.168.1.50:8096
bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
```

Proxmox options: `--ctid`, `--storage`, `--bridge`, `--ip`, `--gateway`, `--cores`, `--memory`, `--disk`, `--tailscale` / `--no-tailscale`, `--tailscale-key-file`, `--settings-dir`. Every other option goes to the installer inside the container. Passwords and tokens reach it as root-only files, never as command arguments.

Shell into it with `pct enter <id>`; the compose project is in `/opt/sudohomelab/pihole`. Back it up with Datacenter → Backup (or `vzdump <id> --mode snapshot`). Uninstalling also logs the container out of Tailscale; remove the old `pihole` machine in the Tailscale admin console.

Tested on Proxmox VE 9.2 (nested test VM, Debian 13 container): fresh install with the wizard, add/list/delete names from the menu, re-run, adding Tailscale to an existing container, uninstall keeping settings, reinstall on the same address, purge.

## TrueNAS SCALE 24.10+

In the TrueNAS shell (System → Shell, or SSH), download first and then run the file:

```bash
curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/truenas/pihole.sh -o /tmp/pihole.sh && sudo bash /tmp/pihole.sh
```

> Not `sudo bash -c "$(curl …)"`: TrueNAS turns on sudo's `log_subcmds`, and its sudo kills a command whose text is a whole script.

Same menu, questions, checks and app names. Nothing is installed on the TrueNAS OS:

- **One Custom App** named `pihole` (Apps → Installed) runs Pi-hole, Unbound and the proxy. Settings go in a new dataset, `<pool>/apps/pihole` (it asks for the pool when there's more than one; `--pool=NAME`).
- **TrueNAS's web interface uses ports 80 and 443**, which the app names need. It asks to move it to **8000 / 8443** (default yes; `--move-ui` / `--keep-ui`), checks that TrueNAS answers on the new port, and moves it back if it doesn't. The move runs on its own, so it also finishes when you run this from the TrueNAS web shell (the page reconnects; if it doesn't, open `https://<nas-ip>:8443` and run the command again). Afterwards TrueNAS is at `https://<nas-ip>:8443` and `https://truenas.home`. **Uninstall moves it back.** Keep it where it is and the app names get other ports instead (`https://jellyfin.home:8443`).
- **Port 53** has to be free. If another app holds it (say a catalog Pi-hole), it tells you which and stops: on a NAS it doesn't stop things for you.
- The daily blocklist update is a TrueNAS cron job (System → Advanced → Cron Jobs).
- Passwords never go on a command line, so TrueNAS's sudo log never sees them.

```bash
sudo bash /tmp/pihole.sh --install --yes                  # moves the web interface (default)
sudo bash /tmp/pihole.sh --install --keep-ui --yes
sudo bash /tmp/pihole.sh --add=jellyfin=localhost:8096    # an app on the NAS itself
sudo bash /tmp/pihole.sh --uninstall [--purge]            # --purge also deletes the dataset
```

Tested on TrueNAS SCALE 25.10.1 (VM, with 12 media apps running): fresh install with the wizard and with flags, moving the web interface and moving it back, `truenas.home` through the proxy (websockets work), names for apps on the NAS, add/delete, re-run, uninstall keeping settings, reinstall, purge.

## Coming next

AdGuard Home as an alternative to Pi-hole.
