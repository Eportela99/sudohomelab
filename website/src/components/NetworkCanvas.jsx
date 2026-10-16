import { useEffect, useRef } from 'react'

// Drifting "server" nodes that link up when close, with data packets
// travelling along the links. Reacts to the mouse.
export default function NetworkCanvas({ density = 0.00009 }) {
  const ref = useRef()

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas.getContext('2d')
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const colors = ['90,247,142', '87,199,255', '179,140,255']
    let w, h, dpr, nodes, packets, raf
    const mouse = { x: -9999, y: -9999 }
    const LINK = 150

    function init() {
      dpr = Math.min(window.devicePixelRatio || 1, 2)
      w = canvas.clientWidth
      h = canvas.clientHeight
      canvas.width = w * dpr
      canvas.height = h * dpr
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      const n = Math.max(24, Math.min(90, Math.round(w * h * density)))
      nodes = Array.from({ length: n }, () => ({
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.25,
        vy: (Math.random() - 0.5) * 0.25,
        r: Math.random() * 1.6 + 0.8,
        c: colors[Math.floor(Math.random() * colors.length)],
        pulse: Math.random() * Math.PI * 2,
      }))
      packets = []
    }

    function frame() {
      ctx.clearRect(0, 0, w, h)
      for (const n of nodes) {
        n.x += n.vx
        n.y += n.vy
        if (n.x < 0 || n.x > w) n.vx *= -1
        if (n.y < 0 || n.y > h) n.vy *= -1
        const dx = n.x - mouse.x
        const dy = n.y - mouse.y
        const d = Math.hypot(dx, dy)
        if (d < 120) {
          n.x += (dx / d) * 0.6
          n.y += (dy / d) * 0.6
        }
        n.pulse += 0.03
      }

      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const a = nodes[i]
          const b = nodes[j]
          const d = Math.hypot(a.x - b.x, a.y - b.y)
          if (d < LINK) {
            const alpha = (1 - d / LINK) * 0.22
            ctx.strokeStyle = `rgba(${a.c},${alpha})`
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(a.x, a.y)
            ctx.lineTo(b.x, b.y)
            ctx.stroke()
            if (!reduce && Math.random() < 0.0009) packets.push({ a, b, t: 0, s: 0.008 + Math.random() * 0.012 })
          }
        }
      }

      packets = packets.filter((p) => p.t <= 1 && Math.hypot(p.a.x - p.b.x, p.a.y - p.b.y) < LINK * 1.2)
      for (const p of packets) {
        p.t += p.s
        const x = p.a.x + (p.b.x - p.a.x) * p.t
        const y = p.a.y + (p.b.y - p.a.y) * p.t
        const g = ctx.createRadialGradient(x, y, 0, x, y, 7)
        g.addColorStop(0, `rgba(${p.a.c},0.95)`)
        g.addColorStop(1, `rgba(${p.a.c},0)`)
        ctx.fillStyle = g
        ctx.beginPath()
        ctx.arc(x, y, 7, 0, Math.PI * 2)
        ctx.fill()
      }

      for (const n of nodes) {
        const glow = 0.5 + Math.sin(n.pulse) * 0.3
        ctx.fillStyle = `rgba(${n.c},${glow})`
        ctx.beginPath()
        ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2)
        ctx.fill()
      }
      if (!reduce) raf = requestAnimationFrame(frame)
    }

    const onMove = (e) => {
      const r = canvas.getBoundingClientRect()
      mouse.x = e.clientX - r.left
      mouse.y = e.clientY - r.top
    }
    const onLeave = () => {
      mouse.x = mouse.y = -9999
    }
    const onResize = () => {
      cancelAnimationFrame(raf)
      init()
      frame()
    }

    init()
    frame()
    window.addEventListener('resize', onResize)
    window.addEventListener('mousemove', onMove)
    document.addEventListener('mouseleave', onLeave)
    return () => {
      cancelAnimationFrame(raf)
      window.removeEventListener('resize', onResize)
      window.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseleave', onLeave)
    }
  }, [density])

  return <canvas ref={ref} className="net-canvas" aria-hidden />
}
