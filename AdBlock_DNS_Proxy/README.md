<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Ad-blocking, DNS & Proxy

Block ads network-wide and put every app behind a clean URL.

DNS sinkholes, recursive resolvers and reverse proxies with automatic HTTPS.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Pi-hole** | The classic network-wide ad blocker and DNS server. | Proxmox, Linux, TrueNAS | Planned |
| **AdGuard Home** | Modern ad blocker with DoH/DoT and per-client rules. | Proxmox, Linux, TrueNAS | Planned |
| **Unbound** | Recursive DNS resolver, so no upstream provider sees your lookups. | Proxmox, Linux, TrueNAS | Planned |
| **Nginx Proxy Manager** | Reverse proxy with a GUI and free Let's Encrypt certificates. | Proxmox, Linux, TrueNAS | Planned |
| **Caddy** | Zero-config reverse proxy with automatic HTTPS. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |

## Pre-wired stack: Private DNS Stack

Ad blocker forwarding to your own recursive resolver, plus a reverse proxy so every app gets a name like jellyfin.home.

Status: planned. Script: `AdBlock_DNS_Proxy/<platform>/dns-stack.sh`

## Layout

Scripts go in one folder per platform:

```
AdBlock_DNS_Proxy/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
