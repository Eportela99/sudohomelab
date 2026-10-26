import { useState } from 'react'
import { useCopy } from '../hooks'

const ICON_CDN = 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/'

// App / platform icon from dashboard-icons, with a monogram fallback.
export function AppIcon({ icon, name, size = 40, accent = '#5af78e', original }) {
  const [failed, setFailed] = useState(!icon)
  const style = { width: size, height: size, '--accent': accent }
  if (failed || original) {
    return (
      <span className={`app-icon mono ${original ? 'original' : ''}`} style={style} aria-hidden>
        {original ? <PromptGlyph /> : name.replace(/[^A-Za-z0-9]/g, '').slice(0, 2)}
      </span>
    )
  }
  return (
    <span className="app-icon" style={style} aria-hidden>
      <img src={`${ICON_CDN}${icon}.svg`} alt="" loading="lazy" onError={() => setFailed(true)} />
    </span>
  )
}

export function PromptGlyph({ className }) {
  return (
    <svg className={className} viewBox="0 0 64 64" fill="none" aria-hidden>
      <path d="M15 22l11 10-11 10" stroke="currentColor" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
      <rect x="31" y="39" width="18" height="5.5" rx="2.75" fill="currentColor" />
    </svg>
  )
}

export function Logo({ onClick }) {
  return (
    <a className="logo" href="#/" onClick={onClick}>
      <span className="logo-mark">
        <PromptGlyph />
      </span>
      <span className="logo-text">
        <span className="logo-sudo">sudo</span>
        <span className="logo-home">homelab</span>
        <span className="logo-cursor" />
      </span>
    </a>
  )
}

export function CopyButton({ text, label = 'Copy', className = '' }) {
  const [copied, copy] = useCopy()
  return (
    <button className={`btn-copy ${copied ? 'copied' : ''} ${className}`} onClick={() => copy(text)} aria-label="Copy command">
      <span className="btn-copy-inner">
        {copied ? (
          <>
            <Icon.Check /> Copied
          </>
        ) : (
          <>
            <Icon.Copy /> {label}
          </>
        )}
      </span>
    </button>
  )
}

export function StatusBadge({ status = 'planned' }) {
  const label = { planned: 'Coming soon', beta: 'Beta', ready: 'Ready', official: 'Official install' }[status]
  return <span className={`badge badge-${status}`}>{label}</span>
}

export const Icon = {
  Copy: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="12" height="12" rx="2" /><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" /></svg>
  ),
  Check: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><path d="M20 6 9 17l-5-5" /></svg>
  ),
  Download: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3" /></svg>
  ),
  Search: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></svg>
  ),
  Arrow: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12h14M13 6l6 6-6 6" /></svg>
  ),
  Back: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M19 12H5M11 18l-6-6 6-6" /></svg>
  ),
  Close: () => (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M18 6 6 18M6 6l12 12" /></svg>
  ),
  GitHub: () => (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M12 .5a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.6-1.4-1.4-1.8-1.4-1.8-1.1-.7.1-.7.1-.7 1.2.1 1.9 1.2 1.9 1.2 1.1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.7-.3-5.5-1.3-5.5-5.9 0-1.3.5-2.4 1.2-3.2-.1-.3-.5-1.5.1-3.2 0 0 1-.3 3.3 1.2a11.5 11.5 0 0 1 6 0c2.3-1.5 3.3-1.2 3.3-1.2.7 1.7.2 2.9.1 3.2.8.8 1.2 1.9 1.2 3.2 0 4.6-2.8 5.6-5.5 5.9.4.4.8 1.1.8 2.2v3.3c0 .3.2.7.8.6A12 12 0 0 0 12 .5Z" /></svg>
  ),
  Trash: () => (
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6" /></svg>
  ),
  Spark: () => (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1" /><circle cx="12" cy="12" r="3" /></svg>
  ),
  Chip: () => (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="6" y="6" width="12" height="12" rx="2" /><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4" /></svg>
  ),
}

// Text with `inline code` spans.
export function Rich({ text }) {
  return text.split(/(`[^`]+`)/).map((part, i) =>
    part.startsWith('`') && part.endsWith('`') ? <code key={i}>{part.slice(1, -1)}</code> : part
  )
}
