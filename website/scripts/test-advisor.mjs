// Logic test for api/advisor.js with FAKE Anthropic + Redis: no keys, no cost.
// Run: npm run test:advisor
process.env.ANTHROPIC_API_KEY = 'test-key-not-real'
process.env.KV_REST_API_URL = 'https://redis.mock'
process.env.KV_REST_API_TOKEN = 'mock'

const store = new Map()
let calls = 0
let script = []
globalThis.fetch = async (url, init = {}) => {
  const u = String(url)
  const json = (o) => new Response(JSON.stringify(o), { status: 200, headers: { 'content-type': 'application/json' } })
  if (u.startsWith('https://redis.mock')) {
    const one = ([op, key, val]) => {
      if (op === 'get') return { result: store.has(key) ? store.get(key) : null }
      if (op === 'incr') { store.set(key, String((Number(store.get(key)) || 0) + 1)); return { result: Number(store.get(key)) } }
      if (op === 'incrby') { store.set(key, String((Number(store.get(key)) || 0) + Number(val))); return { result: Number(store.get(key)) } }
      return { result: 1 }
    }
    const cmd = JSON.parse(init.body)
    return json(Array.isArray(cmd[0]) ? cmd.map((c) => one(c.map(String))) : one(cmd.map(String)))
  }
  if (u.includes('/v1/messages')) {
    calls++
    const body = JSON.parse(init.body)
    if (calls === 1) console.log('   request: model', body.model, '| tools', body.tools.map((t) => t.name).join(','), '| cache_control', JSON.stringify(body.cache_control), '| system chars', body.system.length)
    return json(script.shift()(body))
  }
  throw new Error('unexpected fetch ' + u)
}

const { default: handler } = await import('../api/advisor.js')
const call = async (messages, ip = '1.2.3.4') => {
  let out
  const res = { status(c) { this.code = c; return this }, json(o) { out = { code: this.code, ...o }; return this } }
  await handler({ method: 'POST', headers: { 'x-forwarded-for': ip }, body: { messages } }, res)
  return out
}
const usage = { input_tokens: 2500, output_tokens: 300, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 }
const msg = (content, stop_reason) => () => ({ id: 'm', type: 'message', role: 'assistant', model: 'claude-haiku-4-5', content, stop_reason, usage })

console.log('1) report + models via tools')
script = [
  msg([{ type: 'tool_use', id: 't1', name: 'show_lab_report', input: { machine: 'Old desktop / laptop', cpu: 'i7-8700', ram_gb: 32, storage_tb: 4, gpu: 'NVIDIA', gpu_model: 'GTX 1060 6GB', goals: ['Media', 'AI'] } }], 'tool_use'),
  (body) => {
    const tr = body.messages.at(-1).content[0]
    console.log('   tool_result:', tr.content.slice(0, 260), '...')
    return msg([{ type: 'text', text: 'Your Dell is a **solid starter lab**.\n- Proxmox\n- Media: #/c/media' }], 'end_turn')()
  },
]
let r = await call([{ role: 'user', content: 'Old Dell i7-8700, 32GB, GTX 1060 6GB, 4TB. Plex + local AI?' }])
console.log('   ->', JSON.stringify({ reply: r.reply, report: r.report, remaining: r.remaining }).slice(0, 300))

console.log('2) suggest_models with a missing VRAM -> error back to the model')
script = [
  msg([{ type: 'tool_use', id: 't2', name: 'suggest_models', input: { gpu: 'RTX 3060', ram_gb: 16 } }], 'tool_use'),
  (body) => { console.log('   tool_result:', body.messages.at(-1).content[0].content, 'is_error', body.messages.at(-1).content[0].is_error); return msg([{ type: 'text', text: 'How much VRAM does it have?' }], 'end_turn')() },
]
r = await call([{ role: 'user', content: 'RTX 3060, which model?' }], '5.6.7.8')
console.log('   ->', r.reply)

console.log('3) visitor limit: 3 new conversations per day')
for (let i = 0; i < 3; i++) {
  script = [msg([{ type: 'text', text: 'ok' }], 'end_turn')]
  r = await call([{ role: 'user', content: 'hi' }], '9.9.9.9')
}
console.log('   4th ->', JSON.stringify(await call([{ role: 'user', content: 'hi' }], '9.9.9.9')))

console.log('4) daily budget: spent so far', store.get(`adv:spend:${new Date().toISOString().slice(0, 10)}`), 'micro-$; force over budget')
store.set(`adv:spend:${new Date().toISOString().slice(0, 10)}`, '1000000')
console.log('   ->', JSON.stringify(await call([{ role: 'user', content: 'hi' }], '8.8.8.8')))

console.log('5) bad input ->', JSON.stringify(await call([{ role: 'assistant', content: 'x' }])))
console.log('model calls made:', calls)
