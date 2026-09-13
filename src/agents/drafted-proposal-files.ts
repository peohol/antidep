// ============================================================================
// Å lese utkastfiler fra disk
//
// Forslagene er data som kommer utenfra — i dag skrevet av et modell-ledd som
// har lest det registrerte grunnlaget, senere kanskje av et innebygd adapter.
// De leveres som JSON-filer i en katalog som er gitignorert for alt annet enn
// dokumentasjonen: `syntheses/` for syntesforslagene, `assessments/` for
// vurderingsforslagene.
//
// Filene er utrygg inndata (CLAUDE.md): innholdet er verdier og tekst, aldri
// instruksjoner. Kontrollen av formen er `parse`, som kalleren gir inn — og en
// fil som ikke er gyldig JSON navngis med sin egen sti framfor å velte kjøringen
// med en parserfeil uten kontekst.
//
// ----------------------------------------------------------------------------
// Hvorfor lesingen er felles og kontrakten ikke er det
//
// De to leddene leser to forskjellige kontrakter, men de leser dem på nøyaktig
// samme måte: samme navnerekkefølge, samme filfilter, samme feilmeldinger. To
// nesten like lesere ville vært to steder å glemme en grense. `parse` er derfor
// en parameter, og kontrakten blir værende i sin egen modul.
//
// Formen er den samme som `proposal-files.ts` har for ekstraksjonsforslagene.
// Den står for seg selv fordi ekstraksjonssiden leser et oppdrag ved siden av
// forslaget, og har en registreringsmodus de to andre ikke har.
// ============================================================================

import { readdir, readFile, stat } from 'node:fs/promises'
import { basename, join } from 'node:path'

/** Ett forslag, med navnet det ble lest under, slik rapporten kan navngi det. */
export interface LabelledProposal<T> {
  readonly label: string
  readonly proposal: T
}

/** Leser og kontrollerer ett forslag fra en fil. */
export async function readDraftedProposalFile<T>(
  path: string,
  parse: (value: unknown) => T,
): Promise<LabelledProposal<T>> {
  let json: unknown
  const text = await readFile(path, 'utf8')
  try {
    json = JSON.parse(text) as unknown
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path} er ikke gyldig JSON: ${message}`, { cause })
  }

  try {
    return { label: basename(path), proposal: parse(json) }
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`${path}: ${message}`, { cause })
  }
}

/**
 * Leser alle forslagene i en katalog, i navnerekkefølge.
 *
 * Rekkefølgen er navnerekkefølge og ikke filsystemets egen: en levering på to
 * objekter skal registreres i den samme rekkefølgen hver gang, slik at kjøringen
 * i `provenance.agent_runs` kan leses tilbake mot filene.
 *
 * `emptyMessage` er kallerens, fordi en tom katalog skal peke på den
 * dokumentasjonen som beskriver nettopp den kontrakten.
 */
export async function readDraftedProposalDirectory<T>(
  directory: string,
  parse: (value: unknown) => T,
  emptyMessage: (directory: string) => string,
): Promise<LabelledProposal<T>[]> {
  const entries = (await readdir(directory))
    .filter((name) => name.endsWith('.json') && !name.endsWith('.schema.json'))
    .sort()

  const proposals: LabelledProposal<T>[] = []
  for (const name of entries) {
    const path = join(directory, name)
    if (!(await stat(path)).isFile()) {
      continue
    }
    proposals.push(await readDraftedProposalFile(path, parse))
  }

  if (proposals.length === 0) {
    throw new Error(emptyMessage(directory))
  }
  return proposals
}
