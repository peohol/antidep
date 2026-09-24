import { readFileSync } from 'node:fs'

// ============================================================================
// Kildeleddene skal kunne gjøre jobben sin med Antideps fem verktøy
//
// Dette er prøven for den feilen som faktisk oppsto i drift. Den autonome
// Workspace Agent-en kom fram til sin første `source_discovery`-oppgave og
// frigjorde den med `could_not_complete`, med en helt korrekt begrunnelse:
//
//   «Den første oppgaven krever faktiske databasesøk, men oppgaveteksten og
//    kjørereglene tillater ingen verktøy utenfor Antidep.»
//
// Motsigelsen var Antideps: instruksen sa «bruk bare Antidep-appens verktøy»,
// og oppgaven ba om søk ingen av de fem verktøyene kan utføre. Prøvene under
// holder de to sidene sammen, slik at de ikke kan gå fra hverandre igjen.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { HANDOFF_ROLES, parseAgentTask } from './agent-task.ts'
import { renderAgentTaskFile } from './agent-task-file.ts'
import { handoffResultProblem } from './handoff-result.ts'
import { buildSourceCoverageControlDraftSchema } from './handoff-schemas.ts'
import { discoveryAnswerBounds } from './discovery-answer-bounds.ts'
import { resultFor, taskPayload, TEST_CANDIDATE_DOI } from './handoff-test-support.ts'
import { TOOL_NAMES } from '../mcp/tools.ts'

const KILDELEDD = ['source_discovery', 'source_quality_assessment'] as const

/** De fem verktøyene den planlagte kjøreren faktisk har. Ingen av dem søker. */
const ANTIDEP_MCP_TOOLS = [
  'list_pending_agent_tasks',
  'claim_agent_task',
  'get_agent_task',
  'submit_agent_answer',
  'release_agent_task',
]

describe('Antidep-appens verktøyflate', () => {
  it('er de fem verktøyene, og ikke ett til', () => {
    expect([...TOOL_NAMES].sort()).toEqual([...ANTIDEP_MCP_TOOLS].sort())
  })

  it('har ingen vei til et søk, en hentet adresse eller en ekstern tjeneste', () => {
    for (const name of TOOL_NAMES) {
      expect(name).not.toMatch(/search|fetch|http|browse|url/i)
    }
  })
})

// Invarianten som gjør regelen i agentinstruksen sann for alle seks leddene:
// ingen oppgave ber om et nettverkskall. Den sto én gang bare for fire av dem,
// og de to som manglet, var nettopp de som ble umulige i drift.
describe.each(HANDOFF_ROLES)('oppgaven til %s', (role) => {
  it('ber aldri agenten hente noe fra nettet', () => {
    const file = renderAgentTaskFile(parseAgentTask(taskPayload(role)))
    expect(file).toMatch(/Ikke (søk på|hent noe fra) nettet/)
  })
})

describe.each(KILDELEDD)('kildeoppgaven til %s', (role) => {
  const task = parseAgentTask(taskPayload(role))
  const file = renderAgentTaskFile(task)

  it('sier at søkene alt er utført av Antideps egen kode', () => {
    expect(file).toContain('### Søkene Antidep har utført')
    expect(file).toContain('maskinelt utførte')
    expect(file).toMatch(/responsavtrykk/)
  })

  it('ber aldri agenten søke selv eller gå på nettet', () => {
    expect(file).toContain('Du utfører ingen søk')
    expect(file).toContain('Ikke søk på nettet')
    expect(file).not.toMatch(/Rapporter bare søk du faktisk/)
    expect(file).not.toMatch(/Søk selv\./)
  })

  it('gir agenten en vei til flere søk som ikke er et verktøykall', () => {
    expect(file).toContain('### Søk du kan be om')
    expect(file).toContain('search_requests')
  })

  it('bærer grunnlaget vurderingen skal gjelde: søk, begrensninger og kandidater', () => {
    expect(file).toContain('### Søkeveier som ikke svarte')
    expect(file).toContain('### Kandidatkildene søkene ga')
    expect(file).toContain(TEST_CANDIDATE_DOI)
  })

  it('skriver ut stoppkravene framfor tomme kuler', () => {
    expect(file).toContain('Hvert obligatorisk søkespor må være forsøkt og dokumentert.')
    expect(file).toContain('At tre artikler er funnet.')
  })

  // Selve poenget: et svar bygget UTELUKKENDE av det som står i oppgaven, og
  // uten et eneste verktøykall utenfor Antidep, er et gyldig svar.
  it('kan besvares av et svar bygget bare av oppgavens eget materiale', () => {
    expect(handoffResultProblem(task, resultFor(role))).toBeNull()
  })
})

