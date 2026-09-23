// ============================================================================
// Svarformen er oppgavens egen (migrasjon 014i)
//
// De to første vellykkede kjøringene av kildeoppdagelsen i produksjon ga de
// samme to avvisningene, begge med rette:
//
//   1. en tilgangsbegrenset kandidatkilde ble satt til «excluded», og
//   2. en narrows_request viste til en runde som ikke var dette leddets.
//
// Prøvene her holder begge feilene utenfor det svaret kan si — i svarformen
// agenten får, i oppgaveteksten den leser, og i kontrollen før svaret sendes —
// og viser at det riktige svaret fortsatt går gjennom. Databasens egen
// avvisning av de samme svarene prøves i
// supabase/tests/992_the_answer_form_is_the_tasks_own_test.sql.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseAgentTask, type AgentTask } from './agent-task.ts'
import { renderAgentTaskFile } from './agent-task-file.ts'
import {
  ACCESS_LIMITED_DECISIONS,
  CANDIDATE_DECISIONS,
  discoveryAnswerBounds,
} from './discovery-answer-bounds.ts'
import { handoffResultProblem } from './handoff-result.ts'
import {
  buildSourceCoverageControlDraftSchema,
  buildSourceDiscoveryDraftSchema,
} from './handoff-schemas.ts'
import { resultFor, taskPayload, TEST_CANDIDATE_DOI } from './handoff-test-support.ts'

type SourceRole = 'source_discovery' | 'source_quality_assessment'
type Schema = Record<string, unknown>

/** Leddets egen avkortede runde: den ene som kan snevres inn. */
const OWN_ROUND = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
/** Det andre kildeleddets avkortede runde. Den står i oppgaven, men er ikke leddets. */
const OTHER_LEG_ROUND = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
/** Leddets egen runde der avkortingen alt er dekket av et senere søk. */
const RESOLVED_ROUND = 'cccccccccccccccccccccccccccccccc'
/** En referanse som ikke står noe sted i oppgaven. */
const UNKNOWN_ROUND = 'dddddddddddddddddddddddddddddddd'

/** En kandidat fra PubMed: tilgangen er ikke avklart, så den er tilgangsbegrenset. */
const LIMITED_PMID = '40000001'

const OTHER_ROLE: Readonly<Record<SourceRole, SourceRole>> = {
  source_discovery: 'source_quality_assessment',
  source_quality_assessment: 'source_discovery',
}

function machineSearch(
  reference: string,
  platform: string,
  runRole: SourceRole,
  truncated: boolean,
  resolved: boolean,
): Record<string, unknown> {
  return {
    platform,
    method: 'keyword',
    query: `"testmiddel" (${platform})`,
    filters: null,
    outcome: 'executed',
    result_count: truncated ? 400 : 12,
    screened_count: truncated ? 25 : 12,
    truncated,
    truncation_note: truncated ? 'Bare den første siden ble hentet.' : null,
    truncation_resolved: resolved,
    request_reference: reference,
    limitation_note: null,
    endpoint: `https://example.test/${platform}`,
    response_digest: `sha256:${'e'.repeat(64)}`,
    execution_evidence: 'machine_executed',
    tracks: [],
    executed_at: '2026-09-15T09:00:00Z',
    run_role: runRole,
  }
}

/**
 * Oppgaven slik databasen bygger den etter 014i, for ett av de to leddene.
 *
 * Tre avkortede søk: leddets eget som ikke er dekket, det andre leddets, og
 * leddets eget som alt er dekket. Bare det første står i `narrowable_rounds`,
 * slik `workflow.monograph_narrowable_rounds(uuid, provenance.agent_role)`
 * bygger listen. To kandidater: én åpen og én tilgangsbegrenset.
 */
