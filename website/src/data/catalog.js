// The whole site is driven from this file. Each category is a folder in the repo,
// scripts live at <folder>/<platform>/<script>.<ext> (e.g. Media_Stack/linux/media-stack.sh).
// Adding an app here adds it to the
// category page, the search palette and the advisor's recommendations.
//
// status: 'planned' | 'beta' | 'ready'
// icon:   slug from https://github.com/homarr-labs/dashboard-icons (falls back to a monogram)
// min:    rough minimum resources, used by the advisor  { ram: GB, cpu: cores, gpu?: bool }

const ALL = ['proxmox', 'linux', 'truenas', 'windows', 'macos']
const SERVER = ['proxmox', 'linux', 'truenas']

// Shared by Pi-hole, Unbound and Nginx Proxy Manager: one script installs all three.
const DNS_UNINSTALL = {
  uninstall: 'Removes Pi-hole, Unbound and the proxy and gives port 53 back to your system (on Proxmox: deletes its container; on TrueNAS: moves the web interface back to 80/443). Keeps your settings, lists, app names and certificates.',
  purge: 'Removes Pi-hole, Unbound and the proxy and deletes their settings, lists, app names, certificates and query history.',
  safe: 'Point your router\'s DNS somewhere else first.',
}
const DNS_DOCS = [
  {
    title: 'What the script does',
    text: 'One script installs Pi-hole v6, Unbound and Nginx Proxy Manager in Docker and connects them. Run it again any time for a menu: Install, List domains, Add domain, Delete domain, Uninstall. After each one it goes back to the menu until you pick Quit.',
    items: [
      'Checks port 53 first. If systemd-resolved holds it, it turns off only the DNS stub and keeps the host resolving. Other DNS servers are shown to you before anything is stopped.',
      'Pi-hole blocks ads with curated HaGeZi lists; Unbound looks sites up privately with DNSSEC.',
      'Nginx Proxy Manager gives apps names like https://jellyfin.home. Pi-hole\'s admin page moves to port 8080 (and https://pihole.home).',
      'Every port is checked: if something has 80 (CasaOS, a web server) it offers another one.',
    ],
  },
  {
    title: 'App names (domains)',
    text: 'Add domain asks for the address you use now (192.168.1.50:8096) and a name (jellyfin). It works out HTTP or HTTPS, creates the route and certificate, adds the DNS record and checks the name opens.',
    items: [
      '`--add=jellyfin=192.168.1.50:8096` · `--delete=jellyfin` · `--list`',
      '`localhost:PORT` means an app on the same server; any LAN address works too (NAS, Proxmox, router).',
      'Your IP:port addresses keep working: names are an extra way in.',
    ],
  },
  {
    title: 'Certificates',
    text: 'Default: the server makes its own certificate authority, limited to your ending (*.home), so trusting it can\'t be misused for other sites. Install it once per device from http://proxy.home/ca.crt. With your own domain on Cloudflare, it can get a Let\'s Encrypt wildcard instead (trusted everywhere).',
  },
  {
    title: 'Over Tailscale',
    text: 'Choose "Any network" at install. Pi-hole answers the same name with the LAN address at home and the Tailscale address over Tailscale. In the Tailscale admin console, add the server\'s Tailscale IP as a nameserver: restrict it to your ending for just the names (split DNS), or override DNS for ad blocking everywhere.',
  },
  {
    title: 'On Proxmox',
    text: 'Run it in the Proxmox host shell. It creates a small Debian container (2 cores, 1 GB RAM, 8 GB disk) with a fixed IP, since your devices use it as their DNS server, and runs the same installer inside it. It suggests a free address and checks nothing else uses it.',
    items: [
      'Optional Tailscale in the container: it joins your tailnet as pihole, with an auth key or a login link.',
      'Settings stay on the host in /opt/sudohomelab/pihole, so uninstalling can keep them and a reinstall comes back on the same address.',
      '`--ip=192.168.1.53/24` · `--tailscale` · `--tailscale-key-file=FILE` · `--storage` · `--ctid`',
    ],
  },
  {
    title: 'On TrueNAS',
    text: 'One Custom App (pihole) with its settings in a <pool>/apps/pihole dataset. TrueNAS\'s web interface uses ports 80/443, which the app names need, so it offers to move it to 8000/8443, checks TrueNAS answers there and moves it back if not. Uninstall puts it back on 80/443.',
    items: [
      'TrueNAS is then at https://<nas-ip>:8443 and https://truenas.home.',
      'Choose Keep it (`--keep-ui`) and the app names use other ports instead (https://jellyfin.home:8443).',
      'The daily blocklist update is a TrueNAS cron job. Port 53 must be free (it won\'t stop other apps for you).',
    ],
  },
  {
    title: 'Choices while installing',
    items: [
      '`--password` one password for Pi-hole and the proxy: generated, or type your own',
      '`--blocklists` Light · Balanced (default) · Aggressive · Classic, plus `--extras` and `--allowlists`',
      '`--upstream` Unbound (default) · Cloudflare · Quad9 · Google · your own IPs',
      '`--dns-access` Local network, or any network (Tailscale, WireGuard)',
      '`--domain` home (default), lan, home.arpa, or your own domain',
      '`--cert` local (default) or letsencrypt with `--cloudflare-token` and `--email`',
      '`--device-names`, `--refresh` daily (default) or weekly',
    ],
  },
  {
    title: 'Troubleshooting',
    items: [
      'Logs: `/var/log/sudohomelab/pihole-*.log`; passwords in `/opt/sudohomelab/pihole/credentials.txt`',
      'A name shows 502? The app isn\'t answering on that address: check it\'s running.',
      'Browser warning? Install the certificate from http://proxy.<ending>/ca.crt on that device.',
      'Preview without changing anything: add `--dry-run`. All options: `--help`',
    ],
  },
]

