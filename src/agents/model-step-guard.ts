// ============================================================================
// Miljøvakten for modell-leddet — et lag i dybden, ikke *den* grensen
//
// EVIDENCE_PIPELINE.md §63 sier at et ledd som leser utrygt eksternt innhold,
// ikke skal ha unødvendig tilgang til hemmeligheter eller destruktive
// systemhandlinger. Modell-leddet er det leddet.
//
// ----------------------------------------------------------------------------
// Hva denne vakten *ikke* kan
//
// Den ser miljøet til **denne prosessen**, og ingenting annet. Den kan ikke se
// sesjonen som startet den, og den kan ikke se verktøy eller connectorer den
// sesjonen har. Kjøres modell-leddet av en Claude Code Routine, er Routinen en
// autonom sesjon med skall, med miljøet fra det kjøremiljøet den ble gitt, og
// med de connectorene den ble opprettet med. En modell som har lest en
// artikkel med noe instruksjonslignende i seg, kan i den sesjonen bruke hva
// som helst av det — uavhengig av hva denne funksjonen sier.
//
// **Den primære grensen er derfor kjøremiljøet og connectorlisten**, ikke
// koden her: Routinen som kjører modell-leddet, skal ha et eget kjøremiljø
// uten skrivekapable hemmeligheter og uten skrivekapable connectorer
// (`docs/ROUTINE_EXTRACTION.md` §3). Vakten under er laget under det: den
// fanger det vanligste uhellet — at kommandoen kjøres i et skall der en
// hemmelighet allerede er eksportert — og den sier fra med en gang framfor å la
// kjøringen se uskyldig ut.
//
// ----------------------------------------------------------------------------
// Hvilke navn den kjenner
//
// To familier, av to grunner.
//
// Agenthemmelighetene heter `ANTIDEP_*SECRET`, og navnene bor i
// `agent-environment.ts` — modulen modell-leddet ikke kan importere, fordi det
// er selve modulen grensen går ved. Mønsteret gjelder derfor formen på navnet,
// og `model-step-guard.test.ts` krever at hver legitimasjon som faktisk finnes,
// treffes av det. Da er det originalen som holder kopien i sjakk.
//
// De andre er skrivekapable legitimasjoner *utenfor* Antideps egen
// agentmodell — først og fremst den `scripts/deploy-migrations.sh` bruker mot
// Management-API-et, som kan kjøre vilkårlig SQL mot produksjonsbasen. Den
// listen kan ikke utledes av noe mønster og står derfor eksplisitt, med en
// prøve som leser deployskriptet og krever at variablene det faktisk bruker,
// er dekket.
//
// Listen er ikke uttømmende, og skal ikke leses som om den var det. Den er en
// oppsamling av det vi vet finnes i dette repoet.
// ============================================================================

/** Formen på navnet en Antidep-agenthemmelighet har. */
const ANTIDEP_SECRET = /^ANTIDEP_[A-Z0-9_]*SECRET$/

/**
 * Navn på skrivekapabel legitimasjon utenfor Antideps agentmodell.
 *
 * `SUPABASE_PROJECT_REF` står bevisst *ikke* her: en prosjektreferanse er en
 * identifikator og ikke en hemmelighet, og en vakt som stoppet på den, ville
 * stoppet kjøringer uten at noe var galt.
 */
const WRITE_CAPABLE = [
  /^SUPABASE_ACCESS_TOKEN$/,
  /^SUPABASE_DB_PASSWORD$/,
  /^SUPABASE_SECRET_KEY$/,
  /SERVICE_ROLE/,
  /^DATABASE_URL$/,
  /^PG(PASSWORD|SERVICE|URI)$/,
] as const

/** Miljøet slik en kjører leser det. `process.env` passer formen. */
export type ProcessEnv = Readonly<Record<string, string | undefined>>

/** Om navnet er en legitimasjon modell-leddet ikke skal ha i miljøet sitt. */
export function isWriteCapableName(name: string): boolean {
  return ANTIDEP_SECRET.test(name) || WRITE_CAPABLE.some((pattern) => pattern.test(name))
}

/** Navnene på de skrivekapable legitimasjonene som står i miljøet, sortert. */
export function writeCapableCredentialsIn(env: ProcessEnv): readonly string[] {
  return Object.keys(env)
    .filter((name) => isWriteCapableName(name) && (env[name] ?? '').trim().length > 0)
    .sort()
}

/**
 * Kaster dersom modell-leddet ville kjørt med en skrivekapabel legitimasjon i
 * miljøet sitt.
 *
 * Meldingen er den kommandoen som løser det, og ikke bare en beskrivelse av
 * problemet: alternativet er at en kjører står fast på en regel den ikke kan
 * gjøre noe med, og da blir regelen slått av framfor fulgt.
 */
export function assertNoWriteCapableCredentials(env: ProcessEnv, command: string): void {
  const present = writeCapableCredentialsIn(env)
  if (present.length === 0) {
    return
  }
  const unset = present.map((name) => `-u ${name}`).join(' ')
  throw new Error(
    'Modell-leddet skal ikke kjøre med skrivekapabel legitimasjon i miljøet, og disse står ' +
      `der: ${present.join(', ')}.\n\n` +
      'Leddet leser en artikkel Antidep ikke kontrollerer, og et ledd som gjør det, skal ikke ' +
      'samtidig ha tilgang til noe som kan skrive (EVIDENCE_PIPELINE.md §63). Registreringen ' +
      'er en egen kommando, med sin egen identitet, og skal kjøres for seg.\n\n' +
      `Kjør modell-leddet uten dem:\n\n  env ${unset} ${command}\n\n` +
      'Merk at dette bare dekker miljøet til denne prosessen. Kjøres leddet av en Claude Code ' +
      'Routine, er den egentlige grensen at Routinen har sitt eget kjøremiljø uten ' +
      'skrivekapable hemmeligheter og uten skrivekapable connectorer ' +
      '(docs/ROUTINE_EXTRACTION.md §3).',
  )
}
