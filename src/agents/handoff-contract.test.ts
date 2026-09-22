import { readdir, readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

import {
  AGENT_ANSWER_VERSION,
  AGENT_TASK_VERSION,
  HANDOFF_CONTRACTS,
  HANDOFF_ROLES,
  handoffContract,
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
} from './agent-task.ts'
import { taskPayload, TEST_JOB_ID } from './handoff-test-support.ts'

const MIGRATIONS = 'supabase/migrations'

async function migrationFiles(): Promise<readonly string[]> {
  return (await readdir(MIGRATIONS)).filter((name) => name.endsWith('.sql')).sort()
}

/**
 * Den gjeldende definisjonen av en versjonsfunksjon.
 *
 * Som for kontraktfunksjonen under: fasiten er den *siste* definisjonen og ikke
 * den første. Migrasjon 013u hevet svarformen til @2, og en prøve som fortsatt
 * pekte på migrasjonen som innførte formen, ville pinnet flaten mot en utgave
 * som ikke gjelder — og vært stille grønn den dagen de to gikk i utakt.
 */
async function currentVersionFunction(name: string): Promise<string> {
  let current: string | null = null
  for (const file of await migrationFiles()) {
    const sql = await readFile(`${MIGRATIONS}/${file}`, 'utf8')
    const match = new RegExp(
      `create (?:or replace )?function workflow\\.${name}\\(\\)[\\s\\S]*?\\$(?:function)?\\$;`,
      'i',
    ).exec(sql)
    if (match !== null) {
      current = match[0]
    }
  }
  expect(current, `ingen migrasjon definerer workflow.${name}()`).not.toBeNull()
  return current ?? ''
}

/**
 * Den gjeldende definisjonen av `workflow.agent_task_contract`.
 *
 * Funksjonen erstattes av den migrasjonen som legger til en rolle, så fasiten er
 * den *siste* definisjonen og ikke den første. Prøven leter etter den framfor å
 * navngi en fil: en navngitt fil ville pinnet kontrakten mot en utgave som ikke
 * gjelder lenger, og da ville den vært stille grønn.
 */
async function currentContractFunction(): Promise<string> {
  let current: string | null = null
  for (const name of await migrationFiles()) {
    const sql = await readFile(`${MIGRATIONS}/${name}`, 'utf8')
    // Både den håndskrevne formen (`$$`) og den som er spleiset fra databasens
    // egen `pg_get_functiondef` (`$function$`). Uten begge ville prøven lest en
    // eldre utgave av kontrakten og vært stille grønn.
    const match =
      /create or replace function workflow\.agent_task_contract[\s\S]*?\$(?:function)?\$;/i.exec(
        sql,
      )
    if (match !== null) {
      current = match[0]
    }
  }
  expect(current, 'ingen migrasjon definerer workflow.agent_task_contract').not.toBeNull()
  return current ?? ''
}

describe('oppgavekontrakten', () => {
  it('dekker de semantiske leddene og ingen deterministisk kontrollrolle', () => {
    expect([...HANDOFF_ROLES]).toEqual([
      'evidence_extraction',
      'claim_synthesis',
      'evidence_assessment',
      // Migrasjon 013f: kildeoppdagelsen og den separate kontrollen av
      // søkedekningen. Begge er faglige avgjørelser — å planlegge et søk og å
      // vurdere om dekningen holder — og begge går gjennom den samme
      // kontrakten.
      'source_discovery',
      'source_quality_assessment',
      // Migrasjon 013i: svaret på et behov som hviler på et myndighets-,
      // preparat- eller retningslinjedokument. Å lese dokumentet og formulere
      // opplysningen er en faglig vurdering.
      'monograph_answer',
    ])
    // De uavhengige *deterministiske* kontrolleddene er Antideps egen kode. En
    // ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en
    // modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).
    for (const role of [
      'extraction_verification',
      'citation_support_verification',
      'monograph_answer_verification',
    ]) {
      expect(() => handoffContract(role)).toThrow(new RegExp(role))
    }
  })

  it('gir hver rolle sin egen promptmal og sin egen svarform', () => {
    const prompts = HANDOFF_ROLES.map((role) => HANDOFF_CONTRACTS[role].promptTemplateVersion)
    const schemas = HANDOFF_ROLES.map((role) => HANDOFF_CONTRACTS[role].outputSchemaVersion)
    expect(new Set(prompts).size).toBe(HANDOFF_ROLES.length)
    expect(new Set(schemas).size).toBe(HANDOFF_ROLES.length)
  })
})

// ----------------------------------------------------------------------------
// Speilet mot fasiten
//
// Migrasjon 010c eier oppgaven og avtrykket, og begge versjonene inngår i det.
// Blir de to sidene uenige, avviser databasen svaret med en setning om
// svarformen; denne prøven sier det med navn før det skjer.
// ----------------------------------------------------------------------------
describe('kontrakten er den samme som databasens', () => {
  it('bruker de samme oppgave- og svarformversjonene som migrasjonen', async () => {
    expect(await currentVersionFunction('agent_handoff_task_version')).toContain(
      `select '${AGENT_TASK_VERSION}'::text`,
    )
    expect(await currentVersionFunction('agent_handoff_answer_version')).toContain(
      `select '${AGENT_ANSWER_VERSION}'::text`,
    )
  })

  it('bruker de samme promptmal- og svarformversjonene som den gjeldende kontrakten', async () => {
    const contractFunction = await currentContractFunction()

    for (const role of HANDOFF_ROLES) {
      const contract = HANDOFF_CONTRACTS[role]
      const block = new RegExp(
        `when '${role}' then jsonb_build_object\\(\\s*\\n\\s*'prompt_template_version', '([^']+)',\\s*\\n\\s*'output_schema_version', '([^']+)'`,
      ).exec(contractFunction)
      expect(block, `migrasjonen mangler kontrakten for ${role}`).not.toBeNull()
      expect(block?.[1]).toBe(contract.promptTemplateVersion)
      expect(block?.[2]).toBe(contract.outputSchemaVersion)
    }
  })

  it('setter ut nøyaktig de rollene migrasjonen åpner for', async () => {
    const contractFunction = await currentContractFunction()
    const roles = [...contractFunction.matchAll(/when '([a-z_]+)' then/g)].map((match) => match[1])
    expect(roles.sort()).toEqual([...HANDOFF_ROLES].sort())
  })
})

describe('parseAgentTask', () => {
  it('leser en oppgave databasen bygget', () => {
    const task = parseAgentTask(taskPayload('evidence_extraction'))
    expect(task.role).toBe('evidence_extraction')
    expect(task.pipelineJobId).toBe(TEST_JOB_ID)
    expect(task.subject.label).toBe('Syntetisk testkilde')
    expect(task.registeredModel).toBeNull()
  })

  it('leser den registrerte modellen når rollen har en', () => {
    const task = parseAgentTask(
      taskPayload('claim_synthesis', {
        registered_model: {
          provider: 'openai',
          model: 'GPT-5 Thinking',
          model_version: 'ikke-eksponert',
          model_version_disclosure: 'not_exposed',
        },
      }),
    )
    expect(task.registeredModel).toEqual({
      provider: 'openai',
      model: 'GPT-5 Thinking',
      modelVersion: 'ikke-eksponert',
      modelVersionDisclosure: 'not_exposed',
    })
  })

  it('avviser en oppgave fra en rolle flaten ikke kan sette ut', () => {
    expect(() =>
      parseAgentTask(taskPayload('evidence_extraction', { role: 'extraction_verification' })),
    ).toThrow(/role/)
  })

  it('avviser et avtrykk som ikke har formen', () => {
    expect(() =>
      parseAgentTask(taskPayload('evidence_extraction', { request_digest: 'sha256:kort' })),
    ).toThrow(/request_digest/)
  })

  it('sier fra når flaten og databasen er uenige om promptmalen', () => {
    expect(() =>
      parseAgentTask(
        taskPayload('evidence_extraction', { prompt_template_version: 'noe/annet/1' }),
      ),
    ).toThrow(/utakt/)
  })

  it('avviser et ukjent felt framfor å ignorere det', () => {
    expect(() => parseAgentTask(taskPayload('evidence_extraction', { notat: 'hei' }))).toThrow(
      /ukjente felter/,
    )
  })
})

describe('parseAgentWorkQueue', () => {
  const row = (overrides: Record<string, unknown> = {}) => ({
    pipeline_job_id: TEST_JOB_ID,
    agent_role: 'evidence_extraction',
    job_key: 'agent-handoff:x:1',
    state: 'ready',
    attempts: 0,
    max_attempts: 3,
    enqueued_at: '2026-09-15T09:00:00Z',
    failure_reason: null,
    blocked_reason: null,
    answered: false,
    answered_at: null,
    subject_label: 'Syntetisk testkilde',
    registered_model: null,
    ...overrides,
  })

  it('leser radene flaten kan vise', () => {
    const queue = parseAgentWorkQueue([row()])
    expect(queue.items).toHaveLength(1)
    expect(queue.items[0]?.subjectLabel).toBe('Syntetisk testkilde')
    expect(queue.unknownRoles).toBe(0)
  })

  // En database som har fått en ny handoff-rolle før flaten er oppdatert, skal
  // ikke gjøre hele siden ubrukelig. Raden er borte til flaten kan vise den, og
  // køen sier hvor mange den ikke kunne vise — det er en synlig forskjell fra at
  // den ikke finnes (ANTIDEP_CONSTITUTION.md regel 4).
  it('teller rader i en rolle den ikke kjenner, framfor å skjule dem', () => {
    const queue = parseAgentWorkQueue([row(), row({ agent_role: 'editorial_compression' })])
    expect(queue.items).toHaveLength(1)
    expect(queue.unknownRoles).toBe(1)
  })

  it('avviser et svar som ikke er en liste', () => {
    expect(() => parseAgentWorkQueue({})).toThrow(/liste/)
  })
})

describe('parseImportOutcome', () => {
  it('leser utfallet av en import', () => {
    const outcome = parseImportOutcome({
      imported: true,
      already_imported: false,
      pipeline_job_id: TEST_JOB_ID,
      agent_role: 'evidence_extraction',
      agent_run_id: '78000000-0000-4000-8000-0000000000aa',
      request_digest: `sha256:${'1'.repeat(64)}`,
      model: {
        provider: 'openai',
        model: 'GPT-5 Thinking',
        model_version: 'ikke-eksponert',
        model_version_disclosure: 'not_exposed',
      },
      outcome: { evidence_item_id: '78000000-0000-4000-8000-0000000000ee' },
    })
    expect(outcome.imported).toBe(true)
    expect(outcome.model?.model).toBe('GPT-5 Thinking')
    expect(outcome.outcome['evidence_item_id']).toBe('78000000-0000-4000-8000-0000000000ee')
  })
})
