<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Dashboards

One pane of glass for your entire lab.

Start pages that show every service, its status and its stats at a glance.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Homarr** | Drag-and-drop dashboard with deep app integrations. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Homepage** | Fast, YAML-configured dashboard with 100+ service widgets. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **CasaOS** | Friendly home-cloud UI with a one-click app store. | Proxmox, Linux | Planned |
| **Glance** | Minimal feed dashboard: RSS, weather, markets, releases. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **sudo homelab Dash** | Our own dashboard, auto-populated with every app you install from this site. | Proxmox, Linux, TrueNAS, Windows, macOS | Original (planned) |

## Layout

Scripts go in one folder per platform:

```
Dashboards/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
