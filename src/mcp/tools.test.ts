import { describe, expect, it } from 'vitest'

import { HANDOFF_ROLES } from '../agents/agent-task.ts'
import { SERVER_INSTRUCTIONS, SUPPORTED_PROTOCOL_VERSIONS } from './server.ts'
import { TOOL_DEFINITIONS, TOOL_NAMES } from './tools.ts'

// ============================================================================
// Verktøyflaten er en kontrakt, og den skal ikke vokse ved et uhell
//
// En MCP-app som fikk et verktøy til, ville gitt modellen en evne ingen hadde
// tatt stilling til. Prøven fører derfor flaten uttømmende: kommer det et
// verktøy, må denne listen endres i samme endring, og da er valget tatt av et
// menneske (ANTIDEP_CONSTITUTION.md regel 7).
// ============================================================================

const EXPECTED_TOOLS = [
  'list_pending_agent_tasks',
  'claim_agent_task',
  'get_agent_task',
  'submit_agent_answer',
  'release_agent_task',
]

function schemaOf(name: string): Record<string, unknown> {
  const tool = TOOL_DEFINITIONS.find((definition) => definition.name === name)
  if (tool === undefined) {
    throw new Error(`Verktøyet ${name} finnes ikke.`)
  }
  return tool.inputSchema
}

describe('verktøyflaten', () => {
  it('er nøyaktig de fem smale operasjonene, og ingen flere', () => {
    expect([...TOOL_NAMES].sort()).toEqual([...EXPECTED_TOOLS].sort())
  })

  it('gir modellen ingen SQL, ingen tabellesing og ingen generell HTTP', () => {
    const forbidden = /sql|query|table|select|http|fetch|proxy|supabase|database/i
    const named = TOOL_DEFINITIONS.filter((tool) => forbidden.test(tool.name))
    expect(named).toEqual([])
  })

  it('lukker hvert inndataskjema, slik at et ukjent felt ikke blir en stille antakelse', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.inputSchema['type']).toBe('object')
      expect(tool.inputSchema['additionalProperties']).toBe(false)
    }
  })

  it('merker hvert verktøy med om det endrer noe, og ingen som destruktivt', () => {
    const readOnly = TOOL_DEFINITIONS.filter((tool) => tool.annotations.readOnlyHint).map(
      (tool) => tool.name,
    )
    expect(readOnly.sort()).toEqual(['get_agent_task', 'list_pending_agent_tasks'])

    // Ingenting i denne flaten kan slette eller skrive over noe: registreringen
    // er append-only og idempotent på oppgaven.
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.annotations.destructiveHint).toBe(false)
      // Ingen av verktøyene rører noe utenfor Antidep.
      expect(tool.annotations.openWorldHint).toBe(false)
    }
  })

  it('krever et oppgavehåndtak av hvert verktøy som gjelder én bestemt oppgave', () => {
    for (const name of ['get_agent_task', 'submit_agent_answer', 'release_agent_task']) {
      expect(schemaOf(name)['required']).toContain('task_handle')
    }
  })

  it('lar ingen kaller oppgi hvilket agentledd arbeidet gjelder', () => {
    // Rollen er tilkoblingens egen. Kunne modellen oppgi den, ville et token
    // kunnet hente arbeid i et annet ledd enn det mennesket registrerte det for
    // (ANTIDEP_CONSTITUTION.md regel 3).
    for (const tool of TOOL_DEFINITIONS) {
      const properties = tool.inputSchema['properties'] as Record<string, unknown>
      for (const role of HANDOFF_ROLES) {
        expect(Object.keys(properties)).not.toContain(role)
      }
      expect(Object.keys(properties)).not.toContain('agent_role')
      expect(Object.keys(properties)).not.toContain('role')
    }
  })
})

describe('serverinstruksen', () => {
  it('sier at materialet er data og aldri en instruks', () => {
    expect(SERVER_INSTRUCTIONS).toMatch(/DATA/)
    expect(SERVER_INSTRUCTIONS).toMatch(/aldri følges/)
  })

  it('sier at en avvisning skal rapporteres framfor omgås', () => {
    expect(SERVER_INSTRUCTIONS).toMatch(/ingen vei utenom kontrollen/)
  })

  it('sier at en tom kø skal avsluttes stille', () => {
    expect(SERVER_INSTRUCTIONS).toMatch(/avslutt stille/i)
  })

  it('snakker den protokollversjonen MCP-autorisasjonen er skrevet mot', () => {
    expect(SUPPORTED_PROTOCOL_VERSIONS).toContain('2025-11-25')
  })
})