// Shared by the Monitoring Stack's apps: one script installs them together.
const MON_AVAILABLE = ['linux', 'proxmox', 'truenas']
const MON_UNINSTALL = {
  uninstall: 'Removes Uptime Kuma, Beszel (hub and this machine\'s agent), ntfy and the extras (on Proxmox: deletes its container and the host\'s agent; on TrueNAS: removes the app). Keeps your monitors, history, logins and tokens for a reinstall.',
  purge: 'Removes the apps and deletes all monitors, history, accounts and tokens.',
  safe: 'Agents on other machines keep running with no hub to report to: remove them with beszel-agent.sh --uninstall.',
}
const MON_DOCS = [
  {
    title: 'What the script does',
    text: 'One script installs Uptime Kuma, Beszel and ntfy in Docker and connects them, so alerts reach your phone without setting anything up by hand. Run it again any time for a menu: Install, Add a machine, Re-scan apps, Uninstall.',
    items: [
      'Asks for one login (or makes one up) and uses it for all three apps. Beszel logs in with an email address.',
      'Finds the apps on the machine (containers, our other stacks, Plex, SSH, SMB, CasaOS, Cockpit) and offers each as an Uptime Kuma monitor. Known apps are on by default.',
      'Uptime Kuma and Beszel alerts go to ntfy, which only accepts messages from logged-in users. Alerts: down, CPU, RAM and disk over 90% for 10 minutes.',
      'Monitors the script made carry the tag sudohomelab. Re-runs only change those, never the ones you made.',
      'Extras: Dozzle (live container logs) and Portainer (container management), with the same login.',
    ],
  },
  {
    title: 'Alerts on your phone',
    items: [
      'Install the ntfy app (Android, iOS) and add a server: http://<server-ip>:2586, with your login.',
      'Subscribe to the topic exactly as the script shows it (default homelab-alerts). A test message waits there.',
      'Your own scripts can post too: the summary shows a curl line with the publish token.',
    ],
  },
  {
    title: 'Add another machine to Beszel',
    text: 'Pick Add a machine in the menu. It prints one command to run on the other computer (Linux), with the hub address, key and token filled in.',
    items: [
      'Or run beszel-agent.sh with no options on the other machine: it asks for the hub address and your Beszel login, and gets the key and token itself.',
      'With Docker there it runs as a container (Docker stats included); without, as a system service that updates itself daily.',
      'A TrueNAS box joins as a TrueNAS app: run truenas/beszel-agent.sh in its shell (the menu shows the line) and log in.',
      'Re-scan apps gives every new machine the default alerts.',
    ],
  },
  {
    title: 'Proxmox & TrueNAS',
    items: [
      'Proxmox: creates one small unprivileged container with a fixed address. Uptime Kuma also pings every container and VM, watches the apps inside running containers and the Proxmox page, and the Beszel agent goes on the host itself.',
      'TrueNAS: one Custom App with its settings in <pool>/apps/monitoring. Uptime Kuma watches every TrueNAS app and the TrueNAS page; a stopped app keeps its monitor and shows as down.',
    ],
  },
]

// Shared by the Cloud Stack's apps: one script installs them together.
const CLOUD_AVAILABLE = ['linux', 'proxmox', 'truenas']
const CLOUD_UNINSTALL = {
  uninstall: 'Removes Nextcloud and the other apps (on Proxmox: deletes its container; on TrueNAS: removes the app). Keeps settings, databases and your files, so reinstalling brings it all back.',
  purge: 'Removes the apps and deletes their settings and databases: calendars, contacts, Immich albums, your vault. Your files (Documents, Notes, Photos) stay unless you also add --delete-files.',
  safe: 'Your files are only deleted with --delete-files, after typing DELETE.',
}
const CLOUD_DOCS = [
  {
    title: 'What the script does',
    text: 'One script installs Nextcloud, Collabora, Immich, Vaultwarden, Stirling PDF and Obsidian in Docker and connects them to one folder tree. Run it again any time for a menu: Install, Lock sign-ups, Back up now, Uninstall.',
    items: [
      'Asks for one login (or makes one up) for Nextcloud, Immich, Stirling PDF and Obsidian. Immich logs in with an email address.',
      'Nextcloud comes with Postgres, Redis, a cron container and the Calendar, Tasks, Contacts, Mail, Deck, Collectives, News, Notes and Office apps.',
      'Office opens Word, Excel and PowerPoint files inside Nextcloud through Collabora.',
      'Pick the apps you want: Office, Immich (+ optional smart search), Vaultwarden, Stirling PDF, Obsidian. It checks RAM and disk for your choice first (all of them download about 21 GB).',
      'When it finishes it checks every app: logins, Office connected, the shared folders, the nightly backup.',
    ],
  },
  {
    title: 'One folder tree for every app',
    items: [
      '`/srv/cloud/Documents`: a Nextcloud folder. With Stirling PDF, PDFs dropped in `PDF Inbox/OCR` (searchable text) or `PDF Inbox/Compress` come out in `PDF Done`.',
      '`/srv/cloud/Notes`: Nextcloud Notes and the Obsidian vault are the same folder.',
      '`/srv/cloud/Photos`: a Nextcloud folder that Immich also shows as a library.',
      '`/srv/cloud/backups`: nightly database dumps and Vaultwarden, the last 7 of each.',
      'App settings and databases live apart, in `/opt/sudohomelab/cloud`. `--data-dir` puts your files on another disk.',
    ],
  },
  {
    title: 'HTTPS: two ways',
    items: [
      'Built-in (default): a small proxy with its own certificate, made only for addresses in your home network and Tailscale. Each app gets an HTTPS port (Nextcloud 443, Immich 2283, Vaultwarden 8222, Stirling PDF 8484, Obsidian 3443).',
      'Trust the certificate once per device: open http://<server-ip>/ for the file and the steps for iPhone, Android, Windows, macOS and Linux.',
      'With the Private DNS Stack: names like https://cloud.home, office, photos, vault, pdf and notes. It finds the DNS stack on the same machine (or asks for its address) and adds the names itself.',
    ],
  },
  {
    title: 'After installing',
    items: [
      'Vaultwarden: create your account in the web vault with a master password only you know (the script can\'t do it for you). Then pick Lock sign-ups so nobody else can.',
      'Phones: the Nextcloud, Immich and Bitwarden apps log in with the address the summary shows.',
      'Logins and links are saved in `/opt/sudohomelab/cloud/credentials.txt` (root only).',
    ],
  },
  {
    title: 'Proxmox & TrueNAS',
    items: [
      'Proxmox: one unprivileged Debian container (4 cores, 8 GB, 32 GB disk by default) with a fixed address. Your files stay on the host in /srv/cloud (`--data-dir` for your big storage) and settings in /opt/sudohomelab/cloud, so the container can be deleted and rebuilt. With the DNS stack container on the host, the names are added to it.',
      'TrueNAS: one Custom App ("cloud"), settings in the dataset <pool>/apps/cloud and your files in their own dataset <pool>/cloud (snapshot or share it like any other). The nightly backup is a TrueNAS cron job.',
    ],
  },
  {
    title: 'Troubleshooting',
    items: [
      'Logs: `/var/log/sudohomelab/cloud-*.log`',
      'Browser warning? Trust the certificate from http://<server-ip>/ on that device, then restart the browser.',
      'Office doesn\'t open? Open Nextcloud by an address the script knows (`--trusted` adds more), then re-run Install.',
      'Preview without changing anything: add `--dry-run`. All options: `--help`',
    ],
  },
]

