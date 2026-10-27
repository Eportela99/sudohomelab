# Monitoring & Management

Know what's up, what's down and what's eating your RAM.

| App | What it does | Platform | Status |
| --- | --- | --- | --- |
| **Monitoring Stack:** Uptime Kuma + Beszel + ntfy | Uptime checks for every app it finds, CPU/RAM/disk metrics for all your machines, and alerts on your phone | Ubuntu / Debian: [`linux/monitoring.sh`](linux/monitoring.sh)<br>Proxmox VE 8 / 9: [`proxmox/monitoring.sh`](proxmox/monitoring.sh)<br>TrueNAS SCALE 24.10+: [`truenas/monitoring.sh`](truenas/monitoring.sh) | 🧪 Beta |
| **Beszel agent** (for your other machines) | Adds another computer to the stack's Beszel | Ubuntu / Debian (any Linux with systemd or Docker): [`linux/beszel-agent.sh`](linux/beszel-agent.sh)<br>TrueNAS SCALE 24.10+: [`truenas/beszel-agent.sh`](truenas/beszel-agent.sh) | 🧪 Beta |
| Dozzle, Portainer | Live container logs, container management | Extras in the Monitoring Stack script | 🧪 Beta |

## Monitoring Stack (Ubuntu / Debian)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/linux/monitoring.sh)"
```

> Use this `sudo bash -c "$(curl …)"` form, not `curl … | sudo bash`, so the script can ask you questions.

Run it and pick what to do:

```
  What would you like to do?
    1) Install        Uptime Kuma + Beszel + ntfy, connected, then pick what to watch
    2) Add a machine  show the command that adds another computer to Beszel
    3) Re-scan apps   look for new apps on this machine and update Uptime Kuma's monitors
    4) Uninstall      remove the apps (asks whether to keep the data)
    5) Quit           close the menu
```

After each action, press Enter to go back to the menu, or `q` to quit.

Or skip the menu with an action:

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --install
sudo bash -c "$(curl -fsSL <url>)" _ --agent-cmd          # the add-a-machine command
sudo bash -c "$(curl -fsSL <url>)" _ --sync               # re-scan apps
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall          # keeps data
sudo bash -c "$(curl -fsSL <url>)" _ --uninstall --purge  # deletes it too
```

### What gets installed

