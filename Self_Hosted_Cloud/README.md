# Self-Hosted Cloud

Your files, photos and passwords, on your hardware.

| App | What it does | Platform | Status |
| --- | --- | --- | --- |
| **Cloud Stack:** Nextcloud + Collabora + Immich + Vaultwarden + Stirling PDF + Obsidian | Files, calendar, contacts, mail and Office; phone photo backup; a password manager; PDF tools; notes. All on one folder tree, behind HTTPS, with nightly backups | Ubuntu / Debian: [`linux/cloud.sh`](linux/cloud.sh)<br>Proxmox VE 8 / 9: [`proxmox/cloud.sh`](proxmox/cloud.sh)<br>TrueNAS SCALE 24.10+: [`truenas/cloud.sh`](truenas/cloud.sh) | 🧪 Beta |
| Syncthing, Paperless-ngx | Folder sync, document archive | | Planned |

## Cloud Stack (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Self_Hosted_Cloud/linux/cloud.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`, so the script can ask you questions.

Run it and pick what to do:

```
  What would you like to do?
    1) Install        Nextcloud + Office, Immich, Vaultwarden, Stirling PDF, Obsidian
    2) Lock sign-ups  close Vaultwarden sign-ups once your account exists
    3) Back up now    save the databases and Vaultwarden into the backups folder
    4) Uninstall      remove the apps (asks whether to keep the data)
    5) Quit           close the menu
```

Or skip the menu with an action:

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --install
sudo bash -c "$(curl -fsSL <url>)" _ --lock-signups
sudo bash -c "$(curl -fsSL <url>)" _ --backup
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall                          # keeps everything
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge                  # deletes settings + databases
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge --delete-files   # and your files
```

### What gets installed

| Piece | Job |
| --- | --- |
| **Nextcloud** (+ Postgres, Redis, a cron container) | Your files, synced to phone and computer, with the Calendar, Tasks, Contacts, Mail, Deck, Collectives, News, Notes and Office apps installed. |
| **Collabora** *(Office)* | Opens Word, Excel and PowerPoint files inside Nextcloud. |
| **Immich** *(Photos)* | Backs up your phone's camera roll; also shows the Photos folder. Smart search and face recognition are an extra choice (about 2 GB more RAM). |
| **Vaultwarden** *(Passwords)* | A password server for the Bitwarden apps and browser extensions. |
| **Stirling PDF** *(PDF)* | Merge, split, OCR, compress, plus drop folders that do it on their own. |
| **Obsidian** *(Notes)* | The real Obsidian app in your browser, opened on the shared Notes folder. |

Pick any of the apps in brackets (Nextcloud is always there). It checks RAM and disk for your choice first: all of them download about 21 GB.

### One folder tree

```
/srv/cloud/                     (--data-dir to put it on another disk)
  Documents/                    Nextcloud "Documents"
    PDF Inbox/OCR, /Compress    drop PDFs here → Stirling PDF puts the result in PDF Done/
  Notes/                        Nextcloud Notes = the Obsidian vault
  Photos/                       Nextcloud "Photos" = an Immich library
  nextcloud/  immich/           the apps' own storage
  backups/                      nightly database dumps + Vaultwarden, last 7 of each
/opt/sudohomelab/cloud/         settings, databases, credentials.txt (root only)
```

Every user sees Documents, Notes and Photos in Nextcloud. Files added from any app, or straight into the folder, show up in the others.

### HTTPS: two ways

The installer asks which one (`--https=caddy|dns`):

- **Built-in** (default): a small proxy with its own certificate, made only for home-network addresses and Tailscale, so it can't be used to impersonate real sites. Each app gets an HTTPS port:

  | App | Address |
  | --- | --- |
  | Nextcloud (+ Office) | `https://<server-ip>` |
  | Immich | `https://<server-ip>:2283` |
  | Vaultwarden | `https://<server-ip>:8222` |
  | Stirling PDF | `https://<server-ip>:8484` |
  | Obsidian | `https://<server-ip>:3443` |

  Trust the certificate once per device: `http://<server-ip>/` has the file and the steps for iPhone, Android, Windows, macOS and Linux. On a Mac, after downloading it:

  ```bash
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/sudohomelab-cloud-ca.crt
  ```

  If a port is taken, it offers the next free one (port 80 moves to 8880 when CasaOS or TrueNAS has it).

- **Names from the [Private DNS Stack](../AdBlock_DNS_Proxy):** `https://cloud.home`, `office.home`, `photos.home`, `vault.home`, `pdf.home`, `notes.home`. When the DNS stack is on the same machine (or the same Proxmox host or NAS), the names are added for you; when it's elsewhere, give its address with `--dns-host=IP` and the installer prints the lines to run there.

### What it asks while installing

