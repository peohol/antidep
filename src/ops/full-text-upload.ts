// ============================================================================
// Svaret fra fulltekstopplastingen, lest med den samme strengheten som en fil
//
// `api.upload_full_text_document` gjør fire ting i én transaksjon: legger filen
// i det private biblioteket, kontrollerer at fullteksten bærer publikasjonens
// egen identitet, prøver lesbarheten inkludert tabellene, og registrerer
// kildeversjonen. Svaret er jsonb, og jsonb har ingen kolonnetyper PostgREST
// kan håndheve.
//
// Modulen her leser det svaret, og avviser alt som ikke er kontrakten. Formen
// er den samme disiplinen `strict-fields.ts` eier: et felt med skrivefeil skal
// stoppe kommandoen, ikke bli til en manglende opplysning i en rapport.
//
// ----------------------------------------------------------------------------
// Hvorfor bindingsgrunnlaget leses og ikke bare vises
//
// «Hvordan vet vi at dette er artikkelen» er ikke en detalj. En binding gjort på
// DOI er entydig; en gjort på tittel kan i prinsippet ha truffet en
// referanseliste. Kommandoen skal derfor kunne si hvilken av delene det var, og
// en rapport som bare sa «bundet», ville skjult forskjellen
// (ANTIDEP_CONSTITUTION.md regel 4).
// ============================================================================

import { asText, fieldsOf, problem, raw, type Fields } from '../agents/strict-fields.ts'
import type { Uuid } from '../types/api.ts'

const SUBJECT = 'Opplastingssvaret'

/** Hva som knyttet filen til publikasjonen, og verdien det ble gjort på. */
export interface PublicationBinding {
  /** `doi`, `pmid` eller `title` — i synkende styrke. */
  readonly basis: string
  readonly evidence: string
}

/** Målingen lesbarhetsdommen ble felt på. */
export interface UploadedReadability {
  readonly characterCount: number
  readonly lineCount: number
  readonly tableRowCount: number
  readonly tableDeclarationCount: number
}

export interface FullTextUploadResult {
  readonly sourceDocumentId: Uuid
  readonly documentSha256: string
  readonly documentByteSize: number
  /** `false` betyr at filen allerede lå i biblioteket — samme fil, samme rad. */
  readonly documentStored: boolean
  readonly sourceVersionId: Uuid
  /** `false` betyr at den samme fullteksten allerede var registrert. */
  readonly sourceVersionCreated: boolean
  readonly contentHash: string
  readonly publicationBinding: PublicationBinding
  readonly readability: UploadedReadability
}

function asBoolean(fields: Fields, key: string): boolean {
  const value = raw(fields, key)
  if (typeof value !== 'boolean') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en boolsk verdi')
  }
  return value
}

function asCount(fields: Fields, key: string): number {
  const value = raw(fields, key)
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke et helt tall som ikke er negativt')
  }
  return value
}

export function parseFullTextUploadResult(value: unknown): FullTextUploadResult {
  const fields = fieldsOf(value, SUBJECT, 'svaret')

  const binding = fieldsOf(
    raw(fields, 'publication_binding'),
    SUBJECT,
    'svaret.publication_binding',
  )
  const readability = fieldsOf(raw(fields, 'readability'), SUBJECT, 'svaret.readability')

  return {
    sourceDocumentId: asText(fields, 'source_document_id') as Uuid,
    documentSha256: asText(fields, 'document_sha256'),
    documentByteSize: asCount(fields, 'document_byte_size'),
    documentStored: asBoolean(fields, 'document_stored'),
    sourceVersionId: asText(fields, 'source_version_id') as Uuid,
    sourceVersionCreated: asBoolean(fields, 'source_version_created'),
    contentHash: asText(fields, 'content_hash'),
    publicationBinding: {
      basis: asText(binding, 'basis'),
      evidence: asText(binding, 'evidence'),
    },
    readability: {
      characterCount: asCount(readability, 'character_count'),
      lineCount: asCount(readability, 'line_count'),
      tableRowCount: asCount(readability, 'table_rows'),
      tableDeclarationCount: asCount(readability, 'table_declarations'),
    },
  }
}

/**
 * Én setning om hva som faktisk ble kontrollert, til den som kjørte kommandoen.
 *
 * Bindingsgrunnlaget står først, fordi det er det som svarer på «er dette
 * artikkelen». Tabelltallet står med, fordi det er det som svarer på «kom
 * tallene med».
 */
export function describeUpload(result: FullTextUploadResult): string {
  const basis =
    result.publicationBinding.basis === 'title'
      ? `tittelen («${result.publicationBinding.evidence}»)`
      : `${result.publicationBinding.basis.toUpperCase()} ${result.publicationBinding.evidence}`
  return (
    `Fulltekst bundet til publikasjonen på ${basis}. ` +
    `${String(result.readability.characterCount)} tegn, ` +
    `${String(result.readability.tableRowCount)} datarader og ` +
    `${String(result.readability.tableDeclarationCount)} tabellerklæringer. ` +
    `Fil ${result.documentStored ? 'lagt i' : 'fantes fra før i'} biblioteket; kildeversjon ` +
    `${result.sourceVersionCreated ? 'registrert' : 'gjenbrukt'}: ${result.sourceVersionId}.`
  )
}
