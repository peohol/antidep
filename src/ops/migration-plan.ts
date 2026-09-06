// ============================================================================
// Hva som mangler å kjøres i et hostet Supabase-prosjekt, og når man ikke skal
// kjøre noe i det hele tatt
//
// `scripts/deploy-migrations.sh` sammenligner filene i `supabase/migrations/`
// med radene i `supabase_migrations.schema_migrations`. Selve sammenligningen
// ligger her, som en ren funksjon uten I/O, fordi den avgjør om det skrives til
// produksjon — og fordi den ene regelen under er lett å utelate og vanskelig å
// oppdage etterpå.
//
// ----------------------------------------------------------------------------
// Regelen: det som er kjørt, må være et sammenhengende prefiks av det som finnes
//
// Første utgave behandlet enhver lokal migrasjon uten en rad som «manglende».
// Med lokal historikk `A, B, C` og registrert historikk `A, C` ga det `B` som
// manglende — og `B` ville blitt kjørt *etter* `C`. En migrasjon skrevet med den
// forutsetningen at alt før den har kjørt, kan da gjøre noe helt annet enn den
// gjorde lokalt, eller gjeninnføre en endring i feil rekkefølge. Funnet kom fra
// teknisk review (MVP_IMPLEMENTATION_PLAN.md §74.34).
//
// Et hull er ikke noe et deployskript skal reparere på egen hånd: det betyr at
// prosjektets historikk og repoet har kommet fra hverandre, og hvorfor er et
// spørsmål et menneske må svare på. Supabase skiller selv mellom et vanlig push
// og `--include-all` nettopp her. Denne funksjonen feiler derfor lukket — den
// melder hullet og lar `pending` stå tom — framfor å kjøre en eldre migrasjon
// etter en nyere.
//
// Den sikre regelen, uttrykt på den formen den kontrolleres: **når en lokal
// migrasjon mangler, skal ingen nyere versjon allerede være registrert.**
// ============================================================================

/** En rad i `supabase_migrations.schema_migrations`. */
export interface RemoteMigration {
  readonly version: string
  readonly name: string
}

/** En migrasjonsfil som skal kjøres. */
export interface PendingMigration {
  readonly file: string
  readonly version: string
  readonly name: string
}

export interface MigrationPlan {
  readonly localCount: number
  readonly appliedCount: number
  /** Tom når `problems` ikke er tom: ingenting skal kjøres da. */
  readonly pending: readonly PendingMigration[]
  /** Ikke tom betyr: skriv ingenting, og si fra. */
  readonly problems: readonly string[]
}

const FILENAME = /^(\d{14})_(.+)\.sql$/

/**
 * Sammenligner migrasjonsfilene i repoet med historikken i prosjektet.
 *
 * `localFiles` er filnavn (ikke baner), `remote` er radene som finnes. Ved
 * ethvert avvik er `pending` tom og `problems` beskriver hva som er galt.
 */
export function planMigrations(
  localFiles: readonly string[],
  remote: readonly RemoteMigration[],
): MigrationPlan {
  const problems: string[] = []
  const locals: PendingMigration[] = []
  const seen = new Set<string>()

  for (const file of [...localFiles].sort()) {
    const match = FILENAME.exec(file)
    if (!match) {
      problems.push(`${file}: filnavnet har ikke formen <14 sifre>_<navn>.sql`)
      continue
    }
    const [, version = '', name = ''] = match
    if (seen.has(version)) {
      problems.push(`${version}: to migrasjonsfiler har samme versjonsnummer`)
      continue
    }
    seen.add(version)
    locals.push({ file, version, name })
  }

  const remoteByVersion = new Map(remote.map((row) => [row.version, row]))

  for (const local of locals) {
    const row = remoteByVersion.get(local.version)
    if (row && row.name !== local.name) {
      problems.push(`${local.version}: historikken heter «${row.name}», filen «${local.name}»`)
    }
  }

  for (const row of remote) {
    if (!seen.has(row.version)) {
      problems.push(`${row.version} ${row.name}: kjørt i prosjektet, men finnes ikke i repoet`)
    }
  }

  const pending = locals.filter((local) => !remoteByVersion.has(local.version))

  // Hullkontrollen. Versjonene er 14 sifre med fast bredde, så en tekstlig
  // sammenligning er den samme som en numerisk.
  const highestApplied = remote.reduce(
    (høyest, row) => (row.version > høyest ? row.version : høyest),
    '',
  )
  for (const missing of pending) {
    if (missing.version < highestApplied) {
      problems.push(
        `${missing.version} ${missing.name}: mangler i prosjektet, men en nyere ` +
          `migrasjon (${highestApplied}) er allerede kjørt der. Historikken har et ` +
          'hull, og å kjøre denne nå ville kjørt en eldre migrasjon etter en nyere.',
      )
    }
  }

  return {
    localCount: locals.length,
    appliedCount: remote.length,
    pending: problems.length > 0 ? [] : pending,
    problems,
  }
}
