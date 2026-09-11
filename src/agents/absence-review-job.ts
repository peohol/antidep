// ============================================================================
// Kjøremappa for den kildeomfattende fraværsgjennomlesningen
//
// Samme form og samme grunn som `drafting-job.ts`: selve gjennomlesningen gjøres
// av en aktør Antidep ikke kaller — en Claude Code Routine, en modell i et
// nettleservindu, en fagperson — og et ledd som leser utrygt eksternt innhold
// skal ikke samtidig ha en skrivevei inn i basen (EVIDENCE_PIPELINE.md §63).
//
//   verifikatoren      henter representasjonen, bygger den versjonerte
//   (--absence-prompts) forespørselen, og legger igjen prompt.txt, en tom
//                      svar.json og forespoersel.json
//   (aktøren)          leser prompt.txt og skriver svaret sitt i svar.json
//   verifikatoren      leser svaret, kontrollerer at det gjelder nøyaktig den
//   (--absence-reviews) representasjonen den selv nettopp hentet, og lar det
//                      avgjøre om `source_wide_absence` kan føres opp
//
// Aktøren ser bare filer. Den har ingen legitimasjon, ingen agentidentitet og
// ingen tilgang til Antidep.
//
// ----------------------------------------------------------------------------
// Bindingen er avtrykket, og den er hele sikkerheten i mappa
//
// `request_digest` dekker promptmalversjonen, feltene det spørres om og HELE
// representasjonsteksten. Verifikatoren regner det ut på nytt av den teksten den
// selv hentet, og et svar med et annet avtrykk legges bort.
//
// Det stenger tre ting på én gang: et svar avgitt på en annen artikkel, et svar
// avgitt på en eldre utgave av den samme artikkelen, og et svar avgitt på et
// annet spørsmål enn det raden faktisk stiller. Uten den bindingen ville en fil
// lagt i riktig mappe vært nok til å åpne en publiseringssperre
// (ANTIDEP_CONSTITUTION.md §14).
//
// Mappenavnet er evidensfunnets id, og svaret oppgir den samme id-en. Begge
// kontrolleres — mappa fordi den er det kjøreren slår opp på, id-en i filen
// fordi en fil kan være lagt i feil mappe.
// ============================================================================

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import {
  ABSENCE_REVIEW_VERSION,
  buildAbsenceReviewRequest,
  globalAbsenceStatus,
  parseAbsenceReview,
  type AbsenceReviewOutcome,
  type AbsenceReviewSubject,
} from './absence-review.ts'
import { sourceVersionContentHash } from './content-hash.ts'
import { modelRequestDigest } from './model-client.ts'
import { MODEL_ANSWER_VERSION, parseCompletionJson, parseModelAnswer } from './model-answer.ts'
import { PLACEHOLDER_IDENTITY, PLACEHOLDER_PREFIX } from './model-identity.ts'
import type { VerificationItem } from './verification-input.ts'

/**
 * Hvor mye klokkene får sprike før et svartidspunkt regnes som usant.
 *
 * Samme grunn og samme slakk som i `drafting-job.ts`: kontrollen finnes for å
 * fange et tidspunkt som ikke kan stemme, ikke for å kreve sekundpresisjon av en
 * aktør som kjører på en annen maskin.
 */
const ANSWER_CLOCK_SLACK_MS = 5 * 60 * 1000

/** Filnavnene i en kjøremappe. Faste navn, av samme grunn som i `drafting-job.ts`. */
export const ABSENCE_REVIEW_FILES = {
  request: 'forespoersel.json',
  prompt: 'prompt.txt',
  answer: 'svar.json',
} as const

/** Versjonen av forespørselsfilen. */
export const ABSENCE_REQUEST_VERSION = 'antidep/source-wide-absence-request@1'

/**
 * Hva funnet spør om, utledet av den registrerte raden.
 *
 * Utledet og ikke oppgitt: aktøren skal få vite hvilken arm, hvilket endepunkt
 * og hvilket tidspunkt fraværet gjelder, og de opplysningene finnes allerede på
 * raden. Et parameter til ville vært et sted å ta feil.
 */
export function absenceReviewSubject(item: VerificationItem): AbsenceReviewSubject {
  const e = item.extraction
  const timepoint =
    e.timepointMin === null && e.timepointMax === null
      ? null
      : [e.timepointMin, e.timepointMax].filter((part) => part !== null).join(' – ')
  return {
    evidenceItemId: item.evidenceItemId,
    interventionArm: e.interventionDrugName,
    comparatorArm: e.comparatorDrugName ?? (e.comparatorKind === 'none' ? null : e.comparatorKind),
    outcome: e.outcomeLabel,
    timepoint,
    // Statusen følger feltet helt fram til spørsmålet: `not_reported` og
    // `not_measured` påstår forskjellige ting, og et felt som spørres om det
    // ene, kan ikke dekke det andre (`globalAbsenceStatus`). Et felt uten en
    // status denne koden kjenner, utelates — da blir det aldri besvart, og
    // aldri dekket. Det er den lukkede feilen, og den riktige.
    fields: item.sourceWideAbsenceFields.flatMap((field) => {
      const status = globalAbsenceStatus(e, field)
      return status === null ? [] : [{ checkField: field, status }]
    }),
  }
}

