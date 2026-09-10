// ============================================================================
// Den kontrollerte skriveveien for å registrere en kildeversjon
//
// Leddet mellom `create-source.ts` og `create-evidence-item.ts`: et evidensfunn
// skal peke på den representasjonen ekstraksjonen faktisk ble lest av
// (DATABASE_ARCHITECTURE.md §18), og fram til nå fantes det ingen måte å
// registrere en slik representasjon på (issue #44).
//
// Ett kall til `api.create_source_version(...)` (migrasjon 007f). Ingen egen
// validering utover det formen selv samler inn: constraintene på
// `knowledge.source_versions` er fasiten (§43, §48, §57).
//
// ----------------------------------------------------------------------------
// Klienten sender innholdet, ikke hashen
//
// `content_hash` er ikke en parameter, og det er ikke en forglemmelse.
// Databasen beregner den av `retrievedContent` i samme transaksjon som raden
// skrives, av samme grunn som `content_hash` på et evidensfunn eies av
// databasen: en hash klienten kunne oppgi, ville sett ut som en garanti uten å
// være det. Se hodekommentaren i migrasjonen for hele tillitsmodellen.
//
// Konsekvensen for klienten er at innholdet må sendes ordrett, uten trimming og
// uten omforming — det er nøyaktig de bytene hashen skal kunne reproduseres fra.
// ============================================================================

import type { AntidepClient } from './supabase'
import type { Uuid } from '../types/api'

/** Feltene skjemaet samler inn. Tomme valgfrie felter sendes som `null`. */
export interface CreateSourceVersionInput {
  readonly sourceId: Uuid
  /** Da representasjonen ble hentet. ISO-8601 med tidssone. */
  readonly retrievedAt: string
  /** Den nøyaktige adressen representasjonen ble hentet fra. */
  readonly retrievedFrom: string
  /** Representasjonen ordrett, slik den ble hentet. Databasen hasher den. */
  readonly retrievedContent: string
  /**
   * Hva slags representasjon dette er (EVIDENCE_PIPELINE.md §13).
   *
   * Kolonnen er nullbar, men skjemaet krever verdien: en versjon uten den kan
   * ikke bære en agentekstraksjon (migrasjon 005v), og en standardverdi ville
   * vært en gjetning om hva noen faktisk lastet ned.
   */
  readonly representation: string
  readonly externalVersion: string | null
  readonly storageReference: string | null
}

export type CreateSourceVersionResult =
  | { readonly status: 'ok'; readonly sourceVersionId: Uuid }
  | { readonly status: 'error'; readonly message: string }

/**
 * Kaller `api.create_source_version(...)`. Returnerer aldri en avvisning som et
 * kastet unntak: siden skal kunne vise enhver avvisning — manglende
 * editor-rolle, tom representasjon, en dublett, en ukjent kilde — med
 * databasens egen tekst, uten å måtte skille feiltyper fra hverandre her.
 */
export async function createSourceVersion(
  client: AntidepClient,
  input: CreateSourceVersionInput,
): Promise<CreateSourceVersionResult> {
  const { data, error } = await client.rpc('create_source_version', {
    p_source_id: input.sourceId,
    p_retrieved_at: input.retrievedAt,
    p_retrieved_from: input.retrievedFrom,
    p_retrieved_content: input.retrievedContent,
    p_representation: input.representation,
    p_external_version: input.externalVersion,
    p_storage_reference: input.storageReference,
  })

  if (error !== null) {
    return { status: 'error', message: error.message }
  }
  return { status: 'ok', sourceVersionId: data }
}
