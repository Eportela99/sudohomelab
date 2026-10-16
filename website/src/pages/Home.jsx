import { useEffect, useRef, useState } from 'react'
import { ALL_APPS, CATEGORIES, STACKS, categoryById } from '../data/catalog'
import { PLATFORMS } from '../data/platforms'
import { spotlight, useReveal } from '../hooks'
import { AppIcon, CopyButton, Icon } from '../components/Bits'
import NetworkCanvas from '../components/NetworkCanvas'
import Terminal from '../components/Terminal'
import { StackBuilder } from '../components/Stack'
import { supportedFor } from './Category'

// Cycles through words with a quick character-scramble transition.
function Scramble({ words }) {
  const [text, setText] = useState(words[0])
  const i = useRef(0)
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    const glyphs = '!<>-_\\/[]{}=+*^?#01'
    let frame
    const id = setInterval(() => {
      i.current = (i.current + 1) % words.length
      const target = words[i.current]
      let n = 0
      cancelAnimationFrame(frame)
      const tick = () => {
        n++
        const out = target
          .split('')
          .map((ch, k) => (k < n / 2 ? ch : ch === ' ' ? ' ' : glyphs[Math.floor(Math.random() * glyphs.length)]))
          .join('')
        setText(out)
        if (n / 2 < target.length) frame = requestAnimationFrame(tick)
      }
      tick()
    }, 2800)
    return () => {
      clearInterval(id)
      cancelAnimationFrame(frame)
    }
  }, [words])
  return <span className="scramble">{text}</span>
}

function CountUp({ to, suffix = '' }) {
  const [n, setN] = useState(0)
  const ref = useRef()
  useEffect(() => {
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return
      io.disconnect()
      const t0 = performance.now()
      const step = (t) => {
        const p = Math.min(1, (t - t0) / 1200)
        setN(Math.round(to * (1 - Math.pow(1 - p, 3))))
        if (p < 1) requestAnimationFrame(step)
      }
      requestAnimationFrame(step)
    })
    io.observe(ref.current)
    return () => io.disconnect()
  }, [to])
  return (
    <span ref={ref}>
      {n}
      {suffix}
    </span>
  )
}

function Hero() {
  const oneLiner = 'curl -fsSL sudohomelab.com | bash' // future interactive menu
  return (
    <section className="hero">
      <NetworkCanvas />
      <div className="hero-grid-bg" />
      <div className="orb-bg o1" />
      <div className="orb-bg o2" />
      <div className="container hero-inner">
        <div className="hero-copy">
          <a href="#/stacks" className="hero-pill">
            <span className="pulse-dot" /> v0.1 preview · Pre-wired stacks are coming <Icon.Arrow />
          </a>
          <h1>
            Your entire homelab,
            <br />
            <span className="grad">
              <Scramble words={['one command away.', 'already wired up.', 'on any platform.', 'sized to fit.']} />
            </span>
          </h1>
          <p className="hero-sub">
            One-line installers and fully pre-configured stacks for <strong>Proxmox</strong>, <strong>TrueNAS</strong>, <strong>Ubuntu Server</strong>, <strong>Windows</strong> and <strong>macOS</strong>. Plus an AI advisor that tells you what your hardware can actually handle.
          </p>
          <div className="hero-ctas">
            <a href="#/catalog" className="btn-primary">
              Browse the catalog <Icon.Arrow />
            </a>
            <a href="#/advisor" className="btn-secondary">
              <Icon.Spark /> Ask the AI advisor
            </a>
          </div>
          <div className="hero-cmd">
            <span className="cmd-shell">$</span>
            <code>{oneLiner}</code>
            <CopyButton text={oneLiner} label="" />
          </div>
          <small className="hero-cmd-hint">Interactive menu: pick apps, pick a platform, done.</small>
        </div>
        <div className="hero-term">
          <Terminal />
        </div>
      </div>
      <div className="scroll-hint">
        <span />
      </div>
    </section>
  )
}

