// ============================================================================
// Kjøremappa: grensesnittet en Claude Code Routine faktisk kjører
//
// Det som prøves her, er de tilstandene en autonom kjøring kan komme i, og at
// ingen av dem kan ende med et forslag som ikke er lest ut av den registrerte
// kildeversjonen:
//
//   * de to stegene, og at de er idempotente hver for seg
//   * en kjøring som ble avbrutt mellom dem, eller midt i det andre
//   * et svar som svarer på en annen forespørsel enn kjøringen ble åpnet for
//   * et svar med oppdiktede utdrag, med en katalogverdi utenfor oppdraget,
//     eller med en form som ikke er kontrakten
//   * en kilde som har endret seg, og et oppdrag som er redigert
//   * proveniens som ville vært usann
//
// Ingen modell, ingen leverandørkonto, ingen database og ingen nettilgang:
// hentingen er injisert, og modellsvaret er en fil testen skriver.
// ============================================================================

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { sourceVersionContentHash } from './content-hash'
import {
  closeDraftingJob,
  defaultRunDirectory,
  JOB_FILES,
  openDraftingJob,
  parseDraftingJob,
  readDraftingJobStatus,
} from './drafting-job'
import { parseExtractionProposal } from './extraction-proposal'
import { EXTRACTION_DRAFTING_PROMPT_VERSION } from './extraction-prompt'
import { MODEL_ANSWER_VERSION } from './model-answer'
import type { RetrieveLike } from './source-retrieval'
import { FIXTURE_SOURCE_TEXT } from './test-support'

const DRUG = '40000000-0000-4000-8000-000000000001'
const OTHER_DRUG = '40000000-0000-4000-8000-000000000002'
const OUTCOME = '41000000-0000-4000-8000-000000000001'

const EXCERPT = 'Sertraline patients (N = 284) with major depressive disorder were randomised.'
const QUOTE = 'mean weight change of 1.5 kg'

const OPENED_AT = '2026-09-10T09:00:00Z'
const ANSWERED_AT = '2026-09-10T09:12:00Z'
const CLOSED_AT = '2026-09-10T10:00:00Z'

const temporaries: string[] = []

afterEach(() => {
  while (temporaries.length > 0) {
    rmSync(temporaries.pop() as string, { recursive: true, force: true })
  }
})

function workspace(): string {
  const directory = mkdtempSync(join(tmpdir(), 'antidep-kjoremappe-'))
  temporaries.push(directory)
  return directory
}

async function writeAssignment(
  directory: string,
  overrides: Record<string, unknown> = {},
): Promise<string> {
  const path = join(directory, 'oppdrag.json')
  writeFileSync(
    path,
    JSON.stringify({
      assignment_version: 'antidep/extraction-assignment@2',
      source_id: '50000000-0000-4000-8000-000000000001',
      source_version_id: '51000000-0000-4000-8000-000000000001',
      retrieved_from: 'https://eksempel.invalid/kilde',
      content_hash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
      drugs: [{ drug_id: DRUG, label: 'sertralin' }],
      outcomes: [{ outcome_concept_id: OUTCOME, label: 'vektendring' }],
      populations: [],
      ...overrides,
    }),
    'utf8',
  )
  return path
}

function retrieveFixture(overrides: { content?: string; hash?: string } = {}): RetrieveLike {
  const content = overrides.content ?? FIXTURE_SOURCE_TEXT
  return async (url) => ({
    status: 'ok',
    representation: {
      url,
      status: 200,
      contentType: 'text/xml',
      content,
      byteLength: content.length,
      contentHash: overrides.hash ?? (await sourceVersionContentHash(content)),
      bytesAreUtf8: true,
    },
  })
}

function utkast(overrides: { extraction?: Record<string, unknown>; groundings?: unknown } = {}) {
  return {
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne med depressiv lidelse.',
      sample_size: 284,
      sample_size_availability: 'reported_value',
      intervention_drug_id: DRUG,
      comparator_kind: 'none',
      outcome_concept_id: OUTCOME,
      outcome_detail: 'Gjennomsnittlig vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate: '1.5',
      estimate_unit: 'kg',
      estimate_availability: 'reported_value',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag, RESULTS',
      source_quote: QUOTE,
      ...overrides.extraction,
    },
    field_groundings: overrides.groundings ?? [
      {
        check_field: 'intervention_arm',
        source_excerpt: EXCERPT,
        source_locator: 'Sammendrag, METHODS',
        justification: 'Armen er navngitt i metodeavsnittet.',
      },
      {
        check_field: 'sample_size',
        source_excerpt: EXCERPT,
        source_locator: 'Sammendrag, METHODS',
        justification: 'Utvalgsstørrelsen står ved siden av armen.',
      },
    ],
  }
}

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>
}

