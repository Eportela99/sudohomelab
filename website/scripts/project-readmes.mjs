// Creates one folder per catalog category at the repo root, each with a README
// listing its apps. Re-run after editing src/data/catalog.js:
//   npm run readmes
// READMEs carrying the AUTOGEN marker are regenerated; hand-written ones
// (like Media_Stack's) are left alone.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { CATEGORIES } from '../src/data/catalog.js'
import { PLATFORMS, platformById } from '../src/data/platforms.js'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const MARK = '<!-- AUTOGEN: website/scripts/project-readmes.mjs -->'
const status = (a) => (a.original ? 'Original (planned)' : { planned: 'Planned', beta: 'Beta', ready: 'Ready' }[a.status || 'planned'])

for (const c of CATEGORIES) {
  const dir = join(root, c.folder)
  const file = join(dir, 'README.md')
  mkdirSync(dir, { recursive: true })
  if (existsSync(file) && !readFileSync(file, 'utf8').includes(MARK)) {
    console.log(`keep    ${c.folder}/README.md (hand-written)`)
    continue
  }
  const rows = c.apps
    .map((a) => `| **${a.name}** | ${a.desc} | ${a.platforms.map((p) => platformById[p].short).join(', ')} | ${status(a)} |`)
    .join('\n')
  const stack = c.stack
    ? `\n## Pre-wired stack: ${c.stack.name}\n\n${c.stack.pitch}\n\nStatus: planned. Script: \`${c.folder}/<platform>/${c.stack.id}.sh\`\n`
    : ''
  writeFileSync(
    file,
    `${MARK}
# ${c.name}

${c.tagline}

${c.description}

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
${rows}
${stack}
## Layout

Scripts go in one folder per platform:

\`\`\`
${c.folder}/
${PLATFORMS.map((p) => `  ${p.id}/        ${p.name}`).join('\n')}
\`\`\`

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
`
  )
  console.log(`write   ${c.folder}/README.md`)
}
