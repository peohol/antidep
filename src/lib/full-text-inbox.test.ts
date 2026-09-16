import { describe, expect, it } from 'vitest'

import {
  describeArticle,
  inboxStateSentence,
  parseFullTextInbox,
  parseFullTextSubmission,
  rejectionSentence,
} from './full-text-inbox'

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    reference: 'r1',
    title: 'Sertraline and weight change over 52 weeks',
    authors: 'Fava m.fl.',
    published_year: 2000,
    state: 'needs_upload',
    previous_rejection: null,
    ...overrides,
  }
}

describe('lesingen av innboksen', () => {
  it('leser artikkelen slik den skal vises', () => {
    const [item] = parseFullTextInbox([row()])
    expect(item).toEqual({
      reference: 'r1',
      title: 'Sertraline and weight change over 52 weeks',
      authors: 'Fava m.fl.',
      publishedYear: 2000,
      state: 'needs_upload',
      previousRejection: null,
    })
  })

  it('tåler en artikkel uten registrert årstall', () => {
    const [item] = parseFullTextInbox([row({ published_year: null })])
    expect(item?.publishedYear).toBeNull()
    expect(describeArticle(item as never)).toBe('Fava m.fl.')
  })

  it.each([
    ['ikke en liste', {}],
    ['en tilstand som ikke finnes', [row({ state: 'venter litt' })]],
    ['et årstall som ikke er et tall', [row({ published_year: '2000' })]],
    ['en manglende tittel', [row({ title: '' })]],
  ])('avviser %s', (_what, value) => {
    expect(() => parseFullTextInbox(value)).toThrow(/Fulltekstinnboksen er ugyldig/)
  })
})

describe('setningene innboksen viser', () => {
  it('ber om nøyaktig én handling når artikkelen mangler', () => {
    expect(inboxStateSentence('needs_upload')).toBe(
      'Last opp fullteksten for at Antidep skal kunne fortsette.',
    )
  })

  it('sier at Antidep gjør resten selv når filen er levert', () => {
    expect(inboxStateSentence('processing')).toMatch(/trenger ikke gjøre noe mer/)
  })

  it('setter forfattere og år sammen slik en redaktør kjenner artikkelen igjen', () => {
    const [item] = parseFullTextInbox([row()])
    expect(describeArticle(item as never)).toBe('Fava m.fl. (2000)')
  })
})

describe('avvisningen som produkttilstand', () => {
  // Hver grunn skal si hva som kan gjøres i stedet, og ingen av dem skal bære
  // et teknisk begrep: koden er lukket i databasen, setningen er flatens.
  it.each([
    ['not_this_article', /denne artikkelen/],
    ['unreadable', /lese/],
    ['not_a_pdf', /PDF/],
    ['other_document_same_text', /allerede registrert/],
    ['extraction_failed', /teknisk problem/],
  ])('oversetter %s til en setning om hva som kan gjøres', (code, expected) => {
    expect(rejectionSentence(code)).toMatch(expected)
  })

  it.each(['not_this_article', 'unreadable', 'not_a_pdf', 'other_document_same_text'])(
    'bærer ingen teknisk verdi i setningen for %s',
    (code) => {
      const sentence = rejectionSentence(code).toLowerCase()
      for (const teknisk of ['sha256', 'uuid', 'sqlstate', 'pdftotext', 'rpc', 'json']) {
        expect(sentence).not.toContain(teknisk)
      }
    },
  )

  it('lar en ukjent grunn bli en sann, generell setning framfor å forsvinne', () => {
    expect(rejectionSentence('noe_nytt')).toMatch(/kunne ikke brukes/)
  })
})

describe('lesingen av opplastingssvaret', () => {
  it('sier om filen ble tatt imot nå eller alt var levert', () => {
    expect(parseFullTextSubmission({ accepted: true })).toEqual({ accepted: true })
    expect(parseFullTextSubmission({ accepted: false })).toEqual({ accepted: false })
  })

  it('avviser et svar som ikke stemmer med kontrakten', () => {
    expect(() => parseFullTextSubmission({ accepted: 'ja' })).toThrow(/ugyldig/)
  })
})
