import { describe, expect, it } from 'vitest'

import type {
  AgentRunPremises,
  ClaimVerificationApi,
  RegisterClaimVerificationArgs,
} from './agent-api'
import { clampText, runClaimVerification, type RetrieveLike } from './claim-verification-run'
import type { ClaimEvidenceLink, ClaimRevisionInput } from './claim-verification-input'
import { sourceVersionContentHash } from './content-hash'
import { parseVerifierArguments } from './cli-arguments'
import { FIXTURE_SOURCE_TEXT, claimEvidenceLinkFixture, claimRevisionFixture } from './test-support'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'deterministic-claim-check',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'claim-verification/deterministic/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'

interface FakeApi extends ClaimVerificationApi {
  readonly registered: RegisterClaimVerificationArgs[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

/**
 * Databasen som en dobbel. Hele orkestreringen kan dermed prøves uten stack, og
 * hvert kall som faktisk ble gjort, er observerbart — det er kallene som er
 * kontrakten, ikke returverdiene.
 */
function fakeApi(
  revisions: readonly ClaimRevisionInput[],
  overrides: Partial<FakeApi> = {},
): FakeApi {
  const registered: RegisterClaimVerificationArgs[] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    completions,
    beginRun: () => Promise.resolve(RUN_ID),
    readInput: () =>
      Promise.resolve({
        agent_run_id: RUN_ID,
        verifier_actor_id: '22222222-2222-4222-8222-222222222222',
        revisions: revisions.map(toPayload),
      }),
    registerVerification: (args) => {
      registered.push(args)
      return Promise.resolve(`ver-${String(registered.length)}`)
    },
    completeRun: (_runId, status, outputManifest, failureReason) => {
      completions.push({ status, outputManifest, failureReason })
      return Promise.resolve()
    },
    ...overrides,
  }
}

/** Speiler formen migrasjon 005k dokumenterer. */
function toPayload(revision: ClaimRevisionInput): Record<string, unknown> {
  const c = revision.claim
  return {
    claim_revision_id: revision.claimRevisionId,
    claim_id: revision.claimId,
    revision_number: revision.revisionNumber,
    knowledge_type: revision.knowledgeType,
    created_by_actor_id: revision.createdByActorId,
    created_by_actor_key: revision.createdByActorKey,
    content_hash: revision.contentHash,
    claim_retired_at: revision.claimRetiredAt,
    topic_concept_id: revision.topicConceptId,
    topic_label: revision.topicLabel,
    subject_drug_id: revision.subjectDrugId,
    subject_drug_name: revision.subjectDrugName,
    evidence_set_digest: revision.evidenceSetDigest,
    claim: {
      statement: c.statement,
      scope: c.scope,
      population_id: c.populationId,
      population_label: c.populationLabel,
      timeframe_min: c.timeframeMin,
      timeframe_max: c.timeframeMax,
      comparator_kind: c.comparatorKind,
      comparator_drug_id: c.comparatorDrugId,
      comparator_drug_name: c.comparatorDrugName,
      direction: c.direction,
      magnitude_measure: c.magnitudeMeasure,
      magnitude_value: c.magnitudeValue,
      magnitude_unit: c.magnitudeUnit,
      qualifiers: c.qualifiers,
      uncertainty_summary: c.uncertaintySummary,
    },
    links: revision.links.map(toLinkPayload),
    unlinked_related_evidence: revision.unlinkedRelatedEvidence,
    verifications_by_this_actor: revision.verificationsByThisActor,
    verifications_total: revision.verificationsTotal,
  }
}

function toLinkPayload(link: ClaimEvidenceLink): Record<string, unknown> {
  const e = link.evidenceItem.extraction
  const version = link.evidenceItem.sourceVersion
  return {
    claim_evidence_link_id: link.claimEvidenceLinkId,
    relationship_type: link.relationshipType,
    directness: link.directness,
    relevance_note: link.relevanceNote,
    evidence_item: {
      evidence_item_id: link.evidenceItem.evidenceItemId,
      created_by_actor_id: link.evidenceItem.createdByActorId,
      created_by_actor_key: link.evidenceItem.createdByActorKey,
      extraction_method: link.evidenceItem.extractionMethod,
      content_hash: link.evidenceItem.contentHash,
      source: {
        source_id: link.evidenceItem.sourceId,
        source_type: 'journal_article',
        title: link.evidenceItem.sourceTitle,
        authors_or_issuer: 'Testforfatter m.fl.',
        publisher_or_journal: 'Testtidsskrift',
        publication_date: '2024-01-01',
        publication_date_precision: 'day',
        source_status: 'active',
        status_note: null,
      },
      source_version:
        version === null
          ? null
          : {
              source_version_id: version.sourceVersionId,
              retrieved_at: version.retrievedAt,
              retrieved_from: version.retrievedFrom,
              external_version: version.externalVersion,
              content_hash: version.contentHash,
              has_storage_reference: version.hasStorageReference,
            },
      extraction: {
        design_code: e.designCode,
        population_label: e.populationLabel,
        population_availability: e.populationAvailability,
        population_detail: e.populationDetail,
        sample_size: e.sampleSize,
        sample_size_availability: e.sampleSizeAvailability,
        intervention_drug_name: e.interventionDrugName,
        intervention_detail: e.interventionDetail,
        comparator_kind: e.comparatorKind,
        comparator_drug_name: e.comparatorDrugName,
        comparator_detail: e.comparatorDetail,
        outcome_label: e.outcomeLabel,
        outcome_detail: e.outcomeDetail,
        timepoint_min: e.timepointMin,
        timepoint_max: e.timepointMax,
        timepoint_availability: e.timepointAvailability,
        reported_direction: e.reportedDirection,
        effect_measure: e.effectMeasure,
        estimate: e.estimate,
        estimate_unit: e.estimateUnit,
        estimate_availability: e.estimateAvailability,
        ci_lower: e.ciLower,
        ci_upper: e.ciUpper,
        ci_level_percent: e.ciLevelPercent,
        confidence_interval_availability: e.confidenceIntervalAvailability,
        limitations_text: e.limitationsText,
        source_locator: e.sourceLocator,
        raw_extraction: e.rawExtraction,
      },
    },
    current_extraction_verification:
      link.currentExtractionVerification === null
        ? null
        : {
            evidence_verification_id: link.currentExtractionVerification.evidenceVerificationId,
            outcome: link.currentExtractionVerification.outcome,
            source_access: link.currentExtractionVerification.sourceAccess,
            checked_fields: link.currentExtractionVerification.checkedFields,
            verified_at: link.currentExtractionVerification.verifiedAt,
          },
  }
}

function retrieveFixture(overrides: { content?: string; hash?: string } = {}): RetrieveLike {
  return async (url) => ({
    status: 'ok',
    representation: {
      url,
      status: 200,
      contentType: 'text/xml',
      content: overrides.content ?? FIXTURE_SOURCE_TEXT,
      byteLength: (overrides.content ?? FIXTURE_SOURCE_TEXT).length,
      contentHash: overrides.hash ?? (await sourceVersionContentHash(FIXTURE_SOURCE_TEXT)),
      bytesAreUtf8: true,
    },
  })
}

async function matchingLink(
  overrides: Parameters<typeof claimEvidenceLinkFixture>[0] = {},
): Promise<ClaimEvidenceLink> {
  return claimEvidenceLinkFixture({
    ...overrides,
    evidenceItem: {
      ...overrides.evidenceItem,
      sourceVersion: {
        sourceVersionId: '51000000-0000-4000-8000-000000000001',
        retrievedAt: '2026-09-01T00:00:00+00:00',
        retrievedFrom: 'https://eksempel.invalid/kilde',
        externalVersion: null,
        contentHash: await sourceVersionContentHash(FIXTURE_SOURCE_TEXT),
        representation: 'full_text',
        document: null,
        hasStorageReference: false,
      },
    },
  })
}

describe('runClaimVerification — den lykkede stien', () => {
  it('registrerer én kontroll per revisjon, med én kontrollrad per evidenslenke', async () => {
    const api = fakeApi([claimRevisionFixture({ links: [await matchingLink()] })])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(report.runStatus).toBe('succeeded')
    expect(api.registered).toHaveLength(1)
    expect(api.registered[0]?.citations).toHaveLength(1)
    expect(api.registered[0]?.outcome).toBe('uncertain')
    expect(report.revisions[0]?.decision).toBe('registered')
  })

  it('oppgir verifiable_representation med kildeversjonens registrerte fingeravtrykk', async () => {
    const link = await matchingLink()
    const api = fakeApi([claimRevisionFixture({ links: [link] })])

    await runClaimVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() })

    const [citation] = api.registered[0]?.citations ?? []
    expect(citation?.sourceAccess).toBe('verifiable_representation')
    expect(citation?.sourceVersionId).toBe(link.evidenceItem.sourceVersion?.sourceVersionId)
    expect(citation?.checkedContentHash).toBe(link.evidenceItem.sourceVersion?.contentHash)
  })

