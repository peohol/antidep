import { describe, expect, it } from 'vitest'

import {
  areaSentence,
  parseTechnicalProblemSummary,
  parseTechnicalProblems,
} from './technical-problems'

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    reference: 'p1',
    area: 'automatic_task',
    first_seen_at: '2026-09-28T09:00:00+00:00',
    last_seen_at: '2026-09-29T09:00:00+00:00',
    occurrence_count: 3,
    ongoing: true,
    resolved_at: null,
    ...overrides,
  }
}

describe('lesingen av problemoversikten', () => {
  it('leser området og tidspunktene, og ingenting annet', () => {
    const [problem] = parseTechnicalProblems([row()])
    expect(problem).toEqual({
      reference: 'p1',
      area: 'automatic_task',
      firstSeenAt: '2026-09-28T09:00:00+00:00',
      lastSeenAt: '2026-09-29T09:00:00+00:00',
      occurrenceCount: 3,
      ongoing: true,
      resolvedAt: null,
    })
  })

  it.each([
    ['ikke en liste', {}],
    ['en teller som ikke er et antall', [row({ occurrence_count: -1 })]],
    ['en pågår-verdi som ikke er boolsk', [row({ ongoing: 'ja' })]],
  ])('avviser %s', (_what, value) => {
    expect(() => parseTechnicalProblems(value)).toThrow(/Problemoversikten er ugyldig/)
  })
})

describe('setningene om hva som er galt', () => {
  // Setningene skal si hva slags konsekvens problemet har, og aldri hva som
  // teknisk er galt: det er nettopp det issue #99 punkt 6 ber om.
  it.each([
    ['work_queue', 'Antidep får ikke lest arbeidsoversikten'],
    ['automatic_task', 'En automatisk oppgave har stoppet'],
    ['agent_service', 'Tilkoblingen til agenttjenesten virker ikke'],
    ['full_text_intake', 'En opplastet fulltekst kunne ikke behandles'],
    ['clinical_content', 'Klinikerinnholdet kunne ikke vises'],
  ])('oversetter %s til en setning en ikke-tekniker kan lese', (area, expected) => {
    expect(areaSentence(area)).toBe(expected)
  })

  it('bærer ingen teknisk verdi i noen av setningene', () => {
    const areas = [
      'work_queue',
      'automatic_task',
      'agent_service',
      'full_text_intake',
      'clinical_content',
    ]
    for (const area of areas) {
      const sentence = areaSentence(area).toLowerCase()
      for (const teknisk of ['sqlstate', 'jwt', 'rpc', 'postgrest', 'uuid', 'stack']) {
        expect(sentence).not.toContain(teknisk)
      }
    }
  })

  it('lar et ukjent område bli en sann, generell setning framfor å forsvinne', () => {
    expect(areaSentence('noe_nytt')).toBe('Noe i Antidep virker ikke som det skal')
  })
})

describe('tellingen bak merket i navigasjonen', () => {
  it('sier både om merket skal vises og hvor mange som er uløst', () => {
    expect(parseTechnicalProblemSummary({ visible: true, unresolved: 2 })).toEqual({
      visible: true,
      unresolved: 2,
    })
  })

  // Tellingen svarer stille «ikke synlig» til alle som ikke er admin. Det er en
  // reell tilstand, ikke en feil.
  it('leser «ikke synlig» som en tilstand og ikke som et avslag', () => {
    expect(parseTechnicalProblemSummary({ visible: false, unresolved: 0 })).toEqual({
      visible: false,
      unresolved: 0,
    })
  })

  it('avviser et svar som ikke stemmer med kontrakten', () => {
    expect(() => parseTechnicalProblemSummary({ visible: 'kanskje', unresolved: 0 })).toThrow(
      /ugyldig/,
    )
  })
})
