import { useEffect } from 'react'
import { appById, categoryById } from '../data/catalog'
import { platformById } from '../data/platforms'
import { go, spotlight } from '../hooks'
import { AppIcon, Icon, Rich, StatusBadge } from './Bits'
import { InstallBox } from './Install'

const fmtRam = (gb) => (gb < 1 ? `${Math.round(gb * 1024)} MB` : `${gb} GB`)

export function AppCard({ app, accent, index = 0 }) {
  return (
    <a href={`#/c/${app.category}/${app.id}`} className="app-card reveal" style={{ '--accent': accent, '--d': `${(index % 8) * 50}ms` }} onMouseMove={spotlight}>
      <div className="app-card-top">
        <AppIcon icon={app.icon} name={app.name} size={44} accent={accent} original={app.original} />
        {app.original ? <span className="badge badge-original">Original</span> : <StatusBadge status={app.status} />}
      </div>
      <h3>{app.name}</h3>
      <p>{app.desc}</p>
      <div className="app-card-foot">
        <span className="app-plats">
          {app.platforms.map((p) => (
            <span key={p} className="plat-dot" title={platformById[p].name}>
              <AppIcon icon={platformById[p].icon} name={platformById[p].short} size={14} />
            </span>
          ))}
        </span>
        <span className="app-card-cta">
          Install <Icon.Arrow />
        </span>
      </div>
    </a>
  )
}

// Apps that the given app is wired to inside its category's stack.
function wiredWith(app) {
  const stack = categoryById[app.category].stack
  if (!stack) return []
  const ids = new Set()
  stack.wires.forEach(([a, b]) => {
    const resolve = (x) => (x.startsWith('$') ? stack.options.find((o) => o.key === x.slice(1))?.choices || [] : [x])
    const as = resolve(a)
    const bs = resolve(b)
    if (as.includes(app.id)) bs.forEach((x) => ids.add(x))
    if (bs.includes(app.id)) as.forEach((x) => ids.add(x))
  })
  ids.delete(app.id)
  return [...ids].map((id) => appById[id]).filter(Boolean)
}

export function AppDrawer({ appId, onClose }) {
  const app = appById[appId]

  useEffect(() => {
    if (!app) return
    const onKey = (e) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    document.body.classList.add('locked')
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.classList.remove('locked')
    }
  }, [app, onClose])

  if (!app) return null
  const cat = categoryById[app.category]
  const friends = wiredWith(app)

  return (
    <div className="drawer-backdrop" onMouseDown={onClose}>
      <aside className="drawer" style={{ '--accent': cat.accent }} onMouseDown={(e) => e.stopPropagation()} role="dialog" aria-label={app.name}>
        <button className="drawer-close" onClick={onClose} aria-label="Close">
          <Icon.Close />
        </button>
        <div className="drawer-hero">
          <div className="drawer-icon">
            <AppIcon icon={app.icon} name={app.name} size={64} accent={cat.accent} original={app.original} />
          </div>
          <div>
            <span className="eyebrow">{cat.name}</span>
            <h2>{app.name}</h2>
            <p>{app.desc}</p>
          </div>
        </div>

        <div className="drawer-facts">
          <div>
            <small>Status</small>
            {app.original ? <span className="badge badge-original">Original</span> : <StatusBadge status={app.status} />}
          </div>
          <div>
            <small>Min RAM</small>
            <strong>{fmtRam(app.min.ram)}</strong>
          </div>
          <div>
            <small>CPU</small>
            <strong>{app.min.cpu} core{app.min.cpu > 1 ? 's' : ''}</strong>
          </div>
          <div>
            <small>Ports</small>
            <strong className="mono">{app.ports.length ? app.ports.join(', ') : '—'}</strong>
          </div>
          {app.min.gpu && (
            <div>
              <small>GPU</small>
              <strong>Recommended</strong>
            </div>
          )}
        </div>

        {app.note && <div className="drawer-note">ⓘ {app.note}</div>}

        <h4 className="drawer-h">Install</h4>
        <InstallBox name={app.name} folder={cat.folder} script={app.script || app.id} supported={app.platforms} available={app.available} notes={app.uninstall} accent={cat.accent} />

        {friends.length > 0 && (
          <>
            <h4 className="drawer-h">Auto-wires with</h4>
            <div className="drawer-friends">
              {friends.map((f) => (
                <button key={f.id} className="chip on" onClick={() => go(`/c/${f.category}/${f.id}`)} style={{ '--accent': cat.accent }}>
                  <AppIcon icon={f.icon} name={f.name} size={18} accent={cat.accent} original={f.original} />
                  {f.name}
                </button>
              ))}
            </div>
          </>
        )}

        <h4 className="drawer-h">Documentation</h4>
        {app.docs ? (
          <div className="docs-skeleton">
            {app.docs.map((d, i) => (
              <details key={d.title} open={i === 0}>
                <summary>{d.title}</summary>
                <div className="doc-body">
                  {d.text && (
                    <p>
                      <Rich text={d.text} />
                    </p>
                  )}
                  {d.items && (
                    <ul>
                      {d.items.map((it) => (
                        <li key={it}>
                          <Rich text={it} />
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </details>
            ))}
          </div>
        ) : (
        <div className="docs-skeleton">
          {['What the script does', 'Configuration & environment', 'After installing', 'Updating & uninstalling', 'Troubleshooting'].map((t, i) => (
            <details key={t} open={i === 0}>
              <summary>{t}</summary>
              <div className="skeleton-lines">
                <span style={{ width: '92%' }} />
                <span style={{ width: '78%' }} />
                <span style={{ width: '85%' }} />
                <em>Docs land here when the {app.name} script is published.</em>
              </div>
            </details>
          ))}
        </div>
        )}

        <div className="drawer-tags">
          {app.tags.map((t) => (
            <span key={t}>#{t}</span>
          ))}
        </div>
      </aside>
    </div>
  )
}
