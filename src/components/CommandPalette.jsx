import { useEffect, useMemo, useRef, useState } from 'react'
import { ALL_APPS, CATEGORIES, STACKS, categoryById } from '../data/catalog'
import { go } from '../hooks'
import { AppIcon, Icon } from './Bits'

export default function CommandPalette({ open, onClose }) {
  const [q, setQ] = useState('')
  const [sel, setSel] = useState(0)
  const input = useRef()

  useEffect(() => {
    if (open) {
      setQ('')
      setSel(0)
      setTimeout(() => input.current?.focus(), 20)
    }
  }, [open])

  const results = useMemo(() => {
    const term = q.trim().toLowerCase()
    const items = [
      ...STACKS.map((s) => ({ kind: 'Stack', id: s.id, name: s.name, sub: categoryById[s.category].name, href: `#/c/${s.category}`, accent: s.accent, icon: null, stack: true })),
      ...CATEGORIES.map((c) => ({ kind: 'Category', id: c.id, name: c.name, sub: `${c.apps.length} apps`, href: `#/c/${c.id}`, accent: c.accent, glyph: c.glyph })),
      ...ALL_APPS.map((a) => ({ kind: 'App', id: a.id, name: a.name, sub: a.desc, href: `#/c/${a.category}/${a.id}`, accent: a.accent, icon: a.icon, original: a.original, tags: a.tags })),
      { kind: 'Page', id: 'advisor', name: 'AI Hardware Advisor', sub: 'Find out what your hardware can run', href: '#/advisor', accent: '#b38cff', glyph: '✦' },
    ]
    if (!term) return items.filter((i) => i.kind !== 'App').concat(ALL_APPS.slice(0, 6).map((a) => items.find((i) => i.id === a.id && i.kind === 'App')))
    return items
      .map((i) => {
        const hay = `${i.name} ${i.sub} ${(i.tags || []).join(' ')}`.toLowerCase()
        const score = i.name.toLowerCase().startsWith(term) ? 3 : i.name.toLowerCase().includes(term) ? 2 : hay.includes(term) ? 1 : 0
        return { ...i, score }
      })
      .filter((i) => i.score)
      .sort((a, b) => b.score - a.score)
      .slice(0, 12)
  }, [q])

  useEffect(() => setSel(0), [q])

  if (!open) return null

  const choose = (item) => {
    go(item.href.slice(1))
    onClose()
  }

  const onKey = (e) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setSel((s) => Math.min(s + 1, results.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setSel((s) => Math.max(s - 1, 0))
    } else if (e.key === 'Enter' && results[sel]) {
      choose(results[sel])
    } else if (e.key === 'Escape') {
      onClose()
    }
  }

  return (
    <div className="palette-backdrop" onMouseDown={onClose}>
      <div className="palette" onMouseDown={(e) => e.stopPropagation()} role="dialog" aria-label="Search">
        <div className="palette-input">
          <span className="palette-prompt">$ sudo homelab find</span>
          <input ref={input} value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={onKey} placeholder="jellyfin, dns, photos…" spellCheck={false} />
          <kbd>esc</kbd>
        </div>
        <ul className="palette-list">
          {results.length === 0 && <li className="palette-empty">No matches for “{q}”. Try a category like “media”.</li>}
          {results.map((r, i) => (
            <li key={r.kind + r.id} className={`palette-item ${i === sel ? 'sel' : ''}`} onMouseEnter={() => setSel(i)} onClick={() => choose(r)} style={{ '--accent': r.accent }}>
              {r.kind === 'App' ? (
                <AppIcon icon={r.icon} name={r.name} size={30} accent={r.accent} original={r.original} />
              ) : (
                <span className="palette-glyph">{r.glyph || '⧉'}</span>
              )}
              <span className="palette-text">
                <strong>{r.name}</strong>
                <small>{r.sub}</small>
              </span>
              <span className="palette-kind">{r.kind}</span>
              <Icon.Arrow />
            </li>
          ))}
        </ul>
      </div>
    </div>
  )
}
