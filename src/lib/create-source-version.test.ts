import { describe, expect, it, vi } from 'vitest'

import { createSourceVersion } from './create-source-version'
import type { AntidepClient } from './supabase'

function fakeClient(outcome: { data?: string; error?: { message: string } }) {
  const rpc = vi
    .fn()
    .mockResolvedValue({ data: outcome.data ?? null, error: outcome.error ?? null })
  return { client: { rpc } as unknown as AntidepClient, rpc }
}

const INPUT = {
  sourceId: '50000000-0000-4000-8000-000000000001',
  retrievedAt: '2026-09-07T09:15:00.000Z',
  retrievedFrom: 'https://eksempel.invalid/kilde',
  retrievedContent: '  innhold med blanktegn i begge ender  ',
  externalVersion: null,
  storageReference: null,
} as const

describe('createSourceVersion', () => {
  it('kaller api.create_source_version med feltene skjemaet samlet inn', async () => {
    const { client, rpc } = fakeClient({ data: '51000000-0000-4000-8000-000000000001' })
    await createSourceVersion(client, INPUT)
    expect(rpc).toHaveBeenCalledWith('create_source_version', {
      p_source_id: INPUT.sourceId,
      p_retrieved_at: INPUT.retrievedAt,
      p_retrieved_from: INPUT.retrievedFrom,
      p_retrieved_content: INPUT.retrievedContent,
      p_external_version: null,
      p_storage_reference: null,
    })
  })

  // Hashen er databasens (migrasjon 007f). En parameter her ville gjort den til
  // en påstand klienten skriver om seg selv.
  it('sender ingen hash', async () => {
    const { client, rpc } = fakeClient({ data: '51000000-0000-4000-8000-000000000001' })
    await createSourceVersion(client, INPUT)
    const args = rpc.mock.calls[0]?.[1] as Record<string, unknown>
    expect(Object.keys(args)).not.toContain('p_content_hash')
  })

  it('gir id-en tilbake når registreringen lyktes', async () => {
    const { client } = fakeClient({ data: '51000000-0000-4000-8000-000000000001' })
    await expect(createSourceVersion(client, INPUT)).resolves.toEqual({
      status: 'ok',
      sourceVersionId: '51000000-0000-4000-8000-000000000001',
    })
  })

  it('gir databasens egen tekst tilbake ved avvisning, uten å kaste', async () => {
    const { client } = fakeClient({ error: { message: 'Brukeren har ikke gyldig editor-rolle.' } })
    await expect(createSourceVersion(client, INPUT)).resolves.toEqual({
      status: 'error',
      message: 'Brukeren har ikke gyldig editor-rolle.',
    })
  })
})
