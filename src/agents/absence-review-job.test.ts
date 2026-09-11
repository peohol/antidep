// ============================================================================
// Kjøremappa for fraværsgjennomlesningen
//
// Hele sikkerheten i mappa er bindingen: et svar dekker et fravær bare når det
// ble avgitt på nøyaktig den teksten kontrollen selv hentet. Prøvene under er
// derfor i hovedsak prøver på at et svar blir LAGT BORT — på feil tekst, på
// feil funn, på feil form, eller fordi det aldri ble avgitt.
//
// Et svar som legges bort, er aldri en feil som stopper kjøringen. Det er en
// åpen kildeomfattende halvdel med en grunn, og resten av kontrollen av det
// funnet er like gyldig uten den.
// ============================================================================

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import {
  ABSENCE_REVIEW_FILES,
  absenceReviewSubject,
  answerHoldsAnAnswer,
  readAbsenceReviewOutcome,
  writeAbsenceReviewJob,
} from './absence-review-job'
import { ABSENCE_REVIEW_VERSION } from './absence-review'
import { MODEL_ANSWER_VERSION } from './model-answer'
import { verificationItemFixture } from './test-support'

const ITEM = verificationItemFixture({
  extraction: {
    ciLower: null,
    ciUpper: null,
    ciLevelPercent: null,
    confidenceIntervalAvailability: 'not_reported',
    timepointAvailability: 'not_applicable',
  },
})

const TEKST = 'Sertraline-treated patients had a mean weight change of 1.5 kg.'
const HASH = `sha256:${'ab'.repeat(32)}`

const katalogene: string[] = []

function katalog(): string {
  const path = mkdtempSync(join(tmpdir(), 'antidep-fravaer-'))
  katalogene.push(path)
  return path
}

afterEach(() => {
  for (const path of katalogene.splice(0)) {
    rmSync(path, { recursive: true, force: true })
  }
})

const job = (directory: string) => ({
  directory,
  item: ITEM,
  representation: TEKST,
  contentHash: HASH,
})

function svarFil(
  directory: string,
  requestDigest: string,
  draft: unknown,
  answeredAt: string = new Date().toISOString(),
): void {
  writeFileSync(
    join(directory, ITEM.evidenceItemId, ABSENCE_REVIEW_FILES.answer),
    JSON.stringify({
      answer_version: MODEL_ANSWER_VERSION,
      request_digest: requestDigest,
      identity: { provider: 'test', model: 'lesing', model_version: '1' },
      answered_at: answeredAt,
      draft,
    }),
    'utf8',
  )
}

const GYLDIG_SVAR = {
  review_version: ABSENCE_REVIEW_VERSION,
  evidence_item_id: ITEM.evidenceItemId,
  fields: [
    {
      check_field: 'confidence_interval',
      status: 'not_reported',
      verdict: 'absent',
      rationale: 'Gikk gjennom hele teksten og fant ingen presisjonsangivelse noe sted.',
    },
  ],
}

describe('absenceReviewSubject', () => {
  it('utleder armen, endepunktet og feltene av den registrerte raden', () => {
    const subject = absenceReviewSubject(ITEM)
    expect(subject.evidenceItemId).toBe(ITEM.evidenceItemId)
    expect(subject.interventionArm).toBe(ITEM.extraction.interventionDrugName)
    expect(subject.outcome).toBe(ITEM.extraction.outcomeLabel)
    expect(subject.fields).toEqual([{ checkField: 'confidence_interval', status: 'not_reported' }])
  })
})

describe('writeAbsenceReviewJob', () => {
  it('legger igjen prompten, forespørselen og en tom svarmal', async () => {
    const rot = katalog()
    const report = await writeAbsenceReviewJob(job(rot))
    expect(report.wroteTemplate).toBe(true)

    const prompt = readFileSync(join(report.directory, ABSENCE_REVIEW_FILES.prompt), 'utf8')
    expect(prompt).toMatch(/confidence_interval/)
    expect(prompt).toMatch(TEKST)

    const forespørsel = JSON.parse(
      readFileSync(join(report.directory, ABSENCE_REVIEW_FILES.request), 'utf8'),
    ) as Record<string, unknown>
    expect(forespørsel.request_digest).toBe(report.requestDigest)
    expect(forespørsel.content_hash).toBe(HASH)
    expect(forespørsel.fields).toEqual([
      { check_field: 'confidence_interval', status: 'not_reported' },
    ])
  })

  // Et svar kan være eneste kopi av et arbeid som allerede er gjort. En ny
  // kjøring skal ikke kunne slette det i stillhet.
  it('skriver ikke over et svar som allerede ligger der', async () => {
    const rot = katalog()
    const første = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, første.requestDigest, GYLDIG_SVAR)

    const andre = await writeAbsenceReviewJob(job(rot))
    expect(andre.wroteTemplate).toBe(false)
    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('reviewed')
  })
})