export interface AbsenceReviewJobInput {
  /** Rotmappa kjøringen legger én undermappe per evidensfunn i. */
  readonly directory: string
  readonly item: VerificationItem
  /** Representasjonen slik verifikatoren faktisk hentet den, ordrett. */
  readonly representation: string
  /** Fingeravtrykket av den samme representasjonen. */
  readonly contentHash: string
  readonly now?: () => string
}

export interface AbsenceReviewJobReport {
  readonly directory: string
  readonly requestDigest: string
  /** `false` når mappa allerede bar et svar, og kjøringen lot det stå. */
  readonly wroteTemplate: boolean
}

/** Malen aktøren fyller ut. Avtrykket står der; resten er ting bare aktøren vet. */
function answerTemplate(requestDigest: string, subject: AbsenceReviewSubject): unknown {
  return {
    answer_version: MODEL_ANSWER_VERSION,
    request_digest: requestDigest,
    identity: PLACEHOLDER_IDENTITY,
    answered_at: `${PLACEHOLDER_PREFIX}TIDSPUNKT`,
    draft: {
      review_version: ABSENCE_REVIEW_VERSION,
      evidence_item_id: subject.evidenceItemId,
      // Statusen er forhåndsutfylt: den er radens, ikke aktørens, og et felt
      // aktøren måtte fylle ut selv, ville vært ett sted til å ta feil av
      // hvilket spørsmål som ble besvart.
      fields: subject.fields.map((field) => ({
        check_field: field.checkField,
        status: field.status,
        verdict: `${PLACEHOLDER_PREFIX}absent-present-eller-uncertain`,
        rationale: `${PLACEHOLDER_PREFIX}HVOR-DU-LETTE`,
      })),
    },
  }
}

async function readJsonFile(path: string): Promise<{ present: boolean; value?: unknown }> {
  let text: string
  try {
    text = await readFile(path, 'utf8')
  } catch {
    return { present: false }
  }
  try {
    return { present: true, value: JSON.parse(text) as unknown }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }
}

/**
 * Om svarfilen bærer et svar, eller bare er malen kjøringen la igjen.
 *
 * Skillet avgjør om en ny kjøring får skrive over den. Et svar kan være eneste
 * kopi av et arbeid som allerede er gjort, og en gjentatt kjøring skal ikke
 * kunne slette det i stillhet.
 */
export function answerHoldsAnAnswer(value: unknown): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false
  }
  const record = value as Record<string, unknown>
  const completion = record.completion
  if (typeof completion === 'string' && completion.trim().length > 0) {
    return true
  }
  const draft = record.draft
  if (typeof draft !== 'object' || draft === null || Array.isArray(draft)) {
    return false
  }
  // Malen *er* et utfylt objekt — den har både feltlisten og plassholderne — så
  // «draft er ikke tom» duger ikke her slik den gjør for ekstraksjonsutkastet.
  // Et svar er en mal der ingen plassholder står igjen.
  return !JSON.stringify(draft).includes(PLACEHOLDER_PREFIX)
}

/**
 * Legger igjen forespørselen for ett funn.
 *
 * Skriver ingenting over et svar som allerede ligger der. Prompten og
 * forespørselsfilen skrives likevel på nytt: de er utledet av representasjonen
 * og malen, og en uendret representasjon gir nøyaktig den samme teksten.
 */
export async function writeAbsenceReviewJob(
  input: AbsenceReviewJobInput,
): Promise<AbsenceReviewJobReport> {
  const { now = () => new Date().toISOString() } = input
  const subject = absenceReviewSubject(input.item)
  const request = buildAbsenceReviewRequest({
    subject,
    contentHash: input.contentHash,
    representation: input.representation,
  })
  const requestDigest = await modelRequestDigest(request)

  const directory = join(input.directory, input.item.evidenceItemId)
  await mkdir(directory, { recursive: true })

  await writeFile(
    join(directory, ABSENCE_REVIEW_FILES.prompt),
    `${request.system}\n\n---\n\n${request.user}\n`,
    'utf8',
  )
  await writeFile(
    join(directory, ABSENCE_REVIEW_FILES.request),
    `${JSON.stringify(
      {
        request_version: ABSENCE_REQUEST_VERSION,
        evidence_item_id: input.item.evidenceItemId,
        source_version_id: input.item.sourceVersion?.sourceVersionId ?? null,
        content_hash: input.contentHash,
        fields: subject.fields.map((field) => ({
          check_field: field.checkField,
          status: field.status,
        })),
        request_digest: requestDigest,
        prompt_template_version: request.promptTemplateVersion,
        opened_at: now(),
      },
      null,
      2,
    )}\n`,
    'utf8',
  )

  const answerPath = join(directory, ABSENCE_REVIEW_FILES.answer)
  const existing = await readJsonFile(answerPath)
  if (existing.present && answerHoldsAnAnswer(existing.value)) {
    return { directory, requestDigest, wroteTemplate: false }
  }
  await writeFile(
    answerPath,
    `${JSON.stringify(answerTemplate(requestDigest, subject), null, 2)}\n`,
    'utf8',
  )
  return { directory, requestDigest, wroteTemplate: true }
}

