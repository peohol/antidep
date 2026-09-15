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
//
// ----------------------------------------------------------------------------
// Hvorfor «ingen versjon» er en opplysning og ikke et tomt felt
//
// Fra den eksterne agent-handoffen utføres det semantiske arbeidet av KI-agenter
// eieren allerede har tilgang til, og en slik tjeneste eksponerer sjelden noen
// intern build. Et krav om en eksakt versjon ville tvunget fram enten en
// oppdiktet streng — en usann proveniens — eller en fri tekst per svar
// («ukjent», «unknown», «n/a»), som ville gjort to kjøringer av *samme* modell
// til to forskjellige modellidentiteter. Da ville separasjonsregelen sluttet å
// virke nettopp der den betyr mest (ANTIDEP_CONSTITUTION.md regel 3, 4).
//
// `modelVersionDisclosure` sier derfor hvilken av to ting versjonsfeltet er, og
// «ikke eksponert» har én kanonisk verdi. Den samme regelen står i databasen
// (migrasjon 010a), og de to sidene pinnes mot hverandre av en prøve.
// ============================================================================

import {
  asOptionalText,
  asText,
  nestedFields,
  problem,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

/** Om versjonsfeltet er en versjon tjenesten oppgir, eller ingen versjon i det hele tatt. */
export type ModelVersionDisclosure = 'exact' | 'not_exposed'

export const MODEL_VERSION_DISCLOSURES: readonly ModelVersionDisclosure[] = ['exact', 'not_exposed']

/**
 * Den kanoniske verdien `modelVersion` bærer når tjenesten ikke oppgir noen.
 *
 * Kanonisk og ikke fri tekst: to ukjente versjoner av den samme modellen skal
 * være den samme identiteten. Verdien er den samme som
 * `provenance.unexposed_model_version()` i databasen.
 */
export const UNEXPOSED_MODEL_VERSION = 'ikke-eksponert'

/** Hvem som svarte, i de feltene proveniensen krever. */
export interface ModelIdentity {
  readonly provider: string
  readonly model: string
  readonly modelVersion: string
  readonly modelVersionDisclosure: ModelVersionDisclosure
}

/** Prefikset malene skriver, og som må rettes før filen kan brukes. */
export const PLACEHOLDER_PREFIX = 'SETT-INN-'

/** Identiteten en mal skrives med, slik at feltene sier hva de skal fylles med. */
export const PLACEHOLDER_IDENTITY = {
  provider: `${PLACEHOLDER_PREFIX}LEVERANDØR`,
  model: `${PLACEHOLDER_PREFIX}MODELL`,
  model_version: `${PLACEHOLDER_PREFIX}MODELLVERSJON`,
} as const

/** Identiteten som JSON, slik begge filformene skriver den. */
export function serializeModelIdentity(identity: ModelIdentity): Record<string, unknown> {
  return {
    provider: identity.provider,
    model: identity.model,
    model_version: identity.modelVersion,
    model_version_disclosure: identity.modelVersionDisclosure,
  }
}

/**
 * Nøkkelen separasjonen gjelder.
 *
 * De tre feltene, og ikke eksponeringsgraden: to identiteter som begge har en
 * ikke-eksponert versjon, bærer den samme kanoniske verdien og er dermed den
 * samme modellen — som er sant.
 */
export function modelIdentityKey(identity: ModelIdentity): string {
  return `${identity.provider}/${identity.model}/${identity.modelVersion}`
}

/** Om to identiteter er den samme modellen. */
export function sameModelIdentity(a: ModelIdentity, b: ModelIdentity): boolean {
  return modelIdentityKey(a) === modelIdentityKey(b)
}

/** Identiteten i klartekst, slik en flate viser den for et menneske. */
export function describeModelIdentity(identity: ModelIdentity): string {
  return identity.modelVersionDisclosure === 'not_exposed'
    ? `${identity.model} (${identity.provider}) — tjenesten oppgir ingen eksakt versjon`
    : `${identity.model} ${identity.modelVersion} (${identity.provider})`
}

/** Leser `identity` fra en fil, eller sier hvilket felt som er galt. */
export function parseModelIdentity(
  parent: Fields,
  value: unknown,
  where = 'identity',
): ModelIdentity {
  const fields = nestedFields(parent, value, where)
  const provider = asText(fields, 'provider')
  const model = asText(fields, 'model')
  const declaredVersion = asOptionalText(fields, 'model_version')
  const declaredDisclosure = asOptionalText(fields, 'model_version_disclosure')
  rejectUnknown(fields)

  // Standardverdien er `exact`, slik at en fil skrevet før eksponeringsgraden
  // fantes, leses som det den var: en erklæring om en versjon noen faktisk
  // oppga.
  const disclosure = declaredDisclosure ?? 'exact'
  if (disclosure !== 'exact' && disclosure !== 'not_exposed') {
    problem(
      fields.subject,
      `${fields.where}.model_version_disclosure`,
      `er ${JSON.stringify(disclosure)}, som verken er «exact» eller «not_exposed»`,
    )
  }

  for (const [key, text] of [
    ['provider', provider],
    ['model', model],
    ['model_version', declaredVersion ?? ''],
  ] as const) {
    if (text.trimStart().startsWith(PLACEHOLDER_PREFIX)) {
      problem(
        fields.subject,
        `${fields.where}.${key}`,
        'står fortsatt med plassholderen fra malen. Verdien registreres som premissene utkastet ble laget under, og en plassholder ville vært en usann proveniens — fyll inn leverandøren, modellen og modellversjonen som faktisk svarte',
      )
    }
  }

  if (disclosure === 'not_exposed') {
    // Den kanoniske verdien, uansett hva filen måtte ha skrevet i feltet. En
    // fri tekst her ville gjort to ukjente versjoner av den samme modellen til
    // to forskjellige identiteter.
    if (declaredVersion !== null && declaredVersion !== UNEXPOSED_MODEL_VERSION) {
      problem(
        fields.subject,
        `${fields.where}.model_version`,
        `er ${JSON.stringify(declaredVersion)}, men model_version_disclosure sier at tjenesten ` +
          'ikke oppgir noen versjon. La feltet stå tomt, eller oppgi den versjonen tjenesten ' +
          'faktisk viser og sett model_version_disclosure til «exact»',
      )
    }
    return {
      provider,
      model,
      modelVersion: UNEXPOSED_MODEL_VERSION,
      modelVersionDisclosure: disclosure,
    }
  }

  if (declaredVersion === null) {
    problem(
      fields.subject,
      `${fields.where}.model_version`,
      'mangler. Oppgir tjenesten ingen versjon, skal model_version_disclosure være ' +
        '«not_exposed» — en oppdiktet versjon ville sett like troverdig ut som en sann',
    )
  }
  if (declaredVersion === UNEXPOSED_MODEL_VERSION) {
    problem(
      fields.subject,
      `${fields.where}.model_version`,
      `er ${JSON.stringify(UNEXPOSED_MODEL_VERSION)}, som er den kanoniske verdien for en ` +
        'versjon tjenesten ikke oppgir. Sett model_version_disclosure til «not_exposed» og la ' +
        'model_version stå tom',
    )
  }
  return { provider, model, modelVersion: declaredVersion, modelVersionDisclosure: 'exact' }
}