  it('henter hver kildeversjon én gang, også når flere lenker deler den', async () => {
    const first = await matchingLink()
    const second = await matchingLink({
      claimEvidenceLinkId: '53000000-0000-4000-8000-000000000002',
    })
    const urls: string[] = []
    const retrieve: RetrieveLike = async (url) => {
      urls.push(url)
      return retrieveFixture()(url)
    }

    await runClaimVerification({
      api: fakeApi([claimRevisionFixture({ links: [first, second] })]),
      premises: PREMISSER,
      retrieve,
    })

    // To henteforsøk mot samme adresse ville vært to sjanser til å få
    // forskjellig svar for det samme fingeravtrykket.
    expect(urls).toHaveLength(1)
  })
})

describe('runClaimVerification — når ingenting skal registreres', () => {
  it('hopper over hele revisjonen når én lenke mangler kildeversjon', async () => {
    // Kontrollen må dekke hele evidenssettet
    // (workflow.assert_claim_verification_complete), så en lenke uten
    // etterprøvbart grunnlag feller revisjonen — ikke bare den ene lenken.
    const api = fakeApi([
      claimRevisionFixture({
        links: [
          await matchingLink(),
          claimEvidenceLinkFixture({
            claimEvidenceLinkId: '53000000-0000-4000-8000-000000000003',
            evidenceItem: { sourceVersion: null },
          }),
        ],
      }),
    ])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.revisions[0]?.decision).toBe('skipped')
    expect(report.revisions[0]?.reason).toContain('ingen registrert kildeversjon')
  })

  it('hopper over revisjonen når kildeversjonen mangler fingeravtrykk', async () => {
    const api = fakeApi([
      claimRevisionFixture({
        links: [
          claimEvidenceLinkFixture({
            evidenceItem: {
              sourceVersion: {
                sourceVersionId: '51000000-0000-4000-8000-000000000001',
                retrievedAt: '2026-09-01T00:00:00+00:00',
                retrievedFrom: 'https://eksempel.invalid/kilde',
                externalVersion: null,
                contentHash: null,
                representation: 'full_text',
                document: null,
                hasStorageReference: false,
              },
            },
          }),
        ],
      }),
    ])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.revisions[0]?.reason).toContain('sporet besøk uten fingeravtrykk')
  })

  it('hopper over revisjonen når kilden har endret seg', async () => {
    // Verifikatoren har da sett *en* utgave, men ikke den ekstraksjonen ble
    // gjort fra. Ingen av verdiene i workflow.verification_source_access
    // beskriver det sant, og en usann verdi er verre enn en manglende rad.
    const api = fakeApi([claimRevisionFixture({ links: [await matchingLink()] })])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture({ content: 'noe helt annet', hash: `sha256:${'f'.repeat(64)}` }),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.revisions[0]?.reason).toContain('Kilden har endret seg')
  })

  it('hopper over revisjonen når kilden ikke lot seg hente', async () => {
    const api = fakeApi([claimRevisionFixture({ links: [await matchingLink()] })])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: () => Promise.resolve({ status: 'error', message: 'Adressen svarte ikke.' }),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.revisions[0]?.reason).toBe('Adressen svarte ikke.')
  })

  it('lar én uventet feil felle sin egen revisjon og ikke køen', async () => {
    let attempts = 0
    const retrieve: RetrieveLike = async (url) => {
      attempts += 1
      if (attempts === 1) {
        throw new Error('Noe uventet i den første kilden.')
      }
      return retrieveFixture()(url)
    }
    const api = fakeApi([
      claimRevisionFixture({ links: [await matchingLink()] }),
      claimRevisionFixture({
        claimRevisionId: '55000000-0000-4000-8000-000000000009',
        links: [await matchingLink()],
      }),
    ])

    const report = await runClaimVerification({ api, premises: PREMISSER, retrieve })

    expect(report.revisions[0]?.decision).toBe('skipped')
    expect(report.revisions[0]?.reason).toContain('feilet uventet')
    expect(report.revisions[1]?.decision).toBe('registered')
  })

  it('lar en avvist registrering felle sin egen revisjon og ikke køen', async () => {
    let calls = 0
    const api = fakeApi(
      [
        claimRevisionFixture({ links: [await matchingLink()] }),
        claimRevisionFixture({
          claimRevisionId: '55000000-0000-4000-8000-000000000009',
          links: [await matchingLink()],
        }),
      ],
      {
        registerVerification: () => {
          calls += 1
          if (calls === 1) {
            return Promise.reject(new Error('Evidenslenker som ikke er kontrollert: …'))
          }
          return Promise.resolve(`ver-${String(calls)}`)
        },
      },
    )

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      retrieve: retrieveFixture(),
    })

    expect(report.revisions[0]?.reason).toContain('avvist av databasen')
    expect(report.revisions[1]?.decision).toBe('registered')
  })
})

