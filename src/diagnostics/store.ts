// ============================================================================
// Forbindelsen som ikke går gjennom Data API-et
//
// Alt annet Antidep gjør mot databasen, går over PostgREST med kallerens egen
// token. Det er riktig for produktet: ingen flate holder en hemmelighet, og
// hele autorisasjonen ligger i databasen.
//
// Men den rå årsaken skal overleve at nettopp den veien er nede. En lagring som
// bare virker når det den beskriver ikke skjedde, er ingen lagring. Denne
// modulen er derfor den ene forbindelsen i Antidep som snakker Postgres-
// protokollen rett, uten PostgREST i veien.
//
// ----------------------------------------------------------------------------
// Hva legitimasjonen her faktisk kan
//
// Rollen `antidep_diagnostics` kan kjøre to funksjoner som *legger til* rader.
// Ingen tabellrettigheter, ingen lesevei, ingen bypass av RLS, ingen create.
// Lekker den, er det verste noen kan gjøre å skrive vaskede, klippede og
// mengdebegrensede observasjoner inn i en privat tabell ingen brukerflate
// leser — og den kan ikke lese én rad ut igjen, heller ikke sine egne.
//
// Det er mindre fullmakt enn en innlogget redaktør har, og langt mindre enn
// `service_role`, som fortsatt er forbudt overalt.
//
// ----------------------------------------------------------------------------
// Hvorfor forbindelsen åpnes og lukkes per kall
//
// Ruten kjører som en serverless funksjon. En pool ville holdt forbindelser
// åpne i instanser som kan bli revet ned når som helst, og databasen har et
// tak på antall forbindelser som ikke skal brukes opp av en diagnostikkvei.
// Én forbindelse per observasjon er dyrere og riktigere.
//
// Begge tidsgrensene er satt med vilje: en database som henger, skal ikke få
// ruten til å henge med seg. Da er det bedre å svare 503 og la nettleseren
// beholde observasjonen.
// ============================================================================

import { Client } from 'pg'

/** Miljøet den varige reserveveien leser. Server-side, aldri i nettleserbygget. */
export interface StoreEnvironment {
  readonly ANTIDEP_DIAGNOSTICS_DATABASE_URL?: string | undefined
}

/** Én observasjon på vei inn den varige veien. */
export interface StoredDiagnostic {
  readonly reporterIpHash: string
  readonly eventId: string
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
  readonly detail: string
}

/** Én melding fra en offentlig flate. Uten ett eneste tegn fritekst. */
export interface StoredPublicProblem {
  readonly reporterIpHash: string
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
}

/**
 * Den varige lagringen, slik ruten ser den. Injiserbar, slik at en prøve
 * slipper en database.
 */
export interface DiagnosticsStore {
  /** `true` når raden er skrevet. `false` når den ikke er det, uansett grunn. */
  keep(entry: StoredDiagnostic): Promise<boolean>
  keepPublicProblem(entry: StoredPublicProblem): Promise<boolean>
}

const CONNECT_TIMEOUT_MS = 4000
const STATEMENT_TIMEOUT_MS = 4000

async function run(url: string, sql: string, values: readonly unknown[]): Promise<boolean> {
  const client = new Client({
    connectionString: url,
    connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
    statement_timeout: STATEMENT_TIMEOUT_MS,
    // TLS avgjøres av adressen selv, med `sslmode`. Supabase avviser en
    // forbindelse uten, og deres egen connection string bærer `sslmode=require`
    // — så kravet står i verdien den som drifter limer inn, framfor i en
    // innstilling her som kunne kommet i utakt med den. En lokal prøvestack
    // uten sertifikat trenger ingenting.
    application_name: 'antidep-diagnostikk',
  })
  try {
    await client.connect()
    await client.query(sql, values as unknown[])
    return true
  } catch {
    // Grunnen står i kjøreloggen gjennom ruten, som skriver linjen uansett.
    // Her er det bare ett spørsmål som betyr noe: ble raden skrevet?
    return false
  } finally {
    try {
      await client.end()
    } catch {
      // En forbindelse som ikke lot seg lukke pent, er ikke en feil å melde.
    }
  }
}

/**
 * Den ekte lagringen, når utrullingen har fått legitimasjonen.
 *
 * Uten adressen finnes ingen reservevei, og `keep` svarer `false` framfor å
 * late som. Ruten skriver da linjen i kjøreloggen og ber nettleseren beholde
 * observasjonen — ingenting forsvinner stille.
 */
export function createDiagnosticsStore(env: StoreEnvironment): DiagnosticsStore | null {
  const url = env.ANTIDEP_DIAGNOSTICS_DATABASE_URL?.trim()
  if (url === undefined || url.length === 0) {
    return null
  }
  return {
    keep: (entry) =>
      run(url, 'select workflow.ingest_client_diagnostic($1, $2, $3, $4, $5, $6, $7, $8, $9)', [
        entry.reporterIpHash,
        entry.eventId,
        entry.area,
        entry.kind,
        entry.operation,
        entry.code,
        entry.httpStatus,
        entry.transport,
        entry.detail,
      ]),
    keepPublicProblem: (entry) =>
      run(url, 'select workflow.ingest_public_technical_problem($1, $2, $3, $4, $5, $6, $7)', [
        entry.reporterIpHash,
        entry.area,
        entry.kind,
        entry.operation,
        entry.code,
        entry.httpStatus,
        entry.transport,
      ]),
  }
}
