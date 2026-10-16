<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# VPN & Remote Access

Reach your lab from anywhere without opening ports.

Mesh VPNs, classic WireGuard and tunnels for sharing apps securely.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Tailscale** | Zero-config WireGuard mesh with subnet routing & exit nodes. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Headscale** | Self-hosted Tailscale control server. | Proxmox, Linux, TrueNAS | Planned |
| **WireGuard (wg-easy)** | Classic WireGuard server with a web UI for peers & QR codes. | Proxmox, Linux, TrueNAS | Planned |
| **Cloudflare Tunnel** | Publish apps to the internet without port forwarding. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |

## Layout

Scripts go in one folder per platform:

```
VPN_Remote_Access/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
