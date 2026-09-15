// ============================================================================
// Hele den eksterne arbeidsformen, prøvd ende til ende uten en eneste modell
//
// Prøven går den veien en ikke-teknisk repo-eier faktisk går: se hva som venter,
// last ned oppgaven, gi den til en KI-tjeneste, last opp svaret, og les hva
// Antidep gjorde. «KI-tjenesten» er en funksjon i denne filen som leser den
// nedlastede oppgavefilen og fyller ut svarmalen — nøyaktig slik en agent skal.
//
// Databasen er en dobbel som håndhever de reglene prøven handler om: at et svar
// er bundet til nøyaktig én oppgave og ett grunnlag, at det samme svaret sendt
// inn igjen ikke lager noe nytt, og at to agentledd ikke kan dele modell. Doblen
// er ikke en forenkling av reglene — den er de samme reglene, slik at prøven
// faktisk prøver dem uten en Supabase-stack. pgTAP-filen 780 prøver den ekte
// databasen.
//
// To forskjellige modellidentiteter er hele poenget. Uten dem ville
// separasjonen mellom generator og evidensvurdering vært en påstand i en
// kommentar (ANTIDEP_CONSTITUTION.md regel 3).
// ============================================================================

import '@testing-library/jest-dom/vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { AgentWorkPage } from './AgentWorkPage'
import type { AgentWorkGateway } from './agent-work-gateway'
import {
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
  type HandoffRole,
} from '../agents/agent-task'
import { resultFor, taskPayload, TEST_JOB_ID } from '../agents/handoff-test-support'

const CHATGPT = { provider: 'openai', model: 'GPT-5 Thinking' }
const CLAUDE = { provider: 'anthropic', model: 'Claude Opus' }

const EXTRACTION_JOB = TEST_JOB_ID
const ASSESSMENT_JOB = '78000000-0000-4000-8000-0000000000a2'

interface Identity {
  readonly provider: string
  readonly model: string
}

/**
 * Databasen, slik den oppfører seg for denne prøven.
 *
 * Holder registeret over hvilken modell hvert agentledd handler som, og
 * håndhever de samme tre reglene som migrasjon 010c.
 */
