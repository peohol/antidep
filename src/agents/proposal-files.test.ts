// ============================================================================
// Å lese forslagsfiler fra disk
//
// Det som prøves, er at en fil som ikke holder mål navngis med sin egen sti —
// en levering på flere artikler skal si *hvilken* fil som er feil — og at
// katalogen leses i navnerekkefølge, slik at kjøringene i provenance.agent_runs
// kan leses tilbake mot filene.
// ============================================================================

import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

import { EXTRACTION_PROPOSAL_VERSION } from './extraction-proposal'
import { readProposalDirectory, readProposalFile } from './proposal-files'

const EXAMPLE = 'proposals/eksempel-syntetisk-forslag.json'

async function workspace(files: Readonly<Record<string, string>>): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'antidep-forslag-'))
  for (const [name, content] of Object.entries(files)) {
    await writeFile(join(directory, name), content, 'utf8')
  }
  return directory
}

async function exampleText(): Promise<string> {
  const { readFile } = await import('node:fs/promises')
  return readFile(EXAMPLE, 'utf8')
}

describe('readProposalFile', () => {
  it('leser det commitede eksempelet', async () => {
    const { label, proposal } = await readProposalFile(EXAMPLE)
    expect(label).toBe('eksempel-syntetisk-forslag.json')
    expect(proposal.proposalVersion).toBe(EXTRACTION_PROPOSAL_VERSION)
  })

  it('navngir filen når den ikke er gyldig JSON', async () => {
    const directory = await workspace({ 'a.json': '{ ikke json' })
    await expect(readProposalFile(join(directory, 'a.json'))).rejects.toThrow(
      /a\.json er ikke gyldig JSON/,
    )
  })

  it('navngir filen når formen ikke holder', async () => {
    const directory = await workspace({ 'b.json': '{"proposal_version": "feil"}' })
    await expect(readProposalFile(join(directory, 'b.json'))).rejects.toThrow(
      /b\.json: Ekstraksjonsforslaget er ugyldig/,
    )
  })
})

describe('readProposalDirectory', () => {
  it('leser forslagene i navnerekkefølge', async () => {
    const text = await exampleText()
    const directory = await workspace({ 'b-andre.json': text, 'a-forste.json': text })
    const proposals = await readProposalDirectory(directory)
    expect(proposals.map((entry) => entry.label)).toEqual(['a-forste.json', 'b-andre.json'])
  })

  // Skjemafilen ligger i den samme katalogen og er ikke et forslag.
  it('hopper over skjemafilen og alt som ikke er json', async () => {
    const directory = await workspace({
      'forslag.json': await exampleText(),
      'extraction-proposal.schema.json': '{"$schema": "x"}',
      'README.md': '# ikke et forslag',
    })
    const proposals = await readProposalDirectory(directory)
    expect(proposals.map((entry) => entry.label)).toEqual(['forslag.json'])
  })

  it('sier fra når katalogen er tom', async () => {
    const directory = await workspace({ 'README.md': '# tom' })
    await expect(readProposalDirectory(directory)).rejects.toThrow(/Fant ingen forslagsfiler/)
  })
})
