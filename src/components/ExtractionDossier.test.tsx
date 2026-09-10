// ============================================================================
// Grunnlaget kontrolløren ser: hvem som laget verdiene
//
// Den som skal bedømme om verdiene følger av kilden, leser et maskinutkast fra
// en bestemt modell og en bestemt promptmal annerledes enn en kollegas egen
// ekstraksjon (ANTIDEP_CONSTITUTION.md §12, EVIDENCE_PIPELINE.md §46). Panelet
// skal si hvilket av de to det er — og si fravær som fravær når funnet ble ført
// inn i adminflyten uten en agentkjøring.
// ============================================================================

import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { ExtractionSourcePanel } from './ExtractionDossier'
import { verificationItemFixture } from '../agents/test-support'

describe('ExtractionSourcePanel — premissene verdiene ble laget under', () => {
  it('viser leverandøren, modellen, modellversjonen og promptmalen', () => {
    render(
      <ExtractionSourcePanel
        item={verificationItemFixture({
          draftedBy: {
            agentRunId: '77777777-7777-4777-8777-777777777777',
            agentRole: 'evidence_extraction',
            provider: 'en-leverandør',
            model: 'en-modell',
            modelVersion: '2026-09-15',
            promptTemplateVersion: 'evidence-extraction/proposal-drafting/1',
            pipelineVersion: 'antidep-evidence/1',
            startedAt: '2026-09-15T09:00:00+00:00',
          },
        })}
      />,
    )

    expect(screen.getByText('en-leverandør/en-modell 2026-09-15')).toBeInTheDocument()
    expect(
      screen.getByText('Promptmal evidence-extraction/proposal-drafting/1'),
    ).toBeInTheDocument()
    expect(screen.getByText('Pipeline antidep-evidence/1')).toBeInTheDocument()
  })

  // Fravær vises som fravær, aldri som tomme felter eller som noe utledet av
  // ekstraksjonsmetoden (ANTIDEP_CONSTITUTION.md §6).
  it('sier at ingen agentkjøring er registrert når funnet kom fra adminflyten', () => {
    render(<ExtractionSourcePanel item={verificationItemFixture({ draftedBy: null })} />)

    expect(screen.getByText(/Ingen agentkjøring er registrert/)).toBeInTheDocument()
    expect(screen.queryByText(/Promptmal/)).not.toBeInTheDocument()
  })
})