describe('runClaimVerification — tørrkjøring', () => {
  it('kontrollerer, registrerer ingenting, og lukker kjøringen som aborted', async () => {
    const api = fakeApi([claimRevisionFixture({ links: [await matchingLink()] })])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      dryRun: true,
      retrieve: retrieveFixture(),
    })

    expect(api.registered).toHaveLength(0)
    expect(report.runStatus).toBe('aborted')
    expect(api.completions[0]?.status).toBe('aborted')
    expect(report.revisions[0]?.decision).toBe('previewed')
    expect(report.revisions[0]?.outcome).toBe('uncertain')
  })
})

describe('runClaimVerification — kjøringen lukkes alltid', () => {
  it('lukkes som failed når noe uventet skjer, og feilen når kalleren', async () => {
    const api = fakeApi([], { readInput: () => Promise.reject(new Error('Ingen tilgang.')) })

    await expect(
      runClaimVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() }),
    ).rejects.toThrow('Ingen tilgang.')
    expect(api.completions[0]?.status).toBe('failed')
  })

  it('lar den opprinnelige feilen nå kalleren selv om lukkingen også feiler', async () => {
    const api = fakeApi([], {
      readInput: () => Promise.reject(new Error('Ingen tilgang.')),
      completeRun: () => Promise.reject(new Error('Kunne ikke lukke.')),
    })

    await expect(
      runClaimVerification({ api, premises: PREMISSER, retrieve: retrieveFixture() }),
    ).rejects.toThrow('Ingen tilgang.')
  })
})