function exists(path: string): boolean {
  try {
    readFileSync(path)
    return true
  } catch {
    return false
  }
}

/** Skriver svarfilen slik aktøren som utførte modellarbeidet ville gjort det. */
function writeAnswer(
  runDirectory: string,
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  const path = join(runDirectory, JOB_FILES.answer)
  const digest = readJson(join(runDirectory, JOB_FILES.job)).request_digest
  const answer = {
    answer_version: MODEL_ANSWER_VERSION,
    request_digest: digest,
    identity: { provider: 'anthropic', model: 'claude-code', model_version: 'opus-5' },
    answered_at: ANSWERED_AT,
    draft: utkast(),
    ...overrides,
  }
  writeFileSync(path, JSON.stringify(answer, null, 2), 'utf8')
  return answer
}

/** Åpner en kjøring i en fersk mappe og gir tilbake stiene testen trenger. */
async function opened(overrides: Record<string, unknown> = {}) {
  const directory = workspace()
  const assignmentPath = await writeAssignment(directory, overrides)
  const runDirectory = join(directory, 'kjoring')
  const report = await openDraftingJob({
    assignmentPath,
    runDirectory,
    retrieve: retrieveFixture(),
    now: () => OPENED_AT,
  })
  return { directory, assignmentPath, runDirectory, report }
}

function closeOptions(assignmentPath: string, runDirectory: string) {
  return {
    runDirectory,
    assignmentPath,
    retrieve: retrieveFixture(),
    now: () => CLOSED_AT,
  }
}

describe('defaultRunDirectory', () => {
  it('utleder kjøremappa av oppdragsfilen, slik at ingen må velge en', () => {
    expect(defaultRunDirectory('assignments/fava-2000.json')).toBe(join('assignments', 'fava-2000'))
  })
})

describe('openDraftingJob', () => {
  it('legger igjen prompten, en tom svarfil og kjøringen, uten å skrive noe forslag', async () => {
    const { runDirectory, report } = await opened()

    expect(report.outcome).toBe('opened')
    expect(readFileSync(join(runDirectory, JOB_FILES.prompt), 'utf8')).toContain(
      'Sertraline patients (N = 284)',
    )

    const job = parseDraftingJob(readJson(join(runDirectory, JOB_FILES.job)))
    expect(job.state).toBe('awaiting_answer')
    expect(job.openedAt).toBe(OPENED_AT)
    expect(job.promptTemplateVersion).toBe(EXTRACTION_DRAFTING_PROMPT_VERSION)
    expect(job.requestDigest).toMatch(/^sha256:[0-9a-f]{64}$/)

    const template = readJson(join(runDirectory, JOB_FILES.answer))
    expect(template.request_digest).toBe(job.requestDigest)
    expect(JSON.stringify(template.identity)).toContain('SETT-INN-')
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(false)
  })

  it('er idempotent: den samme kommandoen igjen gir den samme kjøringen', async () => {
    const { assignmentPath, runDirectory, report } = await opened()
    const igjen = await openDraftingJob({
      assignmentPath,
      runDirectory,
      retrieve: retrieveFixture(),
      now: () => '2026-09-10T11:00:00Z',
    })

    expect(igjen.outcome).toBe('resumed')
    expect(igjen.job.requestDigest).toBe(report.job.requestDigest)
    // Åpningstidspunktet er kjøringens, ikke gjenopptakelsens: det er starten
    // på vinduet et svar må være avgitt innenfor.
    expect(igjen.job.openedAt).toBe(OPENED_AT)
  })

  it('lar et svar som allerede er lagt inn, stå urørt ved en gjenopptakelse', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    const før = readFileSync(join(runDirectory, JOB_FILES.answer), 'utf8')

    await openDraftingJob({ assignmentPath, runDirectory, retrieve: retrieveFixture() })

    expect(readFileSync(join(runDirectory, JOB_FILES.answer), 'utf8')).toBe(før)
  })

  it('bygger ingen prompt når kilden har endret seg siden den ble registrert', async () => {
    const directory = workspace()
    const assignmentPath = await writeAssignment(directory)

    await expect(
      openDraftingJob({
        assignmentPath,
        runDirectory: join(directory, 'kjoring'),
        retrieve: retrieveFixture({ content: 'En helt annen tekst enn den registrerte.' }),
      }),
    ).rejects.toThrow(/Kilden har endret seg/)
  })

  it('nekter å dele kjøremappe med et annet oppdrag', async () => {
    const { directory, runDirectory } = await opened()
    const annet = join(directory, 'annet-oppdrag.json')
    writeFileSync(annet, readFileSync(join(directory, 'oppdrag.json'), 'utf8'), 'utf8')

    await expect(
      openDraftingJob({ assignmentPath: annet, runDirectory, retrieve: retrieveFixture() }),
    ).rejects.toThrow(/er kjøremappa til/)
  })

  it('nekter å gjenoppta når oppdraget er endret og svaret allerede er gitt', async () => {
    const { directory, assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    // Katalogen i oppdraget står i prompten, så en redigert etikett gir en
    // annen forespørsel — og svaret er da lest ut av en annen forespørsel.
    await writeAssignment(directory, {
      drugs: [{ drug_id: DRUG, label: 'sertralin (revidert etikett)' }],
    })

    await expect(
      openDraftingJob({ assignmentPath, runDirectory, retrieve: retrieveFixture() }),
    ).rejects.toThrow(/annet fingeravtrykk/)
  })
})

