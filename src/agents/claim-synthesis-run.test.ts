import { describe, expect, it } from 'vitest'

import {
  AgentApiError,
  type AgentRunPremises,
  type ClaimSynthesisApi,
  type RegisterClaimSynthesisArgs,
} from './agent-api'
import {
  CLAIM_SYNTHESIS_PROPOSAL_VERSION,
  parseClaimSynthesisProposal,
  type ClaimSynthesisProposal,
} from './claim-synthesis-proposal'
import {
  parseClaimSynthesisResult,
  runClaimSynthesis,
  type LabelledSynthesisProposal,
} from './claim-synthesis-run'
import { parseDraftedProposalArguments } from './cli-arguments'

const PREMISSER: AgentRunPremises = {
  provider: 'antidep',
  model: 'proposal-registered-synthesis',
  modelVersion: '1.0.0',
  promptTemplateVersion: 'claim-synthesis/proposal/1',
  pipelineVersion: 'antidep-evidence/1',
}

const RUN_ID = '11111111-1111-4111-8111-111111111111'
const CLAIM_ID = '22222222-2222-4222-8222-222222222222'
const REVISION_ID = '33333333-3333-4333-8333-333333333333'
const LINK_ID = '55555555-5555-4555-8555-555555555555'
const ITEM_ID = '66666666-6666-4666-8666-666666666666'

function svar(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    claim_id: CLAIM_ID,
    claim_revision_id: REVISION_ID,
    revision_number: 1,
    supersedes_revision_id: null,
    evidence_links: [{ claim_evidence_link_id: LINK_ID, evidence_item_id: ITEM_ID }],
    evidence_set_digest: `sha256-v1:${'a'.repeat(64)}`,
    ...overrides,
  }
}

interface FakeApi extends ClaimSynthesisApi {
  readonly registered: RegisterClaimSynthesisArgs[]
  readonly runs: { manifest: Record<string, unknown> }[]
  readonly completions: {
    status: string
    outputManifest: Record<string, unknown> | null
    failureReason: string | null
  }[]
}

/**
 * Databasen som en dobbel. Kallene er kontrakten, ikke returverdiene: prøvene
 * ser på hva som faktisk ble sendt og i hvilken rekkefølge.
 */
function fakeApi(overrides: Partial<ClaimSynthesisApi> = {}): FakeApi {
  const registered: RegisterClaimSynthesisArgs[] = []
  const runs: FakeApi['runs'] = []
  const completions: FakeApi['completions'] = []

  return {
    registered,
    runs,
    completions,
    beginRun: (_premises, manifest) => {
      runs.push({ manifest })
      return Promise.resolve(RUN_ID)
    },
    registerSynthesis: (args) => {
      registered.push(args)
      return Promise.resolve(svar())
    },
    completeRun: (_runId, status, outputManifest, failureReason) => {
      completions.push({ status, outputManifest, failureReason })
      return Promise.resolve()
    },
    ...overrides,
  }
}

function forslag(overrides: Record<string, unknown> = {}): ClaimSynthesisProposal {
  return parseClaimSynthesisProposal({
    proposal_version: CLAIM_SYNTHESIS_PROPOSAL_VERSION,
    generated_by: {
      producer: 'model',
      provider: 'testleverandør',
      model: 'testmodell',
      model_version: '2026-09-13',
      prompt_template_version: 'claim-synthesis/1',
      drafted_at: '2026-09-13T09:00:00Z',
      request_digest: null,
    },
    claim: {
      claim_id: null,
      topic_concept_id: '77777777-7777-4777-8777-777777777777',
      subject_drug_id: '88888888-8888-4888-8888-888888888888',
      statement: 'Hos voksne er behandling forbundet med en gjennomsnittlig vektøkning.',
      scope: 'Gjelder gjennomsnittlig vektendring fra behandlingsstart i åtte uker.',
      population_id: null,
      timeframe_min: '8 weeks',
      timeframe_max: '8 weeks',
      comparator_kind: 'none',
      comparator_drug_id: null,
      direction: 'increase',
      magnitude_measure: null,
      magnitude_value: null,
      magnitude_unit: null,
      qualifiers: null,
      uncertainty_summary: 'Ett evidensfunn fra én studie ligger til grunn.',
    },
    evidence_links: [
      {
        evidence_item_id: ITEM_ID,
        relationship_type: 'supports',
        directness: 'indirect',
        relevance_note: 'Funnet rapporterer vektendring for behandlingsarmen påstanden gjelder.',
      },
    ],
    ...overrides,
  })
}

