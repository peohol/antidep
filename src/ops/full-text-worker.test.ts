// ============================================================================
// Antideps egen tekstuttrekker, prøvd mot det den faktisk skal gjøre
//
// Prøven går gjennom det **ekte** verktøyet for den vellykkede veien, av samme
// grunn som `reading-order.test.ts` gjør det: oppskriften er en prosess, og en
// prøve mot en håndskrevet XML-fil kunne vært grønn mens kjeden var rød.
//
// De to stopppunktene prøves derimot med en dobbel, fordi de handler om hva
// kommandoen gjør når verktøyet *ikke* svarer — og et verktøy som ikke finnes,
// kan ikke installeres bort i en prøve.
// ============================================================================

import { describe, expect, it } from 'vitest'

import type { RunTool, ToolRun } from '../agents/document-text.ts'
import { syntheticLayoutPdf } from '../agents/test-support.ts'
import {
  apiFailure,
  describeUnexpectedFailure,
  describeWorkerReport,
  OperationalFailure,
  parseClaimedTask,
  parseCompletionOutcome,
  runFullTextWorker,
  type FailureStage,
  type FullTextIntakeApi,
} from './full-text-worker.ts'

const ARTIKKEL = syntheticLayoutPdf([
  { x: 60, y: 60, lines: ['Sertraline and weight change'], fontSize: 16 },
  { x: 60, y: 120, lines: ['Patients were randomised to treatment.', 'Weight rose by 1.5 kg.'] },
])

/** Databasen, som en dobbel som registrerer hva kommandoen gjorde. */
function api(overrides: Partial<FullTextIntakeApi> = {}): {
  readonly api: FullTextIntakeApi
  readonly completed: { handle: string; text: string; toolVersion: string }[]
  readonly failures: { handle: string; stage: FailureStage }[]
  readonly resumes: number[]
} {
  const completed: { handle: string; text: string; toolVersion: string }[] = []
  const failures: { handle: string; stage: FailureStage }[] = []
  const resumes: number[] = []
  let remaining = 1

  const base: FullTextIntakeApi = {
    claim: () => {
      if (remaining === 0) {
        return Promise.resolve({ available: false })
      }
      remaining -= 1
      return Promise.resolve({
        available: true,
        handle: '11111111-1111-4111-8111-111111111111',
        reference: 'abc',
        document_base64: Buffer.from(ARTIKKEL).toString('base64'),
      })
    },
    complete: (handle, text, toolVersion) => {
      completed.push({ handle, text, toolVersion })
      return Promise.resolve({ status: 'registered', rejection: null })
    },
    fail: (handle, stage) => {
      failures.push({ handle, stage })
      return Promise.resolve({
        reference: 'abc',
        state: stage === 'tool_missing' ? 'blocked' : 'received',
      })
    },
    resume: () => {
      resumes.push(resumes.length)
      return Promise.resolve({ resumed: 0 })
    },
  }

  return { api: { ...base, ...overrides }, completed, failures, resumes }
}

const ingenVerktøy: RunTool = () =>
  Promise.resolve<ToolRun>({ status: 'failed', message: 'pdftotext kunne ikke kjøres (ENOENT).' })

const verktøyetStopper: RunTool = (_tool, args) =>
  args.includes('-v')
    ? Promise.resolve<ToolRun>({
        status: 'ran',
        exitCode: 99,
        stdout: '',
        stderr: 'pdftotext version 24.02.0',
      })
    : Promise.resolve<ToolRun>({
        status: 'ran',
        exitCode: 1,
        stdout: '',
        stderr: 'Syntax Error: Couldn’t read xref table',
      })

