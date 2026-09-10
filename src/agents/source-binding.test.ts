// ============================================================================
// Kildebindingen: at teksten er den registrerte, og at den kom rett vei
//
// Prøvene her handler om den ene avgjørelsen `resolveRepresentation` tar — om
// representasjonen hentes fra adressen eller ut av originaldokumentet — og om
// at ingen av de to veiene kan tre inn for den andre.
//
// Det er invarianten hele dokumentveien finnes for: kunne en fulltekstversjon
// tilfredsstilles av det som lå på `retrieved_from`, ville et sammendrag hentet
// fra PubMed kunnet bli kontrollgrunnlaget for en ekstraksjon registrert som
// fulltekst.
// ============================================================================

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { sourceVersionContentHash } from './content-hash.ts'
import {
  documentBindingMismatch,
  documentDigest,
  parseDocumentBindingValue,
  serializeDocumentBinding,
  textLooksLikePdf,
  type DocumentBinding,
} from './document-binding.ts'
import { PDF_TEXT_ARGUMENTS, PDF_TEXT_TOOL, type RunTool } from './document-text.ts'
import { resolveRepresentation, type ResolvePorts } from './source-binding.ts'
import { documentsIn, loadDocumentFile } from './source-document.ts'
import { retrieveRepresentation, type RetrieveLike } from './source-retrieval.ts'
import { syntheticPdf } from './test-support.ts'

const LINJER = [
  'Mean weight change was 1.0% after 26 to 32 weeks of treatment.',
  'Forty-eight sertraline-treated patients completed the trial.',
]
const PDF = syntheticPdf(LINJER)
const TEKST = `${LINJER.join('\n')}\n`

/** Et verktøy som «henter ut» nøyaktig linjene PDF-en ble bygget av. */
const utdrag: RunTool = (tool, args, stdin) => {
  if (args.includes('-v')) {
    return Promise.resolve({
      status: 'ran',
      exitCode: 99,
      stdout: '',
      stderr: 'pdftotext version 24.02.0\n',
    })
  }
  if (stdin === undefined || stdin.length !== PDF.length) {
    return Promise.resolve({ status: 'ran', exitCode: 1, stdout: '', stderr: 'ukjent dokument' })
  }
  expect(tool).toBe(PDF_TEXT_TOOL)
  return Promise.resolve({ status: 'ran', exitCode: 0, stdout: TEKST, stderr: '' })
}

/** Et verktøy som gir en annen tekst — en annen versjon av poppler. */
const annenVersjon: RunTool = (_tool, args) =>
  Promise.resolve(
    args.includes('-v')
      ? { status: 'ran', exitCode: 99, stdout: '', stderr: 'pdftotext version 22.02.0\n' }
      : { status: 'ran', exitCode: 0, stdout: `${TEKST}\f`, stderr: '' },
  )

const OPPSKRIFT = {
  tool: PDF_TEXT_TOOL,
  toolVersion: 'pdftotext 24.02.0',
  arguments: PDF_TEXT_ARGUMENTS,
}

async function dokumentbinding(): Promise<DocumentBinding> {
  return {
    sha256: await documentDigest(PDF),
    byteSize: PDF.length,
    mediaType: 'application/pdf',
    textExtraction: OPPSKRIFT,
  }
}

const kataloger: string[] = []

async function katalogMed(filer: Readonly<Record<string, Uint8Array | string>>): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'antidep-dokument-'))
  kataloger.push(directory)
  for (const [name, content] of Object.entries(filer)) {
    await writeFile(join(directory, name), content)
  }
  return directory
}

afterEach(async () => {
  await Promise.all(kataloger.splice(0).map((directory) => rm(directory, { recursive: true })))
})

function hentet(tekst: string, hash: string): RetrieveLike {
  return (url) =>
    Promise.resolve({
      status: 'ok',
      representation: {
        url,
        status: 200,
        contentType: 'text/plain',
        content: tekst,
        byteLength: Buffer.byteLength(tekst, 'utf8'),
        contentHash: hash,
        bytesAreUtf8: true,
      },
    })
}

