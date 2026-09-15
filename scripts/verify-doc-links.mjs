import { existsSync, globSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

const failures = []
const documentationFiles = globSync([
  '*.md',
  'docs/*.md',
  'supabase/*.md',
  'assignments/*.md',
  'proposals/*.md',
  'assessments/*.md',
  'syntheses/*.md',
  'documents/*.md',
])

for (const file of documentationFiles) {
  const text = readFileSync(file, 'utf8')
  for (const match of text.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
    const target = match[1].split('#')[0]
    if (!target || /^(https?:|mailto:)/.test(target)) continue
    if (!existsSync(resolve(dirname(file), decodeURIComponent(target)))) {
      failures.push(`${file}: ${target}`)
    }
  }
}

if (failures.length) {
  console.error(`Brutte lokale dokumentlenker:\n${failures.join('\n')}`)
  process.exit(1)
}
