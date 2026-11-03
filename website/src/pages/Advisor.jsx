import { useEffect, useRef, useState } from 'react'
import { categoryById } from '../data/catalog'
import { Icon } from '../components/Bits'
import { parseGpu, suggest } from '../advisor/engine'

// Rule-based advisor (v1). The AI-model picks come from advisor/engine.js, the
// same catalog and math as the AI Node installer. The free-text AI chat
// (Claude, /api/advisor) will call those same functions as tools.

const STEPS = [
  { key: 'machine', q: 'What kind of machine are we working with?', chips: ['Mini PC', 'Old desktop / laptop', 'Rack / tower server', 'NAS', 'Raspberry Pi / SBC', 'Gaming PC'] },
  { key: 'cpu', q: 'Which CPU does it have? Type the model if you know it.', chips: ['Intel N100 / N150', 'Intel i5 / i7 (8th gen+)', 'AMD Ryzen 5 / 7', 'Xeon / EPYC', 'Raspberry Pi 5'], free: true, ph: 'e.g. Intel i5-12500T' },
  { key: 'ram', q: 'How much RAM?', chips: ['4 GB', '8 GB', '16 GB', '32 GB', '64 GB', '128 GB+'] },
  { key: 'storage', q: 'Roughly how much storage?', chips: ['< 500 GB', '1–2 TB', '4–10 TB', '10 TB+'] },
  { key: 'gpu', q: 'Any GPU? Integrated graphics count, they’re great for transcoding.', chips: ['None', 'Intel iGPU (QuickSync)', 'NVIDIA', 'AMD'] },
  { key: 'gpuModel', q: 'Which card? Type the model with its memory, like “RTX 3060 12GB”, or just pick the VRAM.', chips: ['4 GB', '6 GB', '8 GB', '10 GB', '12 GB', '16 GB', '20 GB', '24 GB', '32 GB', '48 GB'], free: true, ph: 'e.g. RTX 3060 12GB',
    when: (a) => a.gpu === 'NVIDIA' || a.gpu === 'AMD',
    check: (v, a) => (parseGpu(v, a.gpu.toLowerCase()).vram ? null : 'I need the memory size too, like “RTX 3060 12GB”, or pick one of the sizes below 👇') },
  { key: 'goals', q: 'Last one. What do you want to run? Pick as many as you like.', chips: ['Media', 'Cloud & Photos', 'Smart Home', 'Ad-blocking', 'AI', 'Monitoring'], multi: true },
]

const GOAL_CAT = { Media: 'media', 'Cloud & Photos': 'cloud', 'Smart Home': 'home', 'Ad-blocking': 'network', AI: 'ai', Monitoring: 'ops' }

// Next step after `i` that applies to these answers (-1 = done).
const nextStep = (i, a) => {
  for (let j = i + 1; j < STEPS.length; j++) if (!STEPS[j].when || STEPS[j].when(a)) return j
  return -1
}

