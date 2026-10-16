import { useEffect, useRef, useState } from 'react'

// Scripted terminal session that types commands and streams output, looping
// through a few demos.
const SESSIONS = [
  {
    cmd: 'sudo homelab install media-stack --server=jellyfin',
    out: [
      ['dim', '› detecting platform … Proxmox VE 9.0 (pve-01)'],
      ['dim', '› creating LXC 120 "media" · 4 vCPU · 8 GB · iGPU passthrough'],
      ['ok', '✓ jellyfin      :8096'],
      ['ok', '✓ radarr        :7878'],
      ['ok', '✓ sonarr        :8989'],
      ['ok', '✓ prowlarr      :9696'],
      ['ok', '✓ qbittorrent   :8080'],
      ['ok', '✓ seerr         :5055'],
      ['info', '⚡ wiring  prowlarr → radarr, sonarr'],
      ['info', '⚡ wiring  radarr, sonarr → qbittorrent'],
      ['info', '⚡ wiring  seerr → jellyfin (auth) → radarr, sonarr'],
      ['accent', '★ media stack online in 2m 41s · http://media.home'],
    ],
  },
  {
    cmd: 'sudo homelab advise',
    out: [
      ['dim', '› scanning hardware …'],
      ['plain', '  cpu   Intel i5-12500T · 6C/12T · QuickSync'],
      ['plain', '  ram   32 GB DDR4'],
      ['plain', '  disk  1 TB NVMe + 2× 8 TB HDD'],
      ['accent', '✦ verdict: excellent all-rounder'],
      ['ok', '  ✓ Media Stack (Plex w/ hardware transcoding)'],
      ['ok', '  ✓ Immich + Nextcloud Suite'],
      ['ok', '  ✓ Home Assistant (VM)'],
      ['warn', '  ! Local LLMs: 7–8B models only, CPU inference'],
    ],
  },
  {
    cmd: 'sudo homelab install pihole --with=unbound',
    out: [
      ['dim', '› detecting platform … Ubuntu Server 24.04'],
      ['ok', '✓ docker found'],
      ['ok', '✓ pihole        :53 :80'],
      ['ok', '✓ unbound       :5335'],
      ['info', '⚡ wiring  pihole upstream → unbound'],
      ['accent', '★ point your router DNS to 192.168.1.20'],
    ],
  },
]

export default function Terminal() {
  const [idx, setIdx] = useState(0)
  const [typed, setTyped] = useState('')
  const [lines, setLines] = useState(0)
  const [phase, setPhase] = useState('typing')
  const timers = useRef([])

  useEffect(() => {
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const s = SESSIONS[idx]
    const later = (fn, ms) => timers.current.push(setTimeout(fn, ms))
    timers.current.forEach(clearTimeout)
    timers.current = []

    if (reduce) {
      setTyped(s.cmd)
      setLines(s.out.length)
      setPhase('done')
      return
    }

    setTyped('')
    setLines(0)
    setPhase('typing')
    let t = 400
    for (let i = 1; i <= s.cmd.length; i++) {
      t += 28 + Math.random() * 45
      later(() => setTyped(s.cmd.slice(0, i)), t)
    }
    t += 350
    later(() => setPhase('running'), t)
    s.out.forEach((_, i) => {
      t += i < 2 ? 420 : 170 + Math.random() * 160
      later(() => setLines(i + 1), t)
    })
    later(() => setPhase('done'), t)
    later(() => setIdx((idx + 1) % SESSIONS.length), t + 3800)
    return () => timers.current.forEach(clearTimeout)
  }, [idx])

  const s = SESSIONS[idx]
  return (
    <div className="terminal">
      <div className="terminal-bar">
        <span className="dot r" />
        <span className="dot y" />
        <span className="dot g" />
        <span className="terminal-title">root@homelab: ~</span>
        <span className="terminal-tabs">
          {SESSIONS.map((_, i) => (
            <button key={i} className={i === idx ? 'on' : ''} onClick={() => setIdx(i)} aria-label={`Demo ${i + 1}`} />
          ))}
        </span>
      </div>
      <div className="terminal-body">
        <div className="t-line">
          <span className="t-prompt">❯</span> <span className="t-cmd">{typed}</span>
          {phase === 'typing' && <span className="t-caret" />}
        </div>
        {s.out.slice(0, lines).map(([kind, text], i) => (
          <div key={idx + '-' + i} className={`t-line t-${kind} t-in`}>
            {text}
          </div>
        ))}
        {phase === 'running' && lines < s.out.length && <div className="t-line t-dim t-spin">⠋</div>}
        {phase === 'done' && (
          <div className="t-line">
            <span className="t-prompt">❯</span> <span className="t-caret" />
          </div>
        )}
      </div>
    </div>
  )
}
