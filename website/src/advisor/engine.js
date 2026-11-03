// sudo homelab advisor: the rules engine.
// Pure JavaScript (no React), so the Advisor page, the future AI advisor
// (/api/advisor tools) and any remake of the website can share it.
// The model math is a port of AI_Tools/linux/ai-node.sh (the AI Node installer)
// and reads the same catalog, so the website and the installer agree.
import catalog from '../data/models.json'

const GiB = 1024 ** 3
const KV_BYTES = 34 / 32 // q8_0 KV cache: 34 bytes per 32 values
const HEADROOM = 0.5 // GiB left free on each GPU
const CPU_RESERVE = 3 // GiB of RAM left for the system on CPU-only
const CTX_STEPS = [8192, 16384, 32768, 65536, 131072]
const EFF_GPU = 0.95
const EFF_CPU = 0.55
const LAYER_GPU_S = 8e-5
const LAYER_CPU_S = 5e-5
const LAYER_MOE_S = 1.5e-4

export const models = catalog.models

// ── hardware ──────────────────────────────────────────────────────────────────

const RAM_BW = 50 // GB/s, a typical dual-channel DDR4/DDR5 desktop

/** "RTX 3060 12GB" → { name, vram, bw, bwKnown, vendor } (vram may be null if not given). */
export function parseGpu(text = '', vendor = '') {
  const t = String(text).trim()
  const m = t.match(/(\d+(?:\.\d+)?)\s*(?:gb|g\b)/i)
  const vram = m ? parseFloat(m[1]) : null
  const hit = catalog.gpus.find(([pat]) => t.toLowerCase().includes(pat.toLowerCase()))
  const v = vendor || (/radeon|rx\s?\d|amd|instinct|mi\d/i.test(t) ? 'amd' : /rtx|gtx|quadro|tesla|nvidia|a\d{3,4}|l4|t4/i.test(t) ? 'nvidia' : '')
  return {
    name: hit ? hit[0] : t,
    vram,
    bw: hit ? hit[1] : vram ? 120 + 25 * vram : null,
    bwKnown: Boolean(hit),
    vendor: v,
  }
}

export function engineFor(gpu) {
  if (!gpu || !gpu.vram) return { id: 'cpu', label: 'CPU (AVX2)' }
  if (gpu.vendor === 'amd') return { id: 'vulkan', label: 'Vulkan (ROCm on supported Linux cards)' }
  return { id: 'cuda', label: 'CUDA' }
}

// ── model math (same as the installer) ────────────────────────────────────────

const gib = (gb) => (gb * 1e9) / GiB
export const kvGib = (m, ctx) => (KV_BYTES * (m.kv.full * ctx + m.kv.swa * Math.min(ctx, m.kv.window + 512))) / GiB
const overhead = (m) => m.overhead_gib || 0.45 + 0.03 * gib(m.file_gb)

/** Memory budget: { mode: 'gpu'|'cpu', total, usable, tierGb, bw } */
export function budget({ gpu, ramGb }) {
  if (gpu?.vram) {
    return { mode: 'gpu', total: gpu.vram, usable: gpu.vram - HEADROOM, tierGb: Math.round(gpu.vram), bw: gpu.bw || 120 + 25 * gpu.vram, bwKnown: gpu.bwKnown }
  }
  return { mode: 'cpu', total: ramGb, usable: ramGb - CPU_RESERVE, tierGb: Math.round(ramGb), bw: RAM_BW, bwKnown: false }
}

function measuredOn(m, gpuName) {
  if (!gpuName) return null
  for (const [k, t] of Object.entries(m.tested || {})) {
    if (gpuName.toLowerCase().includes(k.toLowerCase()) && t?.tg) return t.tg
  }
  return null
}

