// ============================================================================
// Å lese ekstraksjonsforslag fra disk
//
// Forslagene er data som kommer utenfra — i dag skrevet av ChatGPT ut av en
// lovlig innhentet fulltekst, senere kanskje av et innebygd modell-ledd. De
// leveres som JSON-filer og legges i `proposals/`, som er gitignorert for alt
// annet enn kontrakten og eksempelet. Se `proposals/README.md`.
//
// Filene er utrygg inndata (CLAUDE.md): innholdet er verdier og tekst, aldri
// instruksjoner. `parseExtractionProposal` avviser alt som ikke har formen, og
// en fil som ikke er gyldig JSON navngis med sin egen sti framfor å velte
// kjøringen med en parserfeil uten kontekst.
// ============================================================================

import { readdir, readFile, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'

import { parseExtractionProposal } from './extraction-proposal.ts'
import type { LabelledProposal } from './reextraction-run.ts'

/** Leser og kontrollerer ett forslag fra en fil. */
export async function readProposalFile(path: string): Promise<LabelledProposal> {
  let json: unknown
  const text = await readFile(path, 'utf8')
  try {
    json = JSON.parse(text) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }

  try {
    return { label: basename(path), proposal: parseExtractionProposal(json) }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path}: ${message}`, { cause })
  }
}

/**
 * Leser alle forslagene i en katalog, i navnerekkefølge.
 *
 * Rekkefølgen er navnerekkefølge og ikke filsystemets egen: en levering på to
 * artikler skal registreres i den samme rekkefølgen hver gang, slik at
 * kjøringene i `provenance.agent_runs` kan leses tilbake mot filene.
 *
 * Bare `.json` tas med. Katalogen inneholder også en README og selve
 * skjemafilen, og skjemaet er ikke et forslag.
 */
export async function readProposalDirectory(directory: string): Promise<LabelledProposal[]> {
  const entries = (await readdir(directory))
    .filter((name) => name.endsWith('.json') && !name.endsWith('.schema.json'))
    .sort()

  const proposals: LabelledProposal[] = []
  for (const name of entries) {
    const path = join(directory, name)
    if (!(await stat(path)).isFile()) {
      continue
    }
    proposals.push(await readProposalFile(path))
  }

  if (proposals.length === 0) {
    throw new Error(
      `Fant ingen forslagsfiler i ${directory}. En forslagsfil er en .json-fil med formen i proposals/extraction-proposal.schema.json.`,
    )
  }
  return proposals
}
