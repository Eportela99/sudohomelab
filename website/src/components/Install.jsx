import { useLayoutEffect, useRef, useState } from 'react'
import { PLATFORMS, GITHUB_REPO, SCRIPT_BASE, platformById, placeholderScript, scriptPath } from '../data/platforms'
import { downloadText, usePlatform } from '../hooks'
import { AppIcon, CopyButton, Icon } from './Bits'

// Segmented control with a sliding highlight.
export function PlatformSwitcher({ supported = PLATFORMS.map((p) => p.id), compact }) {
  const { platform, setPlatform } = usePlatform()
  const wrap = useRef()
  const [pill, setPill] = useState({ left: 0, width: 0 })

  useLayoutEffect(() => {
    const measure = () => {
      const el = wrap.current?.querySelector(`[data-p="${platform}"]`)
      if (el) setPill({ left: el.offsetLeft, width: el.offsetWidth })
    }
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [platform, compact])

  return (
    <div className={`pswitch ${compact ? 'compact' : ''}`} ref={wrap} role="tablist">
      <span className="pswitch-pill" style={{ transform: `translateX(${pill.left}px)`, width: pill.width }} />
      {PLATFORMS.map((p) => {
        const ok = supported.includes(p.id)
        return (
          <button key={p.id} data-p={p.id} role="tab" aria-selected={platform === p.id} className={`pswitch-btn ${platform === p.id ? 'on' : ''} ${ok ? '' : 'na'}`} onClick={() => setPlatform(p.id)} title={ok ? p.name : `${p.name}: not supported`}>
            <AppIcon icon={p.icon} name={p.short} size={18} />
            <span>{compact ? p.short : p.name}</span>
          </button>
        )
      })}
    </div>
  )
}

// Light syntax highlighting for one-line shell commands.
function highlight(cmd) {
  return cmd.split(/(\s+)/).map((tok, i) => {
    let cls = ''
    if (/https?:\/\//.test(tok)) cls = 'tk-url'
    else if (/^(curl|bash|sudo|irm|iex|&)$/.test(tok.replace(/[^a-z&]/g, ''))) cls = 'tk-bin'
    else if (/^--?[A-Za-z]/.test(tok)) cls = 'tk-flag'
    else if (tok === '|') cls = 'tk-pipe'
    return (
      <span key={i} className={cls}>
        {tok}
      </span>
    )
  })
}

// available: platforms whose script is already published (undefined = none yet).
// folder: repo project folder (e.g. Media_Stack) · script: file name without extension
// notes: optional { uninstall, purge, safe } to replace the media-stack wording.
export function InstallBox({ name, folder, script, supported, available, flags = [], accent, notes = {} }) {
  const { platform, setPlatform } = usePlatform()
  const p = platformById[platform]
  const ok = supported.includes(platform)
  const path = scriptPath(folder, p, script)
  const filename = `${script}-${p.id}.${p.ext}`
  const published = available?.includes(platform)
  // Published scripts get three commands: install, uninstall, uninstall + delete settings.
  const [action, setAction] = useState('install')
  const ACTIONS = [
    { id: 'install', label: 'Install', flags, note: null },
    { id: 'uninstall', label: 'Uninstall', flags: [['uninstall', true]],
      note: notes.uninstall || 'Removes the apps but keeps their settings, so reinstalling brings back your logins and wiring.' },
    { id: 'purge', label: 'Uninstall + delete settings', flags: [['uninstall', true], ['purge', true]],
      note: notes.purge || 'Removes the apps and deletes their settings, logins and API keys.' },
  ]
  const current = published ? ACTIONS.find((a) => a.id === action) : ACTIONS[0]
  const shown = p.cmd(path, current.flags)
  const danger = current.id !== 'install'

  // Published scripts are fetched from GitHub (raw URLs allow CORS); others get a placeholder.
  const download = async () => {
    if (published) {
      try {
        const res = await fetch(`${SCRIPT_BASE}/${path}`)
        if (res.ok) return downloadText(filename, await res.text())
      } catch {
        /* fall through to placeholder */
      }
    }
    downloadText(filename, placeholderScript(p, name, path))
  }

  return (
    <div className="install" style={{ '--accent': accent }}>
      <PlatformSwitcher supported={supported} compact />
      {ok ? (
        <>
          {published && (
            <div className="actions" role="tablist" aria-label="What to do">
              {ACTIONS.map((a) => (
                <button key={a.id} role="tab" aria-selected={action === a.id} className={`action ${a.id !== 'install' ? 'danger' : ''} ${action === a.id ? 'on' : ''}`} onClick={() => setAction(a.id)}>
                  {a.id === 'install' ? <Icon.Download /> : <Icon.Trash />} {a.label}
                </button>
              ))}
            </div>
          )}
          <div className={`cmd ${danger ? 'danger' : ''}`} key={platform + shown}>
            <span className="cmd-shell">{p.shell === 'powershell' ? 'PS>' : '$'}</span>
            <code className="cmd-text">{highlight(shown)}</code>
            <CopyButton text={shown} />
          </div>
          {danger && (
            <p className="uninstall-note">
              {current.note} <strong>{notes.safe || 'Your media is never deleted.'}</strong> It asks before removing anything.
            </p>
          )}
          {available?.length > 0 && !available.includes(platform) && (
            <div className="install-soon">
              The {p.name} script is coming soon. Ready now on: {available.map((id) => platformById[id].name).join(', ')}.
            </div>
          )}
          <div className="install-foot">
            <span className="install-note">
              <AppIcon icon={p.icon} name={p.short} size={14} /> {p.note}
            </span>
            <span className="install-actions">
              <button className="btn-ghost sm" onClick={download}>
                <Icon.Download /> Download .{p.ext}
              </button>
              <a className="btn-ghost sm" href={`${GITHUB_REPO}/blob/main/${path}`} target="_blank" rel="noreferrer">
                <Icon.GitHub /> Source
              </a>
            </span>
          </div>
        </>
      ) : (
        <div className="install-na">
          <strong>{name} isn’t supported on {p.name}.</strong>
          <span>
            Available on:{' '}
            {supported.map((id) => (
              <button key={id} className="link" onClick={() => setPlatform(id)}>
                {platformById[id].name}
              </button>
            ))}
          </span>
        </div>
      )}
    </div>
  )
}

const OFFICIAL_WHERE = {
  proxmox: 'Run in the Proxmox host shell (root).',
  linux: 'Ubuntu / Debian, with Docker installed.',
  truenas: 'In the TrueNAS web interface.',
  windows: 'PowerShell, with Docker Desktop running.',
  macos: 'Terminal, with Docker Desktop or OrbStack running.',
}

// Apps installed with their project's own method (no sudo homelab script).
// official: { site, docs, how: { <platform>: { cmd } | { steps: [..] } }, note }
export function OfficialInstall({ app, accent }) {
  const { platform, setPlatform } = usePlatform()
  const p = platformById[platform]
  const how = app.official.how[platform]
  return (
    <div className="install" style={{ '--accent': accent }}>
      <PlatformSwitcher supported={app.platforms} compact />
      {how ? (
        <>
          {how.cmd && (
            <div className="cmd" key={platform + how.cmd}>
              <span className="cmd-shell">{p.shell === 'powershell' ? 'PS>' : '$'}</span>
              <code className="cmd-text">{highlight(how.cmd)}</code>
              <CopyButton text={how.cmd} />
            </div>
          )}
          {how.steps && (
            <ol className="install-steps">
              {how.steps.map((s) => (
                <li key={s}>{s}</li>
              ))}
            </ol>
          )}
          <p className="install-official">{how.note || app.official.note}</p>
          <div className="install-foot">
            <span className="install-note">
              <AppIcon icon={p.icon} name={p.short} size={14} /> {how.where || OFFICIAL_WHERE[platform]}
            </span>
            <span className="install-actions">
              <a className="btn-ghost sm" href={app.official.docs} target="_blank" rel="noreferrer">
                <Icon.Arrow /> Official docs
              </a>
              <a className="btn-ghost sm" href={app.official.site} target="_blank" rel="noreferrer">
                <Icon.Arrow /> Website
              </a>
            </span>
          </div>
        </>
      ) : (
        <div className="install-na">
          <strong>{app.name} isn’t supported on {p.name}.</strong>
          <span>
            Available on:{' '}
            {app.platforms.map((id) => (
              <button key={id} className="link" onClick={() => setPlatform(id)}>
                {platformById[id].name}
              </button>
            ))}
          </span>
        </div>
      )}
    </div>
  )
}
