import { useEffect, useRef, useState } from 'react'
import { categoryById } from '../data/catalog'
import { Icon } from '../components/Bits'

// PREVIEW: a scripted, rule-based conversation. The questions and the shape
// of the final report are what the real AI advisor will produce; the
// `analyze()` function gets replaced by a call to the model.

const STEPS = [
  { key: 'machine', q: 'What kind of machine are we working with?', chips: ['Mini PC', 'Old desktop / laptop', 'Rack / tower server', 'NAS', 'Raspberry Pi / SBC', 'Gaming PC'] },
  { key: 'cpu', q: 'Which CPU does it have? Type the model if you know it.', chips: ['Intel N100 / N150', 'Intel i5 / i7 (8th gen+)', 'AMD Ryzen 5 / 7', 'Xeon / EPYC', 'Raspberry Pi 5'], free: true },
  { key: 'ram', q: 'How much RAM?', chips: ['4 GB', '8 GB', '16 GB', '32 GB', '64 GB', '128 GB+'] },
  { key: 'storage', q: 'Roughly how much storage?', chips: ['< 500 GB', '1–2 TB', '4–10 TB', '10 TB+'] },
  { key: 'gpu', q: 'Any GPU? Integrated graphics count, they’re great for transcoding.', chips: ['None', 'Intel iGPU (QuickSync)', 'NVIDIA', 'AMD'] },
  { key: 'goals', q: 'Last one. What do you want to run? Pick as many as you like.', chips: ['Media', 'Cloud & Photos', 'Smart Home', 'Ad-blocking', 'AI', 'Monitoring'], multi: true },
]

const GOAL_CAT = { Media: 'media', 'Cloud & Photos': 'cloud', 'Smart Home': 'home', 'Ad-blocking': 'network', AI: 'ai', Monitoring: 'ops' }

function analyze(a) {
  const ram = parseInt(a.ram, 10) || 8
  const cpu = a.cpu.toLowerCase()
  const tier = /n1\d0|n95|n97|celeron|atom|pi|j4125|j5005/.test(cpu) ? 1 : /xeon|epyc|ryzen 7|ryzen 9|i7|i9|threadripper/.test(cpu) ? 3 : 2
  const gpu = a.gpu
  const tb = { '< 500 GB': 0.4, '1–2 TB': 1.5, '4–10 TB': 7, '10 TB+': 16 }[a.storage] ?? 1
  const hwTranscode = gpu !== 'None'

  const platform =
    a.machine === 'NAS' || tb >= 10
      ? { id: 'truenas', name: 'TrueNAS SCALE', why: 'Lots of storage. Let ZFS protect it and run apps alongside.' }
      : ram >= 16 && a.machine !== 'Raspberry Pi / SBC'
        ? { id: 'proxmox', name: 'Proxmox VE', why: 'Enough RAM to split services into LXCs and VMs with snapshots & backups.' }
        : { id: 'linux', name: 'Ubuntu Server', why: 'Lean host. Docker directly on bare metal keeps overhead minimal.' }

  const goals = a.goals.length ? a.goals : ['Media', 'Ad-blocking', 'Monitoring']
  const recs = goals.map((g) => {
    const cat = categoryById[GOAL_CAT[g]]
    let fit = 'great'
    let why = ''
    let ramUse = 1
    switch (cat.id) {
      case 'media':
        ramUse = 5
        if (!hwTranscode && tier < 3) [fit, why] = ['good', 'No hardware transcoding. Direct play is fine, but 4K transcodes will struggle.']
        else why = hwTranscode ? `${gpu} handles multiple 4K transcodes at once.` : 'Strong CPU can software-transcode a stream or two.'
        if (tb < 2) [fit, why] = ['tight', 'Storage is the bottleneck. Plan for at least 4 TB for a real library.']
        break
      case 'cloud':
        ramUse = 6
        if (ram < 8) [fit, why] = ['tight', 'Immich’s ML + Nextcloud want ~6 GB together. Pick one for now.']
        else why = 'Room for Nextcloud Suite and Immich with face recognition.'
        break
      case 'home':
        ramUse = 3
        why = platform.id === 'proxmox' ? 'Run Home Assistant OS as a VM for full add-on support.' : 'Home Assistant Container + MQTT run comfortably.'
        break
      case 'network':
        ramUse = 0.5
        why = 'Pi-hole + Unbound barely use resources. Give it a static IP.'
        break
      case 'ai':
        ramUse = gpu === 'NVIDIA' ? 8 : 12
        if (gpu === 'NVIDIA' && ram >= 16) why = 'NVIDIA GPU + RAM: 7–14B models run fast with Ollama.'
        else if (ram >= 32) [fit, why] = ['good', 'CPU-only, but enough RAM for 7–8B models at usable speed.']
        else if (ram >= 16) [fit, why] = ['tight', 'Small models only (≤ 3–4B). Consider Open WebUI against a cloud API.']
        else [fit, why] = ['no', 'Not enough RAM for local LLMs. Use Open WebUI with a remote API instead.']
        break
      case 'ops':
        ramUse = 0.5
        why = 'Beszel + Uptime Kuma are tiny. Always worth running.'
        break
    }
    if (tier === 1 && fit === 'great' && ['media', 'cloud', 'ai'].includes(cat.id)) fit = 'good'
    return { cat, fit, why, ramUse }
  })

  const overhead = platform.id === 'proxmox' ? 2 : platform.id === 'truenas' ? 4 : 1
  const used = overhead + recs.filter((r) => r.fit !== 'no').reduce((s, r) => s + r.ramUse, 0)
  const score = Math.round(Math.min(98, 30 + Math.min(ram, 64) * 0.6 + tier * 7 + (hwTranscode ? 8 : 0) + Math.min(tb, 16)))
  const verdict = score >= 90 ? 'Beast mode' : score >= 72 ? 'Excellent all-rounder' : score >= 55 ? 'Solid starter lab' : 'Lightweight lab'

  return { platform, recs, ram, used, overhead, score, verdict }
}