function PlatformStrip() {
  const icons = ALL_APPS.filter((a) => a.icon)
  return (
    <section className="strip">
      <div className="container">
        <p className="strip-label reveal">One catalog · five platforms · same one-liner experience</p>
        <div className="strip-plats reveal">
          {PLATFORMS.map((p, i) => (
            <div key={p.id} className="strip-plat" style={{ '--d': `${i * 80}ms` }}>
              <AppIcon icon={p.icon} name={p.short} size={34} />
              <span>{p.name}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="marquee" aria-hidden>
        {[0, 1].map((k) => (
          <div className="marquee-track" key={k}>
            {icons.map((a) => (
              <span key={a.id} className="marquee-item" style={{ '--accent': a.accent }}>
                <AppIcon icon={a.icon} name={a.name} size={22} accent={a.accent} />
                {a.name}
              </span>
            ))}
          </div>
        ))}
      </div>
    </section>
  )
}

function Stats() {
  const stats = [
    { n: ALL_APPS.length, s: '+', l: 'apps in the catalog' },
    { n: STACKS.length, s: '', l: 'pre-wired stacks' },
    { n: PLATFORMS.length, s: '', l: 'supported platforms' },
    { n: 0, s: '', l: 'config files to edit by hand', zero: true },
  ]
  return (
    <section className="container stats">
      {stats.map((s, i) => (
        <div key={i} className="stat reveal" style={{ '--d': `${i * 80}ms` }}>
          <strong className={s.zero ? 'zero' : ''}>{s.zero ? '0' : <CountUp to={s.n} suffix={s.s} />}</strong>
          <span>{s.l}</span>
        </div>
      ))}
    </section>
  )
}

// Three wide cards keep the 3-column bento grid free of gaps (9 cards + 3 = 12 cells).
const WIDE = new Set([0, 5, 8])

function Categories() {
  return (
    <section className="container section" id="categories">
      <div className="section-head reveal">
        <span className="eyebrow">The catalog</span>
        <h2>Everything a homelab runs.</h2>
        <p>Install any app on its own, or grab the whole category as a stack that’s already configured end-to-end.</p>
      </div>
      <div className="cat-grid">
        {CATEGORIES.map((c, i) => (
          <a key={c.id} href={`#/c/${c.id}`} className={`cat-card reveal ${WIDE.has(i) ? 'wide' : ''}`} style={{ '--accent': c.accent, '--d': `${(i % 3) * 70}ms` }} onMouseMove={spotlight}>
            <div className="cat-top">
              <span className="cat-glyph">{c.glyph}</span>
              {c.stack && <span className="badge badge-stack">Stack available</span>}
            </div>
            <h3>{c.name}</h3>
            <p>{c.tagline}</p>
            <div className="cat-foot">
              <span className="cat-icons">
                {c.apps.slice(0, WIDE.has(i) ? 8 : 5).map((a) => (
                  <AppIcon key={a.id} icon={a.icon} name={a.name} size={28} accent={c.accent} original={a.original} />
                ))}
              </span>
              <span className="cat-count">
                {c.apps.length} apps <Icon.Arrow />
              </span>
            </div>
          </a>
        ))}
      </div>
    </section>
  )
}

function FeaturedStack() {
  const media = categoryById.media
  return (
    <section className="container section">
      <div className="section-head reveal">
        <span className="eyebrow">Why sudo homelab</span>
        <h2>
          Stop wiring apps together <span className="strike">by hand</span>.
        </h2>
        <p>Other script sites install apps. We install them already connected: API keys exchanged, indexers synced, download clients and libraries mapped. Try it, flip the options and watch the wiring change.</p>
      </div>
      <div className="reveal">
        <StackBuilder stack={media.stack} folder={media.folder} accent={media.accent} supported={supportedFor(media)} />
      </div>
    </section>
  )
}

function AdvisorTeaser() {
  return (
    <section className="container section">
      <div className="teaser reveal">
        <div className="teaser-copy">
          <span className="eyebrow">
            <Icon.Spark /> AI Hardware Advisor
          </span>
          <h2>Not sure what your box can handle?</h2>
          <p>Tell the advisor what you’re running: an N100 mini PC, an old Dell Optiplex, a 64-core EPYC. It recommends a host OS, the stacks that fit, and warns you before you run out of RAM.</p>
          <a href="#/advisor" className="btn-primary">
            Start the hardware check <Icon.Arrow />
          </a>
        </div>
        <div className="teaser-chat" aria-hidden>
          <div className="msg user t1">
            <div className="msg-bubble">Dell Optiplex 7060, i5-8500T, 16 GB RAM, 2 TB SSD</div>
          </div>
          <div className="msg bot t2">
            <span className="msg-avatar">
              <Icon.Chip />
            </span>
            <div className="msg-bubble">
              Nice box. QuickSync on that i5 handles <b>3–4 Plex 4K transcodes</b>. I’d run <b>Proxmox</b> with:
              <ul>
                <li>
                  <span className="ok">✓</span> Media Stack in an LXC
                </li>
                <li>
                  <span className="ok">✓</span> Home Assistant OS as a VM
                </li>
                <li>
                  <span className="ok">✓</span> Pi-hole + Unbound
                </li>
                <li>
                  <span className="warn">!</span> Skip local LLMs, RAM is tight
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

function HowItWorks() {
  const steps = [
    { n: '01', t: 'Pick your platform', d: 'Proxmox LXC, TrueNAS app, Docker on Ubuntu, or native on Windows & macOS. The site remembers your choice.' },
    { n: '02', t: 'Choose an app or a stack', d: 'Single installs for quick wins, or a stack with every option you want toggled on.' },
    { n: '03', t: 'Paste one line', d: 'Copy the command or download the script. Read it first; every script is open source on GitHub.' },
  ]
  return (
    <section className="container section">
      <div className="section-head reveal">
        <span className="eyebrow">How it works</span>
        <h2>Three steps. No YAML archaeology.</h2>
      </div>
      <div className="steps">
        {steps.map((s, i) => (
          <div key={s.n} className="step reveal" style={{ '--d': `${i * 100}ms` }}>
            <span className="step-n">{s.n}</span>
            <h3>{s.t}</h3>
            <p>{s.d}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

function Trust() {
  return (
    <section className="container section">
      <div className="trust reveal">
        <div>
          <span className="eyebrow">Read before you run</span>
          <h2>Transparent by default.</h2>
          <p>Piping scripts to a shell takes trust. Every installer is open source, versioned and short enough to read. Each one prints exactly what it’s about to do and waits for you to confirm.</p>
        </div>
        <ul className="trust-list">
          <li>
            <Icon.Check /> Source on GitHub, linked from every command
          </li>
          <li>
            <Icon.Check /> Dry-run mode: <code>--dry-run</code>
          </li>
          <li>
            <Icon.Check /> SHA-256 checksums for every release
          </li>
          <li>
            <Icon.Check /> Clean uninstall for everything we install
          </li>
        </ul>
      </div>
    </section>
  )
}

export default function Home() {
  useReveal()
  return (
    <>
      <Hero />
      <PlatformStrip />
      <Stats />
      <Categories />
      <FeaturedStack />
      <AdvisorTeaser />
      <HowItWorks />
      <Trust />
    </>
  )
}
