// ============================================================================
// Kommandoen som lager et oppdrag: hva den velger, og hva den nekter å gjette
//
// Prøvene her handler om de valgene kommandoen tar på egen hånd — hvilken
// kilde, hvilken kildeversjon, og om en PDF skal registreres eller gjenbrukes —
// og om at ingen av dem blir gjettet når svaret er tvetydig.
//
// Selve oppdraget bygges av databasen (migrasjon 007i) og settes aldri sammen
// her; prøvene bruker derfor en dobbel som svarer med den samme formen, og
// kontrollerer at svaret leses med den samme strengheten som en fil.
// ============================================================================

import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { sourceVersionContentHash } from '../agents/content-hash.ts'
import { documentDigest } from '../agents/document-binding.ts'
import { PDF_TEXT_ARGUMENTS, PDF_TEXT_TOOL, type RunTool } from '../agents/document-text.ts'
import { syntheticPdf } from '../agents/test-support.ts'
import type { EditorSourceRow, EditorSourceVersionRow, Uuid } from '../types/api.ts'
import {
  buildAssignmentFromCatalog,
  chooseSourceVersion,
  matchSource,
  type BuildAssignmentInput,
  type DocumentVersionInput,
  type EditorCatalogApi,
} from './extraction-assignment.ts'

const LINJER = ['Mean weight change was 1.0% after 26 to 32 weeks.', 'Forty-eight completed.']
const PDF = syntheticPdf(LINJER)
const TEKST = `${LINJER.join('\n')}\n`

const KILDE = '11111111-1111-4111-8111-111111111111' as Uuid
const ANNEN_KILDE = '22222222-2222-4222-8222-222222222222' as Uuid
const VERSJON = '33333333-3333-4333-8333-333333333333' as Uuid
const NY_VERSJON = '44444444-4444-4444-8444-444444444444' as Uuid

const verktoy: RunTool = (_tool, args) =>
  Promise.resolve(
    args.includes('-v')
      ? { status: 'ran', exitCode: 99, stdout: '', stderr: 'pdftotext version 24.02.0\n' }
      : { status: 'ran', exitCode: 0, stdout: TEKST, stderr: '' },
  )

function kilde(overrides: Partial<EditorSourceRow> = {}): EditorSourceRow {
  return {
    source_id: KILDE,
    source_type: 'journal_article',
    title: 'Fluoxetine versus sertraline and paroxetine',
    authors_or_issuer: 'Fava M, Judge R',
    publisher_or_journal: 'The Journal of Clinical Psychiatry',
    publication_date: '2000-11-01',
    publication_date_precision: 'month',
    source_status: 'active',
    status_note: null,
    ...overrides,
  }
}

function versjon(overrides: Partial<EditorSourceVersionRow> = {}): EditorSourceVersionRow {
  return {
    source_version_id: VERSJON,
    source_id: KILDE,
    retrieved_at: '2026-08-19T06:17:31Z',
    retrieved_from: 'https://eutils.ncbi.nlm.nih.gov/…',
    external_version: null,
    content_hash: `sha256:${'a'.repeat(64)}`,
    representation: 'abstract',
    document_sha256: null,
    document_byte_size: null,
    document_media_type: null,
    text_extraction_tool: null,
    text_extraction_tool_version: null,
    text_extraction_arguments: null,
    ...overrides,
  }
}

interface FakeCatalog extends EditorCatalogApi {
  readonly registered: DocumentVersionInput[]
  readonly built: BuildAssignmentInput[]
}

function katalog(options: {
  readonly sources?: readonly EditorSourceRow[]
  readonly versions?: readonly EditorSourceVersionRow[]
  readonly assignment?: (input: BuildAssignmentInput) => unknown
}): FakeCatalog {
  const registered: DocumentVersionInput[] = []
  const built: BuildAssignmentInput[] = []
  const versions = [...(options.versions ?? [])]
  return {
    registered,
    built,
    listSources: () => Promise.resolve(options.sources ?? [kilde()]),
    listSourceVersions: (sourceId) =>
      Promise.resolve(versions.filter((row) => row.source_id === sourceId)),
    createSourceVersionFromDocument: (input) => {
      registered.push(input)
      return Promise.resolve(NY_VERSJON)
    },
    buildAssignment: (input) => {
      built.push(input)
      return Promise.resolve(
        options.assignment?.(input) ?? {
          assignment_version: 'antidep/extraction-assignment@2',
          source_id: KILDE,
          source_version_id: input.sourceVersionId,
          retrieved_from: 'https://doi.org/10.4088/jcp.v61n1109',
          content_hash: `sha256:${'c'.repeat(64)}`,
          document: null,
          drugs: [{ drug_id: '55555555-5555-4555-8555-555555555555', label: 'sertralin' }],
          outcomes: [
            { outcome_concept_id: '66666666-6666-4666-8666-666666666666', label: 'vektendring' },
          ],
          populations: [],
        },
      )
    },
  }
}

