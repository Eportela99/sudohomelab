import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { nodeInfo } from '../data/catalog'
import { AppIcon, StatusBadge } from './Bits'
import { InstallBox } from './Install'

const NODE_W = 150
const NODE_H = 46
const ROW_H = 66

export function defaultSelection(stack) {
  return Object.fromEntries(stack.options.map((o) => [o.key, o.default]))
}

// Turn the stack definition + current choices into concrete nodes and edges.
export function resolveStack(stack, sel) {
  const asList = (v) => (Array.isArray(v) ? v : v ? [v] : [])
  const active = new Set(stack.core)
  stack.options.forEach((o) => {
    if (o.diagram !== false) asList(sel[o.key]).forEach((id) => active.add(id))
  })
  const expand = (end) => (end.startsWith('$') ? asList(sel[end.slice(1)]) : [end])
  const edges = []
  stack.wires.forEach(([a, b, label]) => {
    expand(a).forEach((from) =>
      expand(b).forEach((to) => {
        if (active.has(from) && active.has(to) && from !== to) edges.push({ from, to, label, id: `${from}>${to}` })
      })
    )
  })
  return { nodes: [...active], edges }
}

// Column = distance from the sink, so the "end" of each pipeline sits on the right.
function layout(nodes, edges) {
  const out = Object.fromEntries(nodes.map((n) => [n, []]))
  edges.forEach((e) => out[e.from].push(e.to))
  const memo = {}
  const toSink = (n, seen = new Set()) => {
    if (memo[n] != null) return memo[n]
    if (seen.has(n)) return 0
    seen.add(n)
    const v = out[n].length ? 1 + Math.max(...out[n].map((m) => toSink(m, seen))) : 0
    return (memo[n] = v)
  }
  const depth = Math.max(0, ...nodes.map((n) => toSink(n)))
  const cols = Array.from({ length: depth + 1 }, () => [])
  nodes.forEach((n) => cols[depth - toSink(n)].push(n))
  return cols
}

export function WireDiagram({ stack, sel, accent }) {
  const { nodes, edges } = useMemo(() => resolveStack(stack, sel), [stack, sel])
  const cols = useMemo(() => layout(nodes, edges), [nodes, edges])
  const box = useRef()
  const [width, setWidth] = useState(800)
  const [hover, setHover] = useState(null)
  const lit = (e) => hover && (e.from === hover || e.to === hover)

  useLayoutEffect(() => {
    const ro = new ResizeObserver(([e]) => setWidth(Math.max(e.contentRect.width, cols.length * (NODE_W + 40))))
    ro.observe(box.current)
    return () => ro.disconnect()
  }, [cols.length])

  const rows = Math.max(...cols.map((c) => c.length))
  const height = rows * ROW_H + 30
  const gap = cols.length > 1 ? (width - NODE_W - 24) / (cols.length - 1) : 0
  const pos = {}
  cols.forEach((col, ci) => {
    const offset = (height - col.length * ROW_H) / 2
    col.forEach((n, ri) => {
      pos[n] = { x: 12 + ci * gap, y: offset + ri * ROW_H + (ROW_H - NODE_H) / 2 }
    })
  })

  const path = (e) => {
    const a = pos[e.from]
    const b = pos[e.to]
    const x1 = a.x + NODE_W
    const y1 = a.y + NODE_H / 2
    const x2 = b.x
    const y2 = b.y + NODE_H / 2
    const dx = Math.max(40, (x2 - x1) / 2)
    return `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`
  }

  return (
    <div className="wire-scroll" ref={box}>
      <div className={`wire ${hover ? 'has-hover' : ''}`} style={{ width, height, '--accent': accent }}>
        <svg width={width} height={height} className="wire-svg">
          <defs>
            <linearGradient id={`wg-${stack.id}`} x1="0" x2="1">
              <stop offset="0" stopColor={accent} stopOpacity="0.15" />
              <stop offset="1" stopColor={accent} stopOpacity="0.85" />
            </linearGradient>
          </defs>
          {edges.map((e, i) => {
            const d = path(e)
            return (
              <g key={e.id} className={`wire-edge ${lit(e) ? 'lit' : ''}`}>
                <path d={d} className="wire-base" />
                <path d={d} className="wire-line" stroke={`url(#wg-${stack.id})`} pathLength="1" />
                <path d={d} className="wire-flow" />
                <circle r="3.5" className="wire-packet">
                  <animateMotion dur={`${2.2 + (i % 4) * 0.4}s`} repeatCount="indefinite" path={d} begin={`${(i * 0.37) % 2}s`} />
                </circle>
              </g>
            )
          })}
        </svg>
        {edges.filter(lit).map((e) => {
          const a = pos[e.from]
          const b = pos[e.to]
          return (
            <span key={'l' + e.id} className="wire-label" style={{ left: (a.x + NODE_W + b.x) / 2, top: (a.y + b.y + NODE_H) / 2 }}>
              {e.label}
            </span>
          )
        })}
        {nodes.map((n) => {
          const info = nodeInfo(n)
          return (
            <div
              key={n}
              className={`wire-node ${hover === n ? 'lit' : ''}`}
              style={{ left: pos[n].x, top: pos[n].y, width: NODE_W, height: NODE_H }}
              onMouseEnter={() => setHover(n)}
              onMouseLeave={() => setHover(null)}
            >
              <AppIcon icon={info.icon} name={info.name} size={24} accent={accent} original={info.original} />
              <span>{info.name}</span>
            </div>
          )
        })}
      </div>
      <span className="wire-hint">hover a service to trace its connections</span>
    </div>
  )
}