describe('fingeravtrykket av et dokument', () => {
  it('er sha256 av bytene, med algoritmen som prefiks', async () => {
    // Den samme verdien `sha256sum` gir på filen. Uten det er fingeravtrykket
    // ikke etterprøvbart av noen utenfor Antidep.
    // Referanseverdien er den `printf 'antidep' | sha256sum` gir, som er hele
    // poenget: en tredjepart skal komme fram til det samme uten Antidep.
    expect(await documentDigest(new TextEncoder().encode('antidep'))).toBe(
      'sha256:4f031f35e9e54f26eaed0a8e2333d6d51dd0be1d72d67a74ee8b72ca46b0dfba',
    )
    expect(await documentDigest(PDF)).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('er uavhengig av at bytene er et utsnitt av en større buffer', async () => {
    // En Uint8Array kan peke inn i en større ArrayBuffer, og et fingeravtrykk
    // som hashet hele bufferen, ville vært av noe annet enn filen.
    const stor = new Uint8Array(PDF.length + 32)
    stor.set(PDF, 16)
    expect(await documentDigest(stor.subarray(16, 16 + PDF.length))).toBe(await documentDigest(PDF))
  })

  it('kjenner igjen en PDF på tekstform', () => {
    expect(textLooksLikePdf('%PDF-1.7\n…')).toBe(true)
    expect(textLooksLikePdf('<PubmedArticle>')).toBe(false)
  })
})

describe('dokumentbindingen i en fil', () => {
  it('leses tilbake nøyaktig slik den ble skrevet', async () => {
    const binding = await dokumentbinding()
    expect(
      parseDocumentBindingValue(serializeDocumentBinding(binding), 'Prøven', 'binding'),
    ).toEqual(binding)
  })

  it('er null når den ikke står der, og ikke et tomt objekt', () => {
    expect(parseDocumentBindingValue(null, 'Prøven', 'binding')).toBeNull()
    expect(parseDocumentBindingValue(undefined, 'Prøven', 'binding')).toBeNull()
  })

  it('avviser et fingeravtrykk som ikke har formen', async () => {
    const feil = serializeDocumentBinding(await dokumentbinding()) as Record<string, unknown>
    expect(() =>
      parseDocumentBindingValue({ ...feil, sha256: 'md5:kort' }, 'Prøven', 'binding'),
    ).toThrow(/sha256/)
  })

  it('avviser et ukjent felt framfor å ignorere det', async () => {
    const feil = serializeDocumentBinding(await dokumentbinding()) as Record<string, unknown>
    expect(() =>
      parseDocumentBindingValue({ ...feil, storrelse: 12 }, 'Prøven', 'binding'),
    ).toThrow(/storrelse/)
  })
})

describe('to bindinger som ikke beskriver det samme', () => {
  it('sier fra når dokumentet er et annet', async () => {
    const binding = await dokumentbinding()
    expect(
      documentBindingMismatch(binding, { ...binding, sha256: `sha256:${'0'.repeat(64)}` }),
    ).toMatch(/document\.sha256/)
  })

  it('sier fra når oppskriften er en annen', async () => {
    const binding = await dokumentbinding()
    expect(
      documentBindingMismatch(binding, {
        ...binding,
        textExtraction: { ...OPPSKRIFT, arguments: '-raw' },
      }),
    ).toMatch(/arguments/)
  })

  it('regner fravær av en binding som en forskjell begge veier', async () => {
    const binding = await dokumentbinding()
    expect(documentBindingMismatch(binding, null)).toMatch(/ingen dokumentbinding/)
    expect(documentBindingMismatch(null, binding)).toMatch(/oppgir en dokumentbinding/)
    expect(documentBindingMismatch(null, null)).toBeNull()
  })
})

describe('resolveRepresentation — teksten på adressen', () => {
  it('gir teksten når fingeravtrykket er den registrerte', async () => {
    const hash = await sourceVersionContentHash(TEKST)
    const resolved = await resolveRepresentation(
      { retrievedFrom: 'https://eksempel.invalid/x', contentHash: hash, document: null },
      { retrieve: hentet(TEKST, hash) },
    )
    expect(resolved).toEqual({ status: 'ok', text: TEKST, origin: 'retrieved_text' })
  })

  it('gir ingenting når kilden har endret seg', async () => {
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://eksempel.invalid/x',
        contentHash: `sha256:${'a'.repeat(64)}`,
        document: null,
      },
      { retrieve: hentet(TEKST, await sourceVersionContentHash(TEKST)) },
    )
    expect(resolved.status).toBe('error')
    expect(resolved.status === 'error' && resolved.message).toMatch(/Kilden har endret seg/)
  })
})