const kataloger: string[] = []

async function pdfPaDisk(bytes: Uint8Array = PDF): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'antidep-oppdrag-'))
  kataloger.push(directory)
  const path = join(directory, 'artikkel.pdf')
  await writeFile(path, bytes)
  return path
}

afterEach(async () => {
  await Promise.all(kataloger.splice(0).map((directory) => rm(directory, { recursive: true })))
})

describe('matchSource', () => {
  it('finner kilden på en del av tittelen eller på en forfatter', () => {
    expect(matchSource([kilde()], 'fava')).toEqual({ source: kilde() })
    expect(matchSource([kilde()], 'paroxetine')).toEqual({ source: kilde() })
  })

  it('gjetter ikke når søket treffer flere', () => {
    const to = [kilde(), kilde({ source_id: ANNEN_KILDE, title: 'Fava et al., en annen studie' })]
    const result = matchSource(to, 'fava')
    expect('error' in result && result.error).toMatch(/treffer 2 kilder/)
  })

  it('lister de registrerte kildene når søket ikke treffer noe', () => {
    const result = matchSource([kilde()], 'versiani')
    expect('error' in result && result.error).toMatch(/Fluoxetine versus sertraline/)
  })
})

describe('chooseSourceVersion', () => {
  it('velger den nyeste av den representasjonstypen kalleren ba om', () => {
    const gammel = versjon({ representation: 'full_text', retrieved_at: '2026-01-01T00:00:00Z' })
    const ny = versjon({
      source_version_id: NY_VERSJON,
      representation: 'full_text',
      retrieved_at: '2026-09-01T00:00:00Z',
    })
    const result = chooseSourceVersion([gammel, ny, versjon()], 'full_text')
    expect('version' in result && result.version.source_version_id).toBe(NY_VERSJON)
  })

  it('velger aldri en versjon uten fingeravtrykk', () => {
    const result = chooseSourceVersion([versjon({ content_hash: null })], null)
    expect('error' in result && result.error).toMatch(/fingeravtrykk/)
  })

  it('velger aldri en versjon uten representasjonstype', () => {
    // Migrasjon 005v avviser den ved registreringen uansett; her sies det før
    // arbeidet framfor etter.
    const result = chooseSourceVersion([versjon({ representation: null })], null)
    expect('error' in result && result.error).toMatch(/representasjonstype/)
  })

  it('sier hva som faktisk finnes når ingenting passer', () => {
    const result = chooseSourceVersion([versjon()], 'full_text')
    expect('error' in result && result.error).toMatch(/abstract fra 2026-08-19/)
    expect('error' in result && result.error).toMatch(/--pdf/)
  })
})

describe('buildAssignmentFromCatalog — uten dokument', () => {
  it('bygger oppdraget av den valgte versjonen, og leser svaret strengt', async () => {
    const catalog = katalog({ versions: [versjon()] })
    const report = await buildAssignmentFromCatalog({
      catalog,
      sourceQuery: 'fava',
      drugs: ['sertralin'],
      outcomes: ['vektendring'],
      populations: [],
    })
    expect(report.versionOutcome).toBe('selected')
    expect(report.sourceVersionId).toBe(VERSJON)
    expect(catalog.built).toEqual([
      {
        sourceVersionId: VERSJON,
        drugs: ['sertralin'],
        outcomes: ['vektendring'],
        populations: [],
      },
    ])
    expect(report.assignment.drugs[0]?.label).toBe('sertralin')
  })

  it('avviser et svar som ikke har kontraktens form', async () => {
    // Databasens svar leses like strengt som en fil noen har skrevet: en
    // projeksjon som en dag mangler en nøkkel, skal stoppe her.
    const catalog = katalog({
      versions: [versjon()],
      assignment: () => ({ assignment_version: 'antidep/extraction-assignment@2' }),
    })
    await expect(
      buildAssignmentFromCatalog({
        catalog,
        sourceQuery: 'fava',
        drugs: ['sertralin'],
        outcomes: ['vektendring'],
        populations: [],
      }),
    ).rejects.toThrow(/source_id/)
  })
})