describe('closeDraftingJob — den lykkede stien', () => {
  it('skriver forslaget, opptaket og en lukket kjøring', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('drafted')
    expect(report.job.state).toBe('drafted')
    expect(report.job.closedAt).toBe(CLOSED_AT)
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(true)
    expect(exists(join(runDirectory, JOB_FILES.recording))).toBe(true)
  })

  it('skriver et forslag den ekte registreringen leser uendret', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    const proposal = parseExtractionProposal(readJson(join(runDirectory, JOB_FILES.proposal)))
    expect(proposal.sourceVersionId).toBe('51000000-0000-4000-8000-000000000001')
    expect(proposal.extraction.interventionDrugId).toBe(DRUG)
    expect(proposal.fieldGroundings.map((g) => g.checkField)).toEqual([
      'intervention_arm',
      'sample_size',
    ])
  })

  it('fører proveniensen som aktøren erklærte den, og ikke som en fast verdi', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    const generatedBy = report.proposal?.generatedBy
    expect(generatedBy).toEqual({
      producer: 'model',
      provider: 'anthropic',
      model: 'claude-code',
      modelVersion: 'opus-5',
      promptTemplateVersion: EXTRACTION_DRAFTING_PROMPT_VERSION,
      // Tidspunktet er da aktøren svarte, ikke da kjøringen ble lukket.
      draftedAt: ANSWERED_AT,
      requestDigest: report.job.requestDigest,
    })
  })

  it('bruker lukketidspunktet når aktøren ikke oppga et, framfor å finne på et', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, { answered_at: undefined })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.proposal?.generatedBy.draftedAt).toBe(CLOSED_AT)
  })

  it('tar imot et svar gitt som ordrett tekst, med kodegjerder og alt', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: undefined,
      completion: `\`\`\`json\n${JSON.stringify(utkast())}\n\`\`\``,
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('drafted')
  })

  it('skriver et opptak som kan spilles av igjen gjennom de samme kontrollene', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    const recording = readJson(join(runDirectory, JOB_FILES.recording))
    expect(recording.identity).toEqual({
      provider: 'anthropic',
      model: 'claude-code',
      model_version: 'opus-5',
    })
    const entries = recording.entries as { request_digest: string }[]
    expect(entries[0]?.request_digest).toBe(report.job.requestDigest)
  })
})