describe('lesingen av uttrekksoppdraget', () => {
  it('leser et oppdrag som det står', () => {
    expect(
      parseClaimedTask({
        available: true,
        handle: 'h',
        reference: 'r',
        document_base64: 'JVBERg==',
      }),
    ).toEqual({ available: true, handle: 'h', reference: 'r', documentBase64: 'JVBERg==' })
  })

  // En tom kø er en normal kjøring, ikke en feil.
  it('leser en tom kø som en tilstand og ikke som et avslag', () => {
    expect(parseClaimedTask({ available: false })).toEqual({ available: false })
  })

  it('avviser et svar som ikke stemmer med kontrakten', () => {
    expect(() => parseClaimedTask({ available: 'kanskje' })).toThrow(/ugyldig/)
    expect(() => parseClaimedTask({ available: true, handle: 'h' })).toThrow(/ugyldig/)
  })

  it('leser begge utfallene databasen kan gi', () => {
    expect(parseCompletionOutcome({ status: 'registered', rejection: null })).toEqual({
      status: 'registered',
      rejection: null,
    })
    expect(parseCompletionOutcome({ status: 'rejected', rejection: 'not_this_article' })).toEqual({
      status: 'rejected',
      rejection: 'not_this_article',
    })
    expect(() => parseCompletionOutcome({ status: 'kanskje' })).toThrow(/ugyldig/)
  })
})

