// Copies the model catalog (AI_Tools/models/models.json, shared with the AI Node
// installer) into the website, keeping only what the advisor needs.
// Runs before every build; when the repo folder isn't there (a build that only
// has website/), the committed copy in src/data/models.json is used as is.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = join(here, '..', '..', 'AI_Tools', 'models', 'models.json')
const out = join(here, '..', 'src', 'data', 'models.json')

if (!existsSync(src)) {
  console.log('sync-models: no AI_Tools/models/models.json here, keeping src/data/models.json')
  process.exit(0)
}

const c = JSON.parse(readFileSync(src, 'utf8'))
const keep = ['family', 'repo', 'quant', 'params_b', 'active_params_b', 'moe', 'file_gb', 'ctx_max', 'license', 'roles', 'tool_calling', 'kv', 'tested', 'notes']
const models = Object.fromEntries(
  Object.entries(c.models).map(([id, m]) => [id, Object.fromEntries(keep.filter((k) => k in m).map((k) => [k, m[k]]))]),
)
const slim = { updated: c.updated, tiers: c.tiers, cpu_tiers: c.cpu_tiers, hybrid_tiers: c.hybrid_tiers, gpus: c.gpus, models }
writeFileSync(out, JSON.stringify(slim) + '\n')
console.log(`sync-models: ${Object.keys(models).length} models -> src/data/models.json`)
