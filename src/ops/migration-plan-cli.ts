// ============================================================================
// Leser historikken og migrasjonsfilene, og skriver ut planen
//
//   node src/ops/migration-plan-cli.ts <historikk.json> <mangler.json>
//
// Kalles av `scripts/deploy-migrations.sh`. Avslutter med 1 og skriver
// ingenting til `<mangler.json>` hvis repoet og prosjektet har kommet fra
// hverandre — se hodekommentaren i `migration-plan.ts` for hvorfor et hull i
// historikken ikke er noe et deployskript skal rette opp selv.
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { readdirSync, readFileSync, writeFileSync } from 'node:fs'

import { planMigrations, type RemoteMigration } from './migration-plan.ts'

const MIGRATIONS = 'supabase/migrations'

function main(argv: readonly string[]): number {
  const [historyFile, pendingFile] = argv

  if (historyFile === undefined || pendingFile === undefined) {
    console.error('Bruk: node src/ops/migration-plan-cli.ts <historikk.json> <mangler.json>')
    return 2
  }

  const remote = JSON.parse(readFileSync(historyFile, 'utf8')) as RemoteMigration[]
  const local = readdirSync(MIGRATIONS).filter((file) => file.endsWith('.sql'))
  const plan = planMigrations(local, remote)

  console.log(
    `${plan.appliedCount} migrasjoner registrert i prosjektet, ${plan.localCount} filer i repoet.`,
  )

  if (plan.problems.length > 0) {
    console.error('\nAvvik mellom repoet og prosjektet — ingenting er kjørt:')
    for (const problem of plan.problems) console.error(`  ${problem}`)
    return 1
  }

  writeFileSync(pendingFile, JSON.stringify(plan.pending))

  if (plan.pending.length === 0) {
    console.log('Ingenting mangler.')
  } else {
    console.log(`\n${plan.pending.length} migrasjoner mangler:`)
    for (const migration of plan.pending) {
      console.log(`  ${migration.version} ${migration.name}`)
    }
  }

  return 0
}

process.exitCode = main(process.argv.slice(2))
