import { describe, expect, it, vi } from 'vitest'

import {
  acquireOne,
  describeAcquisitionReport,
  extractHtmlText,
  HTML_TEXT_RECIPE,
  openAccessPdfUrl,
  runMonographAcquisition,
  type AcquisitionApi,
  type SourceRequest,
} from './monograph-acquisition.ts'
import type { Fetcher } from './monograph-search.ts'

function bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value)
}

function served(
  responses: Readonly<Record<string, { body: Uint8Array; contentType?: string; status?: number }>>,
): Fetcher {
  return async (url) => {
    const match = Object.entries(responses).find(([key]) => url.includes(key))
    if (match === undefined) {
      return { status: 'error', message: 'ingen rute' }
    }
    const [, response] = match
    return {
      status: 'ok',
      httpStatus: response.status ?? 200,
      contentType: response.contentType ?? 'text/html',
      bytes: response.body,
      finalUrl: url,
    }
  }
}

const PDF = bytes('%PDF-1.7\nsyntetisk\n%%EOF')
const SIDE = bytes(
  '<html><head><style>p{}</style></head><body><script>var x=1</script>' +
    `<p>${'Sertralin Testmerke tabletter 50&nbsp;mg. '.repeat(20)}</p></body></html>`,
)

const AUTHORITY: SourceRequest = {
  reference: 'a'.repeat(32),
  kind: 'authority_document',
  title: 'Preparatomtale',
  retrievedFrom: 'https://www.legemiddelsok.no/prove',
  requiredRepresentation: 'regulatory_summary',
  identifiers: [],
}

const RESEARCH: SourceRequest = {
  reference: 'b'.repeat(32),
  kind: 'research_full_text',
  title: 'En artikkel',
  retrievedFrom: 'https://doi.org/10.1000/prove',
  requiredRepresentation: null,
  identifiers: [{ system: 'doi', value: '10.1000/prove' }],
}

function api(overrides: Partial<AcquisitionApi> = {}): AcquisitionApi {
  return {
    orders: async () => ['c'.repeat(32)],
    requests: async () => [AUTHORITY],
    submitDocument: async () => undefined,
    submitFullText: async () => undefined,
    ...overrides,
  }
}

describe('extractHtmlText', () => {
  it('fjerner skript, stil og tagger, og oversetter entiteter', () => {
    const text = extractHtmlText(new TextDecoder().decode(SIDE))
    expect(text).not.toContain('var x=1')
    expect(text).not.toContain('<p>')
    expect(text).toContain('Sertralin Testmerke tabletter 50 mg.')
  })

  // Uttrykket må stå tegn for tegn i den registrerte teksten. Et uttrekk som
  // «ryddet opp», ville gjort et ordrett sitat til noe annet.
  it('endrer ikke ordene i teksten', () => {
    expect(extractHtmlText('<p>50&nbsp;mg daglig</p>')).toBe('50 mg daglig')
  })
})

describe('acquireOne — myndighetsdokument', () => {
  it('henter siden, trekker ut teksten og registrerer begge deler', async () => {
    const submitDocument = vi.fn().mockResolvedValue(undefined)
    const outcome = await acquireOne(
      api({ submitDocument }),
      AUTHORITY,
      served({ legemiddelsok: { body: SIDE } }),
    )

    expect(outcome.status).toBe('registered')
    expect(submitDocument).toHaveBeenCalledOnce()
    const args = submitDocument.mock.calls[0]?.[0] as Record<string, unknown>
    expect(args['recipe']).toBe(HTML_TEXT_RECIPE)
    expect(args['mediaType']).toBe('text/html')
    expect(String(args['extractedText'])).toContain('Sertralin Testmerke')
  })

  // PDF-veien har sin egen signatur- og lesbarhetskontroll. To veier for den
  // samme filtypen ville svekket den ene.
  it('sender ikke en PDF gjennom myndighetsveien', async () => {
    const submitDocument = vi.fn()
    const outcome = await acquireOne(
      api({ submitDocument }),
      AUTHORITY,
      served({ legemiddelsok: { body: PDF, contentType: 'application/pdf' } }),
    )
    expect(outcome.status).toBe('left_open')
    expect(outcome.note).toContain('fulltekstinnboksen')
    expect(submitDocument).not.toHaveBeenCalled()
  })

  it('lar forespørselen stå åpen når adressen ikke svarer', async () => {
    const outcome = await acquireOne(api(), AUTHORITY, async () => ({
      status: 'error',
      message: 'nede',
    }))
    expect(outcome.status).toBe('left_open')
  })

  it('avviser en side med for lite tekst til å være dokumentet', async () => {
    const outcome = await acquireOne(
      api(),
      AUTHORITY,
      served({ legemiddelsok: { body: bytes('<html><body>kort</body></html>') } }),
    )
    expect(outcome.status).toBe('left_open')
    expect(outcome.note).toContain('for lite tekst')
  })
})