export const CATEGORIES = [
  {
    id: 'media',
    folder: 'Media_Stack',   // repo folder: Media_Stack/<platform>/<script>
    name: 'Media Stack',
    tagline: 'Stream, request and automate your whole library.',
    description:
      'Media servers, request portals and the *arr automation suite. Install any piece on its own, or deploy the full stack with every app already talking to each other.',
    accent: '#ff9f43',
    glyph: '▶',
    apps: [
      { id: 'plex', name: 'Plex', icon: 'plex', desc: 'Polished media server with apps on every device.', ports: [32400], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['streaming', 'transcoding'] },
      { id: 'jellyfin', name: 'Jellyfin', icon: 'jellyfin', desc: 'Free and open-source media server. No accounts, no tracking.', ports: [8096], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['streaming', 'foss'] },
      { id: 'seerr', name: 'Seerr', icon: 'jellyseerr', desc: 'Request portal for movies & shows (Overseerr / Jellyseerr).', ports: [5055], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['requests'] },
      { id: 'radarr', name: 'Radarr', icon: 'radarr', desc: 'Finds, grabs and organizes movies automatically.', ports: [7878], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['arr', 'movies'] },
      { id: 'sonarr', name: 'Sonarr', icon: 'sonarr', desc: 'Same as Radarr, for TV series and anime.', ports: [8989], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['arr', 'tv'] },
      { id: 'lidarr', name: 'Lidarr', icon: 'lidarr', desc: 'Music collection manager for the *arr suite.', ports: [8686], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['arr', 'music'] },
      { id: 'prowlarr', name: 'Prowlarr', icon: 'prowlarr', desc: 'One indexer manager that syncs to every *arr app.', ports: [9696], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['arr', 'indexers'] },
      { id: 'flaresolverr', name: 'FlareSolverr', icon: 'flaresolverr', desc: 'Proxy that gets Prowlarr past Cloudflare challenges.', ports: [8191], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['arr', 'helper'] },
      { id: 'qbittorrent', name: 'qBittorrent', icon: 'qbittorrent', desc: 'Torrent client with a clean web UI.', ports: [8080], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['downloader'] },
      { id: 'sabnzbd', name: 'SABnzbd', icon: 'sabnzbd', desc: 'Usenet downloader: fast, automatic, reliable.', ports: [8085], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['downloader', 'usenet'] },
      { id: 'bazarr', name: 'Bazarr', icon: 'bazarr', desc: 'Downloads subtitles for everything Radarr & Sonarr grab.', ports: [6767], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['arr', 'subtitles'] },
      { id: 'tdarr', name: 'Tdarr', icon: 'tdarr', desc: 'Distributed transcoding to shrink and normalize your library.', ports: [8265], platforms: ALL, min: { ram: 4, cpu: 4, gpu: true }, tags: ['transcoding'] },
      { id: 'dispatcharr', name: 'Dispatcharr', icon: 'dispatcharr', desc: 'IPTV stream & EPG manager that feeds Plex / Jellyfin live TV.', ports: [9191], platforms: ALL, min: { ram: 1, cpu: 2 }, tags: ['iptv', 'live-tv'] },
    ],
    stack: {
      id: 'media-stack',
      name: 'The Media Stack',
      available: ['linux', 'truenas'],
      pitch: 'One command. Every app installed, API keys exchanged, download clients, indexers and root folders already connected.',
      options: [
        { key: 'server', label: 'Media server', type: 'one', choices: ['plex', 'jellyfin'], default: 'jellyfin' },
        { key: 'downloader', label: 'Download client', type: 'many', choices: ['qbittorrent', 'sabnzbd'], default: ['qbittorrent'] },
        { key: 'extras', label: 'Extras', type: 'many', choices: ['lidarr', 'bazarr', 'tdarr', 'audiobookshelf', 'komga'], default: [] },
      ],
      core: ['seerr', 'radarr', 'sonarr', 'prowlarr'],
      // "How it works" walk-through shown under the stack builder.
      guide: {
        intro: 'Each app does one job and hands the result to the next. The installer exchanges the API keys and fills in every address, so the whole chain runs on its own from the first request.',
        steps: [
          { title: 'Request', apps: ['seerr'], text: 'You (or anyone you share it with) search for a movie or show in Seerr and press Request. Seerr signs people in with their Jellyfin or Plex account and passes movies to Radarr and series to Sonarr.' },
          { title: 'Search', apps: ['prowlarr'], text: 'Radarr and Sonarr search your indexers through Prowlarr. You add an indexer once in Prowlarr and it syncs to Radarr, Sonarr and Lidarr automatically.' },
          { title: 'Grab', apps: ['radarr', 'sonarr'], text: 'Radarr (movies) and Sonarr (TV) pick the best release for your quality settings and send it to your download client, tagged with a category so each app later finds its own downloads.' },
          { title: 'Download', apps: ['qbittorrent', 'sabnzbd'], text: 'qBittorrent (torrents) and/or SABnzbd (Usenet) download into Active_Downloads. Both share one login with the *arr apps.' },
          { title: 'Import', apps: ['radarr', 'sonarr'], text: 'When a download finishes, Radarr or Sonarr renames it and puts it in Movies or TV_Shows. Everything sits under one /data folder, so this is an instant hardlink: no copy, no double disk space, and torrents keep seeding.' },
          { title: 'Watch', apps: ['jellyfin', 'plex'], text: 'Jellyfin or Plex reads the same Movies and TV_Shows folders, so the new title shows up in your library, and Seerr marks the request as available.' },
          { title: 'Extras', apps: ['bazarr', 'lidarr', 'tdarr', 'audiobookshelf', 'komga'], text: 'Bazarr watches Radarr and Sonarr and downloads subtitles in your languages. Lidarr runs the same flow for music into Music. Tdarr can re-encode your library to save space (off until you choose a Flow). Audiobookshelf and Komga (Linux and TrueNAS) are readers: they get their own Audiobooks and Books folders, ready for you to fill.' },
        ],
        folders: [
          ['/data', 'one data folder (default /srv/media), mounted in every container'],
          ['├─ Active_Downloads', 'qBittorrent / SABnzbd download here'],
          ['├─ Movies', 'Radarr imports → Jellyfin / Plex'],
          ['├─ TV_Shows', 'Sonarr imports → Jellyfin / Plex'],
          ['├─ Music', 'Lidarr imports (extra)'],
          ['├─ Audiobooks', 'Audiobookshelf library (extra)'],
          ['└─ Books', 'Komga: Comics, Ebooks, Manga (extra)'],
          ['\\\\server\\Media', 'optional SMB share of the whole folder, same login (Linux, Proxmox: --smb)'],
        ],
        left: 'Left for you: add indexers in Prowlarr, create your Jellyfin/Plex account and libraries, and sign in to Seerr.',
      },
      // Wiring diagram: [from, to, label]
      wires: [
        ['seerr', 'radarr', 'requests'],
        ['seerr', 'sonarr', 'requests'],
        ['prowlarr', 'radarr', 'indexers'],
        ['prowlarr', 'sonarr', 'indexers'],
        ['radarr', '$downloader', 'grabs'],
        ['sonarr', '$downloader', 'grabs'],
        ['$downloader', '$server', 'library'],
        ['seerr', '$server', 'auth'],
        ['prowlarr', 'lidarr', 'indexers'],
        ['lidarr', '$downloader', 'grabs'],
        ['flaresolverr', 'prowlarr', 'proxy'],
        ['bazarr', 'radarr', 'subs'],
        ['bazarr', 'sonarr', 'subs'],
        ['tdarr', '$server', 'transcodes'],
        ['lidarr', '$server', 'music'],
        ['dispatcharr', '$server', 'live TV'],
      ],
    },
  },
  {
    id: 'dashboards',
    folder: 'Dashboards',   // repo folder: Dashboards/<platform>/<script>
    name: 'Dashboards',
    tagline: 'One pane of glass for your entire lab.',
    description: 'Start pages that show every service, its status and its stats at a glance.',
    accent: '#57c7ff',
    glyph: '▦',
    apps: [
      {
        id: 'homarr', name: 'Homarr', icon: 'homarr', desc: 'Drag-and-drop dashboard with deep app integrations.', ports: [7575], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['dashboard'],
        status: 'official',
        official: {
          site: 'https://homarr.dev',
          docs: 'https://homarr.dev/docs/getting-started/installation/docker',
          note: 'Homarr\'s official Docker image. It keeps its encryption key in a file next to its data: Homarr needs the same key every time it starts.',
          how: {
            linux: { cmd: "sudo mkdir -p /opt/homarr && sudo test -f /opt/homarr/secret.key || openssl rand -hex 32 | sudo tee /opt/homarr/secret.key >/dev/null; sudo docker run -d --name homarr --restart unless-stopped -p 7575:7575 -v /var/run/docker.sock:/var/run/docker.sock -v /opt/homarr/appdata:/appdata -e SECRET_ENCRYPTION_KEY=$(sudo cat /opt/homarr/secret.key) ghcr.io/homarr-labs/homarr:latest" },
            proxmox: { cmd: 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/homarr.sh)"', note: 'The Proxmox VE Helper-Scripts (a community project) create a container with Homarr. Answer its questions, or take the defaults.' },
            truenas: { steps: ['Apps → Discover Apps → search "Homarr" (community train).', 'Install. The defaults are fine; pick where its data lives if asked.', 'Open it from Apps → Installed → Homarr → Web UI.'], note: 'From the TrueNAS app catalog: TrueNAS makes the encryption key and handles updates.' },
            windows: { cmd: "$f = \"$HOME\\homarr-secret.key\"; if (-not (Test-Path $f)) { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) | Set-Content $f }; docker run -d --name homarr --restart unless-stopped -p 7575:7575 -v homarr-appdata:/appdata -e \"SECRET_ENCRYPTION_KEY=$(Get-Content $f)\" ghcr.io/homarr-labs/homarr:latest" },
            macos: { cmd: 'mkdir -p ~/homarr && { [ -f ~/homarr/secret.key ] || openssl rand -hex 32 > ~/homarr/secret.key; } && docker run -d --name homarr --restart unless-stopped -p 7575:7575 -v ~/homarr/appdata:/appdata -e SECRET_ENCRYPTION_KEY=$(cat ~/homarr/secret.key) ghcr.io/homarr-labs/homarr:latest' },
          },
        },
        docs: [
          { title: 'What it is', text: 'A start page for your lab: a board of tiles for your apps, with live widgets (downloads, media, calendar, system stats) for the ones it integrates with. You build it by dragging tiles in the browser, no config files.' },
          {
            title: 'After installing',
            items: [
              'Open `http://<server-ip>:7575` and follow onboarding: create the admin account, then your first board.',
              'Add apps with Add → App: a name, the address you open it at, and an icon (it finds most icons by name).',
              'Integrations (Jellyfin, *arr apps, qBittorrent, Pi-hole…): Manage → Integrations, with the app\'s address and API key. Use an address the Homarr container can reach, like `http://192.168.1.50:8096`, not `localhost`.',
              'The Docker socket mount (Linux) lets Homarr show and start/stop your containers. Leave it out if you don\'t want that.',
            ],
          },
          {
            title: 'Updating',
            text: 'Pull the new image, remove the container and run the same install command again. Your boards live in the appdata folder and the key file stays, so nothing is lost: `sudo docker pull ghcr.io/homarr-labs/homarr:latest && sudo docker rm -f homarr`, then the install command. Back up the appdata folder before a major version (v1 → v2).',
          },
          {
            title: 'Uninstalling',
            items: [
              '`sudo docker rm -f homarr` removes Homarr and keeps its data in `/opt/homarr` (on Mac `~/homarr`, on Windows the `homarr-appdata` volume).',
              'To delete everything too: `sudo rm -rf /opt/homarr`.',
              'Proxmox: delete its container. TrueNAS: Apps → Homarr → Delete.',
            ],
          },
          { title: 'With the Private DNS Stack', text: 'Give it a name: run the DNS script → Add domain, or `--add=homarr=<server-ip>:7575`, then open https://homarr.home.' },
        ],
      },
      {
        id: 'homepage', name: 'Homepage', icon: 'homepage', desc: 'Fast, YAML-configured dashboard with 100+ service widgets.', ports: [3000], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['dashboard', 'yaml'],
        status: 'official',
        official: {
          site: 'https://gethomepage.dev',
          docs: 'https://gethomepage.dev/installation/docker/',
          note: 'Homepage\'s official Docker image. HOMEPAGE_ALLOWED_HOSTS must list every address you open it at (here: this machine\'s IP).',
          how: {
            linux: { cmd: "sudo docker run -d --name homepage --restart unless-stopped -p 3000:3000 -e HOMEPAGE_ALLOWED_HOSTS=$(hostname -I | awk '{print $1}'):3000 -v /opt/homepage/config:/app/config -v /var/run/docker.sock:/var/run/docker.sock:ro ghcr.io/gethomepage/homepage:latest" },
            proxmox: { cmd: 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/homepage.sh)"', note: 'The Proxmox VE Helper-Scripts (a community project) create a container with Homepage. Its config files are in /opt/homepage/config inside it.' },
            truenas: { steps: ['Apps → Discover Apps → search "Homepage" (community train).', 'Install. Set the allowed host to <nas-ip>:<the port it shows>.', 'Open it from Apps → Installed → Homepage → Web UI.'], note: 'From the TrueNAS app catalog.' },
            windows: { cmd: '$ip = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).IPv4Address.IPAddress; docker run -d --name homepage --restart unless-stopped -p 3000:3000 -e "HOMEPAGE_ALLOWED_HOSTS=${ip}:3000" -v "$HOME\\homepage\\config:/app/config" ghcr.io/gethomepage/homepage:latest' },
            macos: { cmd: 'docker run -d --name homepage --restart unless-stopped -p 3000:3000 -e HOMEPAGE_ALLOWED_HOSTS=$(ipconfig getifaddr en0):3000 -v ~/homepage/config:/app/config ghcr.io/gethomepage/homepage:latest' },
          },
        },
        docs: [
          { title: 'What it is', text: 'A fast, static start page set up with YAML files: your services in groups, each with a status dot and, for 100+ apps, a live widget (Jellyfin streams, Sonarr queue, Pi-hole blocked count…).' },
          {
            title: 'After installing',
            items: [
              'Open `http://<server-ip>:3000`. The first start writes example files to the config folder (`/opt/homepage/config` on Linux).',
              '`services.yaml` your apps · `widgets.yaml` the top bar (clock, search, CPU/RAM) · `settings.yaml` title, theme, layout · `bookmarks.yaml` links. Save a file and reload the page: no restart needed.',
              'A service with a widget: `- Jellyfin:` → `href: http://192.168.1.50:8096`, `widget: { type: jellyfin, url: http://192.168.1.50:8096, key: <api key> }`.',
              'Containers on this machine (Linux, socket mounted): add `my-docker: { socket: /var/run/docker.sock }` to `docker.yaml`, then `server: my-docker` and `container: <name>` on a service for its status and stats.',
            ],
          },
          {
            title: '"Host validation failed"',
            text: 'You opened it at an address that isn\'t in HOMEPAGE_ALLOWED_HOSTS (a new IP, or a name like homepage.home). Run it again with every address you use, comma-separated with no spaces, e.g. `-e HOMEPAGE_ALLOWED_HOSTS=192.168.1.50:3000,homepage.home`.',
          },
          {
            title: 'Updating & uninstalling',
            items: [
              'Update: `sudo docker pull ghcr.io/gethomepage/homepage:latest && sudo docker rm -f homepage`, then the install command again. Your YAML files stay.',
              'Uninstall: `sudo docker rm -f homepage` (keeps `/opt/homepage/config`); `sudo rm -rf /opt/homepage` deletes the config too.',
              'Proxmox: delete its container. TrueNAS: Apps → Homepage → Delete.',
            ],
          },
          { title: 'With the Private DNS Stack', text: 'Add a name with `--add=homepage=<server-ip>:3000`, and add `homepage.home` to HOMEPAGE_ALLOWED_HOSTS.' },
        ],
      },
      {
        id: 'casaos', name: 'CasaOS', icon: 'casaos', desc: 'Friendly home-cloud UI with a one-click app store.', ports: [80], platforms: ['proxmox', 'linux'], min: { ram: 1, cpu: 1 }, tags: ['dashboard', 'app-store'],
        status: 'official',
        official: {
          site: 'https://casaos.zimaspace.com',
          docs: 'https://github.com/IceWhaleTech/CasaOS',
          note: 'CasaOS\'s official installer. It installs Docker too if it\'s missing, and prints the address to open when it finishes.',
          how: {
            linux: { cmd: 'curl -fsSL https://get.casaos.io | sudo bash' },
            proxmox: { cmd: 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/casaos.sh)"', note: 'The Proxmox VE Helper-Scripts (a community project) create a container with CasaOS. Don\'t install CasaOS on the Proxmox host itself.' },
          },
        },
        docs: [
          { title: 'What it is', text: 'A friendly home-server desktop in the browser: a dashboard of your apps, a one-click App Store (Docker apps), a file manager and system stats. Good if you prefer clicking to the command line.' },
          {
            title: 'After installing',
            items: [
              'Open `http://<server-ip>` (port 80, or the next free port: the installer prints the address) and create your account.',
              'App Store: install apps with one click. They\'re normal Docker containers, so they show in `docker ps` too.',
              'Already running other Docker apps? Use Import in the App Store to show them as tiles.',
            ],
          },
          {
            title: 'Ports',
            text: 'CasaOS takes port 80. The Private DNS Stack\'s proxy wants 80 too: installed on the same machine, the DNS script sees CasaOS and offers another port for plain http (https on 443 keeps working). CasaOS\'s own port can be changed in its settings (WebUI port).',
          },
          {
            title: 'Updating & uninstalling',
            items: [
              'Update: CasaOS shows new versions in its settings; run the update from there.',
              'Uninstall: `casaos-uninstall` (it asks whether to also remove the apps and their data).',
              'Proxmox: delete its container.',
            ],
          },
        ],
      },
      { id: 'glance', name: 'Glance', icon: 'glance', desc: 'Minimal feed dashboard: RSS, weather, markets, releases.', ports: [8080], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['dashboard', 'feeds'] },
      { id: 'sudo-dash', name: 'sudo homelab Dash', icon: null, desc: 'Our own dashboard, auto-populated with every app you install from this site.', ports: [8000], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['original'], original: true },
    ],
  },
  {
    id: 'network',
    folder: 'AdBlock_DNS_Proxy',   // repo folder: AdBlock_DNS_Proxy/<platform>/<script>
    name: 'Ad-blocking, DNS & Proxy',
    tagline: 'Block ads network-wide and put every app behind a clean URL.',
    description: 'DNS sinkholes, recursive resolvers and reverse proxies with automatic HTTPS.',
    accent: '#ff5c8a',
    glyph: '⛨',
    apps: [
      {
        id: 'pihole', name: 'Pi-hole', icon: 'pi-hole', desc: 'Network-wide ad blocker and DNS server. Installs with Unbound and Nginx Proxy Manager, so apps get names like jellyfin.home.', ports: [53, 8080], platforms: SERVER, min: { ram: 1, cpu: 1 }, tags: ['dns', 'adblock', 'unbound', 'proxy'],
        status: 'beta',
        available: ['linux', 'proxmox', 'truenas'],
        uninstall: DNS_UNINSTALL,
        docs: DNS_DOCS,
      },
      { id: 'adguard', name: 'AdGuard Home', icon: 'adguard-home', desc: 'Modern ad blocker with DoH/DoT and per-client rules.', ports: [53, 3000], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['dns', 'adblock'] },
      { id: 'unbound', name: 'Unbound', icon: 'unbound', desc: 'Recursive DNS resolver, so no upstream provider sees your lookups.', ports: [5335], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['dns', 'privacy'],
        status: 'beta', available: ['linux', 'proxmox', 'truenas'], script: 'pihole', uninstall: DNS_UNINSTALL, docs: DNS_DOCS, note: 'Installed by the Private DNS Stack script, together with Pi-hole and Nginx Proxy Manager.' },
      { id: 'npm', name: 'Nginx Proxy Manager', icon: 'nginx-proxy-manager', desc: 'Reverse proxy with a GUI and free Let\'s Encrypt certificates.', ports: [80, 443, 81], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['proxy', 'ssl'],
        status: 'beta', available: ['linux', 'proxmox', 'truenas'], script: 'pihole', uninstall: DNS_UNINSTALL, docs: DNS_DOCS, note: 'Installed by the Private DNS Stack script, together with Pi-hole and Unbound.' },
      { id: 'caddy', name: 'Caddy', icon: 'caddy', desc: 'Zero-config reverse proxy with automatic HTTPS.', ports: [80, 443], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['proxy', 'ssl'] },
    ],
    stack: {
      id: 'dns-stack',
      name: 'Private DNS Stack',
      available: ['linux', 'proxmox', 'truenas'],
      script: 'pihole',        // AdBlock_DNS_Proxy/linux/pihole.sh installs the whole stack
      flags: false,            // its choices are asked while installing
      uninstall: DNS_UNINSTALL,
      pitch: 'Pi-hole blocking ads for every device, Unbound looking up sites privately, and Nginx Proxy Manager giving each app a name like https://jellyfin.home. Add names from the same script.',
      options: [
        { key: 'blocker', label: 'Ad blocker', type: 'one', choices: ['pihole'], default: 'pihole' },
        { key: 'proxy', label: 'Reverse proxy', type: 'one', choices: ['npm'], default: 'npm' },
      ],
      core: ['unbound'],
      guide: {
        intro: 'Three pieces, one job each. The script connects them, then gives you a menu to add, list and delete app names whenever you want.',
        steps: [
          { title: 'Ask', apps: ['pihole'], text: 'Every device asks Pi-hole for addresses (set it as the DNS server in your router). Ads and trackers get 0.0.0.0, so they never load.' },
          { title: 'Look up', apps: ['unbound'], text: 'Everything else goes to Unbound, which asks the internet\'s root servers directly and checks DNSSEC. No DNS company sees what you browse.' },
          { title: 'Name', apps: ['pihole'], text: 'For your app names (jellyfin.home), Pi-hole answers with this server\'s address: the LAN address at home, the Tailscale address over Tailscale.' },
          { title: 'Route', apps: ['npm'], text: 'Nginx Proxy Manager sees which name was asked for and passes the request to that app\'s IP and port, over HTTPS.' },
          { title: 'Add apps', apps: ['npm', 'pihole'], text: 'Run the script → Add domain → type the address (192.168.1.50:8096) and a name. It creates the route, the certificate and the DNS record, then checks it opens.' },
          { title: 'Anywhere', apps: ['pihole', 'npm'], text: 'With Tailscale, point your tailnet\'s DNS at the server (split DNS for just the names, or everything for ad blocking too). Same names away from home.' },
        ],
        folders: [
          ['https://pihole.home', 'Pi-hole admin (also http://<ip>:8080/admin)'],
          ['https://proxy.home', 'Nginx Proxy Manager admin (also http://<ip>:81)'],
          ['https://<app>.home', 'each app you add → its IP:port'],
          ['http://proxy.home/ca.crt', 'certificate to install once per device'],
        ],
        left: 'Left for you: set the server as the DNS server in your router, install the certificate on your devices (or use your own domain with Let\'s Encrypt), and add your apps.',
      },
      wires: [
        ['$blocker', 'unbound', 'upstream'],
        ['$proxy', '$blocker', 'local DNS'],
      ],
    },
  },
  {
    id: 'cloud',
    folder: 'Self_Hosted_Cloud',   // repo folder: Self_Hosted_Cloud/<platform>/<script>
    name: 'Self-Hosted Cloud',
    tagline: 'Your files, photos and passwords, on your hardware.',
    description: 'Replace Google Drive, Google Photos and password managers with apps you own.',
    accent: '#5af78e',
    glyph: '☁',
    apps: [
      { id: 'nextcloud', name: 'Nextcloud', icon: 'nextcloud', desc: 'Files, calendar, contacts, mail and Office in one place, with Postgres, Redis and cron pre-configured.', ports: [443], platforms: SERVER, min: { ram: 4, cpu: 2 }, tags: ['files', 'office', 'suite'], suite: true,
        status: 'beta', available: CLOUD_AVAILABLE, script: 'cloud', uninstall: CLOUD_UNINSTALL, docs: CLOUD_DOCS, note: 'Installed by the Cloud Stack script, with Calendar, Tasks, Contacts, Mail, Deck, Collectives, News, Notes and Office (Collabora).' },
      { id: 'immich', name: 'Immich', icon: 'immich', desc: 'Google Photos replacement: phone backup, albums, and optional face & object search.', ports: [2283], platforms: SERVER, min: { ram: 4, cpu: 2 }, tags: ['photos', 'ml'],
        status: 'beta', available: CLOUD_AVAILABLE, script: 'cloud', uninstall: CLOUD_UNINSTALL, docs: CLOUD_DOCS, note: 'Part of the Cloud Stack script. It also shows the Photos folder you see in Nextcloud.' },
      { id: 'vaultwarden', name: 'Vaultwarden', icon: 'vaultwarden', desc: 'Lightweight Bitwarden-compatible password server.', ports: [8222], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['passwords'],
        status: 'beta', available: CLOUD_AVAILABLE, script: 'cloud', uninstall: CLOUD_UNINSTALL, docs: CLOUD_DOCS, note: 'Part of the Cloud Stack script. You make your account yourself, then Lock sign-ups closes them.' },
      { id: 'stirling', name: 'Stirling PDF', icon: 'stirling-pdf', desc: 'Merge, split, OCR and compress PDFs in the browser.', ports: [8484], platforms: SERVER, min: { ram: 1, cpu: 1 }, tags: ['pdf', 'ocr'],
        status: 'beta', available: CLOUD_AVAILABLE, script: 'cloud', uninstall: CLOUD_UNINSTALL, docs: CLOUD_DOCS, note: 'Part of the Cloud Stack script, with drop folders in Documents that OCR or compress PDFs on their own.' },
      { id: 'obsidian', name: 'Obsidian', icon: 'obsidian', desc: 'The real Obsidian app, in your browser.', ports: [3443], platforms: SERVER, min: { ram: 1, cpu: 1 }, tags: ['notes'],
        status: 'beta', available: CLOUD_AVAILABLE, script: 'cloud', uninstall: CLOUD_UNINSTALL, docs: CLOUD_DOCS, note: 'Part of the Cloud Stack script, opened on the same Notes folder as Nextcloud Notes.' },
      { id: 'syncthing', name: 'Syncthing', icon: 'syncthing', desc: 'Peer-to-peer folder sync between all your devices.', ports: [8384], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['sync'] },
      { id: 'paperless', name: 'Paperless-ngx', icon: 'paperless-ngx', desc: 'Scan, OCR and search every document you own.', ports: [8000], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['documents', 'ocr'] },
    ],
    stack: {
      id: 'cloud-stack',
      name: 'Cloud Stack',
      available: CLOUD_AVAILABLE,
      script: 'cloud',         // Self_Hosted_Cloud/linux/cloud.sh installs the whole stack
      flags: false,            // its choices are asked while installing
      uninstall: CLOUD_UNINSTALL,
      pitch: 'Nextcloud with Office, Calendar, Mail and Notes, plus Immich for photos, Vaultwarden for passwords, Stirling PDF and Obsidian. All of them on one folder tree, behind HTTPS, with nightly backups.',
      options: [
        { key: 'office', label: 'Office', type: 'one', choices: ['collabora'], default: 'collabora' },
        { key: 'apps', label: 'Apps', type: 'many', choices: ['immich', 'vaultwarden', 'stirling', 'obsidian'], default: ['immich', 'vaultwarden', 'stirling', 'obsidian'] },
      ],
      core: ['nextcloud', 'postgres', 'redis'],
      guide: {
        intro: 'Every app works on the same folders, so a file saved in one shows up in the others. The script asks which apps you want and how to reach them, then checks that each one works.',
        steps: [
          { title: 'Files', apps: ['nextcloud'], text: 'Nextcloud holds your files, calendars, contacts, tasks and mail, and syncs them to your phone and computer. Documents, Notes and Photos are shared folders.' },
          { title: 'Edit', apps: ['collabora'], text: 'Open a Word, Excel or PowerPoint file in Nextcloud and it opens in Collabora, right in the browser.' },
          { title: 'Photos', apps: ['immich'], text: 'The Immich phone app backs up your camera roll. Immich also shows the Photos folder from Nextcloud as a library.' },
          { title: 'Notes', apps: ['obsidian'], text: 'Obsidian runs in the browser on the Notes folder, the same one Nextcloud Notes uses.' },
          { title: 'PDFs', apps: ['stirling'], text: 'Drop a scan in Documents/PDF Inbox/OCR (or /Compress) and Stirling PDF puts the searchable (or smaller) copy in PDF Done.' },
          { title: 'Passwords', apps: ['vaultwarden'], text: 'Vaultwarden works with the Bitwarden apps and browser extensions. You create your account, then Lock sign-ups closes the door.' },
        ],
        folders: [
          ['/srv/cloud/Documents', 'Nextcloud folder (+ PDF Inbox / PDF Done)'],
          ['/srv/cloud/Notes', 'Nextcloud Notes + Obsidian vault'],
          ['/srv/cloud/Photos', 'Nextcloud folder + Immich library'],
          ['/srv/cloud/backups', 'nightly database dumps + Vaultwarden'],
          ['/opt/sudohomelab/cloud', 'settings, databases, credentials.txt'],
        ],
        left: 'Left for you: trust the certificate on each device (or use the DNS stack names), create your Vaultwarden account and lock sign-ups, and install the Nextcloud, Immich and Bitwarden phone apps.',
      },
      wires: [
        ['nextcloud', 'postgres', 'db'],
        ['nextcloud', 'redis', 'cache'],
        ['nextcloud', '$office', 'WOPI'],
        ['immich', 'nextcloud', 'Photos'],
        ['obsidian', 'nextcloud', 'Notes'],
        ['stirling', 'nextcloud', 'Documents'],
      ],
    },
  },
  {
    id: 'ai',
    folder: 'AI_Tools',   // repo folder: AI_Tools/<platform>/<script>
    name: 'AI & Automation',
    tagline: 'Private LLMs, MCP servers and workflow automation.',
    description: 'Run models locally, give them tools through MCP and automate everything else.',
    accent: '#b38cff',
    glyph: '✦',
    apps: [
      { id: 'ollama', name: 'Ollama', icon: 'ollama', desc: 'Run Llama, Qwen, Mistral and friends locally with one command.', ports: [11434], platforms: ALL, min: { ram: 8, cpu: 4, gpu: true }, tags: ['llm'] },
      { id: 'openwebui', name: 'Open WebUI', icon: 'open-webui', desc: 'ChatGPT-style interface for local and cloud models.', ports: [3000], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['llm', 'chat'] },
      { id: 'mcp-full', name: 'MCP Server: Full Install', icon: null, desc: 'Every MCP tool server we maintain, behind one gateway.', ports: [8811], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['mcp', 'original'], original: true },
      { id: 'mcp-picker', name: 'MCP Tool Selector', icon: null, desc: 'Pick exactly which MCP tools to expose: files, Docker, Proxmox, Home Assistant…', ports: [8811], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['mcp', 'original'], original: true },
      { id: 'opencode', name: 'OpenCode', icon: 'opencode', desc: 'Open-source AI coding agent for your terminal.', ports: [], platforms: ['linux', 'windows', 'macos'], min: { ram: 2, cpu: 2 }, tags: ['coding', 'cli'] },
      { id: 'n8n', name: 'n8n', icon: 'n8n', desc: 'Visual workflow automation with AI agent nodes.', ports: [5678], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['automation'] },
    ],
    stack: {
      id: 'ai-stack',
      name: 'Local AI Stack',
      pitch: 'Ollama with models pulled for your GPU, Open WebUI connected, and MCP tools registered, ready to chat with your lab.',
      options: [
        { key: 'models', label: 'Starter models', type: 'many', diagram: false, choices: ['llama3.1:8b', 'qwen2.5:14b', 'mistral:7b', 'nomic-embed-text'], default: ['llama3.1:8b', 'nomic-embed-text'] },
        { key: 'extras', label: 'Extras', type: 'many', choices: ['mcp-full', 'n8n'], default: ['mcp-full'] },
      ],
      core: ['ollama', 'openwebui'],
      wires: [
        ['openwebui', 'ollama', 'inference'],
        ['openwebui', 'mcp-full', 'tools'],
        ['n8n', 'ollama', 'agents'],
      ],
    },
  },
  {
    id: 'home',
    folder: 'Home_Automation',   // repo folder: Home_Automation/<platform>/<script>
    name: 'Home Automation',
    tagline: 'Local-first smart home that keeps working without the internet.',
    description: 'Home Assistant plus the brokers, bridges and NVR that make it shine.',
    accent: '#18bcf2',
    glyph: '⌂',
    apps: [
      { id: 'homeassistant', name: 'Home Assistant', icon: 'home-assistant', desc: 'The open-source smart home hub. 3,000+ integrations.', ports: [8123], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['hub'], note: 'Proxmox VM (HAOS) recommended for add-on support.' },
      { id: 'mosquitto', name: 'Mosquitto', icon: 'mosquitto', desc: 'Lightweight MQTT broker for sensors and devices.', ports: [1883], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['mqtt'] },
      { id: 'zigbee2mqtt', name: 'Zigbee2MQTT', icon: 'zigbee2mqtt', desc: 'Use Zigbee devices without vendor hubs.', ports: [8080], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['zigbee'], note: 'Needs a USB Zigbee coordinator passed through.' },
      { id: 'nodered', name: 'Node-RED', icon: 'node-red', desc: 'Flow-based automations for when YAML isn\'t enough.', ports: [1880], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['automation'] },
      { id: 'esphome', name: 'ESPHome', icon: 'esphome', desc: 'Flash ESP32 boards into custom sensors from YAML.', ports: [6052], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['diy'] },
      { id: 'frigate', name: 'Frigate', icon: 'frigate', desc: 'NVR with real-time AI object detection for cameras.', ports: [5000], platforms: SERVER, min: { ram: 4, cpu: 4, gpu: true }, tags: ['nvr', 'cameras'] },
    ],
    stack: {
      id: 'smart-home-stack',
      name: 'Smart Home Stack',
      pitch: 'Home Assistant with MQTT, Zigbee and Node-RED already integrated. Plug in a coordinator and start pairing.',
      options: [
        { key: 'extras', label: 'Extras', type: 'many', choices: ['zigbee2mqtt', 'nodered', 'esphome', 'frigate'], default: ['zigbee2mqtt', 'nodered'] },
      ],
      core: ['homeassistant', 'mosquitto'],
      wires: [
        ['zigbee2mqtt', 'mosquitto', 'mqtt'],
        ['mosquitto', 'homeassistant', 'mqtt'],
        ['nodered', 'homeassistant', 'websocket'],
        ['frigate', 'mosquitto', 'events'],
        ['esphome', 'homeassistant', 'api'],
      ],
    },
  },
  {
    id: 'books',
    folder: 'Books_Audiobooks',   // repo folder: Books_Audiobooks/<platform>/<script>
    name: 'Books & Audiobooks',
    tagline: 'Your personal Audible and Kindle, minus the subscription.',
    description: 'Servers for audiobooks, podcasts, ebooks and comics with great mobile apps.',
    accent: '#f7d05a',
    glyph: '❡',
    apps: [
      { id: 'audiobookshelf', name: 'Audiobookshelf', icon: 'audiobookshelf', desc: 'Audiobook & podcast server with progress sync.', ports: [13378], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['audiobooks'] },
      { id: 'komga', name: 'Komga', icon: 'komga', desc: 'Comics & manga server with a slick web reader.', ports: [25600], platforms: ALL, min: { ram: 1, cpu: 1 }, tags: ['comics'] },
      { id: 'kavita', name: 'Kavita', icon: 'kavita', desc: 'Fast reader for ebooks, manga and comics.', ports: [5000], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['ebooks'] },
      { id: 'calibreweb', name: 'Calibre-Web', icon: 'calibre-web', desc: 'Browse, read and send your Calibre library to e-readers.', ports: [8083], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['ebooks'] },
    ],
  },
  {
    id: 'remote',
    folder: 'VPN_Remote_Access',   // repo folder: VPN_Remote_Access/<platform>/<script>
    name: 'VPN & Remote Access',
    tagline: 'Reach your lab from anywhere without opening ports.',
    description: 'Mesh VPNs, classic WireGuard and tunnels for sharing apps securely.',
    accent: '#7ee0c3',
    glyph: '⇄',
    apps: [
      { id: 'tailscale', name: 'Tailscale', icon: 'tailscale', desc: 'Zero-config WireGuard mesh with subnet routing & exit nodes.', ports: [], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['mesh', 'vpn'] },
      { id: 'headscale', name: 'Headscale', icon: 'headscale', desc: 'Self-hosted Tailscale control server.', ports: [8080], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['mesh', 'vpn'] },
      { id: 'wireguard', name: 'WireGuard (wg-easy)', icon: 'wireguard', desc: 'Classic WireGuard server with a web UI for peers & QR codes.', ports: [51820, 51821], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['vpn'] },
      { id: 'cloudflared', name: 'Cloudflare Tunnel', icon: 'cloudflare', desc: 'Publish apps to the internet without port forwarding.', ports: [], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['tunnel'] },
    ],
  },
  {
    id: 'ops',
    folder: 'Monitoring_Management',   // repo folder: Monitoring_Management/<platform>/<script>
    name: 'Monitoring & Management',
    tagline: 'Know what\'s up, what\'s down and what\'s eating your RAM.',
    description: 'Container management, uptime checks, metrics and push notifications.',
    accent: '#a0e85b',
    glyph: '◉',
    apps: [
      { id: 'uptimekuma', name: 'Uptime Kuma', icon: 'uptime-kuma', desc: 'Uptime monitoring and status pages. Installs with Beszel and ntfy, already watching the apps it finds.', ports: [3001], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['uptime'],
        status: 'beta', available: MON_AVAILABLE, script: 'monitoring', uninstall: MON_UNINSTALL, docs: MON_DOCS, note: 'Installed by the Monitoring Stack script, together with Beszel and ntfy.' },
      { id: 'beszel', name: 'Beszel', icon: 'beszel', desc: 'Lightweight server metrics hub + agents with Docker stats.', ports: [8090], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['metrics'],
        status: 'beta', available: MON_AVAILABLE, script: 'monitoring', uninstall: MON_UNINSTALL, docs: MON_DOCS, note: 'Installed by the Monitoring Stack script, together with Uptime Kuma and ntfy. Other machines join with beszel-agent.sh (Linux, or as a TrueNAS app; Add a machine in its menu).' },
      { id: 'ntfy', name: 'ntfy', icon: 'ntfy', desc: 'Push notifications to your phone from any script.', ports: [2586], platforms: SERVER, min: { ram: 0.1, cpu: 1 }, tags: ['notifications'],
        status: 'beta', available: MON_AVAILABLE, script: 'monitoring', uninstall: MON_UNINSTALL, docs: MON_DOCS, note: 'Installed by the Monitoring Stack script, together with Uptime Kuma and Beszel; their alerts go to it.' },
      { id: 'dozzle', name: 'Dozzle', icon: 'dozzle', desc: 'Real-time log viewer for all your containers.', ports: [8888], platforms: SERVER, min: { ram: 0.1, cpu: 1 }, tags: ['logs'],
        status: 'beta', available: MON_AVAILABLE, script: 'monitoring', uninstall: MON_UNINSTALL, docs: MON_DOCS, note: 'An extra in the Monitoring Stack script (same login).' },
      { id: 'portainer', name: 'Portainer', icon: 'portainer', desc: 'GUI for Docker containers, stacks and volumes.', ports: [9443], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['docker'],
        status: 'beta', available: MON_AVAILABLE, script: 'monitoring', uninstall: MON_UNINSTALL, docs: MON_DOCS, note: 'An extra in the Monitoring Stack script (same login).' },
    ],
    stack: {
      id: 'monitoring-stack',
      name: 'Monitoring Stack',
      available: MON_AVAILABLE,
      script: 'monitoring',    // Monitoring_Management/linux/monitoring.sh installs the whole stack
      flags: false,            // its choices are asked while installing
      uninstall: MON_UNINSTALL,
      pitch: 'Uptime Kuma watching every app it finds, Beszel showing CPU, RAM and disks for this machine and any you add, and ntfy putting their alerts on your phone. One login for all of it.',
      options: [
        { key: 'uptime', label: 'Uptime checks', type: 'one', choices: ['uptimekuma'], default: 'uptimekuma' },
        { key: 'extras', label: 'Extras', type: 'many', choices: ['dozzle', 'portainer'], default: [] },
      ],
      core: ['beszel', 'ntfy'],
      guide: {
        intro: 'Three apps, one job each, already connected. Run the script again for a menu to add machines and re-scan for new apps.',
        steps: [
          { title: 'Find', apps: ['uptimekuma'], text: 'The script looks at what runs on the machine (containers, our other stacks, Plex, SSH, SMB) and lets you pick what Uptime Kuma should watch.' },
          { title: 'Watch', apps: ['uptimekuma'], text: 'Uptime Kuma checks each app every minute: its web page, its port or its DNS answer.' },
          { title: 'Measure', apps: ['beszel'], text: 'Beszel\'s agent reports CPU, RAM, disks, network, temperatures and each container\'s use. Default alerts: down, and over 90% for 10 minutes.' },
          { title: 'Alert', apps: ['ntfy'], text: 'Both send their alerts to ntfy, which only takes messages from logged-in users. Subscribe in the ntfy phone app.' },
          { title: 'Add machines', apps: ['beszel'], text: 'Add a machine prints one command for your other computers. Or run beszel-agent.sh there and log in: it fetches the key and token itself.' },
          { title: 'Re-scan', apps: ['uptimekuma', 'beszel'], text: 'Installed something new? Re-scan apps adds its monitor and gives new Beszel machines the default alerts.' },
        ],
        folders: [
          ['http://<ip>:3001', 'Uptime Kuma'],
          ['http://<ip>:8090', 'Beszel'],
          ['http://<ip>:2586', 'ntfy (topic homelab-alerts)'],
          ['credentials.txt', 'logins, links and the add-a-machine command (root only)'],
        ],
        left: 'Left for you: install the ntfy app on your phone and subscribe to the topic, and add your other machines to Beszel.',
      },
      wires: [
        ['$uptime', 'ntfy', 'alerts'],
        ['beszel', 'ntfy', 'alerts'],
      ],
    },
  },
]