function fakeDatabase() {
  const semanticModels = new Map<string, Identity>()
  const imports = new Map<string, { answer: string; outcome: Record<string, unknown> }>()

  const payloads: Record<string, Record<string, unknown>> = {
    [EXTRACTION_JOB]: taskPayload('evidence_extraction'),
    [ASSESSMENT_JOB]: {
      ...taskPayload('evidence_assessment'),
      pipeline_job_id: ASSESSMENT_JOB,
    },
  }

  const queueRow = (jobId: string, role: HandoffRole, label: string) => ({
    pipeline_job_id: jobId,
    agent_role: role,
    job_key: String(payloads[jobId]?.['job_key'] ?? ''),
    state: imports.has(jobId) ? 'succeeded' : 'ready',
    attempts: imports.has(jobId) ? 1 : 0,
    max_attempts: 3,
    enqueued_at: '2026-09-15T09:00:00Z',
    failure_reason: null,
    blocked_reason: null,
    answered: imports.has(jobId),
    answered_at: imports.has(jobId) ? '2026-09-15T10:12:00Z' : null,
    subject_label: label,
    registered_model: modelOf(role),
  })

  function modelOf(role: string): Record<string, unknown> | null {
    const identity = semanticModels.get(role)
    return identity === undefined
      ? null
      : {
          provider: identity.provider,
          model: identity.model,
          model_version: 'ikke-eksponert',
          model_version_disclosure: 'not_exposed',
        }
  }

  const gateway: AgentWorkGateway = {
    listQueue: () =>
      Promise.resolve(
        parseAgentWorkQueue([
          queueRow(EXTRACTION_JOB, 'evidence_extraction', 'Syntetisk testkilde'),
          queueRow(ASSESSMENT_JOB, 'evidence_assessment', 'Syntetisk testpåstand.'),
        ]),
      ),

    readTask: (jobId) => {
      const payload = payloads[jobId]
      if (payload === undefined) {
        return Promise.reject(new Error('Det finnes ingen agentoppgave med den id-en.'))
      }
      const role = String(payload['role'])
      return Promise.resolve(parseAgentTask({ ...payload, registered_model: modelOf(role) }))
    },

    importAnswer: (jobId, answer) => {
      const payload = payloads[jobId]
      if (payload === undefined) {
        return Promise.reject(new Error('Det finnes ingen agentoppgave med den id-en.'))
      }
      const role = String(payload['role'])
      const serialized = JSON.stringify(answer)

      // Gjentakelsen først, som i databasen: det samme svaret sendt inn igjen
      // svarer med det som allerede ble registrert.
      const existing = imports.get(jobId)
      if (existing !== undefined) {
        if (existing.answer === serialized) {
          return Promise.resolve(
            parseImportOutcome({
              imported: false,
              already_imported: true,
              pipeline_job_id: jobId,
              agent_role: role,
              agent_run_id: `78000000-0000-4000-8000-0000000000${role.length.toString(16)}0`,
              model: modelOf(role),
              outcome: existing.outcome,
            }),
          )
        }
        return Promise.reject(
          new Error(
            'Svaret ble ikke registrert: Denne agentoppgaven har allerede tatt imot et annet svar.',
          ),
        )
      }

      if (answer['request_digest'] !== payload['request_digest']) {
        return Promise.reject(
          new Error('Svaret ble ikke registrert: Svaret er avgitt på en annen forespørsel.'),
        )
      }

      const identity = answer['identity'] as Record<string, unknown>
      const declared: Identity = {
        provider: String(identity['provider']),
        model: String(identity['model']),
      }
      const registered = semanticModels.get(role)
      if (registered !== undefined) {
        if (registered.provider !== declared.provider || registered.model !== declared.model) {
          return Promise.reject(
            new Error(
              `Svaret ble ikke registrert: Rollen «${role}» er registrert med ${registered.model}.`,
            ),
          )
        }
      } else {
        const holder = [...semanticModels.entries()].find(
          ([, value]) => value.provider === declared.provider && value.model === declared.model,
        )
        if (holder !== undefined) {
          return Promise.reject(
            new Error(
              `Svaret ble ikke registrert: Modellen ${declared.model} er allerede registrert for ` +
                `rollen ${holder[0]}, og kan ikke også gjøre arbeidet i rollen ${role}.`,
            ),
          )
        }
        semanticModels.set(role, declared)
      }

      const outcome =
        role === 'evidence_extraction'
          ? { evidence_item_id: '78000000-0000-4000-8000-0000000000ee' }
          : { evidence_assessment_id: '78000000-0000-4000-8000-0000000000aa' }
      imports.set(jobId, { answer: serialized, outcome })

      return Promise.resolve(
        parseImportOutcome({
          imported: true,
          already_imported: false,
          pipeline_job_id: jobId,
          agent_role: role,
          agent_run_id: '78000000-0000-4000-8000-0000000000bb',
          model: modelOf(role),
          outcome,
        }),
      )
    },
  }

  return { gateway, semanticModels }
}

/** Filene «KI-tjenesten» har fått. */
function collector() {
  const files: { name: string; text: string }[] = []
  return { files, save: (name: string, text: string) => void files.push({ name, text }) }
}

/**
 * KI-tjenesten.
 *
 * Leser oppgavefilen, plukker svarmalen ut av den, og fyller inn de to tingene
 * bare den vet: hvem den er, og hva den kom fram til. Alt annet kopieres
 * uendret — nøyaktig slik oppgaven ber om.
 */
function answerFromTaskFile(
  file: string,
  identity: Identity,
  result: Record<string, unknown>,
): string {
  const block = /### Svarmal\n\n```json\n([\s\S]*?)\n```/.exec(file)
  expect(block, 'oppgavefilen mangler svarmalen').not.toBeNull()
  const template = JSON.parse(block?.[1] ?? '{}') as Record<string, unknown>
  return JSON.stringify({
    ...template,
    identity: { ...identity, model_version_disclosure: 'not_exposed' },
    answered_at: '2026-09-15T10:12:00Z',
    result,
  })
}