describe('openAccessPdfUrl', () => {
  const svar = (rows: unknown[]) =>
    bytes(JSON.stringify({ resultList: { result: [{ fullTextUrlList: { fullTextUrl: rows } }] } }))

  it('finner en åpen PDF-lenke', async () => {
    const url = await openAccessPdfUrl(
      '10.1000/prove',
      served({
        europepmc: {
          body: svar([
            { documentStyle: 'html', availability: 'Open access', url: 'https://x.test/html' },
            { documentStyle: 'pdf', availability: 'Open access', url: 'https://x.test/a.pdf' },
          ]),
          contentType: 'application/json',
        },
      }),
    )
    expect(url).toBe('https://x.test/a.pdf')
  })

  it('velger ikke en lenke som krever abonnement', async () => {
    const url = await openAccessPdfUrl(
      '10.1000/prove',
      served({
        europepmc: {
          body: svar([
            {
              documentStyle: 'pdf',
              availability: 'Subscription required',
              url: 'https://x.test/a.pdf',
            },
          ]),
          contentType: 'application/json',
        },
      }),
    )
    expect(url).toBeNull()
  })

  it('velger ikke en ukryptert adresse', async () => {
    const url = await openAccessPdfUrl(
      '10.1000/prove',
      served({
        europepmc: {
          body: svar([
            { documentStyle: 'pdf', availability: 'Open access', url: 'http://x.test/a.pdf' },
          ]),
          contentType: 'application/json',
        },
      }),
    )
    expect(url).toBeNull()
  })
})

describe('acquireOne — forskningsfulltekst', () => {
  it('henter en åpen PDF og legger den i fulltekstinnboksen', async () => {
    const submitFullText = vi.fn().mockResolvedValue(undefined)
    const outcome = await acquireOne(
      api({ submitFullText }),
      RESEARCH,
      served({
        europepmc: {
          body: bytes(
            JSON.stringify({
              resultList: {
                result: [
                  {
                    fullTextUrlList: {
                      fullTextUrl: [
                        {
                          documentStyle: 'pdf',
                          availability: 'Open access',
                          url: 'https://x.test/a.pdf',
                        },
                      ],
                    },
                  },
                ],
              },
            }),
          ),
          contentType: 'application/json',
        },
        'x.test/a.pdf': { body: PDF, contentType: 'application/pdf' },
      }),
    )
    expect(outcome.status).toBe('registered')
    expect(submitFullText).toHaveBeenCalledOnce()
  })

  // Manglende åpen tilgang er en tilgangsbegrensning, ikke en konklusjon om
  // evidensen (SOURCE_POLICY.md §5).
  it('lar forespørselen stå åpen når ingen åpen PDF finnes', async () => {
    const outcome = await acquireOne(
      api(),
      RESEARCH,
      served({
        europepmc: { body: bytes('{"resultList":{"result":[]}}'), contentType: 'application/json' },
      }),
    )
    expect(outcome.status).toBe('left_open')
    expect(outcome.note).toContain('ikke en faglig konklusjon')
  })
})

describe('runMonographAcquisition', () => {
  it('teller det som ble hentet og det som står åpent', async () => {
    const report = await runMonographAcquisition(api(), {
      fetcher: served({ legemiddelsok: { body: SIDE } }),
    })
    expect(report.requests).toBe(1)
    expect(report.registered).toBe(1)
    expect(report.leftOpen).toBe(0)
  })

  it('stopper på grensen framfor å støvsuge', async () => {
    const many = Array.from({ length: 30 }, () => AUTHORITY)
    const report = await runMonographAcquisition(api({ requests: async () => many }), {
      maxRequests: 4,
      fetcher: served({ legemiddelsok: { body: SIDE } }),
    })
    expect(report.requests).toBe(4)
  })

  it('rapporterer uten å navngi en artikkel', async () => {
    const report = await runMonographAcquisition(api(), {
      fetcher: served({ legemiddelsok: { body: SIDE } }),
    })
    const text = describeAcquisitionReport(report)
    expect(text).toContain('Forespørsler forsøkt: 1')
    expect(text).not.toContain('Preparatomtale')
  })
})