function OptionChips({ opt, value, onChange, accent }) {
  const list = Array.isArray(value) ? value : [value]
  const toggle = (c) => {
    if (opt.type === 'one') onChange(c)
    else onChange(list.includes(c) ? list.filter((x) => x !== c) : [...list, c])
  }
  return (
    <div className="opt">
      <span className="opt-label">
        {opt.label}
        <small>{opt.type === 'one' ? 'pick one' : 'pick any'}</small>
      </span>
      <div className="opt-chips">
        {opt.choices.map((c) => {
          const info = nodeInfo(c)
          const on = list.includes(c)
          return (
            <button key={c} className={`chip ${on ? 'on' : ''} ${opt.type}`} onClick={() => toggle(c)} style={{ '--accent': accent }}>
              {info.icon !== undefined || info.desc ? <AppIcon icon={info.icon} name={info.name} size={18} accent={accent} original={info.original} /> : <span className="chip-dot" />}
              {info.name}
            </button>
          )
        })}
      </div>
    </div>
  )
}

export function StackBuilder({ stack, folder, accent, supported }) {
  const [sel, setSel] = useState(() => defaultSelection(stack))
  useEffect(() => setSel(defaultSelection(stack)), [stack])

  const flags = stack.options
    .map((o) => [o.key, Array.isArray(sel[o.key]) ? sel[o.key].join(',') : sel[o.key]])
    .filter(([, v]) => v)
  const { nodes } = resolveStack(stack, sel)
  const extrasOff = stack.options.filter((o) => o.diagram === false).flatMap((o) => sel[o.key] || [])

  return (
    <section className="stack" style={{ '--accent': accent }}>
      <div className="stack-glow" />
      <div className="stack-head">
        <div>
          <span className="eyebrow">
            <span className="pulse-dot" /> Pre-wired stack
          </span>
          <h2>{stack.name}</h2>
          <p>{stack.pitch}</p>
        </div>
        <StatusBadge status={stack.available?.length ? 'beta' : 'planned'} />
      </div>
      <div className="stack-opts">
        {stack.options.map((o) => (
          <OptionChips key={o.key} opt={o} value={sel[o.key]} accent={accent} onChange={(v) => setSel((s) => ({ ...s, [o.key]: v }))} />
        ))}
      </div>
      <WireDiagram stack={stack} sel={sel} accent={accent} />
      <div className="stack-summary">
        <span>
          <strong>{nodes.length}</strong> services
        </span>
        {extrasOff.length > 0 && (
          <span>
            <strong>{extrasOff.length}</strong> {stack.id === 'ai-stack' ? 'models pre-pulled' : 'add-ons enabled'}
          </span>
        )}
        <span>
          <strong>0</strong> manual config steps
        </span>
      </div>
      <InstallBox name={stack.name} folder={folder} script={stack.id} supported={supported} available={stack.available} flags={flags} accent={accent} />
    </section>
  )
}