describe('answerHoldsAnAnswer', () => {
  it('ser malens plassholdere som «ikke besvart»', () => {
    expect(
      answerHoldsAnAnswer({
        draft: { fields: [{ verdict: 'SETT-INN-absent-present-eller-uncertain' }] },
      }),
    ).toBe(false)
  })

  it('ser et utfylt svar som besvart', () => {
    expect(answerHoldsAnAnswer({ draft: GYLDIG_SVAR })).toBe(true)
  })
})

describe('readAbsenceReviewOutcome', () => {
  it('leser et svar som gjelder nøyaktig denne teksten', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, åpnet.requestDigest, GYLDIG_SVAR)

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('reviewed')
    if (outcome.kind !== 'reviewed') return
    expect(outcome.fields[0]?.verdict).toBe('absent')
    expect(outcome.identity.provider).toBe('test')
    expect(outcome.requestDigest).toBe(åpnet.requestDigest)
  })

  it('sier fra når ingen gjennomlesning er lagt inn', async () => {
    const outcome = await readAbsenceReviewOutcome(job(katalog()))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/ingen gjennomlesning ligger i/)
  })

  it('ser en ubesvart mal som ingen gjennomlesning', async () => {
    const rot = katalog()
    await writeAbsenceReviewJob(job(rot))
    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/plassholder/)
  })

  // Kjernen i bindingen: teksten er byttet ut siden mappa ble åpnet. Svaret
  // gjelder da en annen kilde, og kan ikke dekke et fravær i denne.
  it('legger bort et svar avgitt på en annen tekst', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, åpnet.requestDigest, GYLDIG_SVAR)

    const outcome = await readAbsenceReviewOutcome({
      ...job(rot),
      representation: `${TEKST} The 95% CI was 0.4 to 2.6.`,
    })
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/svarer på forespørselen/)
  })

  // Avtrykket regnes ut av teksten kontrollen selv hentet, ikke av det som står
  // i forespørselsfilen. Ellers ville et redigert avtrykk i mappa vært nok.
  it('godtar ikke et avtrykk kalleren har skrevet inn selv', async () => {
    const rot = katalog()
    await writeAbsenceReviewJob(job(rot))
    svarFil(rot, `sha256:${'f'.repeat(64)}`, GYLDIG_SVAR)

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
  })

  it('legger bort et svar som gjelder et annet evidensfunn', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, åpnet.requestDigest, {
      ...GYLDIG_SVAR,
      evidence_item_id: '00000000-0000-4000-8000-000000000000',
    })

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/gjelder evidensfunnet 00000000/)
  })

  // Et svar avgitt før spørsmålet fantes, er ikke en unøyaktighet — det ville
  // stått i proveniensen som når den uavhengige gjennomlesningen ble gjort.
  it('legger bort et svar avgitt før spørsmålet ble stilt', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, åpnet.requestDigest, GYLDIG_SVAR, '2020-01-01T00:00:00Z')

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/utenfor vinduet/)
  })

  // Proveniensen for leddet som kan åpne publiseringsgaten, skal overleve at
  // arbeidsmappa forsvinner (EVIDENCE_PIPELINE.md §3.7, §65).
  it('bærer tidspunktet og et fingeravtrykk av svaret videre', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    const svartKlokkeslett = new Date().toISOString()
    svarFil(rot, åpnet.requestDigest, GYLDIG_SVAR, svartKlokkeslett)

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('reviewed')
    if (outcome.kind !== 'reviewed') return
    expect(outcome.answeredAt).toBe(svartKlokkeslett)
    expect(outcome.answerDigest).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('legger bort et svar som ikke har kontraktens form', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    svarFil(rot, åpnet.requestDigest, { ...GYLDIG_SVAR, fields: [{ check_field: 'x' }] })

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/ugyldig/)
  })

  it('kaster ikke på en fil som ikke er JSON', async () => {
    const rot = katalog()
    const åpnet = await writeAbsenceReviewJob(job(rot))
    writeFileSync(join(rot, ITEM.evidenceItemId, ABSENCE_REVIEW_FILES.answer), 'ikke json', 'utf8')
    expect(åpnet.wroteTemplate).toBe(true)

    const outcome = await readAbsenceReviewOutcome(job(rot))
    expect(outcome.kind).toBe('missing')
    if (outcome.kind !== 'missing') return
    expect(outcome.reason).toMatch(/kunne ikke leses/)
  })
})
