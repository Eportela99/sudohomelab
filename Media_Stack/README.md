# Media Stack

Stream, request and automate your whole library: Jellyfin and/or Plex, Seerr, Radarr, Sonarr, Prowlarr, qBittorrent and/or SABnzbd, plus optional Lidarr, Bazarr, Tdarr, Audiobookshelf and Komga. Every app is installed **already connected** to the others.

| Platform | Script | Status |
| --- | --- | --- |
| Ubuntu / Debian | [`linux/media-stack.sh`](linux/media-stack.sh) | 🧪 Beta |
| TrueNAS SCALE 24.10+ | [`truenas/media-stack.sh`](truenas/media-stack.sh) | 🧪 Beta (tested on 25.10) |
| Proxmox VE 8 / 9 | [`proxmox/media-stack.sh`](proxmox/media-stack.sh) | ✅ Tested on Proxmox VE 9.2 (nested test VM); interactive run pending |
| Windows 11 / Server 2019+ | [`windows/media-stack.ps1`](windows/media-stack.ps1) | 🧪 Written, not tested yet |
| macOS | not written yet | Planned |

`truenas/media-stack.sh` and `proxmox/media-stack.sh` load `linux/media-stack.sh` as a library (Proxmox also runs it inside the container it creates), so both share the same wiring code. `truenas/test/` has a `midclt` test double and a validator for catalog-app values.

## Ubuntu / Debian

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/linux/media-stack.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`. When sudo's input is a pipe, current sudo (Ubuntu's default `sudo-rs` included) runs the script in the background, so it can't read your answers. The script detects this and tells you the right command.

The installer asks you to pick:

- **Media server:** Jellyfin, Plex or both
- **Download client:** qBittorrent, SABnzbd or both

It always installs **Seerr, Radarr, Sonarr and Prowlarr**. Optional **extras** (pick any):

- **Lidarr:** music, with `/data/Music`, download clients (category `music`) and Prowlarr indexer sync
- **Bazarr:** subtitles, connected to Radarr and Sonarr, with a language profile you choose (e.g. `en,es`) set as the default
- **Tdarr:** transcoding, with the admin account created and **Movies** and **TV_Shows** libraries set up with transcoding **off** until you pick a Flow
- **Audiobookshelf** (Linux, TrueNAS): audiobooks and podcasts, with its own `Audiobooks` folder (mounted at `/audiobooks`). No wiring, just the folder
- **Komga** (Linux, TrueNAS): comics, manga and ebooks, with `Books/Comics`, `Books/Ebooks` and `Books/Manga` (the `Books` folder is mounted at `/data`). No wiring, just the folders

Then it:

- installs Docker if it's missing (official repository, with the distro packages as a fallback)
- creates `Movies`, `TV_Shows` and `Active_Downloads` under one data folder (default `/srv/media`), mounted at `/data` in every container so imports are instant hardlinks
- sets one login for Radarr, Sonarr, Prowlarr, qBittorrent and SABnzbd
- connects **Radarr → /data/Movies** and **Sonarr → /data/TV_Shows**, with your download clients and categories
- connects **Prowlarr → Radarr + Sonarr**, so indexers you add sync automatically
- pre-configures **Seerr** with Radarr and Sonarr

**Network share (optional, Ubuntu/Debian and Proxmox):** answer yes to the SMB question (or pass `--smb`) and the whole media folder is shared as `\\<server-ip>\Media` with the same login. Mac: Finder → Go → Connect to Server → `smb://<server-ip>/Media`. Files you copy in belong to the apps' user, so Radarr, Komga and the rest can rename and import them. It installs Samba and adds its own files (`/etc/samba/sudohomelab-media.conf` plus one `include` and one `username map` line in `smb.conf`), so an existing Samba setup keeps working. `--no-smb` on a re-run (or `--uninstall`) takes the share away again and leaves `smb.conf` as it was. On Proxmox, Samba runs inside the container, so the share is at the container's IP. It also installs `wsdd2` (or `wsdd`), so PCs on the same LAN see the server in Windows' **Network** view and `\\<hostname>\Media` resolves; it answers on the LAN interface only. From another network or over Tailscale, discovery can't reach it: type `\\<server-ip>\Media` instead.