function sourceTask(role: SourceRole, narrowable = true): AgentTask {
  const payload = taskPayload(role)
  const input = payload['input'] as Record<string, unknown>
  const candidates = input['candidates'] as Record<string, unknown>[]
  return parseAgentTask({
    ...payload,
    input: {
      ...input,
      machine_searches: [
        machineSearch(OWN_ROUND, 'Europe PMC', role, true, false),
        machineSearch(OTHER_LEG_ROUND, 'Crossref', OTHER_ROLE[role], true, false),
        machineSearch(RESOLVED_ROUND, 'PubMed', role, true, true),
      ],
      narrowable_rounds: narrowable
        ? [
            {
              request_reference: OWN_ROUND,
              platform: 'Europe PMC',
              method: 'keyword',
              queries: ['"testmiddel" (Europe PMC)'],
            },
          ]
        : [],
      candidates: [
        ...candidates,
        {
          ...candidates[0],
          identifier_kind: 'pmid',
          identifier_value: LIMITED_PMID,
          title: `PubMed-oppføring ${LIMITED_PMID}`,
          access_limited: true,
          access_limitation_note:
            'Treffet er en identifikator fra et søkeregister. Verken tittel eller tilgang er avklart ennå.',
        },
      ],
    },
  })
}

function schemaFor(task: AgentTask): Schema {
  const bounds = discoveryAnswerBounds(task.input)
  return task.role === 'source_discovery'
    ? buildSourceDiscoveryDraftSchema(bounds)
    : buildSourceCoverageControlDraftSchema(bounds)
}

function at(schema: Schema, ...path: string[]): Schema {
  return path.reduce<Schema>((node, key) => node[key] as Schema, schema)
}

/** Et svar leddet ellers kunne levert, med kildevurderingene og forespørslene byttet ut. */
function answer(
  role: SourceRole,
  appraisals: readonly Record<string, unknown>[],
  requests: readonly Record<string, unknown>[] = [],
): Record<string, unknown> {
  const base = resultFor(role)
  if (role === 'source_quality_assessment' && requests.length > 0) {
    const withoutControl = { ...base }
    delete withoutControl['control']
    return { ...withoutControl, candidate_appraisals: appraisals, search_requests: requests }
  }
  return { ...base, candidate_appraisals: appraisals, search_requests: requests }
}

const limited = (decision: string, reason: string | null = 'Tittelen gjelder et annet tema.') => ({
  identifier_kind: 'pmid',
  identifier_value: LIMITED_PMID,
  could_change_conclusion: false,
  materiality_reason: null,
  decision,
  decision_reason: reason,
})

const narrowing = (reference: string, platform = 'Europe PMC', method = 'keyword') => ({
  rationale: 'Den avkortede trefflisten; bare delen som gjelder randomiserte forsøk.',
  platform,
  method,
  query_terms: ['randomized'],
  narrows_request: reference,
})