/** How model `id` would run: context, where, memory use, speed. */
export function plan(id, hw, b = budget(hw)) {
  const m = models[id]
  const w = gib(m.file_gb)
  const ovh = overhead(m)
  const cap = Math.min(131072, m.ctx_max || 32768)
  const steps = CTX_STEPS.filter((c) => c <= cap)
  const p = { id, weights: w, ovh }
  const fits = (c) => w + kvGib(m, c) + ovh <= b.usable
  if (b.mode === 'gpu') {
    const c = [...steps].reverse().find(fits)
    if (c) Object.assign(p, { ctx: c, where: 'gpu', frac: 1 })
    else {
      const c0 = steps[0]
      const frac = Math.max(0, Math.min(1, (b.usable - kvGib(m, c0) - ovh) / w))
      Object.assign(p, { ctx: c0, where: frac > 0.05 ? 'split' : 'cpu', frac })
      if ((1 - frac) * w > hw.ramGb - CPU_RESERVE) p.where = 'nofit'
    }
  } else {
    const c = [...steps].reverse().find(fits)
    Object.assign(p, c ? { ctx: c, where: 'cpu', frac: 0 } : { ctx: steps[0], where: 'nofit', frac: 0 })
  }
  p.kv = kvGib(m, p.ctx)
  const onGpu = b.mode === 'gpu' && p.frac > 0
  p.gpuUse = onGpu ? w * p.frac + p.kv + ovh : 0
  p.ramUse = w * (1 - p.frac) + (onGpu ? 0 : p.kv + ovh)
  const active = m.moe ? w * (m.active_params_b / m.params_b) : w
  let sec = onGpu ? (active * GiB * p.frac) / (b.bw * 1e9 * EFF_GPU) : 0
  sec += (active * GiB * (1 - p.frac)) / (RAM_BW * 1e9 * EFF_CPU)
  sec += m.kv.layers * (onGpu ? (m.moe ? LAYER_MOE_S : LAYER_GPU_S) : LAYER_CPU_S)
  p.tps = sec ? 1 / sec : 0
  p.measured = b.mode === 'gpu' ? measuredOn(m, hw.gpu?.name) : null
  p.speed = Math.round(p.measured || p.tps)
  return p
}

function tierFor(b) {
  if (b.mode === 'gpu') {
    const ts = catalog.tiers.filter((t) => t.vram_gb <= b.tierGb + 0.01)
    if (ts.length) return [ts[ts.length - 1], catalog.tiers]
  }
  const ts = catalog.cpu_tiers.filter((t) => t.ram_gb <= b.tierGb + 0.01)
  return [ts.length ? ts[ts.length - 1] : catalog.cpu_tiers[0], catalog.cpu_tiers]
}

/** Suggested models for this hardware, best first. Same rows as the installer. */
export function suggest(hw) {
  const b = budget(hw)
  const [t, tiers] = tierFor(b)
  const i = tiers.indexOf(t)
  const rows = [[t.default, 'recommended'], ...t.alternatives.map((a) => [a, 'alternative'])]
  if (i > 0) rows.push([tiers[i - 1].default, 'smaller, faster'])
  if (i + 1 < tiers.length) rows.push([tiers[i + 1].default, 'bigger, slower'])
  const seen = new Set()
  const out = []
  for (const [id, why] of rows) {
    if (seen.has(id) || !models[id]) continue
    seen.add(id)
    const p = plan(id, hw, b)
    const label = why === 'bigger, slower' && p.where !== 'gpu' ? 'bigger, partly on the CPU' : why
    if (p.where !== 'nofit') out.push({ ...p, why: label, name: modelName(id), model: models[id] })
  }
  return { tier: t, budget: b, engine: engineFor(hw.gpu), picks: out }
}

export function modelName(id) {
  const m = models[id]
  const base = m.repo.split('/').pop().replace('-GGUF', '').replace('-it', '').replace('-Instruct', '')
  return `${base} ${m.quant.replace('UD-', '')}`
}

export const speedWord = (tps) => (tps >= 30 ? 'fast' : tps >= 12 ? 'good' : tps >= 5 ? 'slow' : 'very slow')
