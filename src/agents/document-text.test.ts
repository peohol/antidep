// ============================================================================
// Oppskriften er en lukket liste — prøvd der den blir en prosess
//
// `text_extraction_tool` og `text_extraction_arguments` er de eneste lagrede
// verdiene i Antidep som senere blir **kjørt**: hver ekstraksjon og hver
// maskinell etterprøving henter teksten ut av originaldokumentet på nytt med
// oppskriften som står i raden. Var feltet fritt, ville en redaktør kunnet
// skrive `sh` i det, og en verdi lest ut av basen ville blitt en kommando kjørt
// med rettighetene og miljøet til den som kontrollerer — kodekjøring ut av en
// skriverettighet, og et brudd på regelen om at lagret innhold aldri blir
// instruksjoner (EVIDENCE_PIPELINE.md §3.8).
//
// Prøvene her handler derfor om ett krav: at en oppskrift utenfor listen
// avvises **uten at verktøyet i det hele tatt blir kalt**. Motstykket ved
// databasegrensen står i supabase/tests/640_source_document_registration_test.sql.
// ============================================================================

import { readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

import { disallowedRecipeReason, documentDigest } from './document-binding.ts'
import {
  extractDocumentText,
  PDF_TEXT_ARGUMENTS,
  PDF_TEXT_TOOL,
  readToolVersion,
  type RunTool,
  type TextExtractionRecipe,
} from './document-text.ts'
import { resolveRepresentation } from './source-binding.ts'
import type { DocumentLookup } from './source-document.ts'
import { syntheticPdf } from './test-support.ts'

/** Migrasjonen som holder den samme listen på den andre siden av grensen. */
const MIGRASJON = 'supabase/migrations/20260916092000_text_extraction_recipe_allowlist.sql'

const LINJER = ['Mean weight change was 0.8 kg after 8 weeks.']
const PDF = syntheticPdf(LINJER)

const OPPSKRIFT: TextExtractionRecipe = {
  tool: PDF_TEXT_TOOL,
  toolVersion: 'pdftotext 24.02.0',
  arguments: PDF_TEXT_ARGUMENTS,
}

/**
 * Et verktøy som teller hvert kall.
 *
 * Tellingen er selve påstanden: en avvisning som først skjer *etter* at
 * prosessen er startet, er ingen avvisning i det hele tatt.
 */
function teller(): { readonly run: RunTool; readonly kall: string[] } {
  const kall: string[] = []
  const run: RunTool = (tool, args) => {
    kall.push(`${tool} ${args.join(' ')}`)
    return Promise.resolve({
      status: 'ran',
      exitCode: 0,
      stdout: `${LINJER.join('\n')}\n`,
      stderr: '',
    })
  }
  return { run, kall }
}

describe('den lukkede oppskriften', () => {
  it('avviser et annet verktøy uten å kalle det', async () => {
    const { run, kall } = teller()
    const resultat = await extractDocumentText({
      bytes: PDF,
      recipe: { ...OPPSKRIFT, tool: 'sh' },
      run,
    })
    expect(resultat.status).toBe('error')
    expect(resultat.status === 'error' ? resultat.message : '').toContain('kjører bare')
    expect(kall).toEqual([])
  })

  it('avviser andre argumenter uten å kalle verktøyet', async () => {
    const { run, kall } = teller()
    const resultat = await extractDocumentText({
      bytes: PDF,
      recipe: { ...OPPSKRIFT, arguments: '-layout -enc UTF-8 -eol unix; rm -rf /' },
      run,
    })
    expect(resultat.status).toBe('error')
    expect(kall).toEqual([])
  })

  it('lar versjonen være fri, fordi den ikke er noe som kjøres', async () => {
    const { run, kall } = teller()
    const resultat = await extractDocumentText({
      bytes: PDF,
      recipe: { ...OPPSKRIFT, toolVersion: 'pdftotext 25.01.0' },
      run,
    })
    expect(resultat.status).toBe('ok')
    expect(kall).toEqual([`${PDF_TEXT_TOOL} ${PDF_TEXT_ARGUMENTS} - -`])
  })

  it('leser ikke versjonen av et annet verktøy heller', async () => {
    const { run, kall } = teller()
    const resultat = await readToolVersion('sh', run)
    expect(resultat.status).toBe('error')
    expect(kall).toEqual([])
  })

  it('sier hva som var galt, uten å gjenta verdien som om den var et forslag', () => {
    expect(disallowedRecipeReason(OPPSKRIFT)).toBeNull()
    expect(disallowedRecipeReason({ ...OPPSKRIFT, tool: 'sh' })).toContain(PDF_TEXT_TOOL)
    expect(disallowedRecipeReason({ ...OPPSKRIFT, arguments: '-raw' })).toContain(
      PDF_TEXT_ARGUMENTS,
    )
  })
})

describe('en registrert rad med en oppskrift utenfor listen', () => {
  it('blir ikke kjørt av kjeden, selv om raden finnes', async () => {
    // Grensen ved databasen (migrasjon 003f) stenger for at verdien blir
    // lagret. Denne prøven er det andre halve: en verdi som *likevel* står i
    // en rad — en eldre base, en gjenopprettet kopi, en skrivevei som ennå
    // ikke finnes — skal ikke kunne bli en prosess her.
    const { run, kall } = teller()
    const digest = await documentDigest(PDF)
    const dokumenter: DocumentLookup = (spurt) =>
      Promise.resolve(
        spurt === digest
          ? {
              status: 'ok',
              document: {
                path: '/tmp/artikkel.pdf',
                bytes: PDF,
                digest,
                byteSize: PDF.length,
                mediaType: 'application/pdf',
              },
            }
          : { status: 'error', message: `Fant ingen fil med ${spurt}.` },
      )

    const resultat = await resolveRepresentation(
      {
        retrievedFrom: 'https://doi.org/10.0000/003f',
        contentHash: `sha256:${'a'.repeat(64)}`,
        document: {
          sha256: digest,
          byteSize: PDF.length,
          mediaType: 'application/pdf',
          textExtraction: { ...OPPSKRIFT, tool: 'sh', arguments: '-c "id"' },
        },
      },
      { documents: dokumenter, runTool: run },
    )

    expect(resultat.status).toBe('error')
    expect(resultat.status === 'error' ? resultat.message : '').toContain(PDF_TEXT_TOOL)
    expect(kall).toEqual([])
  })
})

describe('de to sidene av grensen', () => {
  it('staver den lukkede oppskriften likt i koden og i migrasjonen', async () => {
    // Listen er en sikkerhetsgrense som håndheves to steder, og de to stedene
    // kan ikke dele en konstant på tvers av databasegrensen. Det som kan deles,
    // er kravet om at de staver den likt.
    const migrasjon = await readFile(MIGRASJON, 'utf8')
    expect(migrasjon).toContain(`text_extraction_tool = '${PDF_TEXT_TOOL}'`)
    expect(migrasjon).toContain(`text_extraction_arguments = '${PDF_TEXT_ARGUMENTS}'`)
    expect(migrasjon).toContain(`p_text_extraction_tool is distinct from '${PDF_TEXT_TOOL}'`)
    expect(migrasjon).toContain(
      `p_text_extraction_arguments is distinct from '${PDF_TEXT_ARGUMENTS}'`,
    )
  })
})
