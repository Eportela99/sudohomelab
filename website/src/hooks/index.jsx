import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'

// ── Hash router ───────────────────────────────────────────────────────────
// Routes: #/  ·  #/c/:category  ·  #/c/:category/:app  ·  #/advisor  ·  #/stacks
function parseHash() {
  const parts = window.location.hash.replace(/^#\/?/, '').split('/').filter(Boolean)
  return { page: parts[0] || 'home', params: parts.slice(1) }
}

export function useRoute() {
  const [route, setRoute] = useState(parseHash)
  useEffect(() => {
    const onChange = () => setRoute(parseHash())
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return route
}

export const go = (path) => {
  window.location.hash = path
}

// ── Safe localStorage ─────────────────────────────────────────────────────
function load(key, fallback) {
  try {
    const v = localStorage.getItem(key)
    return v == null ? fallback : JSON.parse(v)
  } catch {
    return fallback
  }
}
function save(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    /* storage unavailable */
  }
}

// ── Selected platform (shared across the whole site) ──────────────────────
const PlatformContext = createContext(null)

export function PlatformProvider({ children }) {
  const [platform, setPlatformState] = useState(() => load('shl.platform', 'linux'))
  const setPlatform = useCallback((p) => {
    setPlatformState(p)
    save('shl.platform', p)
  }, [])
  return <PlatformContext.Provider value={{ platform, setPlatform }}>{children}</PlatformContext.Provider>
}

export const usePlatform = () => useContext(PlatformContext)

// ── Reveal-on-scroll ──────────────────────────────────────────────────────
export function useReveal() {
  useEffect(() => {
    const els = document.querySelectorAll('.reveal:not(.in)')
    const io = new IntersectionObserver(
      (entries) =>
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add('in')
            io.unobserve(e.target)
          }
        }),
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    )
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  })
}

// ── Clipboard with a short "copied" state ─────────────────────────────────
export function useCopy(timeout = 1600) {
  const [copied, setCopied] = useState(false)
  const t = useRef()
  const copy = useCallback(
    async (text) => {
      try {
        await navigator.clipboard.writeText(text)
      } catch {
        const ta = document.createElement('textarea')
        ta.value = text
        document.body.appendChild(ta)
        ta.select()
        document.execCommand('copy')
        ta.remove()
      }
      setCopied(true)
      clearTimeout(t.current)
      t.current = setTimeout(() => setCopied(false), timeout)
    },
    [timeout]
  )
  return [copied, copy]
}

// ── Mouse-follow spotlight for cards ──────────────────────────────────────
export function spotlight(e) {
  const r = e.currentTarget.getBoundingClientRect()
  e.currentTarget.style.setProperty('--mx', `${e.clientX - r.left}px`)
  e.currentTarget.style.setProperty('--my', `${e.clientY - r.top}px`)
}

export function downloadText(filename, text) {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/plain' }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
