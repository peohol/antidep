// ============================================================================
// Argumentlisten de to verifikatorkjørerne deler
//
// Begge kjørerne tar de samme tre valgene, og bare målets navn skiller dem:
//
//   --<mål> <uuid>   kontroller nøyaktig dette objektet
//   --limit <n>      ta høyst n objekter i denne kjøringen
//   --dry-run        kontroller og rapporter, men registrer ingenting
//
// Parsingen ligger her framfor i hver CLI-fil av to grunner. Den ene er
// gjenbruk: to nesten like parsere er to steder å glemme en grense. Den andre er
// at CLI-filene selv kjører `main()` på toppnivå og derfor ikke kan importeres
// av en test — logikken som fortjener en test, må ligge et sted som kan
// importeres uten å starte en kjøring.
// ============================================================================

export interface VerifierCliOptions {
  /** Objektet kjøringen avgrenses til, eller `null` for hele arbeidskøen. */
  readonly targetId: string | null
  readonly dryRun: boolean
  readonly limit: number | null
}

export interface VerifierCliSpec {
  /** Flagget som avgrenser kjøringen, uten `--`, for eksempel `claim-revision`. */
  readonly targetFlag: string
  readonly usage: string
}

/**
 * Leser argumentlisten, eller kaster med en setning som sier hva som er galt.
 *
 * Et ukjent valg avvises framfor å ignoreres: en skrivefeil i `--dry-run` ville
 * ellers blitt til en kjøring som registrerte rader kalleren ikke ba om.
 */
export function parseVerifierArguments(
  argv: readonly string[],
  spec: VerifierCliSpec,
): VerifierCliOptions {
  const target = `--${spec.targetFlag}`
  let targetId: string | null = null
  let dryRun = false
  let limit: number | null = null

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--dry-run') {
      dryRun = true
    } else if (argument === target) {
      const value = argv[index + 1]
      if (value === undefined || value.startsWith('--')) {
        throw new Error(`${target} krever en uuid.`)
      }
      targetId = value
      index += 1
    } else if (argument === '--limit') {
      const value = Number(argv[index + 1])
      if (!Number.isInteger(value) || value < 1) {
        throw new Error('--limit krever et heltall større enn null.')
      }
      limit = value
      index += 1
    } else if (argument === '--help' || argument === '-h') {
      throw new Error(spec.usage)
    } else {
      throw new Error(`Ukjent valg: ${String(argument)}\n\n${spec.usage}`)
    }
  }

  return { targetId, dryRun, limit }
}
