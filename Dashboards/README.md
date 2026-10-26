<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Dashboards

One pane of glass for your entire lab.

Start pages that show every service, its status and its stats at a glance.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Homarr** | Drag-and-drop dashboard with deep app integrations. | Proxmox, Linux, TrueNAS, Windows, macOS | Official install |
| **Homepage** | Fast, YAML-configured dashboard with 100+ service widgets. | Proxmox, Linux, TrueNAS, Windows, macOS | Official install |
| **CasaOS** | Friendly home-cloud UI with a one-click app store. | Proxmox, Linux | Official install |
| **Glance** | Minimal feed dashboard: RSS, weather, markets, releases. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **sudo homelab Dash** | Our own dashboard, auto-populated with every app you install from this site. | Proxmox, Linux, TrueNAS, Windows, macOS | Original (planned) |

## Install (official methods)

These use each project's own installer, not a sudo homelab script. Commands for every platform, and docs: https://sudohomelab.vercel.app/#/c/dashboards

### Homarr

Homarr's official Docker image. It keeps its encryption key in a file next to its data: Homarr needs the same key every time it starts. [Website](https://homarr.dev) · [Docs](https://homarr.dev/docs/getting-started/installation/docker)

Ubuntu / Debian:

```bash
sudo mkdir -p /opt/homarr && sudo test -f /opt/homarr/secret.key || openssl rand -hex 32 | sudo tee /opt/homarr/secret.key >/dev/null; sudo docker run -d --name homarr --restart unless-stopped -p 7575:7575 -v /var/run/docker.sock:/var/run/docker.sock -v /opt/homarr/appdata:/appdata -e SECRET_ENCRYPTION_KEY=$(sudo cat /opt/homarr/secret.key) ghcr.io/homarr-labs/homarr:latest
```

### Homepage

Homepage's official Docker image. HOMEPAGE_ALLOWED_HOSTS must list every address you open it at (here: this machine's IP). [Website](https://gethomepage.dev) · [Docs](https://gethomepage.dev/installation/docker/)

Ubuntu / Debian:

```bash
sudo docker run -d --name homepage --restart unless-stopped -p 3000:3000 -e HOMEPAGE_ALLOWED_HOSTS=$(hostname -I | awk '{print $1}'):3000 -v /opt/homepage/config:/app/config -v /var/run/docker.sock:/var/run/docker.sock:ro ghcr.io/gethomepage/homepage:latest
```

### CasaOS

CasaOS's official installer. It installs Docker too if it's missing, and prints the address to open when it finishes. [Website](https://casaos.zimaspace.com) · [Docs](https://github.com/IceWhaleTech/CasaOS)

Ubuntu / Debian:

```bash
curl -fsSL https://get.casaos.io | sudo bash
```

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

No sudo homelab scripts here yet. See [Media_Stack](../Media_Stack) for a finished project.
