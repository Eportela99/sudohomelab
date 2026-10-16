// The whole site is driven from this file. Adding an app here adds it to the
// category page, the search palette and the advisor's recommendations.
//
// status: 'planned' | 'beta' | 'ready'
// icon:   slug from https://github.com/homarr-labs/dashboard-icons (falls back to a monogram)
// min:    rough minimum resources, used by the advisor  { ram: GB, cpu: cores, gpu?: bool }

const ALL = ['proxmox', 'linux', 'truenas', 'windows', 'macos']
const SERVER = ['proxmox', 'linux', 'truenas']

export const CATEGORIES = [
  {
    id: 'media',
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
      available: ['linux'],
      pitch: 'One command. Every app installed, API keys exchanged, download clients, indexers and root folders already connected.',
      options: [
        { key: 'server', label: 'Media server', type: 'one', choices: ['plex', 'jellyfin'], default: 'jellyfin' },
        { key: 'downloader', label: 'Download client', type: 'many', choices: ['qbittorrent', 'sabnzbd'], default: ['qbittorrent'] },
        { key: 'extras', label: 'Extras', type: 'many', choices: ['lidarr', 'bazarr', 'tdarr'], default: [] },
      ],
      core: ['seerr', 'radarr', 'sonarr', 'prowlarr'],
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
    name: 'Dashboards',
    tagline: 'One pane of glass for your entire lab.',
    description: 'Start pages that show every service, its status and its stats at a glance.',
    accent: '#57c7ff',
    glyph: '▦',
    apps: [
      { id: 'homarr', name: 'Homarr', icon: 'homarr', desc: 'Drag-and-drop dashboard with deep app integrations.', ports: [7575], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['dashboard'] },
      { id: 'homepage', name: 'Homepage', icon: 'homepage', desc: 'Fast, YAML-configured dashboard with 100+ service widgets.', ports: [3000], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['dashboard', 'yaml'] },
      { id: 'casaos', name: 'CasaOS', icon: 'casaos', desc: 'Friendly home-cloud UI with a one-click app store.', ports: [80], platforms: ['proxmox', 'linux'], min: { ram: 1, cpu: 1 }, tags: ['dashboard', 'app-store'] },
      { id: 'glance', name: 'Glance', icon: 'glance', desc: 'Minimal feed dashboard: RSS, weather, markets, releases.', ports: [8080], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['dashboard', 'feeds'] },
      { id: 'sudo-dash', name: 'sudo homelab Dash', icon: null, desc: 'Our own dashboard, auto-populated with every app you install from this site.', ports: [8000], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['original'], original: true },
    ],
  },
  {
    id: 'network',
    name: 'Ad-blocking, DNS & Proxy',
    tagline: 'Block ads network-wide and put every app behind a clean URL.',
    description: 'DNS sinkholes, recursive resolvers and reverse proxies with automatic HTTPS.',
    accent: '#ff5c8a',
    glyph: '⛨',
    apps: [
      { id: 'pihole', name: 'Pi-hole', icon: 'pi-hole', desc: 'The classic network-wide ad blocker and DNS server.', ports: [53, 80], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['dns', 'adblock'] },
      { id: 'adguard', name: 'AdGuard Home', icon: 'adguard-home', desc: 'Modern ad blocker with DoH/DoT and per-client rules.', ports: [53, 3000], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['dns', 'adblock'] },
      { id: 'unbound', name: 'Unbound', icon: 'unbound', desc: 'Recursive DNS resolver, so no upstream provider sees your lookups.', ports: [5335], platforms: SERVER, min: { ram: 0.25, cpu: 1 }, tags: ['dns', 'privacy'] },
      { id: 'npm', name: 'Nginx Proxy Manager', icon: 'nginx-proxy-manager', desc: 'Reverse proxy with a GUI and free Let\'s Encrypt certificates.', ports: [80, 443, 81], platforms: SERVER, min: { ram: 0.5, cpu: 1 }, tags: ['proxy', 'ssl'] },
      { id: 'caddy', name: 'Caddy', icon: 'caddy', desc: 'Zero-config reverse proxy with automatic HTTPS.', ports: [80, 443], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['proxy', 'ssl'] },
    ],
    stack: {
      id: 'dns-stack',
      name: 'Private DNS Stack',
      pitch: 'Ad blocker forwarding to your own recursive resolver, plus a reverse proxy so every app gets a name like jellyfin.home.',
      options: [
        { key: 'blocker', label: 'Ad blocker', type: 'one', choices: ['pihole', 'adguard'], default: 'pihole' },
        { key: 'proxy', label: 'Reverse proxy', type: 'one', choices: ['npm', 'caddy'], default: 'npm' },
      ],
      core: ['unbound'],
      wires: [
        ['$blocker', 'unbound', 'upstream'],
        ['$proxy', '$blocker', 'local DNS'],
      ],
    },
  },
  {
    id: 'cloud',
    name: 'Self-Hosted Cloud',
    tagline: 'Your files, photos and passwords, on your hardware.',
    description: 'Replace Google Drive, Google Photos and password managers with apps you own.',
    accent: '#5af78e',
    glyph: '☁',
    apps: [
      { id: 'nextcloud', name: 'Nextcloud Suite', icon: 'nextcloud', desc: 'Nextcloud with Postgres, Redis, Office, Talk, Calendar & Memories pre-configured.', ports: [443], platforms: ALL, min: { ram: 4, cpu: 2 }, tags: ['files', 'office', 'suite'], suite: true },
      { id: 'immich', name: 'Immich', icon: 'immich', desc: 'Google Photos replacement with face & object search.', ports: [2283], platforms: ALL, min: { ram: 4, cpu: 2 }, tags: ['photos', 'ml'] },
      { id: 'vaultwarden', name: 'Vaultwarden', icon: 'vaultwarden', desc: 'Lightweight Bitwarden-compatible password server.', ports: [8000], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['passwords'] },
      { id: 'syncthing', name: 'Syncthing', icon: 'syncthing', desc: 'Peer-to-peer folder sync between all your devices.', ports: [8384], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['sync'] },
      { id: 'paperless', name: 'Paperless-ngx', icon: 'paperless-ngx', desc: 'Scan, OCR and search every document you own.', ports: [8000], platforms: ALL, min: { ram: 2, cpu: 2 }, tags: ['documents', 'ocr'] },
    ],
    stack: {
      id: 'nextcloud-suite',
      name: 'Nextcloud Suite',
      pitch: 'Not just Nextcloud. A tuned install with database, cache, cron, office editing and your choice of add-ons enabled.',
      options: [
        { key: 'office', label: 'Office suite', type: 'one', choices: ['collabora', 'onlyoffice'], default: 'collabora' },
        { key: 'addons', label: 'Add-ons', type: 'many', diagram: false, choices: ['talk', 'calendar', 'contacts', 'memories', 'notes', 'deck'], default: ['calendar', 'contacts', 'memories'] },
      ],
      core: ['nextcloud', 'postgres', 'redis'],
      wires: [
        ['nextcloud', 'postgres', 'db'],
        ['nextcloud', 'redis', 'cache'],
        ['nextcloud', '$office', 'WOPI'],
      ],
    },
  },
  {
    id: 'ai',
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
    name: 'Monitoring & Management',
    tagline: 'Know what\'s up, what\'s down and what\'s eating your RAM.',
    description: 'Container management, uptime checks, metrics and push notifications.',
    accent: '#a0e85b',
    glyph: '◉',
    apps: [
      { id: 'portainer', name: 'Portainer', icon: 'portainer', desc: 'GUI for Docker containers, stacks and volumes.', ports: [9443], platforms: ALL, min: { ram: 0.5, cpu: 1 }, tags: ['docker'] },
      { id: 'uptimekuma', name: 'Uptime Kuma', icon: 'uptime-kuma', desc: 'Beautiful uptime monitoring and status pages.', ports: [3001], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['uptime'] },
      { id: 'beszel', name: 'Beszel', icon: 'beszel', desc: 'Lightweight server metrics hub + agents with Docker stats.', ports: [8090], platforms: ALL, min: { ram: 0.25, cpu: 1 }, tags: ['metrics'] },
      { id: 'dozzle', name: 'Dozzle', icon: 'dozzle', desc: 'Real-time log viewer for all your containers.', ports: [8080], platforms: ALL, min: { ram: 0.1, cpu: 1 }, tags: ['logs'] },
      { id: 'ntfy', name: 'ntfy', icon: 'ntfy', desc: 'Push notifications to your phone from any script.', ports: [80], platforms: ALL, min: { ram: 0.1, cpu: 1 }, tags: ['notifications'] },
    ],
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

export const ALL_APPS = CATEGORIES.flatMap((c) => c.apps.map((a) => ({ ...a, category: c.id, accent: c.accent })))
export const appById = Object.fromEntries(ALL_APPS.map((a) => [a.id, a]))
export const categoryById = Object.fromEntries(CATEGORIES.map((c) => [c.id, c]))
export const STACKS = CATEGORIES.filter((c) => c.stack).map((c) => ({ ...c.stack, category: c.id, accent: c.accent }))

export function nodeInfo(id) {
  return appById[id] || EXTRA_NODES[id] || { name: id }
}
