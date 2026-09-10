// ============================================================================
// Modellsvaret: den ene filen aktøren som utfører modell-leddet, skriver
//
// Kjøremappa (`drafting-job.ts`) skriver forespørselen ut som `prompt.txt`.
// Aktøren som utfører modellarbeidet — i dag en Claude Code Routine, i går
// ChatGPT i et nettleservindu — leser den og legger svaret sitt i `svar.json`.
// Denne filen er formen på nettopp det svaret, og ingenting annet.
//
//   answer_version   hvilken form filen er skrevet mot
//   request_digest   hvilken forespørsel svaret gjelder
//   identity         hvem som faktisk svarte
//   answered_at      når det ble svart (valgfritt)
//   draft            svaret som objekt  ┐ nøyaktig én av de to
//   completion       svaret som tekst   ┘
//
// ----------------------------------------------------------------------------
// Hvorfor avtrykket står i svaret
//
// Fordi en fil på disk ikke vet hvilken forespørsel den er et svar på. Et svar
// skrevet mot én artikkel kunne ellers blitt lukket inn i en kjøring for en
// annen: filnavnet ville stemt, og ingenting annet ville sagt fra. Avtrykket
// dekker representasjonen, katalogen i oppdraget og promptmalversjonen, og
// kjøringen krever at det er kjøringens eget (`drafting-job.ts`).
//
// Det er også hele grunnen til at en avbrutt kjøring er trygg å gjenoppta: er
// kilden endret i mellomtiden, får forespørselen et annet avtrykk, og det gamle
// svaret gjelder ikke lenger. Det er riktig utfall, ikke et hinder.
//
// ----------------------------------------------------------------------------
// Hvorfor svaret kan være både et objekt og en tekst
//
// De to formene er to reelle måter et svar oppstår på, og begge ender i den
// samme kontrollen:
//
//   * **`draft`** er et JSON-objekt. Det er formen en aktør som *skriver filen
//     selv* naturlig produserer — en Routine som lager `svar.json` — og den
//     krever ingen escaping av et flerlinjers svar inne i en JSON-streng.
//   * **`completion`** er svaret som ordrett tekst. Det er formen når svaret
//     kommer fra et vindu et sted og skal bevares nøyaktig slik det kom, med
//     kodegjerder og alt annet støy modellen måtte ha lagt på.
//
// Nøyaktig én av dem. Begge to ville reist spørsmålet om hvilken som gjaldt, og
// det spørsmålet skal ingen kjøring måtte svare på.
//
// Uansett form går svaret gjennom `parseExtractionDraft` og den ordrette
// kontrollen i `drafting-run.ts`. Formen på filen bestemmer ingenting om hva
// som godtas (EVIDENCE_PIPELINE.md §62).
//
// ----------------------------------------------------------------------------
// Utrygg inndata
//
// Svaret er data, aldri instruksjoner (CLAUDE.md). Det er skrevet av en modell
// som nettopp har lest en artikkel Antidep ikke kontrollerer, og verken
// verdiene, begrunnelsene eller identiteten i det får styre en eneste
// beslutning i kjeden. De blir kontrollert, eller de blir avvist.
// ============================================================================

import { parseModelIdentity, PLACEHOLDER_PREFIX, type ModelIdentity } from './model-identity.ts'
import {
  asOptionalText,
  asText,
  fieldsOf,
  isCalendarTimestamp,
  problem,
  raw,
  rejectUnknown,
} from './strict-fields.ts'

const ANSWER_SUBJECT = 'Modellsvaret'

/** Versjonen av svarformen, oppgitt i hver fil. */
export const MODEL_ANSWER_VERSION = 'antidep/model-answer@1'