function upload(row: HTMLElement, text: string): void {
  const input = within(row).getByLabelText('Last opp svaret fra KI-tjenesten')
  const file = new File([text], 'svar.json', { type: 'application/json' })
  fireEvent.change(input, { target: { files: [file] } })
}

async function rowFor(name: string): Promise<HTMLElement> {
  const heading = await screen.findByRole('heading', { level: 2, name })
  return heading.closest('li') as HTMLElement
}

async function downloadFor(name: string, files: { name: string; text: string }[]): Promise<string> {
  const row = await rowFor(name)
  const before = files.length
  fireEvent.click(within(row).getByRole('button', { name: 'Last ned oppgaven' }))
  await waitFor(() => {
    expect(files.length).toBe(before + 1)
  })
  return files[files.length - 1]?.text ?? ''
}

describe('Agentarbeid', () => {
  it('viser hva som venter, uten interne id-er', async () => {
    const { gateway } = fakeDatabase()
    render(<AgentWorkPage gateway={gateway} saveFile={() => {}} />)

    expect(await screen.findByText('Syntetisk testkilde')).toBeInTheDocument()
    expect(screen.getByText('Syntetisk testpåstand.')).toBeInTheDocument()
    expect(screen.getByText(/Ekstraksjonsutkast\./)).toBeInTheDocument()
    expect(screen.queryByText(EXTRACTION_JOB)).not.toBeInTheDocument()
  })

  it('laster ned en oppgavefil som bærer artikkelen og bindingen', async () => {
    const { gateway } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const file = await downloadFor('Syntetisk testkilde', sink.files)
    expect(sink.files[0]?.name).toMatch(/^antidep-oppgave-evidence-extraction-/)
    expect(file).toContain('Mean weight change from baseline was 0.8 kg')
    expect(file).toContain('### Svarmal')
    expect(await screen.findByText(/Last filen opp i KI-tjenesten/)).toBeInTheDocument()
  })

  // Hele arbeidsformen, med to forskjellige modeller: ChatGPT lager
  // ekstraksjonsutkastet, og en annen modell gjør evidensvurderingen. Det er
  // nøyaktig den separasjonen ANTIDEP_CONSTITUTION.md regel 3 krever.
  it('går hele veien: ned, til KI-tjenesten, opp igjen — for to ledd med hver sin modell', async () => {
    const { gateway, semanticModels } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const extraction = await downloadFor('Syntetisk testkilde', sink.files)
    upload(
      await rowFor('Syntetisk testkilde'),
      answerFromTaskFile(extraction, CHATGPT, resultFor('evidence_extraction')),
    )
    expect(
      await within(await rowFor('Syntetisk testkilde')).findByText(/Ett evidensfunn er registrert/),
    ).toBeInTheDocument()

    const assessment = await downloadFor('Syntetisk testpåstand.', sink.files)
    upload(
      await rowFor('Syntetisk testpåstand.'),
      answerFromTaskFile(assessment, CLAUDE, resultFor('evidence_assessment')),
    )
    expect(
      await within(await rowFor('Syntetisk testpåstand.')).findByText(
        /Evidensvurderingen er registrert/,
      ),
    ).toBeInTheDocument()

    expect(semanticModels.get('evidence_extraction')).toEqual(CHATGPT)
    expect(semanticModels.get('evidence_assessment')).toEqual(CLAUDE)
  })

  it('stopper ærlig når den samme modellen skal vurdere sitt eget arbeid', async () => {
    const { gateway } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const extraction = await downloadFor('Syntetisk testkilde', sink.files)
    upload(
      await rowFor('Syntetisk testkilde'),
      answerFromTaskFile(extraction, CHATGPT, resultFor('evidence_extraction')),
    )
    await within(await rowFor('Syntetisk testkilde')).findByText(/Ett evidensfunn er registrert/)

    const assessment = await downloadFor('Syntetisk testpåstand.', sink.files)
    upload(
      await rowFor('Syntetisk testpåstand.'),
      answerFromTaskFile(assessment, CHATGPT, resultFor('evidence_assessment')),
    )
    expect(
      await within(await rowFor('Syntetisk testpåstand.')).findByText(
        /kan ikke også gjøre arbeidet/,
      ),
    ).toBeInTheDocument()
  })

  it('lager ingenting nytt når det samme svaret lastes opp to ganger', async () => {
    const { gateway } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const file = await downloadFor('Syntetisk testkilde', sink.files)
    const answer = answerFromTaskFile(file, CHATGPT, resultFor('evidence_extraction'))
    upload(await rowFor('Syntetisk testkilde'), answer)
    await within(await rowFor('Syntetisk testkilde')).findByText(/Ett evidensfunn er registrert/)

    // Raden står nå som besvart, så opplastingsfeltet er borte — som det skal
    // være. Den samme filen sendt inn igjen gjennom porten, svarer med det som
    // allerede ble registrert framfor å lage et nytt evidensfunn.
    const outcome = await gateway.importAnswer(
      EXTRACTION_JOB,
      JSON.parse(answer) as Record<string, unknown>,
    )
    expect(outcome.alreadyImported).toBe(true)
    expect(outcome.imported).toBe(false)
  })

  it('avviser et svar fra en annen oppgave uten å spørre databasen', async () => {
    const { gateway } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const assessment = await downloadFor('Syntetisk testpåstand.', sink.files)
    upload(
      await rowFor('Syntetisk testkilde'),
      answerFromTaskFile(assessment, CHATGPT, resultFor('evidence_assessment')),
    )
    expect(
      await within(await rowFor('Syntetisk testkilde')).findByText(/rollen/),
    ).toBeInTheDocument()
  })

  it('avviser et utkast som ikke står ordrett i kildeteksten', async () => {
    const { gateway } = fakeDatabase()
    const sink = collector()
    render(<AgentWorkPage gateway={gateway} saveFile={sink.save} />)

    const file = await downloadFor('Syntetisk testkilde', sink.files)
    const result = resultFor('evidence_extraction')
    const groundings = (result['field_groundings'] as Record<string, unknown>[]).map(
      (grounding, index) =>
        index === 0
          ? {
              ...grounding,
              source_excerpt: 'En setning som ikke står i artikkelen i det hele tatt.',
            }
          : grounding,
    )
    upload(
      await rowFor('Syntetisk testkilde'),
      answerFromTaskFile(file, CHATGPT, { ...result, field_groundings: groundings }),
    )
    expect(
      await within(await rowFor('Syntetisk testkilde')).findByText(/ingenting er registrert/),
    ).toBeInTheDocument()
  })

  it('sier hva som er galt når filen ikke er JSON', async () => {
    const { gateway } = fakeDatabase()
    render(<AgentWorkPage gateway={gateway} saveFile={() => {}} />)

    upload(await rowFor('Syntetisk testkilde'), 'Her er svaret ditt!')
    expect(
      await within(await rowFor('Syntetisk testkilde')).findByText(/ikke gyldig JSON/),
    ).toBeInTheDocument()
  })

  it('sier fra når køen ikke kan leses, framfor å se tom ut', async () => {
    const gateway: AgentWorkGateway = {
      listQueue: () => Promise.reject(new Error('Agentkøen kunne ikke leses: ingen tilgang')),
      readTask: () => Promise.reject(new Error('nei')),
      importAnswer: () => Promise.reject(new Error('nei')),
    }
    render(<AgentWorkPage gateway={gateway} saveFile={() => {}} />)
    expect(await screen.findByText(/ingen tilgang/)).toBeInTheDocument()
    expect(screen.queryByText('Ingen agentoppgaver venter nå.')).not.toBeInTheDocument()
  })
})
