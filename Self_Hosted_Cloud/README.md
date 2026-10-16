<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Self-Hosted Cloud

Your files, photos and passwords, on your hardware.

Replace Google Drive, Google Photos and password managers with apps you own.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Nextcloud Suite** | Nextcloud with Postgres, Redis, Office, Talk, Calendar & Memories pre-configured. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Immich** | Google Photos replacement with face & object search. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Vaultwarden** | Lightweight Bitwarden-compatible password server. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Syncthing** | Peer-to-peer folder sync between all your devices. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Paperless-ngx** | Scan, OCR and search every document you own. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |

## Pre-wired stack: Nextcloud Suite

Not just Nextcloud. A tuned install with database, cache, cron, office editing and your choice of add-ons enabled.

Status: planned. Script: `Self_Hosted_Cloud/<platform>/nextcloud-suite.sh`

## Layout

Scripts go in one folder per platform:

```
Self_Hosted_Cloud/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