/** Ett modellsvar, lest og kontrollert. */
export interface ModelAnswer {
  readonly answerVersion: typeof MODEL_ANSWER_VERSION
  readonly requestDigest: string
  readonly identity: ModelIdentity
  /** Tidspunktet aktøren oppgir at den svarte, eller `null` når det ikke er oppgitt. */
  readonly answeredAt: string | null
  /** Svaret som tekst, uansett hvilken av de to formene filen brukte. */
  readonly completion: string
  /** Hvilken av de to formene filen brukte. Bare til feilmeldinger og logg. */
  readonly form: 'draft' | 'completion'
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

/** Leser og kontrollerer ett modellsvar, eller sier hvilket felt som er galt. */
export function parseModelAnswer(value: unknown): ModelAnswer {
  const fields = fieldsOf(value, ANSWER_SUBJECT, 'svaret')

  const version = asText(fields, 'answer_version')
  if (version !== MODEL_ANSWER_VERSION) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answer_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ${JSON.stringify(MODEL_ANSWER_VERSION)}`,
    )
  }

  const requestDigest = asText(fields, 'request_digest')
  if (!DIGEST_PATTERN.test(requestDigest)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.request_digest',
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn. Verdien står i kjøremappa, ' +
        'og skal kopieres derfra uendret',
    )
  }

  const identity = parseModelIdentity(fields, raw(fields, 'identity'))

  const answeredAt = asOptionalText(fields, 'answered_at')
  if (answeredAt !== null && answeredAt.trimStart().startsWith(PLACEHOLDER_PREFIX)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answered_at',
      'står fortsatt med plassholderen fra malen. Skriv tidspunktet du svarte, på formen ' +
        '2026-09-10T09:12:00Z — det registreres som da utkastet ble laget, og uten det blir ' +
        'tidspunktet i proveniensen den gangen kjøringen ble lukket',
    )
  }
  // Kalenderkontroll, og ikke bare et mønster. «2026-99-99T99:99:99Z» har formen
  // og gir NaN; «2026-09-31T00:00:00Z» har formen og gir 1. oktober. Begge ville
  // sluppet gjennom vindussjekken i `drafting-job.ts` — den første fordi NaN er
  // verken større eller mindre enn noe, den andre fordi den normaliserte datoen
  // faktisk ligger i vinduet rundt et månedsskifte — og blitt skrevet inn i
  // forslaget som da utkastet ble laget. Kontrollen er den samme som
  // `drafted_at` bruker, fra det samme stedet.
  if (answeredAt !== null && !isCalendarTimestamp(answeredAt)) {
    problem(
      ANSWER_SUBJECT,
      'svaret.answered_at',
      'er ikke et tidspunkt på formen 2026-09-10T09:12:00Z',
    )
  }

  const draft = raw(fields, 'draft')
  const completion = raw(fields, 'completion')
  rejectUnknown(fields)

  const hasDraft = draft !== undefined && draft !== null
  const hasCompletion = completion !== undefined && completion !== null

  if (hasDraft && hasCompletion) {
    problem(
      ANSWER_SUBJECT,
      'svaret',
      'oppgir både draft og completion. Nøyaktig én av dem skal stå der, ellers er det ikke ' +
        'entydig hvilket svar kjøringen skal kontrollere',
    )
  }
  if (!hasDraft && !hasCompletion) {
    problem(
      ANSWER_SUBJECT,
      'svaret',
      'har verken draft eller completion. Legg svaret i draft som et JSON-objekt, eller i ' +
        'completion som ordrett tekst',
    )
  }

  if (hasDraft) {
    if (typeof draft !== 'object' || Array.isArray(draft)) {
      problem(ANSWER_SUBJECT, 'svaret.draft', 'er ikke et JSON-objekt')
    }
    // Serialiseringen er ikke et tap: verdien går uansett gjennom JSON.parse i
    // neste ledd, og en fil som allerede *er* JSON, kan ikke bære noe annet enn
    // det den serialiserte formen bærer. Det som ville gått tapt ved den
    // motsatte veien — tekst rundt et objekt, to objekter, en forklaring foran —
    // er nettopp det `completion`-formen finnes for å bevare.
    return {
      answerVersion: MODEL_ANSWER_VERSION,
      requestDigest,
      identity,
      answeredAt,
      completion: JSON.stringify(draft),
      form: 'draft',
    }
  }

  if (typeof completion !== 'string' || completion.trim().length === 0) {
    problem(
      ANSWER_SUBJECT,
      'svaret.completion',
      'er ikke tekst, eller er tom. En tom plass er ikke et svar — kjøringen har ingenting å ' +
        'kontrollere',
    )
  }
  return {
    answerVersion: MODEL_ANSWER_VERSION,
    requestDigest,
    identity,
    answeredAt,
    completion,
    form: 'completion',
  }
}
