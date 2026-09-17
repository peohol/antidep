import { describe, expect, it } from 'vitest'

import {
  activityLabel,
  groupByStatus,
  parseWorkBoard,
  statusPresentation,
  workStatusNote,
  WORK_STATUS_ORDER,
  type WorkStatus,
} from './work-board'

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    reference: 'a1',
    activity: 'findings',
    status: 'planned',
    waiting_for: null,
    subjects: ['sertralin'],
    updated_at: '2026-09-28T09:00:00+00:00',
    ...overrides,
  }
}

describe('lesingen av arbeidsoversikten', () => {
  it('leser en rad som den står', () => {
    const [item] = parseWorkBoard([row()])
    expect(item).toEqual({
      reference: 'a1',
      activity: 'findings',
      status: 'planned',
      waitingFor: null,
      subjects: ['sertralin'],
      updatedAt: '2026-09-28T09:00:00+00:00',
    })
  })

  // Et svar som ikke stemmer med kontrakten, skal stoppe her — ikke bli til en
  // rad som mangler noe uten at noen merket det.
  it.each([
    ['ikke en liste', {}],
    ['en tilstand som ikke finnes', [row({ status: 'kanskje' })]],
    ['en manglende referanse', [row({ reference: '' })]],
    ['en ventetilstand som verken er tekst eller tom', [row({ waiting_for: 7 })]],
    ['et virkestoff som ikke er tekst', [row({ subjects: [1] })]],
  ])('avviser %s', (_what, value) => {
    expect(() => parseWorkBoard(value)).toThrow(/Arbeidsoversikten er ugyldig/)
  })
})

describe('vokabularet oversikten viser', () => {
  it('sier hva slags arbeid det er, i klinikerens språk', () => {
    expect(activityLabel('full_text')).toBe('Skaffe fullteksten til en forskningsartikkel')
    expect(activityLabel('findings')).toBe('Hente funn ut av en forskningsartikkel')
    expect(activityLabel('assessment')).toBe('Vurdere hvor sikker evidensen er')
  })

  // En flate som er eldre enn databasen, vil møte en verdi den ikke kjenner.
  // Oppgaven skal fortsatt vises: en oppgave som forsvant, ville løyet om hvor
  // mye som står igjen.
  it('lar en ukjent verdi bli «annet arbeid» framfor å forsvinne', () => {
    expect(activityLabel('noe_helt_nytt')).toBe('Annet arbeid i kunnskapsgrunnlaget')
  })

  // Status skal kunne leses uten farge: tegnet og teksten er forskjellige for
  // hver tilstand, og ingen tilstand deler noen av delene med en annen.
  it('gir hver tilstand sitt eget tegn og sin egen tekst', () => {
    const statuses: readonly WorkStatus[] = ['planned', 'in_progress', 'failed', 'done']
    const symbols = statuses.map((status) => statusPresentation(status).symbol)
    const labels = statuses.map((status) => statusPresentation(status).label)
    const tones = statuses.map((status) => statusPresentation(status).tone)
    expect(new Set(symbols).size).toBe(statuses.length)
    expect(new Set(labels).size).toBe(statuses.length)
    expect(new Set(tones).size).toBe(statuses.length)
    for (const label of labels) {
      expect(label.length).toBeGreaterThan(0)
    }
  })

  // «Venter på fulltekst» er den ene formuleringen issue #99 navngir, og den er
  // en produkttilstand — ikke en teknisk feil.
  it('sier «Venter på fulltekst» når det er artikkelen som mangler', () => {
    const [waiting] = parseWorkBoard([
      row({ activity: 'full_text', status: 'planned', waiting_for: 'full_text' }),
    ])
    expect(workStatusNote(waiting as never)).toBe('Venter på fulltekst')
  })

  // Og den andre ventetilstanden: ny kunnskap finnes, og en redaktør skal
  // avgjøre om den eksisterende teksten skal skrives om. Planlagt redaksjonelt
  // arbeid, aldri en teknisk feil (ANTIDEP_CONSTITUTION.md regel 4).
  it('sier hva som venter når en redaktør må avgjøre noe', () => {
    const [waiting] = parseWorkBoard([
      row({ activity: 'claim_revision', status: 'planned', waiting_for: 'editorial_decision' }),
    ])
    const note = workStatusNote(waiting as never) ?? ''
    expect(note).toContain('Ny forskning')
    expect(note).toContain('redaktør')
    expect(note.toLowerCase()).not.toContain('feil')
    expect(activityLabel('claim_revision')).toBe(
      'Vurdere om ny forskning endrer en påstand Antidep allerede har',
    )
  })

  // En ventetilstand flaten ikke kjenner, skal ikke bli til en gjettet setning.
  it('finner ikke på en forklaring den ikke har', () => {
    const [waiting] = parseWorkBoard([row({ waiting_for: 'noe_helt_nytt' })])
    expect(workStatusNote(waiting as never)).toBeNull()
  })

  it('sier noe annet, og aldri noe teknisk, når en oppgave har stoppet', () => {
    const [failed] = parseWorkBoard([row({ status: 'failed' })])
    const note = workStatusNote(failed as never) ?? ''
    expect(note).not.toBe('Venter på fulltekst')
    expect(note.toLowerCase()).not.toContain('feil')
  })

  it('sier ingenting ekstra om en oppgave som bare går sin gang', () => {
    const [running] = parseWorkBoard([row({ status: 'in_progress' })])
    expect(workStatusNote(running as never)).toBeNull()
  })
})

describe('grupperingen', () => {
  it('viser det som pågår først og historikken sist, uten tomme grupper', () => {
    const items = parseWorkBoard([
      row({ reference: 'a', status: 'done' }),
      row({ reference: 'b', status: 'in_progress' }),
      row({ reference: 'c', status: 'planned' }),
    ])
    expect(groupByStatus(items).map((group) => group.status)).toEqual([
      'in_progress',
      'planned',
      'done',
    ])
  })

  it('har en rekkefølge som dekker alle fire tilstandene', () => {
    expect([...WORK_STATUS_ORDER].sort()).toEqual(
      ['done', 'failed', 'in_progress', 'planned'].sort(),
    )
  })
})