function kø(...proposals: ClaimSynthesisProposal[]): LabelledSynthesisProposal[] {
  return proposals.map((proposal, index) => ({
    label: `forslag-${String(index + 1)}.json`,
    proposal,
  }))
}

describe('runClaimSynthesis', () => {
  it('registrerer forslaget og lukker kjøringen', async () => {
    const api = fakeApi()
    const report = await runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) })

    expect(report.runStatus).toBe('succeeded')
    expect(report.registered).toBe(1)
    expect(api.registered).toHaveLength(1)
    expect(api.registered[0]?.agentRunId).toBe(RUN_ID)
    expect(report.results[0]?.registered?.claimRevisionId).toBe(REVISION_ID)
    expect(api.completions[0]?.status).toBe('succeeded')
  })

  it('fører erklæringen om hvem som laget utkastet i kjøringens inndatamanifest', async () => {
    // Premissene beskriver registreringen, ikke modellen som formulerte
    // påstanden. Uten erklæringen i manifestet ville proveniensen sagt at
    // Antideps egen kode skrev den kliniske formuleringen.
    const api = fakeApi()
    await runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) })

    const proposals = api.runs[0]?.manifest['proposals'] as Record<string, unknown>[]
    const declaration = proposals[0]?.['generated_by'] as Record<string, unknown>
    expect(declaration['model']).toBe('testmodell')
    expect(declaration['drafted_at']).toBe('2026-09-13T09:00:00Z')
  })

  it('skriver ingenting i en tørrkjøring, men lukker kjøringen som aborted', async () => {
    const api = fakeApi()
    const report = await runClaimSynthesis({
      api,
      premises: PREMISSER,
      proposals: kø(forslag()),
      dryRun: true,
    })

    expect(api.registered).toHaveLength(0)
    expect(report.runStatus).toBe('aborted')
    expect(report.results[0]?.decision).toBe('previewed')
    expect(api.completions[0]?.failureReason).toMatch(/Tørrkjøring/)
  })

  it('lar ett avvist forslag stå alene: de øvrige registreres', async () => {
    let calls = 0
    const api = fakeApi({
      registerSynthesis: () => {
        calls += 1
        if (calls === 1) {
          // En forslagsspesifikk SQLSTATE: vilkåret i forslaget holdt ikke,
          // funksjonen reiste et unntak, og transaksjonen er rullet tilbake. Da
          // — og bare da — er «ingenting registrert» en påstand kjøringen kan
          // stå for.
          return Promise.reject(
            new AgentApiError(
              'api.register_claim_synthesis',
              'Evidensfunn med åpent verifikasjonsfunn: 66666666-6666-4666-8666-666666666666.',
              '23001',
              null,
            ),
          )
        }
        return Promise.resolve(svar({ revision_number: 2 }))
      },
    })

    const report = await runClaimSynthesis({
      api,
      premises: PREMISSER,
      proposals: kø(forslag(), forslag()),
    })

    expect(report.registered).toBe(1)
    expect(report.skipped).toBe(1)
    expect(report.results[0]?.decision).toBe('skipped')
    // Databasens egen setning er det som når kalleren; en generisk melding ville
    // sendt den som skrev forslaget på leting.
    expect(report.results[0]?.reason).toMatch(/åpent verifikasjonsfunn/)
    expect(report.results[1]?.decision).toBe('registered')
    expect(report.runStatus).toBe('succeeded')
  })

  // --------------------------------------------------------------------------
  // Et uavklart utfall er ikke det samme som «ingenting registrert»
  //
  // Skriveveien er ikke idempotent. En registrering som kan ha blitt skrevet,
  // ført som overhoppet, ville invitert til en ny kjøring som lager påstanden en
  // gang til (funnet i teknisk review).
  // --------------------------------------------------------------------------
  it('stopper kjøringen når forbindelsen ryker: raden kan finnes', async () => {
    const api = fakeApi({
      registerSynthesis: () => Promise.reject(new Error('fetch failed')),
    })

    await expect(
      runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag(), forslag()) }),
    ).rejects.toThrow(/utfallet er ukjent/)

    // Ingen av de to forslagene er ført som overhoppet, og det andre er ikke
    // forsøkt: køen skal ikke gå videre på et ukjent utfall.
    expect(api.registered).toHaveLength(0)
    expect(api.completions[0]?.status).toBe('failed')
    expect(api.completions[0]?.failureReason).toMatch(/FØR du kjører filen om igjen/)
  })

  it('stopper kjøringen når svaret ikke har formen: skrivingen kan ha gått gjennom', async () => {
    // parseClaimSynthesisResult kjører ETTER at serveren har committet. Et svar
    // uten revisjons-ID betyr derfor ikke at ingenting ble skrevet.
    const api = fakeApi({
      registerSynthesis: () => Promise.resolve({ ikke: 'en syntese' }),
    })

    await expect(
      runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) }),
    ).rejects.toThrow(/utfallet er ukjent/)

    expect(api.completions[0]?.status).toBe('failed')
  })

  it('en avvisning uten SQLSTATE regnes ikke som en avvisning av forslaget', async () => {
    // PostgRESTs egne koder er ikke SQLSTATE, og en AgentApiError uten kode i
    // det hele tatt er en transportfeil kledd i api-formen.
    const api = fakeApi({
      registerSynthesis: () =>
        Promise.reject(
          new AgentApiError('api.register_claim_synthesis', 'gateway timeout', null, null),
        ),
    })

    await expect(
      runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) }),
    ).rejects.toThrow(/utfallet er ukjent/)
  })

  // --------------------------------------------------------------------------
  // En driftsfeil er ikke et forslag som ikke holder mål
  //
  // Alle kodene under ruller transaksjonen tilbake, så «ingenting ble skrevet»
  // er sant for dem — men de sier ingenting om forslaget, og de gjentar seg
  // gjerne for det neste. Ført som overhoppet ville kjøringen lukket seg som
  // `succeeded` med en rapport om at forslagene ikke holdt mål, mens det som
  // sviktet var driften (funnet i teknisk review).
  // --------------------------------------------------------------------------
  it.each([
    ['40P01', 'deadlock detected'],
    ['40001', 'could not serialize access due to concurrent update'],
    ['42501', 'permission denied for function register_claim_synthesis'],
    ['XX000', 'internal error'],
    ['53300', 'too many connections for role'],
    ['23505', 'duplicate key value violates unique constraint'],
  ])(
    'velter kjøringen på SQLSTATE %s framfor å føre forslaget som overhoppet',
    async (kode, melding) => {
      const api = fakeApi({
        registerSynthesis: () =>
          Promise.reject(new AgentApiError('api.register_claim_synthesis', melding, kode, null)),
      })

      await expect(
        runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag(), forslag()) }),
      ).rejects.toThrow(/utfallet er ukjent/)

      // Det andre forslaget er ikke forsøkt, og kjøringen er ikke lukket som
      // succeeded.
      expect(api.completions[0]?.status).toBe('failed')
    },
  )

  it.each([
    ['22023', 'p_evidence_links må være en ikke-tom JSON-liste med evidenslenker.'],
    ['P0002', 'Evidensfunn som ikke finnes: 66666666-6666-4666-8666-666666666666.'],
    ['22P02', 'invalid input value for enum knowledge.comparator_kind'],
    ['22007', 'invalid input syntax for type interval'],
    ['23503', 'insert or update on table violates foreign key constraint'],
    ['23514', 'new row violates check constraint'],
  ])('fører forslaget som overhoppet på SQLSTATE %s og går videre', async (kode, melding) => {
    let calls = 0
    const api = fakeApi({
      registerSynthesis: () => {
        calls += 1
        if (calls === 1) {
          return Promise.reject(
            new AgentApiError('api.register_claim_synthesis', melding, kode, null),
          )
        }
        return Promise.resolve(svar({ revision_number: 2 }))
      },
    })

    const report = await runClaimSynthesis({
      api,
      premises: PREMISSER,
      proposals: kø(forslag(), forslag()),
    })

    expect(report.skipped).toBe(1)
    expect(report.registered).toBe(1)
    expect(report.runStatus).toBe('succeeded')
  })

  it('lar den opprinnelige årsaken nå kalleren selv om lukkingen også feiler', async () => {
    const api = fakeApi({
      registerSynthesis: () => Promise.reject(new Error('fetch failed')),
      completeRun: () => Promise.reject(new Error('kunne ikke lukke kjøringen')),
    })

    await expect(
      runClaimSynthesis({ api, premises: PREMISSER, proposals: kø(forslag()) }),
    ).rejects.toThrow(/utfallet er ukjent/)
  })
})