const FIT = { great: ['Great fit', 'var(--green)'], good: ['Good fit', 'var(--cyan)'], tight: ['Tight', 'var(--amber)'], no: ['Not recommended', 'var(--red)'] }

function Report({ r }) {
  const pct = Math.min(100, (r.used / r.ram) * 100)
  return (
    <div className="report">
      <div className="report-head">
        <div className="score" style={{ '--p': r.score }}>
          <svg viewBox="0 0 100 100">
            <circle cx="50" cy="50" r="44" className="score-track" />
            <circle cx="50" cy="50" r="44" className="score-bar" pathLength="100" />
          </svg>
          <strong>{r.score}</strong>
        </div>
        <div>
          <span className="eyebrow">Verdict</span>
          <h3>{r.verdict}</h3>
          <p>
            Suggested host OS: <strong>{r.platform.name}</strong>. {r.platform.why}
          </p>
        </div>
      </div>
      <div className="report-recs">
        {r.recs.map(({ cat, fit, why }, i) => (
          <a key={cat.id} href={`#/c/${cat.id}`} className="rec" style={{ '--accent': cat.accent, '--fit': FIT[fit][1], '--d': `${i * 90}ms` }}>
            <span className="rec-glyph">{cat.glyph}</span>
            <span className="rec-body">
              <strong>{cat.stack?.name || cat.name}</strong>
              <small>{why}</small>
            </span>
            <span className="rec-fit">{FIT[fit][0]}</span>
          </a>
        ))}
      </div>
      <div className="ram-budget">
        <div className="ram-label">
          <span>Estimated RAM budget</span>
          <span className="mono">
            ~{r.used} GB of {r.ram} GB
          </span>
        </div>
        <div className="ram-bar">
          <span style={{ width: `${pct}%`, background: pct > 90 ? 'var(--red)' : pct > 70 ? 'var(--amber)' : undefined }} />
        </div>
        <small>Includes ~{r.overhead} GB for the host OS. Leftover RAM becomes ZFS / page cache, which is free performance.</small>
      </div>
    </div>
  )
}

