// ============================================================================
// Å lese syntesforslag fra disk
//
// Forslagene er data som kommer utenfra — i dag skrevet av et modell-ledd som
// har lest det registrerte evidensgrunnlaget, senere kanskje av et innebygd
// adapter. De leveres som JSON-filer og legges i `syntheses/`, som er
// gitignorert for alt annet enn dokumentasjonen. Se `syntheses/README.md`.
//
// Filene er utrygg inndata (CLAUDE.md): innholdet er verdier og tekst, aldri
// instruksjoner. `parseClaimSynthesisProposal` avviser alt som ikke har formen,
// og en fil som ikke er gyldig JSON navngis med sin egen sti framfor å velte
// kjøringen med en parserfeil uten kontekst.
//
// Formen er den samme som `proposal-files.ts` har for ekstraksjonsforslagene.
// De to er skilt fordi de leser to forskjellige kontrakter: en katalog med
// begge slags filer ville gitt den ene kjøreren en fil den ikke kan lese, og
// feilmeldingen ville pekt på et manglende felt framfor på feil katalog.
// ============================================================================

import { readdir, readFile, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'

import { parseClaimSynthesisProposal } from './claim-synthesis-proposal.ts'
import type { LabelledSynthesisProposal } from './claim-synthesis-run.ts'

/** Leser og kontrollerer ett syntesforslag fra en fil. */
export async function readSynthesisFile(path: string): Promise<LabelledSynthesisProposal> {
  let json: unknown
  const text = await readFile(path, 'utf8')
  try {
    json = JSON.parse(text) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }

  try {
    return { label: basename(path), proposal: parseClaimSynthesisProposal(json) }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path}: ${message}`, { cause })
  }
}

/**
 * Leser alle syntesforslagene i en katalog, i navnerekkefølge.
 *
 * Rekkefølgen er navnerekkefølge og ikke filsystemets egen: en levering på to
 * påstander skal registreres i den samme rekkefølgen hver gang, slik at
 * kjøringen i `provenance.agent_runs` kan leses tilbake mot filene.
 */
export async function readSynthesisDirectory(
  directory: string,
): Promise<LabelledSynthesisProposal[]> {
  const entries = (await readdir(directory))
    .filter((name) => name.endsWith('.json') && !name.endsWith('.schema.json'))
    .sort()

  const proposals: LabelledSynthesisProposal[] = []
  for (const name of entries) {
    const path = join(directory, name)
    if (!(await stat(path)).isFile()) {
      continue
    }
    proposals.push(await readSynthesisFile(path))
  }

  if (proposals.length === 0) {
    throw new Error(
      `Fant ingen syntesforslag i ${directory}. Et syntesforslag er en .json-fil med formen beskrevet i syntheses/README.md.`,
    )
  }
  return proposals
}