describe('resolveRepresentation — teksten ut av originaldokumentet', () => {
  async function porter(extra: Partial<ResolvePorts> = {}): Promise<ResolvePorts> {
    return {
      documents: documentsIn(await katalogMed({ 'artikkel.pdf': PDF })),
      runTool: utdrag,
      ...extra,
    }
  }

  it('finner dokumentet på fingeravtrykket og gjentar oppskriften', async () => {
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: await sourceVersionContentHash(TEKST),
        document: await dokumentbinding(),
      },
      await porter(),
    )
    expect(resolved.status).toBe('ok')
    expect(resolved.status === 'ok' && resolved.text).toBe(TEKST)
    expect(resolved.status === 'ok' && resolved.origin).toBe('extracted_from_document')
  })

  it('henter aldri adressen i stedet når dokumentet mangler', async () => {
    // Den viktigste prøven i filen. Faller kjeden tilbake på adressen, kan et
    // sammendrag bli kontrollgrunnlaget for en fulltekstekstraksjon.
    const hash = await sourceVersionContentHash(TEKST)
    let hentetAdresse = false
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: hash,
        document: await dokumentbinding(),
      },
      {
        documents: documentsIn(await katalogMed({})),
        runTool: utdrag,
        retrieve: (url) => {
          hentetAdresse = true
          return hentet(TEKST, hash)(url)
        },
      },
    )
    expect(hentetAdresse).toBe(false)
    expect(resolved.status).toBe('error')
    expect(resolved.status === 'error' && resolved.message).toMatch(/Fant ingen fil/)
  })

  it('sier fra når leddet ikke har noen dokumentkatalog i det hele tatt', async () => {
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: await sourceVersionContentHash(TEKST),
        document: await dokumentbinding(),
      },
      { runTool: utdrag },
    )
    expect(resolved.status === 'error' && resolved.message).toMatch(/ANTIDEP_DOCUMENT_DIR/)
  })

  it('avviser en annen PDF, selv om den ligger i katalogen', async () => {
    const annen = syntheticPdf(['En helt annen artikkel.'])
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: await sourceVersionContentHash(TEKST),
        document: await dokumentbinding(),
      },
      { documents: documentsIn(await katalogMed({ 'annen.pdf': annen })), runTool: utdrag },
    )
    expect(resolved.status === 'error' && resolved.message).toMatch(/Fant ingen fil/)
  })

  it('avviser når oppskriften gir en annen tekst enn den registrerte', async () => {
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: await sourceVersionContentHash(TEKST),
        document: await dokumentbinding(),
      },
      await porter({ runTool: annenVersjon }),
    )
    expect(resolved.status).toBe('error')
    // Meldingen navngir begge versjonene: det er den opplysningen som forklarer
    // avviket, og fasiten er fingeravtrykket — ikke versjonsnummeret.
    expect(resolved.status === 'error' && resolved.message).toMatch(/pdftotext 24\.02\.0/)
  })

  it('avviser når verktøyet ikke ga tekst i det hele tatt', async () => {
    const resolved = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/x',
        contentHash: await sourceVersionContentHash(TEKST),
        document: await dokumentbinding(),
      },
      await porter({
        runTool: () => Promise.resolve({ status: 'ran', exitCode: 0, stdout: '  \n', stderr: '' }),
      }),
    )
    expect(resolved.status === 'error' && resolved.message).toMatch(/innskannet/)
  })
})

describe('dokumentlageret', () => {
  it('finner filen uansett hva den heter', async () => {
    const directory = await katalogMed({ 'hva-som-helst.bin': PDF, 'annet.txt': 'ikke en pdf' })
    const found = await documentsIn(directory)(await documentDigest(PDF))
    expect(found.status).toBe('ok')
    expect(found.status === 'ok' && found.document.byteSize).toBe(PDF.length)
  })

  it('avviser et fingeravtrykk som ikke har formen, framfor å lete', async () => {
    const found = await documentsIn(await katalogMed({}))('ikke-en-hash')
    expect(found.status === 'error' && found.message).toMatch(/64 heksadesimale/)
  })

  it('sier hvor den lette da katalogen ikke finnes', async () => {
    const found = await documentsIn('/finnes/ikke')(await documentDigest(PDF))
    expect(found.status === 'error' && found.message).toMatch(/dokumentkatalogen/)
  })
})

describe('loadDocumentFile', () => {
  it('avviser en fil som ikke er en PDF', async () => {
    const directory = await katalogMed({ 'tekst.pdf': 'dette er ikke en pdf' })
    const loaded = await loadDocumentFile(join(directory, 'tekst.pdf'))
    expect(loaded.status === 'error' && loaded.message).toMatch(/PDF-signaturen/)
  })

  it('avviser en tom fil', async () => {
    const directory = await katalogMed({ 'tom.pdf': '' })
    const loaded = await loadDocumentFile(join(directory, 'tom.pdf'))
    expect(loaded.status === 'error' && loaded.message).toMatch(/tom/)
  })
})

describe('tekstveien tar ikke imot en PDF', () => {
  it('avviser et svar som begynner med PDF-signaturen, og sier hvilken vei som gjelder', async () => {
    // Uten dette ville en PDF hentet over nett blitt dekodet som UTF-8 og
    // hashet — et fingeravtrykk av omkodingen, ikke av filen.
    const result = await retrieveRepresentation('https://eksempel.invalid/artikkel.pdf', {
      httpGet: () =>
        Promise.resolve({
          status: 'ok',
          finalUrl: 'https://eksempel.invalid/artikkel.pdf',
          httpStatus: 200,
          contentType: 'application/pdf',
          bytes: PDF,
        }),
    })
    expect(result.status).toBe('error')
    expect(result.status === 'error' && result.message).toMatch(/er en PDF, ikke tekst/)
  })
})