// Names for stack-only components that aren't standalone catalog apps.
export const EXTRA_NODES = {
  postgres: { name: 'PostgreSQL', icon: 'postgres' },
  redis: { name: 'Redis', icon: 'redis' },
  collabora: { name: 'Collabora', icon: 'collabora-online' },
  onlyoffice: { name: 'OnlyOffice', icon: 'onlyoffice' },
  talk: { name: 'Talk' }, calendar: { name: 'Calendar' }, contacts: { name: 'Contacts' },
  memories: { name: 'Memories' }, notes: { name: 'Notes' }, deck: { name: 'Deck' },
  'llama3.1:8b': { name: 'Llama 3.1 8B' }, 'qwen2.5:14b': { name: 'Qwen 2.5 14B' },
  'mistral:7b': { name: 'Mistral 7B' }, 'nomic-embed-text': { name: 'Nomic Embed' },
}

export const ALL_APPS = CATEGORIES.flatMap((c) => c.apps.map((a) => ({ ...a, category: c.id, folder: c.folder, accent: c.accent })))
export const appById = Object.fromEntries(ALL_APPS.map((a) => [a.id, a]))
export const categoryById = Object.fromEntries(CATEGORIES.map((c) => [c.id, c]))
export const STACKS = CATEGORIES.filter((c) => c.stack).map((c) => ({ ...c.stack, category: c.id, folder: c.folder, accent: c.accent }))

export function nodeInfo(id) {
  return appById[id] || EXTRA_NODES[id] || { name: id }
}