| Question | Choices (default **bold**) | Flag |
| --- | --- | --- |
| Login for the apps | **admin** | `--username` |
| Password (at least 12 characters) | **generate one**, or type your own | `--password`, `--password-file` |
| Immich login (an email) | **`<username>@homelab.local`** | `--email` |
| Where your files go | **/srv/cloud** | `--data-dir` |
| HTTPS | **built-in** · DNS stack names | `--https`, `--domain`, `--dns-host` |
| Apps | **office, photos, vault, pdf, obsidian** · ml (smart search) | `--apps` |
| Other names you open it with | addresses found automatically (LAN, Tailscale, hostname) | `--trusted` |

### When it finishes

It checks every app: Nextcloud over HTTPS and its login, each address it accepts, the shared folders, Office connected, Immich's login, Vaultwarden, Stirling PDF, Obsidian's login, the certificate page and the nightly backup.

- **Vaultwarden:** create your account in its web vault with a master password only you know (the script can't, and shouldn't, know it). Then run **Lock sign-ups** so nobody else can make one.
- **Logins and links:** `/opt/sudohomelab/cloud/credentials.txt` (root only). **Logs:** `/var/log/sudohomelab/cloud-*.log`
- **Backups:** every night at 3:30 into `backups/`. Your files themselves aren't copied: back up `/srv/cloud` elsewhere too.
- **Re-running Install is safe:** it keeps your logins and data and changes only what you changed (switch HTTPS mode, add or remove apps).

### Unattended install

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --install --apps=office,photos,vault --https=caddy --yes
```

All options: `sudo bash cloud.sh --help`. Also `--install-dir`, `--dry-run`.

Tested on Ubuntu 26.04 (4 CPU, 8 GB): built-in mode, re-run, DNS mode against a DNS stack on another machine, uninstall keeping data, reinstall; Office opened in a browser, Notes shared by Nextcloud and Obsidian, both PDF drop folders, the Immich library.

## Proxmox VE 8 / 9

Run in the Proxmox host shell (root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Self_Hosted_Cloud/proxmox/cloud.sh)"
```

Same menu, questions and wiring. Install creates one unprivileged Debian container (`cloud`, tag `sudohomelab-cloud`, 4 cores, 8 GB RAM, 32 GB disk) with a fixed address, and runs the Ubuntu/Debian installer inside it.

- **Your files stay on the host** in `/srv/cloud` (`--data-dir=/your/big/storage`), and settings in `/opt/sudohomelab/cloud`, both mounted into the container. **Uninstall** can delete the container and keep them: Install again later brings everything back.
- **With the Private DNS Stack's container on the same host**, it's found on its own: the names point at the cloud container and are added for you. A full uninstall removes them again.

```bash
bash -c "$(curl -fsSL <url>)" _ --install --ip=192.168.1.95/24 --yes
bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge [--delete-files]]
```

Proxmox options: `--ctid`, `--storage`, `--bridge`, `--ip`, `--gateway`, `--cores`, `--memory`, `--disk`, `--data-dir`, `--settings-dir`. Every other option goes to the installer inside the container. The password reaches it as a root-only file, never as a command argument.

Tested on Proxmox VE 9.2 (nested test VM, Debian 13 container, next to a DNS stack container): DNS mode, re-run, lock sign-ups, back up, uninstall keeping data, reinstall, purge with files.

## TrueNAS SCALE 24.10+

In the TrueNAS shell (System → Shell, or SSH), download first and then run the file:

```bash
curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Self_Hosted_Cloud/truenas/cloud.sh -o /tmp/cloud.sh && sudo bash /tmp/cloud.sh
```

> Not `sudo bash -c "$(curl …)"`: TrueNAS turns on sudo's `log_subcmds`, and its sudo kills a command whose text is a whole script.

Same menu, questions and wiring. Nothing is installed on the TrueNAS OS:

- Everything runs as one **Custom App** called `cloud`, with settings and databases in the dataset `<pool>/apps/cloud` (`--pool=NAME`).
- **Your files get their own dataset**, `<pool>/cloud`: snapshot it, replicate it or share it over SMB like any other.
- Built-in HTTPS on a NAS whose 443 / 80 are taken (by the TrueNAS web interface or the DNS stack's proxy): Nextcloud moves to the next free port (e.g. `https://<nas-ip>:8445`) and the certificate page to 8880. The summary shows the real addresses.
- The nightly backup is a TrueNAS cron job (System → Advanced → Cron Jobs). Passwords never go on a command line or in the app's settings page.
- With the Private DNS Stack on the same NAS, the names are added to it.
- **Uninstall** removes the app and the cron job, and keeps both datasets, or deletes them too.

Tested on TrueNAS SCALE 25.10 (test VM, next to the DNS stack): DNS mode, built-in mode, uninstall keeping data, reinstall, purge with files; the app's settings checked for leaked passwords.

## Layout

```
Self_Hosted_Cloud/
  linux/cloud.sh      the installer (Ubuntu / Debian), also the core the others load
  proxmox/cloud.sh    Proxmox VE: container + host folders + DNS names
  truenas/cloud.sh    TrueNAS SCALE: Custom App + datasets
```