describe('buildAssignmentFromCatalog — med originaldokument', () => {
  const grunnlag = {
    sourceQuery: 'fava',
    drugs: ['sertralin'],
    outcomes: ['vektendring'],
    populations: ['voksne med depressiv lidelse'],
    retrievedFrom: 'https://doi.org/10.4088/jcp.v61n1109',
    runTool: verktoy,
  } as const

  it('registrerer fullteksten med bytene, oppskriften og full_text som standard', async () => {
    const catalog = katalog({ versions: [versjon()] })
    const report = await buildAssignmentFromCatalog({
      ...grunnlag,
      catalog,
      documentPath: await pdfPaDisk(),
    })

    expect(report.versionOutcome).toBe('registered')
    expect(report.representation).toBe('full_text')
    const registered = catalog.registered[0]
    expect(registered?.representation).toBe('full_text')
    expect(registered?.extractedText).toBe(TEKST)
    expect(registered?.recipe).toEqual({
      tool: PDF_TEXT_TOOL,
      toolVersion: 'pdftotext 24.02.0',
      arguments: PDF_TEXT_ARGUMENTS,
    })
    // Bytene sendes, ikke fingeravtrykket: databasen skal eie hashen.
    expect(Buffer.from(registered?.documentBase64 ?? '', 'base64').equals(Buffer.from(PDF))).toBe(
      true,
    )
    expect(report.document?.digest).toBe(await documentDigest(PDF))
  })

  it('legger dokumentet i lageret under fingeravtrykket sitt', async () => {
    const store = await mkdtemp(join(tmpdir(), 'antidep-lager-'))
    kataloger.push(store)
    const report = await buildAssignmentFromCatalog({
      ...grunnlag,
      catalog: katalog({ versions: [versjon()] }),
      documentPath: await pdfPaDisk(),
      documentStore: store,
    })
    const digest = (await documentDigest(PDF)).replace('sha256:', '')
    expect(report.document?.storedAt).toBe(join(store, `${digest}.pdf`))
    expect(await documentDigest(new Uint8Array(await readFile(join(store, `${digest}.pdf`))))).toBe(
      await documentDigest(PDF),
    )
  })

  it('gjenbruker kildeversjonen når den samme teksten og det samme dokumentet er registrert', async () => {
    // Databasen ville avvist dubletten; en avbrutt kjøring skal kunne kjøres om
    // igjen framfor å stoppe på den avvisningen.
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'full_text',
          content_hash: await sourceVersionContentHash(TEKST),
          document_sha256: await documentDigest(PDF),
          document_byte_size: PDF.length,
          document_media_type: 'application/pdf',
          text_extraction_tool: PDF_TEXT_TOOL,
          text_extraction_tool_version: 'pdftotext 24.02.0',
          text_extraction_arguments: PDF_TEXT_ARGUMENTS,
        }),
      ],
    })
    const report = await buildAssignmentFromCatalog({
      ...grunnlag,
      catalog,
      documentPath: await pdfPaDisk(),
    })
    expect(report.versionOutcome).toBe('reused')
    expect(report.sourceVersionId).toBe(NY_VERSJON)
    expect(catalog.registered).toHaveLength(0)
  })

  // Den samme teksten kan komme av en annen PDF — den samme artikkelen fra to
  // utgivere — eller av tekstveien. Gjenbrukte kommandoen raden likevel, ville
  // oppdraget pekt på den gamle bindingen mens lageret fikk den nye filen, og
  // hvert ledd videre ville stanset med «fant ingen fil».
  it('gjenbruker ikke en rad som er bundet til et annet dokument', async () => {
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'full_text',
          content_hash: await sourceVersionContentHash(TEKST),
          document_sha256: `sha256:${'9'.repeat(64)}`,
          document_byte_size: 4242,
          document_media_type: 'application/pdf',
          text_extraction_tool: PDF_TEXT_TOOL,
          text_extraction_tool_version: 'pdftotext 24.02.0',
          text_extraction_arguments: PDF_TEXT_ARGUMENTS,
        }),
      ],
    })
    await expect(
      buildAssignmentFromCatalog({ ...grunnlag, catalog, documentPath: await pdfPaDisk() }),
    ).rejects.toThrow(/utledet av et annet originaldokument \(sha256:99/)
    expect(catalog.registered).toHaveLength(0)
  })

  it('gjenbruker ikke en rad hentet ut med andre argumenter', async () => {
    // Argumentene er en del av oppskriften kjeden faktisk kjører. En rad
    // registrert med andre argumenter beskriver en annen operasjon, selv om
    // teksten tilfeldigvis ble den samme.
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'full_text',
          content_hash: await sourceVersionContentHash(TEKST),
          document_sha256: await documentDigest(PDF),
          document_byte_size: PDF.length,
          document_media_type: 'application/pdf',
          text_extraction_tool: PDF_TEXT_TOOL,
          text_extraction_tool_version: 'pdftotext 24.02.0',
          text_extraction_arguments: '-raw',
        }),
      ],
    })
    await expect(
      buildAssignmentFromCatalog({ ...grunnlag, catalog, documentPath: await pdfPaDisk() }),
    ).rejects.toThrow(/andre argumenter/)
    expect(catalog.registered).toHaveLength(0)
  })

  it('gjenbruker ikke en rad registrert som noe annet enn det kalleren ber om', async () => {
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'abstract',
          content_hash: await sourceVersionContentHash(TEKST),
          document_sha256: await documentDigest(PDF),
          document_byte_size: PDF.length,
          document_media_type: 'application/pdf',
          text_extraction_tool: PDF_TEXT_TOOL,
          text_extraction_tool_version: 'pdftotext 24.02.0',
          text_extraction_arguments: PDF_TEXT_ARGUMENTS,
        }),
      ],
    })
    await expect(
      buildAssignmentFromCatalog({ ...grunnlag, catalog, documentPath: await pdfPaDisk() }),
    ).rejects.toThrow(/registrert som «abstract», ikke som «full_text»/)
    expect(catalog.registered).toHaveLength(0)
  })

  // En nyere poppler som gir byte for byte den samme teksten, skal ikke stenge
  // en riktig kjøring: fasiten er fingeravtrykket, og en ny rad er umulig fordi
  // databasen avviser dubletten. Versjonsnummeret er derfor ikke en del av
  // sammenligningen.
  it('gjenbruker en rad som bare har en annen verktøyversjon', async () => {
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'full_text',
          content_hash: await sourceVersionContentHash(TEKST),
          document_sha256: await documentDigest(PDF),
          document_byte_size: PDF.length,
          document_media_type: 'application/pdf',
          text_extraction_tool: PDF_TEXT_TOOL,
          text_extraction_tool_version: 'pdftotext 22.02.0',
          text_extraction_arguments: PDF_TEXT_ARGUMENTS,
        }),
      ],
    })
    const report = await buildAssignmentFromCatalog({
      ...grunnlag,
      catalog,
      documentPath: await pdfPaDisk(),
    })
    expect(report.versionOutcome).toBe('reused')
    expect(catalog.registered).toHaveLength(0)
  })

  it('gjenbruker ikke en rad uten dokument, og sier hvilken vei som gjelder', async () => {
    const catalog = katalog({
      versions: [
        versjon({
          source_version_id: NY_VERSJON,
          representation: 'abstract',
          content_hash: await sourceVersionContentHash(TEKST),
        }),
      ],
    })
    await expect(
      buildAssignmentFromCatalog({ ...grunnlag, catalog, documentPath: await pdfPaDisk() }),
    ).rejects.toThrow(/registrert som tekst hentet fra en adresse/)
    expect(catalog.registered).toHaveLength(0)
  })

  it('skriver dokumentet på nytt når filen i lageret er ødelagt', async () => {
    // En avbrutt skriving kan etterlate en halv fil under riktig navn. Navnet er
    // ikke identiteten — bytene er det — og oppslaget senere hasher dem.
    const store = await mkdtemp(join(tmpdir(), 'antidep-lager-'))
    kataloger.push(store)
    const digest = (await documentDigest(PDF)).replace('sha256:', '')
    await writeFile(join(store, `${digest}.pdf`), new TextEncoder().encode('%PDF-halv fil'))

    const report = await buildAssignmentFromCatalog({
      ...grunnlag,
      catalog: katalog({ versions: [versjon()] }),
      documentPath: await pdfPaDisk(),
      documentStore: store,
    })
    expect(report.document?.storedAt).toBe(join(store, `${digest}.pdf`))
    expect(await documentDigest(new Uint8Array(await readFile(join(store, `${digest}.pdf`))))).toBe(
      await documentDigest(PDF),
    )
  })

  it('krever å få vite hvor dokumentet kom fra', async () => {
    await expect(
      buildAssignmentFromCatalog({
        ...grunnlag,
        retrievedFrom: '',
        catalog: katalog({ versions: [versjon()] }),
        documentPath: await pdfPaDisk(),
      }),
    ).rejects.toThrow(/--retrieved-from/)
  })

  it('avviser en fil som ikke er en PDF, før noe registreres', async () => {
    const catalog = katalog({ versions: [versjon()] })
    await expect(
      buildAssignmentFromCatalog({
        ...grunnlag,
        catalog,
        documentPath: await pdfPaDisk(new TextEncoder().encode('<PubmedArticle>')),
      }),
    ).rejects.toThrow(/PDF-signaturen/)
    expect(catalog.registered).toHaveLength(0)
  })

  it('registrerer ingenting når verktøyet ikke finnes', async () => {
    const catalog = katalog({ versions: [versjon()] })
    await expect(
      buildAssignmentFromCatalog({
        ...grunnlag,
        catalog,
        documentPath: await pdfPaDisk(),
        runTool: () => Promise.resolve({ status: 'failed', message: 'pdftotext mangler (ENOENT)' }),
      }),
    ).rejects.toThrow(/pdftotext/)
    expect(catalog.registered).toHaveLength(0)
  })
})