describe.each(['source_discovery', 'source_quality_assessment'] as const)(
  'svaret på en oppgave til %s',
  (role) => {
    const task = sourceTask(role)
    const schema = schemaFor(task)

    // ------------------------------------------------------------------------
    // 1 og 2: den tilgangsbegrensede kandidaten
    // ------------------------------------------------------------------------

    it('1. avviser fortsatt «excluded» for en tilgangsbegrenset kandidat', () => {
      expect(handoffResultProblem(task, answer(role, [limited('excluded')]))).toMatch(
        /pmid:40000001 har en registrert tilgangsbegrensning og kan ikke ekskluderes, uansett grunn/,
      )
    })

    it('2. godtar «awaiting_access» for den samme kandidaten', () => {
      expect(handoffResultProblem(task, answer(role, [limited('awaiting_access')]))).toBeNull()
    })

    it('og lar en kilde uten tilgangsbegrensning ekskluderes med en faglig grunn', () => {
      expect(
        handoffResultProblem(
          task,
          answer(role, [
            {
              identifier_kind: 'doi',
              identifier_value: TEST_CANDIDATE_DOI,
              decision: 'excluded',
              decision_reason: 'Gjelder en annen populasjon enn planen.',
            },
          ]),
        ),
      ).toBeNull()
    })

    it('tilbyr ikke «excluded» for den tilgangsbegrensede kandidaten i svarformen', () => {
      const groups = at(schema, 'properties', 'candidate_appraisals', 'items')['anyOf'] as Schema[]
      const limitedGroup = groups.find(
        (group) => at(group, 'properties', 'identifier_kind')['const'] === 'pmid',
      )
      const openGroup = groups.find(
        (group) => at(group, 'properties', 'identifier_kind')['const'] === 'doi',
      )
      expect(at(limitedGroup ?? {}, 'properties', 'identifier_value')['enum']).toEqual([
        LIMITED_PMID,
      ])
      expect(at(limitedGroup ?? {}, 'properties', 'decision')['enum']).toEqual([
        ...ACCESS_LIMITED_DECISIONS,
        null,
      ])
      expect(at(limitedGroup ?? {}, 'properties', 'decision')['enum']).not.toContain('excluded')
      // Den åpne kilden har ingen innsnevring: «excluded» er et gyldig valg for den.
      expect(at(openGroup ?? {}, 'properties')['decision']).toBeUndefined()
      expect(ACCESS_LIMITED_DECISIONS).toEqual(
        CANDIDATE_DECISIONS.filter((decision) => decision !== 'excluded'),
      )
    })

    it('lister bare kandidatkildene oppgaven har, og avviser en annen', () => {
      expect(
        at(schema, 'properties', 'candidate_appraisals', 'items', 'properties', 'identifier_value')[
          'enum'
        ],
      ).toEqual([TEST_CANDIDATE_DOI, LIMITED_PMID])
      expect(
        handoffResultProblem(
          task,
          answer(role, [{ identifier_kind: 'doi', identifier_value: '10.1000/fra-hukommelsen' }]),
        ),
      ).toMatch(/som ikke står blant kandidatkildene i oppgaven/)
    })

    it('merker den tilgangsbegrensede kandidaten der agenten leser kandidatlisten', () => {
      const file = renderAgentTaskFile(task)
      const kandidater = file.slice(file.indexOf('### Kandidatkildene søkene ga'))
      const linje = kandidater.slice(kandidater.indexOf(`pmid:${LIMITED_PMID}`))
      expect(linje).toMatch(/TILGANGSBEGRENSET .*kan ikke ekskluderes; sett «awaiting_access»/)
      const åpen = kandidater.slice(
        kandidater.indexOf(`doi:${TEST_CANDIDATE_DOI}`),
        kandidater.indexOf(`pmid:${LIMITED_PMID}`),
      )
      expect(åpen).not.toContain('TILGANGSBEGRENSET')
    })

    // ------------------------------------------------------------------------
    // 3 og 4: narrows_request
    // ------------------------------------------------------------------------

    it('3. avviser fortsatt en narrows_request til det andre leddets runde', () => {
      expect(
        handoffResultProblem(task, answer(role, [], [narrowing(OTHER_LEG_ROUND, 'Crossref')])),
      ).toMatch(/er ikke en av søkerundene dette agentleddet kan snevre inn/)
    })

    it('3. avviser fortsatt en narrows_request til en ukjent runde', () => {
      expect(handoffResultProblem(task, answer(role, [], [narrowing(UNKNOWN_ROUND)]))).toMatch(
        /er ikke en av søkerundene dette agentleddet kan snevre inn/,
      )
    })

    it('3. avviser en runde der resten alt er dekket', () => {
      expect(
        handoffResultProblem(task, answer(role, [], [narrowing(RESOLVED_ROUND, 'PubMed')])),
      ).toMatch(/er ikke en av søkerundene dette agentleddet kan snevre inn/)
    })

    it('3. avviser leddets egen runde med en annen plattform eller metode', () => {
      expect(
        handoffResultProblem(task, answer(role, [], [narrowing(OWN_ROUND, 'PubMed')])),
      ).toMatch(/en annen plattform eller metode enn runden brukte/)
      expect(
        handoffResultProblem(
          task,
          answer(role, [], [narrowing(OWN_ROUND, 'Europe PMC', 'systematic_review_filter')]),
        ),
      ).toMatch(/en annen plattform eller metode enn runden brukte/)
    })

    it('4. godtar en innsnevring av leddets egen avkortede runde', () => {
      expect(handoffResultProblem(task, answer(role, [], [narrowing(OWN_ROUND)]))).toBeNull()
    })

    // ------------------------------------------------------------------------
    // 5: svarformen eksponerer ikke en ugyldig referanse
    // ------------------------------------------------------------------------

    it('5. tillater bare leddets egne avkortede runder i narrows_request', () => {
      const request = at(schema, 'properties', 'search_requests', 'items')
      expect(at(request, 'properties', 'narrows_request')['enum']).toEqual([OWN_ROUND])

      const alternatives = request['anyOf'] as Schema[]
      expect(alternatives[0]).toMatchObject({ not: { required: ['narrows_request'] } })
      expect(alternatives.slice(1)).toEqual([
        expect.objectContaining({
          required: ['narrows_request', 'platform', 'method'],
          properties: {
            narrows_request: { const: OWN_ROUND },
            platform: { const: 'Europe PMC' },
            method: { const: 'keyword' },
          },
        }),
      ])

      const serialized = JSON.stringify(schema)
      expect(serialized).not.toContain(OTHER_LEG_ROUND)
      expect(serialized).not.toContain(RESOLVED_ROUND)
      expect(serialized).not.toContain('"pattern":"^[0-9a-f]{32}$"')
    })

    it('5. har ikke feltet narrows_request når ingen runde kan snevres inn', () => {
      const none = sourceTask(role, false)
      const request = at(schemaFor(none), 'properties', 'search_requests', 'items')
      expect(request['additionalProperties']).toBe(false)
      expect(request['properties']).not.toHaveProperty('narrows_request')
      expect(request).not.toHaveProperty('anyOf')
      expect(handoffResultProblem(none, answer(role, [], [narrowing(OWN_ROUND)]))).toMatch(
        /ingen runde i denne oppgaven kan snevres inn/,
      )
    })

    it('5. viser ikke det andre leddets runde som noe agenten kan oppgi', () => {
      const file = renderAgentTaskFile(task)
      expect(file).toContain(`narrows_request: ${OWN_ROUND}`)
      expect(file).not.toContain(`narrows_request: ${OTHER_LEG_ROUND}`)
      expect(file).not.toContain(`narrows_request: ${RESOLVED_ROUND}`)
      expect(file).toContain('runden hører til det andre kildeleddet, og bare det kan erstatte den')

      const seksjon = file.slice(
        file.indexOf('### Søkerunder du kan snevre inn'),
        file.indexOf('### Søkepasseringene en redaktør utførte'),
      )
      expect(seksjon).toContain(
        `narrows_request: ${OWN_ROUND} — platform: Europe PMC, method: keyword`,
      )
      expect(seksjon).not.toContain(OTHER_LEG_ROUND)

      // Og svarformen agenten får i den samme teksten, er oppgavens egen.
      expect(file).toContain(JSON.stringify(schemaFor(task), null, 2))
    })
  },
)