describe('runClaimVerification — avgrensning', () => {
  it('tar høyst så mange revisjoner som --limit sier', async () => {
    const api = fakeApi([
      claimRevisionFixture({ links: [await matchingLink()] }),
      claimRevisionFixture({
        claimRevisionId: '55000000-0000-4000-8000-000000000009',
        links: [await matchingLink()],
      }),
    ])

    const report = await runClaimVerification({
      api,
      premises: PREMISSER,
      limit: 1,
      retrieve: retrieveFixture(),
    })

    expect(report.revisions).toHaveLength(1)
  })
})

describe('clampText', () => {
  it('lar en tekst innenfor grensen stå urørt, uten omsluttende mellomrom', () => {
    expect(clampText('  en kort begrunnelse  ')).toBe('en kort begrunnelse')
  })

  it('kutter en for lang tekst og sier at den er kuttet', () => {
    const clamped = clampText('x'.repeat(5000))
    expect(clamped.length).toBeLessThanOrEqual(4000)
    expect(clamped).toContain('Funnlisten er kuttet')
  })
})

describe('parseVerifierArguments', () => {
  const spec = { targetFlag: 'claim-revision', usage: 'Bruk: …' }
  const parse = (argv: readonly string[]) => parseVerifierArguments(argv, spec)

  it('leser en tom argumentliste som «hele køen, registrer»', () => {
    expect(parse([])).toEqual({ targetId: null, dryRun: false, limit: null })
  })

  it('leser de tre valgene', () => {
    expect(parse(['--dry-run', '--claim-revision', 'abc', '--limit', '3'])).toEqual({
      targetId: 'abc',
      dryRun: true,
      limit: 3,
    })
  })

  it('avviser målflagget uten verdi', () => {
    expect(() => parse(['--claim-revision'])).toThrow(/krever en uuid/)
    expect(() => parse(['--claim-revision', '--dry-run'])).toThrow(/krever en uuid/)
  })

  it('avviser en --limit som ikke er et positivt heltall', () => {
    expect(() => parse(['--limit', '0'])).toThrow(/heltall/)
    expect(() => parse(['--limit', 'to'])).toThrow(/heltall/)
  })

  it('avviser et ukjent valg framfor å ignorere det, også det andre leddets flagg', () => {
    // En skrivefeil ville ellers blitt til en kjøring som registrerte rader
    // kalleren ikke ba om.
    expect(() => parse(['--registrer-alt'])).toThrow(/Ukjent valg/)
    expect(() => parse(['--evidence-item', 'abc'])).toThrow(/Ukjent valg/)
  })
})