describe('closeDraftingJob — svar som ikke blir et forslag', () => {
  it('avviser et oppdiktet utdrag, og skriver ingen fil', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: utkast({
        groundings: [
          {
            check_field: 'intervention_arm',
            source_excerpt: 'Paroxetine patients (N = 512) were randomised for twelve weeks.',
            source_locator: 'METHODS',
            justification: 'Armen står i metodeavsnittet.',
          },
        ],
      }),
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/ikke står ordrett/)
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(false)
    expect(parseDraftingJob(readJson(join(runDirectory, JOB_FILES.job))).state).toBe('rejected')
  })

  it('avviser et omskrevet sitat, som er dømt til å bli avvist av kontrollen senere', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: utkast({ extraction: { source_quote: 'en gjennomsnittlig vektendring på 1,5 kg' } }),
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/source_quote/)
  })

  it('avviser en katalogverdi utenfor oppdraget', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: utkast({ extraction: { intervention_drug_id: OTHER_DRUG } }),
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/intervention_drug_id/)
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(false)
  })

  it('avviser et svar som ikke har kontraktens form', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, { draft: { extraction: { design_code: 'ikke_en_studiedesign' } } })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/design_code/)
  })

  it('avviser en tekst som ikke er JSON i det hele tatt', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: undefined,
      completion: 'Beklager, jeg fant ingen brukbare tall i denne artikkelen.',
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.completion).toContain('Beklager')
  })

  it('avviser når kilden har endret seg mellom de to stegene', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)

    const report = await closeDraftingJob({
      ...closeOptions(assignmentPath, runDirectory),
      retrieve: retrieveFixture({ content: 'Artikkelen er trukket tilbake.' }),
    })

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/Kilden har endret seg/)
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(false)
  })

  it('avviser når oppdraget er redigert etter at svaret ble gitt', async () => {
    const { directory, assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await writeAssignment(directory, {
      outcomes: [{ outcome_concept_id: OUTCOME, label: 'vektendring (revidert)' }],
    })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('rejected')
    expect(report.reason).toMatch(/ikke noe svar på denne forespørselen/)
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(false)
  })
})

describe('closeDraftingJob — svar som ikke hører til denne kjøringen', () => {
  it('nekter et svar som svarer på en annen forespørsel', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, { request_digest: `sha256:${'b'.repeat(64)}` })

    await expect(closeDraftingJob(closeOptions(assignmentPath, runDirectory))).rejects.toThrow(
      /svarer på forespørselen/,
    )
  })

  it('nekter et tidspunkt fra før kjøringen ble åpnet', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, { answered_at: '2026-09-09T08:00:00Z' })

    await expect(closeDraftingJob(closeOptions(assignmentPath, runDirectory))).rejects.toThrow(
      /utenfor kjøringen/,
    )
  })

  it('tåler at klokkene spriker med et minutt, som to maskiner gjør', async () => {
    const { assignmentPath, runDirectory } = await opened()
    // Ett minutt etter at kjøringen lukkes: aktøren som svarte, kjørte på en
    // annen klokke, og det er ikke en usann påstand om noe.
    writeAnswer(runDirectory, { answered_at: '2026-09-10T10:01:00Z' })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('drafted')
  })

  it('tåler et tidspunkt oppgitt i en annen tidssone', async () => {
    const { assignmentPath, runDirectory } = await opened()
    // Det samme øyeblikket som ANSWERED_AT, skrevet med norsk sommertidsoffset.
    // Sammenlignet som tekst ville det sett ut som et tidspunkt fra framtiden.
    writeAnswer(runDirectory, { answered_at: '2026-09-10T11:12:00+02:00' })

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('drafted')
    expect(report.proposal?.generatedBy.draftedAt).toBe('2026-09-10T11:12:00+02:00')
  })

  it('nekter et tidspunkt som ligger etter at kjøringen lukkes', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, { answered_at: '2027-01-01T00:00:00Z' })

    await expect(closeDraftingJob(closeOptions(assignmentPath, runDirectory))).rejects.toThrow(
      /utenfor kjøringen/,
    )
  })

  it('nekter når svarfilen fortsatt bare er malen', async () => {
    const { assignmentPath, runDirectory } = await opened()

    await expect(closeDraftingJob(closeOptions(assignmentPath, runDirectory))).rejects.toThrow(
      /uten et svar/,
    )
  })

  it('nekter når det ikke er åpnet noen kjøring i katalogen', async () => {
    const directory = workspace()
    const assignmentPath = await writeAssignment(directory)

    await expect(
      closeDraftingJob({ runDirectory: directory, assignmentPath, retrieve: retrieveFixture() }),
    ).rejects.toThrow(/Åpne kjøringen først/)
  })

  it('nekter når kalleren peker på kjøremappa til et annet oppdrag', async () => {
    const { directory, runDirectory } = await opened()
    writeAnswer(runDirectory)
    const annet = join(directory, 'annet-oppdrag.json')
    writeFileSync(annet, readFileSync(join(directory, 'oppdrag.json'), 'utf8'), 'utf8')

    await expect(
      closeDraftingJob({
        runDirectory,
        assignmentPath: annet,
        retrieve: retrieveFixture(),
      }),
    ).rejects.toThrow(/er kjøremappa til/)
  })
})

