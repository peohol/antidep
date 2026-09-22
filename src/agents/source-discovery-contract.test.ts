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