export default function Advisor() {
  const [msgs, setMsgs] = useState([])
  const [step, setStep] = useState(-1)
  const [answers, setAnswers] = useState({ goals: [] })
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState('')
  const [picked, setPicked] = useState([])
  const end = useRef()
  const session = useRef(0)

  // Rejects if the conversation was restarted while this message was "typing".
  const bot = (content, delay = 700) => {
    const id = session.current
    return new Promise((res, rej) => {
      setTyping(true)
      setTimeout(() => {
        if (id !== session.current) return rej(new Error('restarted'))
        setTyping(false)
        setMsgs((m) => [...m, { from: 'bot', content }])
        res()
      }, delay)
    })
  }

  const start = () => run(async () => {
    session.current++
    setMsgs([])
    setAnswers({ goals: [] })
    setPicked([])
    setStep(-1)
    await bot('Hey! I’m the sudo homelab advisor. Tell me about your hardware and I’ll tell you what it can run, and how to set it up.', 500)
    await bot(STEPS[0].q, 900)
    setStep(0)
  })

  const run = (fn) => fn().catch(() => {})

  useEffect(() => {
    start()
  }, [])

  useEffect(() => {
    end.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
  }, [msgs, typing, step])

  const answer = (value) => run(async () => {
    const s = STEPS[step]
    setMsgs((m) => [...m, { from: 'user', content: Array.isArray(value) ? value.join(', ') : value }])
    const next = { ...answers, [s.key]: value }
    setAnswers(next)
    setText('')
    setPicked([])
    if (step < STEPS.length - 1) {
      setStep(-1)
      await bot(STEPS[step + 1].q)
      setStep(step + 1)
    } else {
      setStep(-2)
      await bot('Crunching the numbers…', 600)
      await bot(<Report r={analyze(next)} />, 1400)
      await bot('Click any recommendation to jump to its installers. Want to try another machine?', 600)
      setStep(99)
    }
  })

  const onSubmit = (e) => {
    e.preventDefault()
    const v = text.trim()
    if (!v || step < 0 || step >= STEPS.length) return
    if (STEPS[step].free) answer(v)
    else {
      setMsgs((m) => [...m, { from: 'user', content: v }, { from: 'bot', content: 'Free-form answers unlock when the AI model is connected. For now, pick one of the options below 👇', note: true }])
      setText('')
    }
  }

  const s = STEPS[step]

  return (
    <div className="advisor-page">
      <div className="advisor-bg" />
      <div className="container advisor-wrap">
        <div className="advisor-intro reveal in">
          <span className="eyebrow">
            <Icon.Spark /> AI Hardware Advisor
          </span>
          <h1>
            What can your <span className="grad">hardware</span> run?
          </h1>
          <p>Answer six quick questions. You’ll get a host-OS recommendation, the stacks that fit, and a RAM budget before you install anything.</p>
          <div className="preview-flag">
            <span className="pulse-dot amber" /> Preview: rule-based answers. The AI model is coming soon.
          </div>
        </div>

        <div className="chat">
          <div className="chat-head">
            <span className="orb" />
            <div>
              <strong>homelab advisor</strong>
              <small>{typing ? 'typing…' : 'online'}</small>
            </div>
            <button className="btn-ghost sm" onClick={start}>
              Restart
            </button>
          </div>
          <div className="chat-body">
            {msgs.map((m, i) => (
              <div key={i} className={`msg ${m.from} ${m.note ? 'note' : ''}`}>
                {m.from === 'bot' && <span className="msg-avatar"><Icon.Chip /></span>}
                <div className="msg-bubble">{m.content}</div>
              </div>
            ))}
            {typing && (
              <div className="msg bot">
                <span className="msg-avatar"><Icon.Chip /></span>
                <div className="msg-bubble typing">
                  <i />
                  <i />
                  <i />
                </div>
              </div>
            )}
            {s && (
              <div className="quick" key={step}>
                {s.chips.map((c) => {
                  const on = picked.includes(c)
                  return (
                    <button key={c} className={`chip ${on ? 'on' : ''}`} onClick={() => (s.multi ? setPicked(on ? picked.filter((x) => x !== c) : [...picked, c]) : answer(c))}>
                      {s.multi && <span className="chip-dot" />}
                      {c}
                    </button>
                  )
                })}
                {s.multi && (
                  <button className="btn-primary sm" disabled={!picked.length} onClick={() => answer(picked)}>
                    Analyze <Icon.Arrow />
                  </button>
                )}
              </div>
            )}
            {step === 99 && (
              <div className="quick">
                <button className="btn-primary sm" onClick={start}>
                  Try another machine
                </button>
              </div>
            )}
            <div ref={end} />
          </div>
          <form className="chat-input" onSubmit={onSubmit}>
            <span className="t-prompt">❯</span>
            <input value={text} onChange={(e) => setText(e.target.value)} placeholder={s?.free ? 'e.g. Intel i5-12500T' : 'Describe your hardware…'} disabled={!s} />
            <button type="submit" className="btn-send" disabled={!text.trim() || !s} aria-label="Send">
              <Icon.Arrow />
            </button>
          </form>
        </div>
      </div>
    </div>
  )
}

export function AdvisorFab() {
  return (
    <a href="#/advisor" className="fab">
      <span className="orb sm" />
      <span className="fab-text">
        <strong>What can my hardware run?</strong>
        <small>Ask the AI advisor</small>
      </span>
      <Icon.Arrow />
    </a>
  )
}
