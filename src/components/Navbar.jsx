import { useEffect, useState } from 'react'
import { Icon, Logo } from './Bits'
import { GITHUB_REPO } from '../data/platforms'

export default function Navbar({ page, onSearch }) {
  const [scrolled, setScrolled] = useState(false)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  const links = [
    { href: '#/catalog', label: 'Catalog', active: page === 'catalog' || page === 'c' },
    { href: '#/stacks', label: 'Stacks', active: page === 'stacks' },
    { href: '#/advisor', label: 'AI Advisor', active: page === 'advisor', spark: true },
  ]

  return (
    <header className={`nav ${scrolled ? 'nav-scrolled' : ''}`}>
      <div className="nav-inner">
        <Logo onClick={() => setOpen(false)} />
        <nav className={`nav-links ${open ? 'open' : ''}`}>
          {links.map((l) => (
            <a key={l.href} href={l.href} className={`nav-link ${l.active ? 'active' : ''}`} onClick={() => setOpen(false)}>
              {l.spark && <span className="nav-spark" />}
              {l.label}
            </a>
          ))}
        </nav>
        <div className="nav-actions">
          <button className="nav-search" onClick={onSearch}>
            <Icon.Search />
            <span>Search apps</span>
            <kbd>⌘K</kbd>
          </button>
          <a className="nav-icon-btn" href={GITHUB_REPO} target="_blank" rel="noreferrer" aria-label="GitHub">
            <Icon.GitHub />
          </a>
          <button className={`nav-burger ${open ? 'open' : ''}`} onClick={() => setOpen(!open)} aria-label="Menu">
            <span />
            <span />
          </button>
        </div>
      </div>
    </header>
  )
}
