<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Monitoring & Management

Know what's up, what's down and what's eating your RAM.

Container management, uptime checks, metrics and push notifications.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Portainer** | GUI for Docker containers, stacks and volumes. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Uptime Kuma** | Beautiful uptime monitoring and status pages. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Beszel** | Lightweight server metrics hub + agents with Docker stats. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Dozzle** | Real-time log viewer for all your containers. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **ntfy** | Push notifications to your phone from any script. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |

## Layout

Scripts go in one folder per platform:

```
Monitoring_Management/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