function analyze(a) {
  const ram = parseInt(a.ram, 10) || 8
  const cpu = a.cpu.toLowerCase()
  const tier = /n1\d0|n95|n97|celeron|atom|pi|j4125|j5005/.test(cpu) ? 1 : /xeon|epyc|ryzen 7|ryzen 9|i7|i9|threadripper/.test(cpu) ? 3 : 2
  const gpu = a.gpu
  const card = a.gpuModel ? parseGpu(a.gpuModel, gpu.toLowerCase()) : null
  const ai = suggest({ gpu: card, ramGb: ram })
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
      case 'ai': {
        const top = ai.picks[0]
        if (!top) {
          ;[fit, why, ramUse] = ['no', 'Not enough memory for a local model. Use Open WebUI with a remote API instead.', 0]
          break
        }
        const where = top.where === 'gpu' ? 'on your GPU' : top.where === 'split' ? 'split between GPU and CPU' : 'on the CPU'
        why = `${top.name} ${where}: ~${top.speed} tokens/s, ${top.ctx / 1024}k context. Models below.`
        ramUse = top.where === 'gpu' ? 1 : Math.ceil(top.ramUse)
        fit = top.speed >= 30 ? 'great' : top.speed >= 12 ? 'good' : top.speed >= 4 ? 'tight' : 'no'
        break
      }
      case 'ops':
        ramUse = 0.5
        why = 'Beszel + Uptime Kuma are tiny. Always worth running.'
        break
    }
    if (tier === 1 && fit === 'great' && ['media', 'cloud'].includes(cat.id)) fit = 'good'
    return { cat, fit, why, ramUse }
  })

  const overhead = platform.id === 'proxmox' ? 2 : platform.id === 'truenas' ? 4 : 1
  const used = overhead + recs.filter((r) => r.fit !== 'no').reduce((s, r) => s + r.ramUse, 0)
  const score = Math.round(Math.min(98, 30 + Math.min(ram, 64) * 0.6 + tier * 7 + (hwTranscode ? 8 : 0) + Math.min(tb, 16)))
  const verdict = score >= 90 ? 'Beast mode' : score >= 72 ? 'Excellent all-rounder' : score >= 55 ? 'Solid starter lab' : 'Lightweight lab'

  return { platform, recs, ram, used, overhead, score, verdict, ai: goals.includes('AI') ? ai : null }
}

function AiModels({ ai }) {
  if (!ai?.picks.length) return null
  const b = ai.budget
  return (
    <div className="ai-models">
      <div className="ram-label">
        <span>AI models for {b.mode === 'gpu' ? `${b.total} GB of VRAM` : `${b.total} GB of RAM (no GPU)`}</span>
        <span className="mono">{ai.engine.label}</span>
      </div>
      {ai.picks.slice(0, 4).map((p, i) => (
        <div key={p.id} className="ai-pick" style={{ '--d': `${i * 90}ms` }}>
          <span className="rec-body">
            <strong>{p.name}</strong>
            <small>
              {p.why} · {p.model.moe ? `MoE, ${p.model.active_params_b}B active` : `${p.model.params_b}B`} · {p.model.license}
            </small>
          </span>
          <span className="ai-stats mono">
            <span>{p.model.file_gb.toFixed(1)} GB</span>
            <span>
              {p.where === 'gpu' ? `${p.gpuUse.toFixed(1)} GB VRAM` : p.where === 'split' ? `${p.gpuUse.toFixed(1)} VRAM + ${p.ramUse.toFixed(1)} RAM` : `${p.ramUse.toFixed(1)} GB RAM`}
            </span>
            <span>{p.ctx / 1024}k ctx</span>
            <span className={p.measured ? 'measured' : ''}>
              ~{p.speed} tok/s{p.measured ? ' ✓' : ''}
            </span>
          </span>
        </div>
      ))}
      <small>
        Download · memory in use · context · speed (✓ measured on that GPU, otherwise an estimate). Same picks as the installer:{' '}
        <a href="#/c/ai">install with AI Node →</a>
      </small>
    </div>
  )
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
      <AiModels ai={r.ai} />
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
    setText('')
    setPicked([])
    const problem = s.check?.(value, answers)
    if (problem) {
      setMsgs((m) => [...m, { from: 'bot', content: problem, note: true }])
      return
    }
    const next = { ...answers, [s.key]: value }
    setAnswers(next)
    const n = nextStep(step, next)
    if (n >= 0) {
      setStep(-1)
      await bot(STEPS[n].q)
      setStep(n)
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
          <p>Answer a few quick questions. You’ll get a host-OS recommendation, the stacks that fit, a RAM budget and the AI models your GPU can run, before you install anything.</p>
          <div className="preview-flag">
            <span className="pulse-dot amber" /> Rule-based answers from the same model catalog as the AI Node installer. Free-text AI chat is coming soon.
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
            <input value={text} onChange={(e) => setText(e.target.value)} placeholder={s?.ph || 'Describe your hardware…'} disabled={!s} />
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