// ----------------------------------------------------------------------------
// Skjemaet agenten følger, og kontrakten svaret møter, må si det samme
//
// Et svar som var gyldig etter det versjonerte skjemaet og likevel ble avvist
// av handoffen, ville vært vår feil og ikke agentens.
// ----------------------------------------------------------------------------
describe('svarformen for dekningskontrollen', () => {
  const schema = buildSourceCoverageControlDraftSchema(
    discoveryAnswerBounds(parseAgentTask(taskPayload('source_quality_assessment')).input),
  )

  it('krever nøyaktig ett av de to utfallene en kontrollrunde kan ha', () => {
    const alternatives = schema['oneOf'] as readonly Record<string, unknown>[]
    expect(alternatives).toHaveLength(2)
    expect(alternatives.map((alternative) => alternative['required'])).toEqual([
      ['control'],
      ['search_requests'],
    ])
  })

  it('krever at en runde som ber om motsøk, faktisk ber om minst ett', () => {
    const alternatives = schema['oneOf'] as readonly Record<string, unknown>[]
    const requests = (alternatives[1]?.['properties'] as Record<string, unknown>)[
      'search_requests'
    ] as Record<string, unknown>
    expect(requests['minItems']).toBe(1)
  })

  // Og de to sidene er faktisk enige: det skjemaet forbyr, avviser kontrakten,
  // og det skjemaet tillater, godtar den.
  it('avvises av kontrakten i nøyaktig de tilfellene skjemaet forbyr', () => {
    const task = parseAgentTask(taskPayload('source_quality_assessment'))
    const withoutOutcome = { ...resultFor('source_quality_assessment') }
    delete withoutOutcome['control']

    expect(handoffResultProblem(task, withoutOutcome)).not.toBeNull()
    expect(
      handoffResultProblem(task, {
        ...withoutOutcome,
        search_requests: [{ rationale: 'Et motsøk mangler.' }],
      }),
    ).toBeNull()
  })
})

describe('kontrolloppgaven', () => {
  const task = parseAgentTask(taskPayload('source_quality_assessment'))
  const file = renderAgentTaskFile(task)

  it('gir kontrollen sine egne, separat utførte motsøk — ikke generatorens vurdering', () => {
    expect(file).toContain('Dine egne, maskinelt utførte motsøk')
    expect(file).toContain('Generatorens egne søk, til sammenligning')
  })

  it('sier at uavhengigheten er maskinelt utført og ikke erklært', () => {
    expect(file).toContain('maskinelt utført og ikke erklært')
  })
})

// ============================================================================
// Proveniensen agenten faktisk får se
//
// 013z ga redaktøren en vei til å registrere søkepasseringen hun selv utførte.
// Men oppgavematerialet la alle søkeradene i det samme feltet, og oppgavefilen
// renderer det feltet under «Søkene Antidep har utført» med setningen «Antideps
// egen kode kalte endepunktet, leste svaret og registrerte et fingeravtrykk av
// det». Et menneskes arbeid ble dermed presentert som maskinelt bekreftet
// utførelse — med «endepunkt: ikke registrert» rett under påstanden om at
// endepunktet ble kalt.
//
// Det er den samme proveniensvaskingen 013v ble skrevet for å fjerne, med
// rollene byttet om. Denne prøven holder de to fra hverandre.
// ============================================================================
describe.each(KILDELEDD)('proveniensen i oppgaven til %s', (role) => {
  const file = renderAgentTaskFile(parseAgentTask(taskPayload(role)))

  it('holder redaktørens passeringer utenfor Antideps egne kall', () => {
    const maskinelt = file.indexOf('### Søkene Antidep har utført')
    const redaktør = file.indexOf('### Søkepasseringene en redaktør utførte')
    expect(maskinelt).toBeGreaterThan(-1)
    expect(redaktør).toBeGreaterThan(maskinelt)

    // Søkeveien mennesket brukte, står under menneskets overskrift — og ikke
    // under maskinens, der den ville arvet en påstand om endepunkt og avtrykk.
    const maskinbolk = file.slice(maskinelt, redaktør)
    expect(maskinbolk).toContain('Europe PMC')
    expect(maskinbolk).not.toContain('ClinicalTrials.gov')
  })

  it('sier om redaktørens passeringer hva de er, og hva de ikke er', () => {
    const redaktør = file.slice(file.indexOf('### Søkepasseringene en redaktør utførte'))
    expect(redaktør).toContain('ikke maskinelt utførte')
    expect(redaktør).toContain('ClinicalTrials.gov')
    expect(redaktør).toContain('utført av et menneske')
    expect(redaktør).toContain('editor_recorded')
  })

  it('og ber agenten om ikke å rapportere noen av dem som sine egne', () => {
    const redaktør = file.slice(file.indexOf('### Søkepasseringene en redaktør utførte'))
    expect(redaktør).toMatch(/skal\s+ikke\s+rapportere dem som dine egne/)
  })

  // Den første utgaven av denne prøven avviste to konkrete formuleringer. Den
  // fanget derfor ikke de tre neste stedene som sa det samme med andre ord:
  // svarskjemaets beskrivelse, oppgavens summary og åpningen av rollen. En
  // prøve som lister forbudte setninger, fanger de setningene — ikke
  // egenskapen.
  //
  // Egenskapen er denne: en *samlet* påstand om «søkene» kan ikke tilskrive dem
  // maskinen alene, for søkegrunnlaget kan bestå av begge slag — og for REG,
  // PROD og SYN består det ofte bare av redaktørens passeringer, fordi Antidep
  // ikke har en maskinell vei til noen av deres søkespor.
  //
  // Setningene som snakker om én av delene («dine egne, maskinelt utførte
  // motsøk», «disse er maskinelt utførte») er sanne og skal stå. Det er
  // nettopp derfor regelen leser subjektet og ikke bare ordene.
  it('tilskriver aldri søkegrunnlaget som helhet til maskinen alene', () => {
    const samletOmSøkene = /\bsøkene\b/i
    const maskinellPåstand = /maskinelt|Antideps egen kode|Antideps egne/i
    const nevnerMennesket = /redaktør|editor_recorded|menneske|to slag|andre enn deg/i

    // Deles på setningsslutt og på avsnitt. Bare på setningsslutt ville en
    // overskrift uten punktum blitt limt sammen med setningen under; på hvert
    // linjeskift ville en ombrukket setning blitt revet i biter. Et avsnitt er
    // grensen som holder begge deler.
    const brudd = file
      .split(/(?<=[.:])\s+|\n{2,}/)
      .filter((setning) => samletOmSøkene.test(setning))
      .filter((setning) => maskinellPåstand.test(setning))
      .filter((setning) => !nevnerMennesket.test(setning))

    expect(brudd).toEqual([])
  })

  it('og sier, der agenten leser først, at søkene er av to slag', () => {
    const rolle = file.slice(0, file.indexOf('### Obligatoriske søkespor'))
    expect(rolle).toMatch(/maskinelt utførte/)
    expect(rolle).toMatch(/redaktørregistrerte|redaktør/)
  })
})

