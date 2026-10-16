import { useCallback, useMemo, useState } from 'react'
import { CATEGORIES, STACKS, appById, categoryById } from '../data/catalog'
import { PLATFORMS } from '../data/platforms'
import { go, usePlatform, useReveal } from '../hooks'
import { AppCard, AppDrawer } from '../components/Apps'
import { Icon } from '../components/Bits'
import { PlatformSwitcher } from '../components/Install'
import { StackBuilder } from '../components/Stack'

// A stack runs where all of its core apps run.
export function supportedFor(category) {
  const core = category.stack.core.map((id) => appById[id]).filter(Boolean)
  return PLATFORMS.map((p) => p.id).filter((p) => core.every((a) => a.platforms.includes(p)))
}

export function CategoryPage({ id, appId }) {
  const cat = categoryById[id]
  useReveal()
  const close = useCallback(() => go(`/c/${id}`), [id])

  if (!cat) return <NotFound />
  const apps = cat.apps.map((a) => appById[a.id])
  const idx = CATEGORIES.indexOf(cat)
  const next = CATEGORIES[(idx + 1) % CATEGORIES.length]

  return (
    <div className="page" style={{ '--accent': cat.accent }}>
      <header className="page-hero">
        <div className="page-hero-glow" />
        <div className="container">
          <a href="#/catalog" className="back">
            <Icon.Back /> All categories
          </a>
          <div className="page-hero-row">
            <span className="page-glyph">{cat.glyph}</span>
            <div>
              <h1>{cat.name}</h1>
              <p>{cat.description}</p>
            </div>
          </div>
        </div>
      </header>

      <div className="container page-body">
        {cat.stack && (
          <div className="reveal">
            <StackBuilder stack={cat.stack} accent={cat.accent} supported={supportedFor(cat)} />
          </div>
        )}

        <div className="section-head left reveal">
          <h2>{cat.stack ? 'Or install apps individually' : 'Apps'}</h2>
          <p>Every app gets its own installer for each platform. Click one for commands, requirements and docs.</p>
        </div>
        <div className="app-grid">
          {apps.map((a, i) => (
            <AppCard key={a.id} app={a} accent={cat.accent} index={i} />
          ))}
        </div>

        <a href={`#/c/${next.id}`} className="next-cat reveal" style={{ '--accent': next.accent }}>
          <span>
            <small>Next category</small>
            <strong>
              {next.glyph} {next.name}
            </strong>
          </span>
          <Icon.Arrow />
        </a>
      </div>
      <AppDrawer appId={appId} onClose={close} />
    </div>
  )
}

export function CatalogPage() {
  const { platform } = usePlatform()
  const [onlyMine, setOnlyMine] = useState(false)
  const [q, setQ] = useState('')
  useReveal()

  const filtered = useMemo(() => {
    const term = q.trim().toLowerCase()
    return CATEGORIES.map((c) => ({
      ...c,
      list: c.apps
        .map((a) => appById[a.id])
        .filter((a) => (!onlyMine || a.platforms.includes(platform)) && (!term || `${a.name} ${a.desc} ${a.tags.join(' ')}`.toLowerCase().includes(term))),
    })).filter((c) => c.list.length)
  }, [q, onlyMine, platform])

  return (
    <div className="page">
      <header className="page-hero">
        <div className="page-hero-glow" />
        <div className="container">
          <span className="eyebrow">The catalog</span>
          <h1>Every app, every platform.</h1>
          <p>Filter by the platform you run. Install commands update everywhere on the site.</p>
          <div className="catalog-tools">
            <PlatformSwitcher />
            <div className="catalog-filter">
              <label className="search-field">
                <Icon.Search />
                <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter apps…" />
              </label>
              <label className="toggle">
                <input type="checkbox" checked={onlyMine} onChange={(e) => setOnlyMine(e.target.checked)} />
                <span className="toggle-track" />
                Only show apps for my platform
              </label>
            </div>
          </div>
        </div>
      </header>
      <div className="container page-body">
        {filtered.length === 0 && <p className="empty">Nothing matches. Try a different filter.</p>}
        {filtered.map((c) => (
          <section key={c.id} className="catalog-group" style={{ '--accent': c.accent }}>
            <div className="catalog-group-head reveal">
              <a href={`#/c/${c.id}`}>
                <span className="cat-glyph sm">{c.glyph}</span>
                <h2>{c.name}</h2>
              </a>
              <span className="catalog-group-tag">{c.tagline}</span>
              <a href={`#/c/${c.id}`} className="btn-ghost sm">
                {c.stack ? 'Open stack builder' : 'View category'} <Icon.Arrow />
              </a>
            </div>
            <div className="app-grid">
              {c.list.map((a, i) => (
                <AppCard key={a.id} app={a} accent={c.accent} index={i} />
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  )
}

export function StacksPage({ id }) {
  const active = STACKS.find((s) => s.id === id) || STACKS[0]
  const cat = categoryById[active.category]
  useReveal()
  return (
    <div className="page" style={{ '--accent': cat.accent }}>
      <header className="page-hero">
        <div className="page-hero-glow" />
        <div className="container">
          <span className="eyebrow">Pre-wired stacks</span>
          <h1>Whole setups, already connected.</h1>
          <p>Each stack installs a group of apps and configures how they talk to each other, so you open the dashboard and it just works.</p>
          <div className="stack-tabs">
            {STACKS.map((s) => (
              <a key={s.id} href={`#/stacks/${s.id}`} className={`stack-tab ${s.id === active.id ? 'on' : ''}`} style={{ '--accent': s.accent }}>
                <span>{categoryById[s.category].glyph}</span> {s.name}
              </a>
            ))}
          </div>
        </div>
      </header>
      <div className="container page-body">
        <StackBuilder key={active.id} stack={active} accent={cat.accent} supported={supportedFor(cat)} />
      </div>
    </div>
  )
}

export function NotFound() {
  return (
    <div className="page notfound container">
      <code>$ sudo homelab cd {window.location.hash.slice(2)}</code>
      <h1>404: no such directory</h1>
      <a href="#/" className="btn-primary">
        cd ~ <Icon.Arrow />
      </a>
    </div>
  )
}
