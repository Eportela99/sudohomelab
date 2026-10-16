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
export function InstallBox({ name, folder, script, supported, available, flags = [], accent }) {
  const { platform, setPlatform } = usePlatform()
  const p = platformById[platform]
  const ok = supported.includes(platform)
  const path = scriptPath(folder, p, script)
  const cmd = p.cmd(path, flags)
  const filename = `${script}-${p.id}.${p.ext}`
  const published = available?.includes(platform)

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
          <div className="cmd" key={platform + cmd}>
            <span className="cmd-shell">{p.shell === 'powershell' ? 'PS>' : '$'}</span>
            <code className="cmd-text">{highlight(cmd)}</code>
            <CopyButton text={cmd} />
          </div>
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