describe('kjøringen', () => {
  it('henter teksten ut av filen og leverer den tilbake', async () => {
    const database = api()
    const report = await runFullTextWorker({ api: database.api })

    expect(report).toEqual({
      resumed: 0,
      claimed: 1,
      registered: 1,
      rejected: 0,
      retried: 0,
      blocked: 0,
    })
    expect(database.completed).toHaveLength(1)
    expect(database.completed[0]?.text).toContain('Weight rose by 1.5 kg.')
    // Versjonen leses av verktøyet som faktisk er installert, og oppgis ikke av
    // kommandoen: den er en opplysning, ikke noe som velges.
    expect(database.completed[0]?.toolVersion).toMatch(/^pdftotext /)
  })

  // En avvist fil er ikke en feil her. Kommandoen leverte teksten; databasen
  // avgjorde at filen ikke kunne brukes, og det er en produkttilstand.
  it('rapporterer en avvist fil som avvist, ikke som en teknisk feil', async () => {
    const database = api({
      complete: () => Promise.resolve({ status: 'rejected', rejection: 'not_this_article' }),
    })
    const report = await runFullTextWorker({ api: database.api })
    expect(report).toEqual({
      resumed: 0,
      claimed: 1,
      registered: 0,
      rejected: 1,
      retried: 0,
      blocked: 0,
    })
  })

  it('stopper og melder fra når verktøyet oppskriften krever, ikke finnes', async () => {
    const database = api()
    const report = await runFullTextWorker({ api: database.api, runTool: ingenVerktøy })

    expect(report).toEqual({
      resumed: 0,
      claimed: 1,
      registered: 0,
      rejected: 0,
      retried: 0,
      blocked: 1,
    })
    expect(database.failures).toEqual([
      { handle: '11111111-1111-4111-8111-111111111111', stage: 'tool_missing' },
    ])
    expect(database.completed).toHaveLength(0)
    // Og ingenting settes i gang igjen: verktøyet mangler fortsatt, så en
    // gjenopptakelse ville bare blokkert de samme radene på nytt.
    expect(database.resumes).toHaveLength(0)
  })

  // Dette er hele forskjellen Peder ba om: et driftsproblem skal ikke bli en ny
  // oppgave for redaktøren. Når verktøyet er på plass igjen, går arbeidet
  // videre av seg selv, uten at noen laster opp filen på nytt.
  it('setter blokkert arbeid i gang igjen så snart verktøyet finnes', async () => {
    const database = api({ resume: () => Promise.resolve({ resumed: 2 }) })
    const lines: string[] = []
    const report = await runFullTextWorker({
      api: database.api,
      log: (line) => lines.push(line),
    })

    expect(report.resumed).toBe(2)
    expect(lines[0]).toMatch(/satt i gang igjen/)
  })

  it('avviser et gjenopptakelsessvar som ikke stemmer med kontrakten', async () => {
    const database = api({ resume: () => Promise.resolve({ resumed: 'to' }) })
    await expect(runFullTextWorker({ api: database.api })).rejects.toThrow(/ugyldig/)
  })

  // Både en PDF verktøyet ikke fikk lest, og en uten tekstlag, kommer hit som
  // det samme: oppskriften ga ingen brukbar tekst. Kommandoen later ikke som om
  // den kan skille dem.
  it('melder fra når oppskriften kjørte uten å gi brukbar tekst', async () => {
    const database = api()
    const report = await runFullTextWorker({ api: database.api, runTool: verktøyetStopper })
    expect(report.retried).toBe(1)
    expect(report.blocked).toBe(0)
    expect(database.failures[0]?.stage).toBe('tool_failed')
  })

  // Kjøringen er planlagt i et offentlig repo, og loggen er offentlig. En rå
  // feiltekst fra verktøyet kan bære deler av dokumentet, og den skal derfor
  // ikke stå der uten at noen har bedt om det (AGENTS.md).
  it('holder den rå årsaken utenfor loggen med mindre den bes om', async () => {
    const stille: string[] = []
    await runFullTextWorker({
      api: api().api,
      runTool: verktøyetStopper,
      log: (line) => stille.push(line),
    })
    expect(stille.join('\n')).not.toContain('xref')

    const høyt: string[] = []
    await runFullTextWorker({
      api: api().api,
      runTool: verktøyetStopper,
      diagnostics: true,
      log: (line) => høyt.push(line),
    })
    expect(høyt.join('\n')).toContain('xref')
  })

  // Kjøringen er en kjøring og ikke en tjeneste: uten et tak ville en kommando
  // kunnet bli stående og holde leier i det uendelige.
  it('tar aldri flere oppdrag enn grensen', async () => {
    let claimed = 0
    const database = api({
      claim: () => {
        claimed += 1
        return Promise.resolve({
          available: true,
          handle: '11111111-1111-4111-8111-111111111111',
          reference: 'abc',
          document_base64: Buffer.from(ARTIKKEL).toString('base64'),
        })
      },
    })
    const report = await runFullTextWorker({ api: database.api, maxTasks: 3 })
    expect(claimed).toBe(3)
    expect(report.claimed).toBe(3)
  })

  // Kjøringen er planlagt i et offentlig repo, og GitHub Actions-loggen er
  // offentlig. En videreformidlet feiltekst fra databasen kan bære et
  // beskrankningsnavn, en adresse eller en verdi fra en rad, og den skal ikke
  // stå der uten at noen har bedt om den (AGENTS.md).
  it('holder databasens egen feiltekst utenfor loggen med mindre den bes om', () => {
    const feil = { message: 'duplicate key value violates unique constraint "x"', code: '23505' }

    const stille = apiFailure('Teksten ble ikke levert.', feil, false).message
    expect(stille).toContain('Teksten ble ikke levert.')
    expect(stille).not.toContain('duplicate key')
    // Koden er en maskinidentifikator og kan ikke bære innhold. Uten den ville
    // en rød kjøring i CI vært helt uten spor.
    expect(stille).toContain('23505')

    expect(apiFailure('Teksten ble ikke levert.', feil, true).message).toContain('duplicate key')
  })

  it('sier «ingen» framfor å late som om det fantes en kode', () => {
    expect(apiFailure('Noe.', { message: 'x' }, false).message).toContain('Kode: ingen.')
  })

  // En setning kommandoen selv har skrevet, er allerede trygg. Alt annet vet
  // den ikke hva bærer, og får derfor en stabil setning.
  it('slipper sine egne setninger gjennom, og ingen andres', () => {
    expect(describeUnexpectedFailure(new OperationalFailure('Min egen setning.'), false)).toBe(
      'Min egen setning.',
    )
    expect(describeUnexpectedFailure(new Error('rå tekst fra et bibliotek'), false)).not.toContain(
      'rå tekst',
    )
    expect(describeUnexpectedFailure(new Error('rå tekst fra et bibliotek'), true)).toContain(
      'rå tekst',
    )
    expect(describeUnexpectedFailure('en kastet streng', false)).toMatch(/stoppet uventet/)
  })

  it('sier hva kjøringen gjorde, i én setning', () => {
    expect(
      describeWorkerReport({
        resumed: 0,
        claimed: 0,
        registered: 0,
        rejected: 0,
        retried: 0,
        blocked: 0,
      }),
    ).toBe('Ingen fulltekst ventet på tekstuttrekk.')
    expect(
      describeWorkerReport({
        resumed: 2,
        claimed: 0,
        registered: 0,
        rejected: 0,
        retried: 0,
        blocked: 0,
      }),
    ).toMatch(/2 fil\(er\) satt i gang igjen/)
    expect(
      describeWorkerReport({
        resumed: 0,
        claimed: 2,
        registered: 1,
        rejected: 1,
        retried: 0,
        blocked: 0,
      }),
    ).toContain('2 fil(er) behandlet')
  })
})
