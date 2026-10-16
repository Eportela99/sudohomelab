// Scripts are served straight from the GitHub repo until the sudohomelab.com domain exists.
// Layout: scripts/<platform id>/<path>.<ext>
export const SCRIPT_BASE = 'https://raw.githubusercontent.com/Eportela99/sudohomelab/main/scripts'
export const GITHUB_REPO = 'https://github.com/Eportela99/sudohomelab'

// flags: [[key, value], ...] → ' --key=value' or ' -Key value'
const unix = (f) => f.map(([k, v]) => ` --${k}=${v}`).join('')
const ps = (f) => f.map(([k, v]) => ` -${k[0].toUpperCase()}${k.slice(1)} ${v}`).join('')

export const PLATFORMS = [
  {
    id: 'proxmox',
    name: 'Proxmox VE',
    short: 'Proxmox',
    icon: 'proxmox',
    shell: 'bash',
    note: 'Run in the Proxmox host shell. Creates a dedicated LXC container.',
    ext: 'sh',
    cmd: (path, f = []) => `bash <(curl -fsSL ${SCRIPT_BASE}/proxmox/${path}.sh)${unix(f)}`,
  },
  {
    id: 'linux',
    name: 'Ubuntu Server',
    short: 'Linux',
    icon: 'ubuntu-linux',
    shell: 'bash',
    note: 'Ubuntu / Debian. Installs Docker if missing, then deploys with Compose.',
    ext: 'sh',
    cmd: (path, f = []) => `curl -fsSL ${SCRIPT_BASE}/linux/${path}.sh | sudo bash${f.length ? ' -s --' + unix(f) : ''}`,
  },
  {
    id: 'truenas',
    name: 'TrueNAS SCALE',
    short: 'TrueNAS',
    icon: 'truenas-scale',
    shell: 'bash',
    note: 'Run from the TrueNAS shell. Deploys as a custom app on your pool.',
    ext: 'sh',
    cmd: (path, f = []) => `curl -fsSL ${SCRIPT_BASE}/truenas/${path}.sh | sudo bash${f.length ? ' -s --' + unix(f) : ''}`,
  },
  {
    id: 'windows',
    name: 'Windows',
    short: 'Windows',
    icon: 'microsoft-windows',
    shell: 'powershell',
    note: 'Run in an elevated PowerShell. Uses Docker Desktop / WSL2 or native installers.',
    ext: 'ps1',
    cmd: (path, f = []) =>
      f.length
        ? `& ([scriptblock]::Create((irm ${SCRIPT_BASE}/windows/${path}.ps1)))${ps(f)}`
        : `irm ${SCRIPT_BASE}/windows/${path}.ps1 | iex`,
  },
  {
    id: 'macos',
    name: 'macOS',
    short: 'macOS',
    icon: 'apple',
    shell: 'zsh',
    note: 'Run in Terminal. Uses Homebrew + OrbStack / Docker Desktop.',
    ext: 'sh',
    cmd: (path, f = []) => `curl -fsSL ${SCRIPT_BASE}/macos/${path}.sh | bash${f.length ? ' -s --' + unix(f) : ''}`,
  },
]

export const platformById = Object.fromEntries(PLATFORMS.map((p) => [p.id, p]))

// Placeholder script contents used by the "Download" button until the real
// scripts are published to GitHub.
export function placeholderScript(platform, name, path) {
  const date = new Date().toISOString().slice(0, 10)
  if (platform.shell === 'powershell') {
    return `# sudo homelab — ${name} installer (${platform.name})
# ${GITHUB_REPO}
# Generated ${date} — PLACEHOLDER, script not published yet.

#Requires -RunAsAdministrator
Write-Host "sudo homelab :: ${name}" -ForegroundColor Green
Write-Host "This installer is still being built. Follow progress at ${GITHUB_REPO}" -ForegroundColor Yellow
`
  }
  return `#!/usr/bin/env bash
# sudo homelab — ${name} installer (${platform.name})
# ${GITHUB_REPO}
# Generated ${date} — PLACEHOLDER, script not published yet.
set -euo pipefail

echo -e "\\e[32msudo homelab :: ${name}\\e[0m"
echo -e "\\e[33mThis installer is still being built. Follow progress at ${GITHUB_REPO}\\e[0m"
# target: ${path}
`
}