describe('avbrutte kjøringer', () => {
  it('lukker ikke den samme kjøringen to ganger', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))
    const første = readFileSync(join(runDirectory, JOB_FILES.proposal), 'utf8')

    const igjen = await closeDraftingJob({
      ...closeOptions(assignmentPath, runDirectory),
      now: () => '2026-09-11T10:00:00Z',
    })

    expect(igjen.outcome).toBe('already_drafted')
    expect(readFileSync(join(runDirectory, JOB_FILES.proposal), 'utf8')).toBe(første)
  })

  it('lager forslaget på nytt når kjøringen ble avbrutt før filen ble skrevet', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))
    // Slik en kjøring som ble drept mellom de to skrivingene ser ut: kjøringen
    // står som lukket, men filen neste ledd venter på, finnes ikke.
    rmSync(join(runDirectory, JOB_FILES.proposal))

    const igjen = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(igjen.outcome).toBe('drafted')
    expect(exists(join(runDirectory, JOB_FILES.proposal))).toBe(true)
  })

  it('sier fra om forrige avvisning når kjøringen åpnes på nytt', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: utkast({ extraction: { intervention_drug_id: OTHER_DRUG } }),
    })
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    const igjen = await openDraftingJob({
      assignmentPath,
      runDirectory,
      retrieve: retrieveFixture(),
    })

    expect(igjen.outcome).toBe('resumed')
    expect(igjen.previousReason).toMatch(/intervention_drug_id/)
    expect(igjen.job.state).toBe('awaiting_answer')
  })

  it('lar et rettet svar bli et forslag etter en avvisning', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory, {
      draft: utkast({ extraction: { intervention_drug_id: OTHER_DRUG } }),
    })
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))
    await openDraftingJob({ assignmentPath, runDirectory, retrieve: retrieveFixture() })
    writeAnswer(runDirectory)

    const report = await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    expect(report.outcome).toBe('drafted')
    expect(report.job.reason).toBeNull()
  })

  it('åpner ikke noe på nytt når forslaget allerede ligger der', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    const igjen = await openDraftingJob({
      assignmentPath,
      runDirectory,
      retrieve: retrieveFixture(),
    })

    expect(igjen.outcome).toBe('already_drafted')
    expect(igjen.job.state).toBe('drafted')
  })

  it('henter ikke kilden i det hele tatt for en ferdig kjøring', async () => {
    const { assignmentPath, runDirectory } = await opened()
    writeAnswer(runDirectory)
    await closeDraftingJob(closeOptions(assignmentPath, runDirectory))

    // Kilden er nede, eller endret. Filen neste ledd venter på, ligger der
    // likevel, og en idempotent kommando skal ikke feile på en henting den ikke
    // trenger å gjøre.
    const aldri: RetrieveLike = () => {
      throw new Error('kilden skulle ikke vært hentet')
    }
    const igjen = await openDraftingJob({ assignmentPath, runDirectory, retrieve: aldri })

    expect(igjen.outcome).toBe('already_drafted')
    expect(igjen.proposalPath).toBe(join(runDirectory, JOB_FILES.proposal))
  })
})

describe('readDraftingJobStatus', () => {
  it('sier hvor kjøringen står, uten å hente noe og uten å skrive noe', async () => {
    const { runDirectory } = await opened()
    const før = await readDraftingJobStatus(runDirectory)
    expect(før).toMatchObject({ answerPresent: false, proposalPresent: false })
    expect(før.job.state).toBe('awaiting_answer')

    writeAnswer(runDirectory)
    const etter = await readDraftingJobStatus(runDirectory)
    expect(etter.answerPresent).toBe(true)
  })

  it('sier fra når katalogen ikke er en kjøremappe', async () => {
    await expect(readDraftingJobStatus(workspace())).rejects.toThrow(/ingen kjøring her/)
  })
})
