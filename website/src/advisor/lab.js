// sudo homelab advisor: the lab analysis (host OS, stacks that fit, RAM budget,
// AI models). Pure JavaScript, shared by the Advisor page (quick questions) and
// the AI advisor (/api/advisor tool), so both always give the same answers.
//
// answers: { machine, cpu, ram: '32 GB', storage: '4–10 TB', gpu: 'None'|'Intel iGPU (QuickSync)'|'NVIDIA'|'AMD',
//            gpuModel: 'RTX 3060 12GB' (optional), goals: ['Media', 'AI', ...] }
import { categoryById } from '../data/catalog.js'
import { parseGpu, suggest } from './engine.js'

export const MACHINES = ['Mini PC', 'Old desktop / laptop', 'Rack / tower server', 'NAS', 'Raspberry Pi / SBC', 'Gaming PC']
export const STORAGE = ['< 500 GB', '1–2 TB', '4–10 TB', '10 TB+']
export const GPUS = ['None', 'Intel iGPU (QuickSync)', 'NVIDIA', 'AMD']
export const GOALS = ['Media', 'Cloud & Photos', 'Smart Home', 'Ad-blocking', 'AI', 'Monitoring']

export const GOAL_CAT = { Media: 'media', 'Cloud & Photos': 'cloud', 'Smart Home': 'home', 'Ad-blocking': 'network', AI: 'ai', Monitoring: 'ops' }

export function analyzeLab(a) {
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