/**
 * Leser gjennomlesningen for ett funn, og sier hvorfor den eventuelt ikke gjelder.
 *
 * Kaster aldri på et dårlig svar. En ugyldig fil er en åpen kildeomfattende
 * halvdel med en grunn — ikke en kjøring som stopper: resten av kontrollen av
 * dette funnet, og alle funnene bak det i køen, er like gyldig uten den.
 */
/** Da spørsmålet ble lagt igjen, eller `null` når filen ikke kan leses. */
async function readOpenedAt(directory: string): Promise<string | null> {
  try {
    const file = await readJsonFile(join(directory, ABSENCE_REVIEW_FILES.request))
    if (!file.present) {
      return null
    }
    const opened = (file.value as Record<string, unknown>).opened_at
    return typeof opened === 'string' && opened.trim().length > 0 ? opened : null
  } catch {
    return null
  }
}

export async function readAbsenceReviewOutcome(
  input: AbsenceReviewJobInput,
): Promise<AbsenceReviewOutcome> {
  const subject = absenceReviewSubject(input.item)
  const directory = join(input.directory, input.item.evidenceItemId)
  const answerPath = join(directory, ABSENCE_REVIEW_FILES.answer)

  let file: { present: boolean; value?: unknown }
  try {
    file = await readJsonFile(answerPath)
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { kind: 'missing', reason: `gjennomlesningen kunne ikke leses (${message})` }
  }
  if (!file.present) {
    return {
      kind: 'missing',
      reason: `ingen gjennomlesning ligger i ${answerPath}`,
    }
  }
  if (!answerHoldsAnAnswer(file.value)) {
    return {
      kind: 'missing',
      reason: `${answerPath} står fortsatt med malens plassholdere, og er ikke et svar`,
    }
  }

  // Avtrykket regnes ut av teksten verifikatoren SELV hentet, ikke av det som
  // står i forespørselsfilen: den er skrevet av en tidligere kjøring, og en fil
  // kan endres. Er kilden byttet ut siden mappa ble åpnet, faller svaret bort
  // her, og det er hele poenget med bindingen.
  const expected = buildAbsenceReviewRequest({
    subject,
    contentHash: input.contentHash,
    representation: input.representation,
  })
  const expectedDigest = await modelRequestDigest(expected)

  try {
    const answer = parseModelAnswer(file.value)
    if (answer.requestDigest !== expectedDigest) {
      return {
        kind: 'missing',
        reason:
          `gjennomlesningen i ${answerPath} svarer på forespørselen ${answer.requestDigest}, ` +
          `mens denne kontrollen gjelder ${expectedDigest}. Et svar lest ut av én tekst kan ikke ` +
          'dekke et fravær i en annen',
      }
    }
    const review = parseAbsenceReview(parseCompletionJson(answer.completion))
    if (review.evidenceItemId !== input.item.evidenceItemId) {
      return {
        kind: 'missing',
        reason:
          `gjennomlesningen i ${answerPath} gjelder evidensfunnet ${review.evidenceItemId}, ` +
          'ikke dette',
      }
    }
    // Tidspunktet må kunne stemme. Et svar avgitt før spørsmålet fantes, er
    // ikke en unøyaktighet — det er usant, og det ville stått i proveniensen
    // som når den uavhengige gjennomlesningen ble gjort. Samme kontroll og
    // samme slakk som modell-leddet ellers (`drafting-job.ts`).
    const openedAt = await readOpenedAt(directory)
    if (answer.answeredAt !== null && openedAt !== null) {
      const answered = Date.parse(answer.answeredAt)
      if (
        answered < Date.parse(openedAt) - ANSWER_CLOCK_SLACK_MS ||
        answered > Date.now() + ANSWER_CLOCK_SLACK_MS
      ) {
        return {
          kind: 'missing',
          reason:
            `gjennomlesningen i ${answerPath} oppgir answered_at ${answer.answeredAt}, som ligger ` +
            `utenfor vinduet: spørsmålet ble lagt igjen ${openedAt}. Tidspunktet registreres som ` +
            'da gjennomlesningen ble gjort, og skal derfor være det',
        }
      }
    }

    return {
      kind: 'reviewed',
      evidenceItemId: review.evidenceItemId,
      identity: answer.identity,
      promptTemplateVersion: expected.promptTemplateVersion,
      requestDigest: expectedDigest,
      answeredAt: answer.answeredAt,
      answerDigest: await sourceVersionContentHash(answer.completion),
      fields: review.fields,
    }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { kind: 'missing', reason: `gjennomlesningen i ${answerPath} er ugyldig: ${message}` }
  }
}
