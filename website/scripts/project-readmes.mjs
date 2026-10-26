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
const status = (a) => (a.original ? 'Original (planned)' : { planned: 'Planned', beta: 'Beta', ready: 'Ready', official: 'Official install' }[a.status || 'planned'])

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
  const official = c.apps.filter((a) => a.official)
  const installs = official.length
    ? `\n## Install (official methods)\n\nThese use each project's own installer, not a sudo homelab script. Commands for every platform, and docs: https://sudohomelab.vercel.app/#/c/${c.id}\n\n` +
      official
        .map((a) => {
          const cmd = a.official.how.linux?.cmd
          return `### ${a.name}\n\n${a.official.note} [Website](${a.official.site}) · [Docs](${a.official.docs})${cmd ? `\n\nUbuntu / Debian:\n\n\`\`\`bash\n${cmd}\n\`\`\`` : ''}\n`
        })
        .join('\n')
    : ''
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
${installs}${stack}
## Layout

Scripts go in one folder per platform:

\`\`\`
${c.folder}/
${PLATFORMS.map((p) => `  ${p.id}/        ${p.name}`).join('\n')}
\`\`\`

${official.length ? 'No sudo homelab scripts here yet.' : 'Nothing here yet.'} See [Media_Stack](../Media_Stack) for a finished project.
`
  )
  console.log(`write   ${c.folder}/README.md`)
}