describe('grensene leses lukket', () => {
  it('tilbyr ikke en runde som ikke har formen til en runde', () => {
    const bounds = discoveryAnswerBounds({
      narrowable_rounds: [
        { request_reference: 'kort', platform: 'Europe PMC', method: 'keyword' },
        { request_reference: OWN_ROUND, platform: 'Et internt arkiv', method: 'keyword' },
        { request_reference: OWN_ROUND, platform: 'Europe PMC', method: 'ukjent' },
        { request_reference: OWN_ROUND, platform: 'Europe PMC', method: 'keyword' },
        { request_reference: OWN_ROUND, platform: 'Europe PMC', method: 'keyword' },
      ],
    })
    expect(bounds.narrowableRounds).toEqual([
      { requestReference: OWN_ROUND, platform: 'Europe PMC', method: 'keyword', queries: [] },
    ])
  })

  it('regner en kandidat uten et entydig access_limited: false som tilgangsbegrenset', () => {
    const bounds = discoveryAnswerBounds({
      candidates: [
        { identifier_kind: 'doi', identifier_value: '10.1/a', access_limited: false },
        { identifier_kind: 'doi', identifier_value: '10.1/b' },
        { identifier_kind: 'doi', identifier_value: '10.1/c', access_limited: 'nei' },
      ],
    })
    expect(bounds.candidates.map((candidate) => candidate.accessLimited)).toEqual([
      false,
      true,
      true,
    ])
  })

  it('gir ingen runder og ingen kilder når oppgaven ikke har listene', () => {
    expect(discoveryAnswerBounds({})).toEqual({ candidates: [], narrowableRounds: [] })
  })
})