// ============================================================================
// Kontrakten mot databasen, og driften som passerte tre ganger
//
// `api.record_monograph_track_by_editor` fikk parametre i tre omganger. To av
// gangene ble `src/types/database.ts` liggende igjen på den forrige formen, og
// ingenting merket det: TypeScript kontrollerer at et *kall* passer typen, ikke
// at typen passer databasen. En typesjekket klient kunne dermed ikke bruke
// veien basen krever — og CI var grønn.
//
// Denne prøven leser signaturen ut av migrasjonen og krever at de to sidene
// sier det samme.
// ============================================================================
describe('RPC-signaturen mot migrasjonen', () => {
  const MIGRASJON =
    'supabase/migrations/20261019095000_the_editors_findings_and_honest_provenance.sql'

  /** Parameternavnene `create function` faktisk deklarerer. */
  function parametersInMigration(fn: string): readonly string[] {
    const sql = readFileSync(MIGRASJON, 'utf8')
    const start = sql.lastIndexOf(`create function ${fn}(`)
    expect(start).toBeGreaterThan(-1)
    const head = sql.slice(start, sql.indexOf('\n)\n', start))
    return [...head.matchAll(/^\s{2}(p_[a-z_]+)\s/gm)].map((m) => m[1] as string)
  }

  /**
   * Og navnene `Database` erklærer. Typen finnes bare ved kompilering, så
   * påstanden må leses fra kilden — en `satisfies` ville sammenlignet typen med
   * seg selv.
   */
  function parametersInType(fn: string): readonly string[] {
    const ts = readFileSync('src/types/database.ts', 'utf8')
    const start = ts.indexOf(`      ${fn}: {`)
    expect(start).toBeGreaterThan(-1)
    const block = ts.slice(start, ts.indexOf('Returns:', start))
    return [...block.matchAll(/^\s+(p_[a-zA-Z_]+)\??:/gm)].map((m) => m[1] as string)
  }

  it('erklærer nøyaktig de parametrene databasen tar imot', () => {
    const fn = 'api.record_monograph_track_by_editor'
    expect(parametersInType('record_monograph_track_by_editor')).toEqual(parametersInMigration(fn))
  })

  it('og har med veien for kandidatene et manuelt søk fant', () => {
    // Den konkrete driften funnet pekte på: uten disse to kan en typesjekket
    // klient ikke registrere et positivt manuelt søk i det hele tatt.
    const declared = parametersInType('record_monograph_track_by_editor')
    expect(declared).toContain('p_candidates')
    expect(declared).toContain('p_screening_note')
  })
})
