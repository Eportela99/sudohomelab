# sudo homelab

One-line installers and **pre-wired stacks** for Proxmox, TrueNAS SCALE, Ubuntu Server, Windows and macOS, plus an AI advisor that tells you what your hardware can run.

> Status: early preview. Scripts are added one at a time. Check the table below for what's ready.

## Projects

Each project is a folder with one subfolder per platform (`linux/`, `truenas/`, `proxmox/`, `windows/`, `macos/`).

| Project | What's inside | Status |
| --- | --- | --- |
| [Media_Stack](Media_Stack) | Jellyfin/Plex, Seerr, *arr apps, downloaders, pre-wired | 🧪 Beta: Ubuntu, TrueNAS |
| [Dashboards](Dashboards) | Homarr, Homepage, CasaOS, Glance | Planned |
| [AdBlock_DNS_Proxy](AdBlock_DNS_Proxy) | Private DNS Stack: Pi-hole + Unbound + Nginx Proxy Manager, app names like `jellyfin.home` | 🧪 Beta: Ubuntu, Proxmox, TrueNAS |
| [Self_Hosted_Cloud](Self_Hosted_Cloud) | Nextcloud Suite, Immich, Vaultwarden, Syncthing | Planned |
| [AI_Tools](AI_Tools) | Ollama, Open WebUI, MCP servers, OpenCode, n8n | Planned |
| [Home_Automation](Home_Automation) | Home Assistant, MQTT, Zigbee2MQTT, Node-RED | Planned |
| [Books_Audiobooks](Books_Audiobooks) | Audiobookshelf, Komga, Kavita, Calibre-Web | Planned |
| [VPN_Remote_Access](VPN_Remote_Access) | Tailscale, Headscale, WireGuard, Cloudflare Tunnel | Planned |
| [Monitoring_Management](Monitoring_Management) | Portainer, Uptime Kuma, Beszel, Dozzle, ntfy | Planned |
| [website](website) | The sudo homelab site (Vite + React) | Live preview |

### Quick start: Media Stack on Ubuntu

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/linux/media-stack.sh)"
```

More, including TrueNAS: [Media_Stack/README.md](Media_Stack/README.md).

### Quick start: Private DNS Stack on Ubuntu

Pi-hole ad blocking, Unbound private DNS, and Nginx Proxy Manager so your apps get names like `https://jellyfin.home` (at home and over Tailscale). Run it again for a menu to add, list and delete names.

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/AdBlock_DNS_Proxy/linux/pihole.sh)"
```

More: [AdBlock_DNS_Proxy/README.md](AdBlock_DNS_Proxy/README.md).

## Website

The site lives in `website/` (Vite + React). Everything on it is driven by `website/src/data/catalog.js`.

```bash
cd website
npm install
npm run dev
npm run readmes   # regenerate the project folders' READMEs from the catalog
```

## Read before you run

Piping a script into a shell means trusting it. Every script here is plain bash: read it first.
