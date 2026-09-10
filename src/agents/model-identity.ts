// ============================================================================
// Hvem som svarte, lest fra en fil
//
// To filformer bærer den samme erklæringen: opptaket (`recorded-model.ts`) og
// modellsvaret en Routine skriver (`model-answer.ts`). Begge ender som
// premissene utkastet ble laget under, i registreringskjøringens
// `input_manifest` (`extraction-run.ts`), og begge må derfor kontrolleres likt.
//
// Lesingen står her og ikke i hver av dem, fordi to nesten like kontroller er
// to steder å glemme den samme regelen — og regelen under er ikke en formalitet.
//
// ----------------------------------------------------------------------------
// Hvorfor en plassholder avvises framfor å advares mot
//
// Verdiene registreres som en påstand om hvilken modell som leste artikkelen
// (ANTIDEP_CONSTITUTION.md §14, §20). En plassholder som blir stående, er
// derfor ikke et tomt felt — det er en usann proveniens, og den ville sett like
// troverdig ut som en sann. En dokumentert advarsel er ikke nok når koden kan
// avvise verdien.
//
// Prefikset og ikke de tre eksakte verdiene: en plassholder som blir *delvis*
// rettet — «SETT-INN-MODELL-2026» — er like usann som en urørt.
// ============================================================================

import { asText, nestedFields, problem, rejectUnknown, type Fields } from './strict-fields.ts'

/** Hvem som svarte, i de tre feltene proveniensen krever. */
export interface ModelIdentity {
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
}

/** Prefikset malene skriver, og som må rettes før filen kan brukes. */
export const PLACEHOLDER_PREFIX = 'SETT-INN-'

/** Identiteten en mal skrives med, slik at feltene sier hva de skal fylles med. */
export const PLACEHOLDER_IDENTITY = {
  provider: `${PLACEHOLDER_PREFIX}LEVERANDØR`,
  model: `${PLACEHOLDER_PREFIX}MODELL`,
  model_version: `${PLACEHOLDER_PREFIX}MODELLVERSJON`,
} as const

/** Leser `identity` fra en fil, eller sier hvilket felt som er galt. */
export function parseModelIdentity(
  parent: Fields,
  value: unknown,
  where = 'identity',
): ModelIdentity {
  const fields = nestedFields(parent, value, where)
  const identity: ModelIdentity = {
    provider: asText(fields, 'provider'),
    model: asText(fields, 'model'),
    modelVersion: asText(fields, 'model_version'),
  }
  rejectUnknown(fields)

  for (const [key, text] of [
    ['provider', identity.provider],
    ['model', identity.model],
    ['model_version', identity.modelVersion],
  ] as const) {
    if (text.trimStart().startsWith(PLACEHOLDER_PREFIX)) {
      problem(
        fields.subject,
        `${fields.where}.${key}`,
        'står fortsatt med plassholderen fra malen. Verdien registreres som premissene utkastet ble laget under, og en plassholder ville vært en usann proveniens — fyll inn leverandøren, modellen og modellversjonen som faktisk svarte',
      )
    }
  }
  return identity
}
