# sudo homelab

One-line installers and **pre-wired stacks** for Proxmox, TrueNAS SCALE, Ubuntu Server, Windows and macOS, plus an AI advisor that tells you what your hardware can run.

> Status: early preview. Scripts are added one at a time. Check the table below for what's ready.

## Scripts

| Script | Platform | Status |
| --- | --- | --- |
| Media Stack | Ubuntu / Debian | 🧪 Beta |

### Media Stack (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts/linux/stack/media-stack.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`. When sudo's input is a pipe, current sudo (Ubuntu's default `sudo-rs` included) runs the script in the background, so it can't read your answers. The script detects this and tells you the right command.

The installer asks you to pick:

- **Media server:** Jellyfin, Plex or both
- **Download client:** qBittorrent, SABnzbd or both

It always installs **Seerr, Radarr, Sonarr and Prowlarr**, then it:

- installs Docker if it's missing (official repository, with the distro packages as a fallback)
- creates `Movies`, `TV_Shows` and `Active_Downloads` under one data folder (default `/srv/media`), mounted at `/data` in every container so imports are instant hardlinks
- sets one login for Radarr, Sonarr, Prowlarr, qBittorrent and SABnzbd
- connects **Radarr → /data/Movies** and **Sonarr → /data/TV_Shows**, with your download clients and categories
- connects **Prowlarr → Radarr + Sonarr**, so indexers you add sync automatically
- pre-configures **Seerr** with Radarr and Sonarr

What's left for you: add indexers in Prowlarr, create your Jellyfin/Plex account and libraries, and sign in to Seerr.

**Uninstall** (your media is never touched, `--purge` also deletes app configs):

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge
```

**Non-interactive** (no questions, so the pipe form is fine here):

```bash
curl -fsSL <url> | sudo bash -s -- --server=jellyfin --downloader=qbittorrent --yes
```

Options: `--server=jellyfin|plex|both`, `--downloader=qbittorrent|sabnzbd|both`, `--data-dir=PATH`, `--username=NAME`, `--password=PASS`, `--plex-claim=TOKEN`, `--dry-run`, `--uninstall [--purge]`, `--help`.

- **Logs:** `/var/log/sudohomelab/media-stack-*.log`
- **Credentials:** `/opt/sudohomelab/media-stack/credentials.txt` (root only)
- **Re-running is safe:** finished steps are skipped.

## Website

The site in `src/` is a Vite + React app. Everything on it is driven by `src/data/catalog.js`.

```bash
npm install
npm run dev
```

## Read before you run

Piping a script into a shell means trusting it. Every script here is plain bash: read it first.