What's left for you: add indexers in Prowlarr, create your Jellyfin/Plex account and libraries, and sign in to Seerr. With extras: pick subtitle providers in Bazarr, choose a Flow in Tdarr, and create your admin account plus libraries in Audiobookshelf (`/audiobooks`) and Komga (`/data/Comics`, `/data/Ebooks`, `/data/Manga`).

**Uninstall** (your media is never touched, `--purge` also deletes app configs):

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge
```

**Non-interactive** (no questions, so the pipe form is fine here):

```bash
curl -fsSL <url> | sudo bash -s -- --server=jellyfin --downloader=qbittorrent --yes
```

Options: `--server=jellyfin|plex|both`, `--downloader=qbittorrent|sabnzbd|both`, `--extras=lidarr,bazarr,tdarr,audiobookshelf,komga|none`, `--subtitle-langs=en,es`, `--smb|--no-smb`, `--data-dir=PATH`, `--username=NAME`, `--password=PASS`, `--plex-claim=TOKEN`, `--dry-run`, `--uninstall [--purge]`, `--help`.

- **Logs:** `/var/log/sudohomelab/media-stack-*.log`
- **Credentials:** `/opt/sudohomelab/media-stack/credentials.txt` (root only)
- **Re-running is safe:** finished steps are skipped.
- **Port already taken?** The installer shows what's using it (a program or another container) and lets you pick the next free port, type your own, or cancel. With `--yes` it picks the next free port automatically. Apps talk to each other on internal container ports, so moving a port never breaks the wiring. Plex is the exception: it must use 32400, so you can skip it and keep a Plex you already run. Chosen ports are saved for re-runs.

## TrueNAS SCALE 24.10+

Run it in the TrueNAS shell (System → Shell, or SSH as an admin):

```bash
curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/truenas/media-stack.sh -o /tmp/media-stack.sh && sudo bash /tmp/media-stack.sh
```

> On TrueNAS, download first and then run the file, as above. TrueNAS turns on sudo's `log_subcmds`, and its sudo 1.9.13 kills `sudo bash -c "$(curl …)"` (the whole script ends up as one huge command, exit 137). For the same reason the installer never puts passwords or API keys in command arguments or environment variables, so they don't land in TrueNAS's logs.

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
curl -fsSL <truenas url> -o /tmp/media-stack.sh && sudo bash /tmp/media-stack.sh --uninstall --purge
```


## Proxmox VE 8 / 9

Run in the Proxmox host shell (root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/proxmox/media-stack.sh)"
```

It creates one unprivileged Debian LXC (`nesting=1,keyctl=1`, starts on boot, tag `sudohomelab-mediastack`) and runs the Ubuntu/Debian installer inside it, with the same apps and wiring. Settings and media live on the host and are bind-mounted in (`/opt/sudohomelab/media-stack` and `/srv/media`), so `--uninstall` deletes the container but keeps your settings, and `--purge` deletes them too. A GPU (`/dev/dri`) is passed through when present (Proxmox 8.2+). The Debian template is downloaded over IPv4 when the host has no IPv6 route (some routers, e.g. AT&T gateways, otherwise hand `pveam` an IPv6-only answer). With `--smb`, the share is served from inside the container.

Extra options: `--ctid`, `--storage`, `--bridge`, `--ip=dhcp|CIDR`, `--gateway`, `--cores`, `--memory`, `--disk`, `--settings-dir`, `--data-dir`.

## Windows 11 / Windows Server 2019+ (not tested yet)

Run in PowerShell (it asks for admin rights itself):

```powershell
irm https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Media_Stack/windows/media-stack.ps1 | iex
```

Native Windows apps, each running as a Windows service (WinSW), with the same wiring. Plex runs from a startup task, because it isn't a service on Windows. Seerr has no Windows build, so it's compiled from source with Node.js as the **last** step (about 5 minutes). You choose whether the services run as a dedicated local user `sudohomelab` (recommended, and works with NAS shares) or as LocalSystem. Firewall rules open the ports for Private and Domain networks only. Settings go in `C:\ProgramData\sudohomelab\media-stack`, programs in `C:\Program Files\sudohomelab`.

Options: `-Server`, `-Downloader`, `-Extras lidarr,bazarr,tdarr,seerr|none`, `-SubtitleLangs`, `-DataDir`, `-Username`, `-Password`, `-ServiceAccount sudohomelab|localsystem`, `-Yes`, `-DryRun`, `-Uninstall [-Purge]`.
