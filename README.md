# sudo homelab

One-line installers and **pre-wired stacks** for Proxmox, TrueNAS SCALE, Ubuntu Server, Windows and macOS, plus an AI advisor that tells you what your hardware can run.

> Status: early preview. Scripts are added one at a time. Check the table below for what's ready.

## Scripts

| Script | Platform | Status |
| --- | --- | --- |
| Media Stack | Ubuntu / Debian | 🧪 Beta |
| Media Stack | TrueNAS SCALE 24.10+ | 🧪 Beta (testing) |

### Media Stack (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts/linux/stack/media-stack.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`. When sudo's input is a pipe, current sudo (Ubuntu's default `sudo-rs` included) runs the script in the background, so it can't read your answers. The script detects this and tells you the right command.

The installer asks you to pick:

- **Media server:** Jellyfin, Plex or both
- **Download client:** qBittorrent, SABnzbd or both

It always installs **Seerr, Radarr, Sonarr and Prowlarr**. Optional **extras** (pick any):

- **Lidarr:** music, with `/data/Music`, download clients (category `music`) and Prowlarr indexer sync
- **Bazarr:** subtitles, connected to Radarr and Sonarr, with a language profile you choose (e.g. `en,es`) set as the default
- **Tdarr:** transcoding, with the admin account created and **Movies** and **TV_Shows** libraries set up with transcoding **off** until you pick a Flow

Then it:

- installs Docker if it's missing (official repository, with the distro packages as a fallback)
- creates `Movies`, `TV_Shows` and `Active_Downloads` under one data folder (default `/srv/media`), mounted at `/data` in every container so imports are instant hardlinks
- sets one login for Radarr, Sonarr, Prowlarr, qBittorrent and SABnzbd
- connects **Radarr → /data/Movies** and **Sonarr → /data/TV_Shows**, with your download clients and categories
- connects **Prowlarr → Radarr + Sonarr**, so indexers you add sync automatically
- pre-configures **Seerr** with Radarr and Sonarr

What's left for you: add indexers in Prowlarr, create your Jellyfin/Plex account and libraries, and sign in to Seerr. With extras: pick subtitle providers in Bazarr, and choose a Flow in Tdarr.

**Uninstall** (your media is never touched, `--purge` also deletes app configs):

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge
```

**Non-interactive** (no questions, so the pipe form is fine here):

```bash
curl -fsSL <url> | sudo bash -s -- --server=jellyfin --downloader=qbittorrent --yes
```

Options: `--server=jellyfin|plex|both`, `--downloader=qbittorrent|sabnzbd|both`, `--extras=lidarr,bazarr,tdarr|none`, `--subtitle-langs=en,es`, `--data-dir=PATH`, `--username=NAME`, `--password=PASS`, `--plex-claim=TOKEN`, `--dry-run`, `--uninstall [--purge]`, `--help`.

- **Logs:** `/var/log/sudohomelab/media-stack-*.log`
- **Credentials:** `/opt/sudohomelab/media-stack/credentials.txt` (root only)
- **Re-running is safe:** finished steps are skipped.
- **Port already taken?** The installer shows what's using it (a program or another container) and lets you pick the next free port, type your own, or cancel. With `--yes` it picks the next free port automatically. Apps talk to each other on internal container ports, so moving a port never breaks the wiring. Plex is the exception: it must use 32400, so you can skip it and keep a Plex you already run. Chosen ports are saved for re-runs.

### Media Stack (TrueNAS SCALE 24.10+)

Run it in the TrueNAS shell (System → Shell, or SSH as an admin):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts/truenas/stack/media-stack.sh)"
```

Same apps, menus and wiring as the Ubuntu version. It also asks **how the stack should appear in TrueNAS**:

- **Custom App:** one app called `mediastack` holding the whole stack (one compose file).
- **Catalog apps:** each app installed from the TrueNAS catalog and listed separately in Apps. They join a shared Docker network (`mediastack`) with aliases, so they find each other by name just like in one compose project.

Differences from Ubuntu:

- Nothing gets installed on the TrueNAS OS (it's read-only). If `jq` is missing, a static copy is fetched for the run.
- You pick a pool. It creates the datasets `<pool>/apps/mediastack` (app settings) and `<pool>/media` (media + downloads). Movies, TV_Shows, Music and Active_Downloads are folders inside **one** dataset, because hardlinks can't cross datasets.
- Apps run as TrueNAS's built-in `apps` user (568:568).
- Needs the Apps service enabled (Apps → Configuration → Choose Pool).
- Options: `--mode=custom|catalog`, `--pool=NAME`, plus all the Ubuntu options.

Uninstall (the media dataset is never touched; `--purge` also deletes `<pool>/apps/mediastack`):

```bash
sudo bash -c "$(curl -fsSL <truenas url>)" _ --uninstall --purge
```

## Website

The site in `src/` is a Vite + React app. Everything on it is driven by `src/data/catalog.js`.

```bash
npm install
npm run dev
```

## Read before you run

Piping a script into a shell means trusting it. Every script here is plain bash: read it first.