describe('parseClaimSynthesisResult', () => {
  it('leser svaret fra databasen', () => {
    const parsed = parseClaimSynthesisResult(svar())
    expect(parsed.claimRevisionId).toBe(REVISION_ID)
    expect(parsed.revisionNumber).toBe(1)
    expect(parsed.supersedesRevisionId).toBeNull()
    expect(parsed.evidenceLinkIds).toEqual([LINK_ID])
  })

  it('leser en videreføring', () => {
    const parsed = parseClaimSynthesisResult(
      svar({ revision_number: 2, supersedes_revision_id: REVISION_ID }),
    )
    expect(parsed.revisionNumber).toBe(2)
    expect(parsed.supersedesRevisionId).toBe(REVISION_ID)
  })

  it('avviser et svar uten revisjons-ID framfor å rapportere en registrering uten den', () => {
    const uten = svar()
    delete uten['claim_revision_id']
    expect(() => parseClaimSynthesisResult(uten)).toThrow(/claim_revision_id/)
  })

  it('avviser et revisjonsnummer som ikke er et heltall', () => {
    expect(() => parseClaimSynthesisResult(svar({ revision_number: '1' }))).toThrow(
      /revision_number/,
    )
  })
})

describe('parseDraftedProposalArguments', () => {
  it('leser en katalog', () => {
    expect(parseDraftedProposalArguments(['--directory', 'syntheses'])).toEqual({
      directory: 'syntheses',
      proposalPaths: [],
      dryRun: false,
    })
  })

  it('leser flere enkeltfiler og tørrkjøring', () => {
    expect(
      parseDraftedProposalArguments(['--proposal', 'a.json', '--proposal', 'b.json', '--dry-run']),
    ).toEqual({
      directory: null,
      proposalPaths: ['a.json', 'b.json'],
      dryRun: true,
    })
  })

  it('krever at noe er oppgitt', () => {
    expect(() => parseDraftedProposalArguments([])).toThrow(/--directory/)
  })

  it('avviser katalog og enkeltfil sammen: rekkefølgen ville vært uklar', () => {
    expect(() =>
      parseDraftedProposalArguments(['--directory', 'syntheses', '--proposal', 'a.json']),
    ).toThrow(/ikke begge/)
  })

  it('avviser et ukjent valg framfor å ignorere det', () => {
    expect(() => parseDraftedProposalArguments(['--registrer-alt'])).toThrow(/Ukjent valg/)
  })

  it('avviser et stiflagg uten verdi', () => {
    expect(() => parseDraftedProposalArguments(['--proposal'])).toThrow(/krever en sti/)
    expect(() => parseDraftedProposalArguments(['--directory', '--dry-run'])).toThrow(
      /krever en sti/,
    )
  })

  it('svarer help på --help', () => {
    expect(parseDraftedProposalArguments(['--help'])).toBe('help')
  })
})