| Piece | Job | Port |
| --- | --- | --- |
| **Uptime Kuma 2** | Checks each app every minute (its web page, port or DNS answer) and tells ntfy when one goes down or comes back. | 3001 |
| **Beszel** (hub + this machine's agent) | CPU, RAM, disks, network, temperatures and each container's use, for this machine and any you add. Default alerts: down, and CPU / RAM / disk over 90% for 10 minutes. | 8090 |
| **ntfy** | Gets every alert and pushes it to your phone. Nobody can read or post without logging in; the alerts use a publish-only account. | 2586 |
| Dozzle *(extra)* | Live logs of every container, with the same login. | 8888 |
| Portainer *(extra)* | Manage containers, images and volumes, with the same login. | 9443 |

```
your apps ◄── Uptime Kuma checks them ──┐
                                        ├──► ntfy ──► your phone
this machine + others ── Beszel agents ─┘
       (CPU, RAM, disk, containers)
```

### What it watches

Install looks at what runs on the machine and offers each one as an Uptime Kuma monitor. Known apps are on by default:

- every container, by its published port, with the right health page for well-known apps (Jellyfin, Plex, the *arr apps, qBittorrent, SABnzbd, Seerr, Tdarr, Audiobookshelf, Komga, Pi-hole, Nginx Proxy Manager, Home Assistant, Immich, Nextcloud…);
- our other stacks ([Media_Stack](../Media_Stack), [AdBlock_DNS_Proxy](../AdBlock_DNS_Proxy)), including Pi-hole's DNS answer;
- services on the machine itself: SSH, SMB file sharing, CasaOS, Cockpit, Plex;
- this stack's own apps.

A stopped container keeps its monitor and shows as down, so a crash gets an alert instead of a silently missing monitor. Monitors the script made carry the tag `sudohomelab`: re-runs only add, change or remove those, never the ones you made yourself. **Re-scan apps** picks up apps you installed later.

### Alerts on your phone

1. Install the **ntfy** app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy), [iOS](https://apps.apple.com/app/ntfy/id1625396347)).
2. Settings → add a server: `http://<server-ip>:2586`, with your login.
3. Subscribe to the topic **exactly** as the script shows it (default `homelab-alerts`). A welcome message is waiting there. The summary also shows a QR code and a browser link.

Your own scripts can post too: the summary shows a `curl` line with the publish token.

### Add another machine to Beszel

**Add a machine** prints one command to run on the other computer, with the hub address, key and token filled in:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/linux/beszel-agent.sh)" _ --hub=http://192.168.1.50:8090 --key='ssh-ed25519 …' --token=…
```

Or run `beszel-agent.sh` with no options there: it asks for the hub address and your Beszel login, gets the key and token itself, waits until the machine shows up and gives it the default alerts.

- With Docker on that machine, the agent runs as a container (Docker stats included); without, as a system service from Beszel's official installer, updating itself daily. `--mode=docker|service` picks one.
- A machine that runs its own Monitoring Stack can report to another hub too: the two agents don't get in each other's way.
- `beszel-agent.sh --uninstall` removes it. The machine stays listed in the hub until you delete it there.

**A TrueNAS SCALE** box joins as a TrueNAS app (the menu shows this line too). In its shell:

```bash
curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/truenas/beszel-agent.sh -o /tmp/beszel-agent.sh && sudo bash /tmp/beszel-agent.sh --hub=http://192.168.1.50:8090
```

It asks for your Beszel login and installs the agent as a Custom App called `beszel-agent`, with its data in `<pool>/apps/beszel-agent`. The key and token are read from files there, so the token doesn't show in the app's settings. TrueNAS's sudo logs every command line, so give the token with `--token-file` rather than `--token=` (or just log in). Docker stats for every TrueNAS app are included; pool space is left to TrueNAS's own alerts. `--uninstall` removes the app, `--uninstall --purge` the dataset too.

### What it asks while installing

Every question has a default (press Enter), and each one has a flag for unattended installs.

| Question | Choices (default **bold**) | Flag |
| --- | --- | --- |
| Login for every app | **admin** | `--username` |
| Password (at least 12 characters) | **generate one**, or type your own | `--password`, `--password-file` |
| Beszel login (an email) | **`<username>@homelab.local`** | `--email` |
| Extras | Dozzle · Portainer (none by default) | `--extras` |
| Apps to watch | **known apps** · every container · none (a checklist) | `--monitor` |

The ntfy topic is `homelab-alerts` (`--topic` changes it). Every port is checked first: if one is taken, it offers the next free one.

### When it finishes

It checks that everything works: ntfy healthy and refusing anonymous messages, the publish token, your ntfy login, Beszel's login and that this machine reports in, Uptime Kuma's login and that none of its monitors is down. A test alert goes to ntfy once (re-runs don't buzz your phone again).

- **Logins, links and the add-a-machine command:** saved in `/opt/sudohomelab/monitoring/credentials.txt` (root only)
- **Logs:** `/var/log/sudohomelab/monitoring-*.log`
- **Re-running Install is safe:** it keeps your logins, tokens, monitors and history, and changes only what you changed.

### Unattended install

```bash
sudo bash -c "$(curl -fsSL <url>)" _ --install --extras=dozzle --yes
```

All options: `sudo bash monitoring.sh --help`. Also `--install-dir`, `--dry-run`.

Tested on Ubuntu 26.04 with the full media stack and CasaOS on the same machine, including a real alert (an app stopped → "Down" on the phone, restarted → "Up").

## Proxmox VE 8 / 9

Run in the Proxmox host shell (root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/proxmox/monitoring.sh)"
```

Same menu. Install creates one small unprivileged Debian container (`monitoring`, tag `sudohomelab-monitoring`, 2 cores, 1.5 GB RAM, 10 GB disk) and runs the Ubuntu/Debian installer inside it, so the questions and wiring are the same. On top of that:

- **A fixed address.** Agents on other machines and your phone connect to it, so it shouldn't change. It suggests a free one in the host's network and checks that nothing answers on the address you type. `dhcp` works too, but then reserve the address in the router.
- **Your other guests:** Uptime Kuma pings every container and VM (VMs need qemu-guest-agent for their address), watches the apps it finds inside each running container (media stack, Pi-hole, anything in Docker) and the Proxmox web page. A stopped guest keeps its checks and shows as down.
- **The Beszel agent goes on the Proxmox host itself** (a system service), so Beszel shows the real host: CPU, RAM, disks, temperatures. If the host already reports to another hub, it asks before moving it.

The settings live on the host in `/opt/sudohomelab/monitoring` (mounted into the container), so **Uninstall** can delete the container and keep them: Install again later brings the same logins, monitors and history back. **Re-scan apps** also looks for new guests.

```bash
bash -c "$(curl -fsSL <url>)" _ --install --ip=192.168.1.90/24 --yes
bash -c "$(curl -fsSL <url>)" _ --sync
bash -c "$(curl -fsSL <url>)" _ --uninstall [--purge]
```

Proxmox options: `--ctid`, `--storage`, `--bridge`, `--ip`, `--gateway`, `--cores`, `--memory`, `--disk`, `--host-agent` / `--no-host-agent`, `--settings-dir`. Every other option goes to the installer inside the container. Passwords reach it as root-only files, never as command arguments.

Shell into it with `pct enter <id>`; the compose project is in `/opt/sudohomelab/monitoring`. Back it up with Datacenter → Backup (or `vzdump <id> --mode snapshot`).

Tested on Proxmox VE 9.2 (nested test VM, Debian 13 container, with a media stack and a Pi-hole container next to it): fresh install, re-run, a guest stopped and started, the host agent moved over from another hub, uninstall keeping data, reinstall, purge.

## TrueNAS SCALE 24.10+

In the TrueNAS shell (System → Shell, or SSH), download first and then run the file:

```bash
curl -fsSL https://raw.githubusercontent.com/Eportela99/sudohomelab/main/Monitoring_Management/truenas/monitoring.sh -o /tmp/monitoring.sh && sudo bash /tmp/monitoring.sh
```

> Not `sudo bash -c "$(curl …)"`: TrueNAS turns on sudo's `log_subcmds`, and its sudo kills a command whose text is a whole script.

Same menu, questions and wiring. Nothing is installed on the TrueNAS OS:

- Everything runs as one **Custom App** called `monitoring` (Apps page), with its settings in the dataset `<pool>/apps/monitoring` (asked when there's more than one pool; `--pool=NAME`).
- Uptime Kuma watches **every TrueNAS app** (catalog or custom) and the TrueNAS web page, wherever its port is. A stopped app keeps its monitor and shows as down.
- The NAS's Beszel agent reads its key and token from files in the dataset, so they don't show in the app's settings page. TrueNAS already alerts on pool space itself, so the agent shows the boot pool, CPU, RAM, network and temperatures.
- Passwords and tokens never go on a command line (TrueNAS's sudo logs every one).
- **Uninstall** removes the app and keeps the dataset, or deletes it too.

Tested on TrueNAS SCALE 25.10 (test VM, with the media stack's 11 catalog apps and the DNS stack running): fresh install, re-run, a stopped app, adding a Linux machine both ways, uninstall keeping data, reinstall, purge; TrueNAS's journal and the app's settings checked for leaked secrets. The TrueNAS agent was tested on the same VM against a hub on Ubuntu: login and key + token-file, re-run, refusing its own Monitoring Stack's hub, uninstall keeping data, reinstall, purge.

## Layout

```
Monitoring_Management/
  linux/monitoring.sh      the installer (Ubuntu / Debian), also the core the others load
  linux/beszel-agent.sh    the agent for your other machines
  truenas/beszel-agent.sh  the agent for a TrueNAS box (TrueNAS app)
  proxmox/monitoring.sh    Proxmox VE: container + host agent + guest checks
  truenas/monitoring.sh    TrueNAS SCALE: Custom App
```
