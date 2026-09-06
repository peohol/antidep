import { describe, expect, it } from 'vitest'

import { sourceChoice, withStatus } from './source-choice'
import type { EditorSourceRow } from '../types/api'

function sourceRow(overrides: Partial<EditorSourceRow> = {}): EditorSourceRow {
  return {
    source_id: '50000000-0000-4000-8000-000000000001',
    source_type: 'journal_article',
    title: 'Testkilde om vektendring',
    authors_or_issuer: 'Testforfatter m.fl.',
    publisher_or_journal: 'Testtidsskrift',
    publication_date: '2021-01-01',
    publication_date_precision: 'year',
    source_status: 'active',
    status_note: null,
    ...overrides,
  }
}

describe('sourceChoice', () => {
  it('gir tittel, opphav og år, slik to publikasjoner fra samme gruppe kan skilles', () => {
    expect(sourceChoice(sourceRow()).label).toBe(
      'Testkilde om vektendring — Testforfatter m.fl. — 2021',
    )
  })

  it('bruker kildens id som verdi', () => {
    expect(sourceChoice(sourceRow()).value).toBe('50000000-0000-4000-8000-000000000001')
  })

  it('utelater året når kilden ikke har noen dato', () => {
    expect(sourceChoice(sourceRow({ publication_date: null })).label).toBe(
      'Testkilde om vektendring — Testforfatter m.fl.',
    )
  })

  // ANTIDEP_CONSTITUTION.md §14: en tilbaketrukket kilde skal ikke kunne velges
  // uten at det er synlig.
  it('viser statusen når kilden ikke er aktiv', () => {
    expect(sourceChoice(sourceRow({ source_status: 'retracted' })).label).toMatch(
      /trukket tilbake/i,
    )
  })

  // Vokabularet i `api` er en dokumentert kontrakt og ikke en lås: databasen kan
  // få en ny kildestatus før typen her kjenner den. Casten er derfor selve
  // poenget med testen — den etterligner nøyaktig det svaret klienten da får.
  it('viser en ukjent status som tekst framfor å skjule den', () => {
    const unknownStatus = 'noe_helt_nytt' as EditorSourceRow['source_status']
    expect(sourceChoice(sourceRow({ source_status: unknownStatus })).label).toContain(
      'noe_helt_nytt',
    )
  })
})

describe('withStatus', () => {
  it('lar et navn stå alene når statusen er den normale', () => {
    expect(withStatus('sertralin', 'active')).toBe('sertralin')
  })

  it('setter statusen i parentes ellers', () => {
    expect(withStatus('sertralin', 'utfaset')).toBe('sertralin (utfaset)')
  })
})
